`timescale 1ns/1ps
//=============================================================================
// amx_tdpbssd -- Intel AMX TDPBSSD: tile dot-product, signed INT8 x signed
// INT8, accumulating into INT32.  C += A @ B.
//
// Semantics taken from the x86 ISA reference, not from memory:
//
//   for m in 0 .. rows-1:
//       tmp := tsrcdest.row[m]
//       for k in 0 .. tsrc1.colsb/4 - 1:
//           for n in 0 .. tsrcdest.colsb/4 - 1:
//               DPBD(tmp.dword[n], tsrc1.row[m].dword[k], tsrc2.row[k].dword[n])
//       tsrcdest.row[m] := tmp
//
//   DPBD(c,x,y):  c := c + sum over b in 0..3 of
//                          sext32(x.byte[b]) * sext32(y.byte[b])
//
// TILE REGISTERS.  tmm0 = A (tsrc1), tmm1 = B (tsrc2), tmm2 = C (tsrcdest).
//
// THE PHYSICAL SHAPE IS NOT THE LOGICAL SHAPE. This is the one thing to get
// right. All three tmm registers are 16 rows x 64 bytes. "B is 64x16" is a
// statement about the LOGICAL matrix; the pseudocode indexes tsrc2.row[k] with
// k in 0..15, so B is VNNI-INTERLEAVED into the same 16x64 register as A:
//
//   tmm0  A  A_phys[m].byte[4k+b] = A[m][4k+b]   plain row-major   16 x 64 INT8
//   tmm1  B  B_phys[k].byte[4n+b] = B[4k+b][n]   INTERLEAVED       64 x 16 INT8
//   tmm2  C  C_phys[m].dword[n]   = C[m][n]      row-major        16 x 16 INT32
//
// Four CONSECUTIVE logical rows of B (4k..4k+3) share one physical row, so that
// byte b of B's dword n lines up with byte b of A's dword k. With K = 4k+b the
// whole thing is
//
//   C[m][n] += sum over K in 0..63 of  A[m][K] * B[K][n]
//
// i.e. a (16,64) @ (64,16) -> (16,16) matrix product, 16,384 INT8 MACs. Get the
// interleave wrong and you still get plausible numbers, which is why the
// testbench checks it against a textbook matmul over UNPACKED matrices and
// mutates the packing to prove that test has teeth.
//
// NOT IMPLEMENTED, deliberately: TILECFG with variable rows/colsb. This is
// locked to the maximum INT8 configuration (rows=16, colsb=64), where the
// reference's write_row_and_zero() and zero_upper_rows() are both no-ops. Also
// no TILELOADD addressing modes (the load port here is a row-at-a-time model),
// no interruptibility, no zero_tilecfg_start().
//
//---------------------------------------------------------------- SATURATION
// SAT=1 IS A DELIBERATE DEVIATION FROM INTEL. The real DPBD is plain modular
// INT32 -- "c := c + p0+p1+p2+p3", no clamp. Both behaviours are built:
//
//   SAT=0   wraps.  BIT-EXACT ISA CONFORMANCE.
//   SAT=1   clamps to [-2^31, 2^31-1].
//
// WHERE the clamp goes is part of the specification, not an implementation
// detail, because saturating addition is NOT associative: folding per step
// versus folding once after a tree over the same four values gives -1 versus
// +1073741824. It goes ONCE PER k-STEP, which is exactly Intel's DPBD call
// boundary, so SAT=0 and SAT=1 differ only in the clamp and never in the
// summation order.
//
// This machine runs k OUTERMOST (all m and n in parallel) while the reference
// runs m outermost. That is still conformant: for a fixed (m,n) the k sequence
// is 0,1,..,15 in both, because m and n index INDEPENDENT accumulators. The
// orders would not agree if the fold were anywhere else.
//
// Note what saturation does NOT reach: one instruction starting from C=0 tops
// out at 64 * 16384 = 1,048,576, which is 21 bits. A SINGLE TDPBSSD CANNOT
// OVERFLOW INT32 (2047x margin). Saturation only matters for the C += chain
// across instructions, so a test that wants to exercise it must preload tmm2
// near the rails -- see tb cases S1..S4.
//
//------------------------------------------------------------- ARCHITECTURE
// 1024 multipliers, 16 cycles: one k per cycle, every m and n in parallel.
// That is 16 m x 16 n x 4 b = 1024 INT8 MACs per cycle, the Sapphire Rapids
// rate. Per cycle:
//
//   B_row    = tmm1[k]                        512b, one 16:1 mux
//   A_dw[m]  = tmm0[m].dword[k]               32b each, a 16:1 mux per row
//   sum4     = sum_b A_dw[m].byte[b] * B_row.dword[n].byte[b]
//   C[m][n] <= fold(C[m][n] + sum4)
//
// Widths are derived, not guessed:
//   product      -128*127 .. -128*-128  = [-16256, +16384]  -> 16 bits signed
//   sum of four  [-65024, +65536]                           -> 18 bits signed
//   accumulator                                                32 bits
// sum4 therefore cannot overflow; only the final add can, which is why the
// clamp sits there and nowhere else.
//
// Tiles are REGISTERS, not ports: 3 x 16 x 512 = 24,576 flops. They cannot be
// ports -- a 384-bit port already measured ~382 buffers of insertion in this
// flow, so 8,192 pins per tile is not an option. They are loaded a row at a
// time over one 512-bit port, which models TILELOADD's row granularity. Holding
// both source tiles means the multiply does zero memory traffic and has free
// random access to any dword, which is what makes k-outermost cost nothing.
//=============================================================================
module amx_tdpbssd #(
    // 0 = wrap (bit-exact Intel). 1 = saturate to INT32 (the deviation).
    // At SAT=0 the overflow detect and the rail muxes fold away entirely.
    parameter integer SAT = 1
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---- tile load, one row per write (models TILELOADD granularity) ------
    // 48 writes fills all three tiles. tile_sel: 0=tmm0/A, 1=tmm1/B, 2=tmm2/C.
    input  wire         tile_we,
    input  wire [1:0]   tile_sel,
    input  wire [3:0]   tile_row,
    input  wire [511:0] tile_wdata,

    // ---- execute ----------------------------------------------------------
    input  wire         start,
    output reg          busy,
    output reg          done,

    // ---- tile read, one row per cycle ------------------------------------
    input  wire [1:0]   rd_sel,
    input  wire [3:0]   rd_row,
    output reg  [511:0] rd_data
);
    // Tile geometry is FIXED by the instruction at the maximum INT8 config.
    // These are localparams, not parameters, on purpose: changing them does not
    // give you a smaller TDPBSSD, it gives you a different instruction.
    localparam integer ROWS   = 16;   // tmm rows
    localparam integer COLSB  = 64;   // tmm bytes per row
    localparam integer DWORDS = COLSB / 4;   // 16 dwords per row -> the n axis
    localparam integer KDW    = COLSB / 4;   // 16 k-steps         -> the k axis
    localparam integer ACC_W  = 32;

    localparam [1:0] SEL_A = 2'd0, SEL_B = 2'd1, SEL_C = 2'd2;

    localparam [1:0] S_IDLE = 2'd0,
                     S_RUN  = 2'd1;

    localparam [ACC_W-1:0] INT32_MAX = 32'h7FFF_FFFF,
                           INT32_MIN = 32'h8000_0000;

    // ---- tile storage -------------------------------------------------------
    // A and B are byte tiles, held as raw 512-bit rows: nothing in this module
    // interprets them except as the byte lanes the ISA names.
    //
    // FLAT PACKED VECTORS, NOT `reg [511:0] tmm_a [0:15]`. An unpacked array is
    // inferred as a MEMORY, which is wrong here in principle and not just for
    // ORFS's SYNTH_MEMORY_MAX_BITS guard (which rejected it outright): the
    // datapath reads a dword from ALL 16 rows of A in the SAME cycle, so this
    // needs 16 concurrent read ports. No SRAM has that. These are registers by
    // necessity, and saying so in the declaration is better than raising a
    // threshold until the tool agrees.
    reg [ROWS*512-1:0] a_flat;   // tmm0
    reg [KDW *512-1:0] b_flat;   // tmm1
    // C is kept as individual dwords rather than packed 512-bit rows so that
    // each accumulator has exactly ONE procedural driver. Packing it would put
    // 16 always blocks on different bit ranges of the same array element, which
    // is not something to rely on a synthesis tool to accept.
    reg [ACC_W-1:0] cacc [0:ROWS-1][0:DWORDS-1];

    reg [1:0]            state;
    reg [3:0]            kcnt;      // the k-step, 0..15

    // ---- control ------------------------------------------------------------
    wire run    = (state == S_RUN);
    wire k_last = (kcnt == (KDW-1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            kcnt  <= 4'd0;
            busy  <= 1'b0;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    // DONE is not terminal: accepting start here is what makes
                    // back-to-back instructions work without a reset, which is
                    // the whole point of a C += chain. See tb case C1.
                    if (start) begin
                        kcnt  <= 4'd0;
                        busy  <= 1'b1;
                        state <= S_RUN;
                    end
                end
                S_RUN: begin
                    if (k_last) begin
                        state <= S_IDLE;
                        busy  <= 1'b0;
                        done  <= 1'b1;
                    end else begin
                        kcnt <= kcnt + 4'd1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // ---- tile loads ---------------------------------------------------------
    // A and B have a single driver each and no read-modify-write, so one block
    // serves both. C's loads live with C's accumulate, below, because they share
    // a driver.
    always @(posedge clk) begin
        // Variable-base part-select writes: one decoded enable per row.
        if (tile_we && tile_sel == SEL_A) a_flat[tile_row*512 +: 512] <= tile_wdata;
        if (tile_we && tile_sel == SEL_B) b_flat[tile_row*512 +: 512] <= tile_wdata;
    end

    // ---- operand fetch for this k-step -------------------------------------
    // One 16:1 mux over 512 bits for B, and one 16:1 mux over 32 bits per row
    // of A. This is the entire cost of holding the tiles in registers.
    wire [511:0] b_row = b_flat[kcnt*512 +: 512];

    // ---- the 1024 multipliers ----------------------------------------------
    genvar gm, gn, gb;
    generate
        for (gm = 0; gm < ROWS; gm = gm + 1) begin : g_m
            // dword k of A row gm. kcnt is a variable base, gm a constant index.
            // gm is a genvar (constant), kcnt a register: constant row offset
            // plus a variable dword offset into the flat tile.
            wire [31:0] a_dw = a_flat[gm*512 + kcnt*32 +: 32];

            for (gn = 0; gn < DWORDS; gn = gn + 1) begin : g_n
                wire [31:0] b_dw = b_row[gn*32 +: 32];

                // Four INT8 x INT8 products. The lane slices are declared
                // `signed` rather than wrapped in $signed() so the sign
                // extension is a property of the declaration and cannot be
                // lost by editing an expression. Dropping it here is the INT8
                // analogue of unsigned INT4 slicing -- tb case X3 mutates it.
                wire signed [15:0] prod [0:3];
                for (gb = 0; gb < 4; gb = gb + 1) begin : g_b
                    wire signed [7:0] a_b = a_dw[gb*8 +: 8];
                    wire signed [7:0] b_b = b_dw[gb*8 +: 8];
                    assign prod[gb] = a_b * b_b;
                end

                // 18 bits is exact: four products in [-16256,+16384] cannot
                // leave [-65024,+65536]. No fold needed here.
                wire signed [17:0] sum4 = prod[0] + prod[1] + prod[2] + prod[3];

                // 33 bits so the 32-bit overflow is visible rather than lost.
                wire signed [ACC_W-1:0] c_cur = cacc[gm][gn];
                wire signed [ACC_W:0]   raw   = c_cur + sum4;

                // Overflow of the INT32 range, from the top two bits: for a
                // 33-bit sum of two 32-bit signed values, raw[32] != raw[31]
                // is exactly the out-of-range condition, and raw[32] is the
                // sign to clamp towards. Cheaper and less error-prone than
                // comparing against the rail constants.
                wire ovf  = raw[ACC_W] ^ raw[ACC_W-1];
                wire [ACC_W-1:0] rail = raw[ACC_W] ? INT32_MIN : INT32_MAX;
                wire [ACC_W-1:0] folded =
                        ((SAT != 0) && ovf) ? rail : raw[ACC_W-1:0];

                // FLAT if/else-if, NOT NESTED. Same lesson as mac_array's
                // accumulator: yosys's flop inference is shape-sensitive, and a
                // leading branch whose condition is a plain load becomes the
                // flop's enable rather than a data mux. Do not "tidy" this into
                // a nested conditional.
                always @(posedge clk) begin
                    if (tile_we && tile_sel == SEL_C && tile_row == gm)
                        cacc[gm][gn] <= tile_wdata[gn*32 +: 32];
                    else if (run)
                        cacc[gm][gn] <= folded;
                end
            end
        end
    endgenerate

    // ---- tile read ----------------------------------------------------------
    // C is reassembled from its dwords here; A and B are already rows.
    integer ci;
    reg [511:0] c_row;
    always @* begin
        c_row = {512{1'b0}};
        for (ci = 0; ci < DWORDS; ci = ci + 1)
            c_row[ci*32 +: 32] = cacc[rd_row][ci];
    end

    always @* begin
        case (rd_sel)
            SEL_A:   rd_data = a_flat[rd_row*512 +: 512];
            SEL_B:   rd_data = b_flat[rd_row*512 +: 512];
            default: rd_data = c_row;
        endcase
    end

    // ---- elaboration-time checks -------------------------------------------
    initial begin
        if (SAT != 0 && SAT != 1) begin
            $display("FATAL: SAT must be 0 or 1 (got %0d)", SAT);
            $finish;
        end
        if (COLSB != 4*DWORDS || KDW != DWORDS) begin
            $display("FATAL: tile geometry is inconsistent (COLSB=%0d DWORDS=%0d KDW=%0d)",
                     COLSB, DWORDS, KDW);
            $finish;
        end
    end

    // ---- runtime check: a load during execute ------------------------------
    // The tiles are read live by the datapath, so writing one mid-instruction
    // changes the operands under the multiply and produces a result that
    // corresponds to no well-defined C += A@B. Say so rather than let it look
    // like an arithmetic bug.
    //
    // `ifndef YOSYS is load-bearing: without it yosys lowers $display into a
    // $print cell that survives into the netlist and reaches ORFS, which has no
    // standard cell for it. Icarus does not define YOSYS, so the check stays
    // live where it is useful.
`ifndef YOSYS
    always @(posedge clk) begin
        if (rst_n && tile_we && state == S_RUN)
            $display("FATAL: t=%0t tile_we during S_RUN -- tiles are read live; the result is undefined.",
                     $time);
    end
`endif

endmodule
