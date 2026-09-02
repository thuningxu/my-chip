//=============================================================================
// amx_fp8 -- Intel AMX-FP8 (Diamond Rapids): all four mix-and-match FP8 tile
// dot-product instructions in one datapath.
//
//   op   mnemonic     src1 (A)      src2 (B)
//   00   TDPBF8PS     BF8 = E5M2    BF8 = E5M2
//   01   TDPBHF8PS    BF8 = E5M2    HF8 = E4M3
//   10   TDPHBF8PS    HF8 = E4M3    BF8 = E5M2
//   11   TDPHF8PS     HF8 = E4M3    HF8 = E4M3
//
// C[16][16] fp32 += A[16][64] fp8 @ B[64][16] fp8, i.e. 16,384 MACs, in 20
// cycles. op[1] is "A is HF8" and op[0] is "B is HF8", so the encoding reads as
// the mnemonic and the four instructions differ by two bits into two decoders.
//
//------------------------------------------------------------ WHY THIS EXISTS
// The repo's other two 1024-MAC designs are both integer. amx_tdpbssd is
// BROADCAST + in-cell INT32 accumulator; tpu_mmu is SYSTOLIC + external
// accumulator. tpu_mmu's merge commit records the flaw in that comparison: it
// moved TWO variables at once, so its result cannot be attributed to either.
//
// This design moves ONE. It reuses amx_tdpbssd's operand delivery exactly -- the
// same 16x64 tiles held as registers, the same 16:1 mux on B's row, the same
// per-row 16:1 mux on A's dword, the same k-outermost schedule with every m and
// n in parallel. The only thing that changes is the arithmetic: an exact INT8
// product tree plus one INT32 accumulate becomes four exact FP8 products plus
// four independent IEEE FP32 accumulates. So the measured delta IS the
// arithmetic.
//
//----------------------------------------------------- WHAT THE ISA SAYS, AND
//----------------------------------------------------- WHERE IT IS UNSETTLED
// Established from three sources, which do not agree. Intel's own patent
// (EP4398097A2) says the four byte-lane products are accumulated "SEPARATELY" --
// a sum of K first products, a sum of K second products, and so on, combined
// with C at the end. That is what is built here: four independent FP32
// accumulators per output element, RNE rounding, DAZ on inputs, FTZ on results.
// Bochs instead keeps two running halves with a pairwise tree, which looks like
// its BF16 code shape (2 elements/dword -> 2 accumulators) carried over to FP8's
// four. LLVM's amxfp8intrin.h shows one wide accumulator, but wraps its fp8
// operands in INT64(...) copy-pasted from the INT8 header, so it was discarded.
//
// GENUINELY UNRESOLVED: the order the four lane sums are combined at the end. A
// balanced tree is used here, on hardware grounds -- two adder levels instead of
// three, and three epilogue cycles instead of four. It matters: tb/fp8_golden.py
// measures that the balanced tree and a sequential chain disagree on about 23%
// of output elements, and prints that number on every run. So this design is
// bit-exact for every finite and infinite input GIVEN the balanced tree, and the
// model can switch to sequential with one flag if better documentation appears.
// That is a known, quantified gap, not a silent assumption.
//
//---------------------------------------------------------- ONE DEVIATION MORE
// NaN results are canonicalised to 0x7FC00000 rather than propagating a source
// NaN's payload -- see rtl/fp32_add.v. Payload muxing across 1024 adders buys
// nothing an ML datapath can use.
//
//---------------------------------------------------------------- ARCHITECTURE
// 1024 fp8 multipliers and 1024 FP32 adders, one k-step per cycle:
//
//   ccnt 0..15   adder b of cell (m,n):  lacc[b] <= lacc[b] + prod[b]
//   ccnt 16      adder 0: lacc[0] + lacc[1] -> lacc[0]
//                adder 2: lacc[2] + lacc[3] -> lacc[2]
//   ccnt 17      adder 0: lacc[0] + lacc[2] -> lacc[0]
//   ccnt 18      adder 0: lacc[0] + C[m][n] -> C[m][n]
//
// THE EPILOGUE REUSES THE LANE ADDERS, and the way it does so is the point.
// lacc[b] feeds operand A of adder b DIRECTLY, with no mux, in every cycle
// including the epilogue -- only operand B is muxed, and in the accumulate phase
// operand B is a product, which is not in the loop. So the feedback path is
// exactly `lacc[b] -> fp32_add -> lacc[b]` and nothing else. FP32 add is
// operand-symmetric, which is what makes that free. 768 adders saved against
// giving the epilogue its own.
//
// The lane accumulators are cleared on the start edge, not by a dedicated cycle,
// so the clear is free. And it must be a real clear rather than "write the first
// product instead of accumulating": lane <= prod would store -0 where
// (+0) + (-0) = +0 is required, and that leaks into the result when C is -0.
//
// LANES IS NOT A PARAMETER, deliberately. Serialising lanes would be bit-exact
// (the accumulators never interact until the epilogue) and would cut the adder
// count proportionally, but sharing an adder between lanes requires muxing
// operand A as well -- which puts a mux inside the accumulate loop and
// contaminates the one measurement this design exists to make. If capacity
// forces a smaller build, that decision belongs with a real synthesised cell
// count in hand.
//
//----------------------------------------------------------- WHAT IS NOT HERE
// TILECFG with variable rows/colsb: locked to the maximum FP8 configuration
// (rows=16, colsb=64), where the reference's write_row_and_zero() and
// zero_upper_rows() are both no-ops. No TILELOADD addressing modes (the load
// port is a row-at-a-time model), no interruptibility.
//
// Not taken, and worth measuring later rather than folding in now: the
// accumulate adder's second operand is a product with only 8 significant bits,
// so a narrow-operand adder would be cheaper than the general fp32_add. The
// epilogue reuse is what forces generality.
//
//========================================================== ACC=1, THE X2 ARM
// Everything above describes ACC=0, which is what row p1 shipped and the only
// mode that claims ISA bit-exactness. ACC=1 replaces the four rounded FP32 lane
// accumulators with ONE WIDE TRUNCATING FIXED-POINT accumulator per output
// element, rounded exactly once at write-back.
//
// It is a DELIBERATE DEVIATION, in the same spirit as SAT=1 in amx_tdpbssd, and
// it is MORE accurate rather than equal: 64 sequential FP32 roundings accumulate
// more error than one truncation. Measured against the exact rational sum over
// the same tiles, TDPHF8PS worst relative error is 5.72e-08 at ACC=1 FX_W=52
// versus 4.09e-06 at ACC=0 -- 71x better, and 0/256 elements incorrectly rounded.
// ACC=1 differs from ACC=0 on 106 of 256 elements, so it is visibly a deviation
// and not a refactor.
//
// Per output element (m,n):
//
//   ref  = maxe(A row m) + maxe(B col n) + 1        the alignment reference
//   low  = ref + 8 - FX_W                          the accumulator's LSB
//   term = floor(sprod * 2^(FX_W-15-d)),  d = ref-1-(ea+eb) >= 0
//   acc += t0+t1+t2+t3     3 CSA levels + one FX_W carry-propagate add
//   epilogue: fx2fp32(acc, low), specials override, then ONE fp32_add for +C
//
// The +8 is real carry headroom, not slack: 64 terms of the largest product
// reach 0.879 x 2^(FX_W-1), so the accumulator is 13.8% from its rail in the
// worst constructible case. fp8_golden.py checks for overflow on every trial
// rather than trusting that algebra.
//
// WHY THE REFERENCE IS COMPUTED AT `start` FROM THE STORED TILES, and not
// maintained incrementally on tile writes as first planned: a running max is
// WRONG when a tile is reloaded with smaller values, and it would have made the
// answer depend on the order rows were written. It also puts a 6-level max tree
// on an input-port path. Computing it on the start edge from a_flat/b_flat is
// reg-to-reg, order-independent, and removes that whole class of bug for 32
// instances of maxmag64.
//
// ACC=1 does NOT instantiate fp8_mul: the FP32 product is never used, so the arm
// takes sig4/exp straight from the shared fp8_dec edge decoders and does its own
// 4x4 multiply. The decoders and the operand delivery are IDENTICAL between the
// two arms, which is what keeps the ACC=0/ACC=1 comparison about the accumulate.
//
// ACC=1 is 19 cycles, not 20: its epilogue needs two cycles (convert, then +=C)
// where ACC=0 needs three. Report that difference rather than smoothing it over
// -- p1's "identical cycles to amx_tdpbssd" claim does not carry to ACC=1.
//
// FX_W must be at least 33. Below that the epilogue's {{(FX_W-32){1'b0}}, epi}
// is a zero- or negative-width replication and elaboration fails, which is a
// better guard than a runtime check that could never run. fx2fp32 independently
// requires >= 26. Verified at 40/44/48/52/56.
//
// NAMING, because there are two widths and they are easy to confuse: ACC_W is
// and remains 32, the FP32 dword width used by C, the products and ACC=0's lane
// accumulators. FX_W is the fixed-point accumulator width, and it is what gets
// passed to fx2fp32's own ACC_W parameter.
//=============================================================================
module amx_fp8 #(
    // 1 registers rd_data, adding one cycle of READBACK latency.
    //
    // Defaulted ON because both prior designs MEASURED this: a multi-level
    // readback mux driving an output port becomes the critical path, and roughly
    // half of its arrival is clock insertion delay that CANNOT cancel, because a
    // port has no capture flop to contribute an offsetting delay. Carried from
    // the start rather than rediscovered a third time. Both states stay
    // buildable so the claim is re-measured here, not assumed.
    parameter integer RD_REG = 1,

    // 0 = four separately-rounded IEEE FP32 lane accumulators (row p1, the ISA
    //     reading from Intel's patent EP4398097A2). The ONLY conformant mode.
    // 1 = one wide truncating fixed-point accumulator per element, rounded once
    //     at write-back. Cheaper, more accurate, and a stated deviation.
    parameter integer ACC = 0,

    // Fixed-point accumulator width; used only when ACC=1. 52 from a measured
    // sweep against the exact rational sum: 44 is bare parity with ACC=0, 48 is
    // 29x better but not exact, 52 matches the exact sum on 100% of trials, 56 is
    // exact and wasteful. Must be >= 33 -- see the header.
    parameter integer FX_W = 52
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---- tile load, one row per write (models TILELOADD granularity) ------
    // tile_sel: 0=tmm0/A, 1=tmm1/B, 2=tmm2/C. A and B are fp8 byte tiles; C is
    // 16 FP32 dwords per row.
    input  wire         tile_we,
    input  wire [1:0]   tile_sel,
    input  wire [3:0]   tile_row,
    input  wire [511:0] tile_wdata,

    // ---- execute ----------------------------------------------------------
    input  wire [1:0]   op,
    input  wire         start,
    output reg          busy,
    output reg          done,

    // ---- tile read, one row per cycle ------------------------------------
    input  wire [1:0]   rd_sel,
    input  wire [3:0]   rd_row,
    output reg  [511:0] rd_data
);
    // Tile geometry is FIXED by the instruction. localparams, not parameters:
    // changing them does not give a smaller AMX-FP8, it gives a different
    // instruction.
    localparam integer ROWS   = 16;          // tmm rows
    localparam integer COLSB  = 64;          // tmm bytes per row
    localparam integer DWORDS = COLSB / 4;   // 16 dwords per row -> the n axis
    localparam integer KDW    = COLSB / 4;   // 16 k-steps        -> the k axis
    localparam integer LANE_N = 4;           // fp8 per dword -> four accumulators
    localparam integer ACC_W  = 32;

    localparam [1:0] SEL_A = 2'd0, SEL_B = 2'd1, SEL_C = 2'd2;
    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1;

    // The four instructions, for readers and for the testbench.
    localparam [1:0] OP_TDPBF8PS  = 2'b00,
                     OP_TDPBHF8PS = 2'b01,
                     OP_TDPHBF8PS = 2'b10,
                     OP_TDPHF8PS  = 2'b11;

    // Epilogue phases. ccnt reaches 18, so 5 bits.
    //
    //   ACC=0   16: lacc0+=lacc1, lacc2+=lacc3   17: lacc0+=lacc2   18: C+=lacc0
    //   ACC=1   16: acc -> FP32 (fx2fp32)        17: C += it            --
    //
    // ACC=1's epilogue is one cycle shorter, so the instruction is 19 cycles
    // rather than 20. LASTC, not EP2, is what ends the instruction.
    localparam integer EP0 = KDW;        // 16
    localparam integer EP1 = KDW + 1;    // 17
    localparam integer EP2 = KDW + 2;    // 18, ACC=0 only
    localparam integer CW  = 5;
    localparam integer LASTC = (ACC == 0) ? EP2 : EP1;

    // ---- ACC=1 derived widths ----------------------------------------------
    // PW is the width the signed 9-bit product is pre-shifted into before the one
    // variable (right) shift. 9 significant bits + (FX_W-15) of constant left
    // shift = FX_W-6. The largest product is 225 < 256, so the value always fits
    // with the sign bit landing exactly at PW-1.
    localparam integer PW = FX_W - 6;
    // low = ref + 8 - FX_W, written as a subtraction so no `signed` keyword is
    // needed anywhere (see the fp8_mul header on STA-0171).
    localparam [9:0] LOW_SUB = FX_W - 8;

    localparam [31:0] QNAN32 = 32'h7FC0_0000,
                      PINF32 = 32'h7F80_0000,
                      NINF32 = 32'hFF80_0000;

    // ---- tile storage -------------------------------------------------------
    // FLAT PACKED VECTORS, not `reg [511:0] tmm [0:15]`. An unpacked array is
    // inferred as a MEMORY, which trips ORFS's SYNTH_MEMORY_MAX_BITS and is
    // wrong in principle: the datapath reads a dword from ALL 16 rows of A in
    // the SAME cycle, so it would need 16 concurrent read ports. No SRAM has
    // that. Same reasoning as rtl/amx_tdpbssd.v:164-181.
    reg [ROWS*512-1:0] a_flat;   // tmm0
    reg [KDW *512-1:0] b_flat;   // tmm1
    // C is kept as individual dwords so each accumulator has exactly ONE
    // procedural driver.
    reg [ACC_W-1:0] cacc [0:ROWS-1][0:DWORDS-1];

    reg [1:0]     state;
    reg [CW-1:0]  ccnt;
    reg [1:0]     op_r;          // latched at start, so it cannot move mid-op

    // ---- control ------------------------------------------------------------
    wire run    = (state == S_RUN);
    wire c_last = (ccnt == LASTC[CW-1:0]);

    // kcnt is only meaningful during the accumulate phase; in the epilogue the
    // low bits of ccnt select a k nobody uses.
    wire [3:0] kcnt      = ccnt[3:0];
    wire       acc_phase = run && (ccnt < KDW[CW-1:0]);
    wire       ep0       = run && (ccnt == EP0[CW-1:0]);
    wire       ep1       = run && (ccnt == EP1[CW-1:0]);
    wire       ep2       = run && (ccnt == EP2[CW-1:0]);

    // ACC=1 reuses the same two cycles under names that say what they do there.
    // Aliases rather than new comparators: ccnt 16 and 17 are already decoded, and
    // under ACC=1 ccnt never reaches 18 so ep2 is dead.
    wire       ep_cvt    = ep0;      // accumulator -> FP32
    wire       ep_adc    = ep1;      // C += it

    // Clearing the lane accumulators on the START edge costs no cycle: the edge
    // that moves IDLE->RUN is already there, and ccnt==0 executes on the edge
    // after it.
    wire lane_clr = (state == S_IDLE) && start;

    wire fmt_a = op_r[1];        // 1 = HF8/E4M3
    wire fmt_b = op_r[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            ccnt  <= {CW{1'b0}};
            busy  <= 1'b0;
            done  <= 1'b0;
            op_r  <= 2'b00;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    // done is not terminal: accepting start here is what makes
                    // back-to-back C += chains work without a reset.
                    if (start) begin
                        ccnt  <= {CW{1'b0}};
                        busy  <= 1'b1;
                        op_r  <= op;
                        state <= S_RUN;
                    end
                end
                S_RUN: begin
                    if (c_last) begin
                        state <= S_IDLE;
                        busy  <= 1'b0;
                        done  <= 1'b1;
                    end else begin
                        ccnt <= ccnt + {{(CW-1){1'b0}}, 1'b1};
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // ---- tile loads ---------------------------------------------------------
    // A and B have one driver each and no read-modify-write, so one block serves
    // both. C's loads live with C's accumulate because they share a driver.
    always @(posedge clk) begin
        if (tile_we && tile_sel == SEL_A) a_flat[tile_row*512 +: 512] <= tile_wdata;
        if (tile_we && tile_sel == SEL_B) b_flat[tile_row*512 +: 512] <= tile_wdata;
    end

    // ---- operand fetch, identical in shape to amx_tdpbssd -------------------
    // One 16:1 mux over 512 bits for B's row, and one 16:1 mux over 32 bits per
    // row of A. This is the entire cost of holding the tiles in registers, and
    // it is deliberately the same structure as the INT8 design so the comparison
    // isolates the arithmetic.
    wire [511:0]        b_row = b_flat[kcnt*512 +: 512];
    wire [ROWS*32-1:0]  a_dw_all;

    // ---- fp8 decode ON THE EDGES, shared by all 256 cells -------------------
    // 16 rows x 4 lanes for A and 16 dwords x 4 lanes for B = 128 decoders, not
    // one inside each of the 1024 multipliers. Same reasoning as sharing the
    // operand mux; saves roughly 1900 decoders.
    //
    // Flat packed vectors again, indexed [i*W +: W] with i = row*LANE_N + lane.
    wire [ROWS*LANE_N-1:0]     ad_sgn, ad_zero, ad_inf, ad_nan;
    wire [ROWS*LANE_N*6-1:0]   ad_exp;
    wire [ROWS*LANE_N*4-1:0]   ad_sig;
    wire [DWORDS*LANE_N-1:0]   bd_sgn, bd_zero, bd_inf, bd_nan;
    wire [DWORDS*LANE_N*6-1:0] bd_exp;
    wire [DWORDS*LANE_N*4-1:0] bd_sig;

    genvar gm, gn, gb, gk;
    generate
        for (gm = 0; gm < ROWS; gm = gm + 1) begin : g_adw
            // dword kcnt of A row gm: constant row offset, variable dword.
            assign a_dw_all[gm*32 +: 32] = a_flat[gm*512 + kcnt*32 +: 32];
            for (gb = 0; gb < LANE_N; gb = gb + 1) begin : g_adec
                fp8_dec u_dec (
                    .b_in    (a_dw_all[gm*32 + gb*8 +: 8]),
                    .fmt     (fmt_a),
                    .sgn     (ad_sgn [gm*LANE_N + gb]),
                    .exp     (ad_exp [(gm*LANE_N + gb)*6 +: 6]),
                    .sig4    (ad_sig [(gm*LANE_N + gb)*4 +: 4]),
                    .is_zero (ad_zero[gm*LANE_N + gb]),
                    .is_inf  (ad_inf [gm*LANE_N + gb]),
                    .is_nan  (ad_nan [gm*LANE_N + gb])
                );
            end
        end
        for (gn = 0; gn < DWORDS; gn = gn + 1) begin : g_bdec_n
            for (gb = 0; gb < LANE_N; gb = gb + 1) begin : g_bdec
                fp8_dec u_dec (
                    .b_in    (b_row[gn*32 + gb*8 +: 8]),
                    .fmt     (fmt_b),
                    .sgn     (bd_sgn [gn*LANE_N + gb]),
                    .exp     (bd_exp [(gn*LANE_N + gb)*6 +: 6]),
                    .sig4    (bd_sig [(gn*LANE_N + gb)*4 +: 4]),
                    .is_zero (bd_zero[gn*LANE_N + gb]),
                    .is_inf  (bd_inf [gn*LANE_N + gb]),
                    .is_nan  (bd_nan [gn*LANE_N + gb])
                );
            end
        end
    endgenerate

    // ---- ACC=1: the alignment reference, latched on the start edge ----------
    // Unbiased exponent per A row and per logical B column, 6 bits each. Declared
    // unconditionally so the cell arms can name them without reaching into a
    // generate scope; under ACC=0 nothing drives or reads them and synthesis
    // removes them.
    reg [ROWS  *6-1:0] maxe_a;
    reg [DWORDS*6-1:0] maxe_b;

    // Unbiased exponent of a max-magnitude byte[6:0]. Identical arithmetic to
    // fp8_dec's `exp` output -- if these two ever disagree the reference is wrong
    // for one format only, which is the hardest kind of bug to see.
    function [5:0] mag_exp;
        input [6:0] mag;
        input       fmt;
        begin
            mag_exp = fmt ? ($signed({2'b00, mag[6:3]}) - $signed(6'd7))
                          : ($signed({1'b0,  mag[6:2]}) - $signed(6'd15));
        end
    endfunction

    generate
        if (ACC != 0) begin : g_ref
            wire [ROWS  *7-1:0] mxa;
            wire [DWORDS*7-1:0] mxb;

            // A row m is one physical row: 64 contiguous bytes.
            for (gm = 0; gm < ROWS; gm = gm + 1) begin : g_mxa
                maxmag64 u_mx (.bytes(a_flat[gm*512 +: 512]),
                               .mx   (mxa[gm*7 +: 7]));
            end

            // A logical B column is SCATTERED: bytes 4n..4n+3 of every one of the
            // 16 physical rows. Gathered into a 512-bit vector so the same max
            // tree serves both axes -- 32 instances of one module, not two.
            for (gn = 0; gn < DWORDS; gn = gn + 1) begin : g_mxb
                wire [511:0] colb;
                for (gk = 0; gk < KDW; gk = gk + 1) begin : g_k
                    for (gb = 0; gb < LANE_N; gb = gb + 1) begin : g_b
                        assign colb[(gk*LANE_N + gb)*8 +: 8] =
                                   b_flat[gk*512 + gn*32 + gb*8 +: 8];
                    end
                end
                maxmag64 u_mx (.bytes(colb), .mx(mxb[gn*7 +: 7]));
            end

            // The bias is subtracted HERE, once per row/column on the single
            // winner, rather than on all 64 candidates -- which is the whole
            // reason the max can be taken over raw bytes before the format is
            // known.
            //
            // `op`, NOT `op_r`. op_r is latched on this very edge and still holds
            // the PREVIOUS instruction's formats, so using it would decode the
            // reference with the wrong bias on every instruction whose format
            // differs from its predecessor -- a bug that hides completely in any
            // test that runs one op at a time.
            for (gm = 0; gm < ROWS; gm = gm + 1) begin : g_rega
                always @(posedge clk)
                    if (lane_clr) maxe_a[gm*6 +: 6] <= mag_exp(mxa[gm*7 +: 7], op[1]);
            end
            for (gn = 0; gn < DWORDS; gn = gn + 1) begin : g_regb
                always @(posedge clk)
                    if (lane_clr) maxe_b[gn*6 +: 6] <= mag_exp(mxb[gn*7 +: 7], op[0]);
            end
        end
    endgenerate

    // ---- the 256 cells, four lanes each ------------------------------------
    generate
        for (gm = 0; gm < ROWS; gm = gm + 1) begin : g_m
            for (gn = 0; gn < DWORDS; gn = gn + 1) begin : g_n

                // BOTH arms drive these two, and ONE cacc flop block below
                // consumes them. That keeps the tile-load path -- which is
                // identical for both -- written exactly once, so a fix to it
                // cannot land in one arm and not the other.
                wire [ACC_W-1:0] c_next;
                wire             c_wr;

              if (ACC == 0) begin : g_p1
                // Four FP32 lane accumulators, packed so ONE always block drives
                // them. Cleared to +0 on the start edge.
                reg  [LANE_N*ACC_W-1:0] lacc;
                wire [LANE_N*ACC_W-1:0] prod;
                wire [LANE_N*ACC_W-1:0] sum;
                wire [LANE_N-1:0]       len;

                for (gb = 0; gb < LANE_N; gb = gb + 1) begin : g_lane

                    fp8_mul u_mul (
                        .a_sgn  (ad_sgn [gm*LANE_N + gb]),
                        .a_exp  (ad_exp [(gm*LANE_N + gb)*6 +: 6]),
                        .a_sig  (ad_sig [(gm*LANE_N + gb)*4 +: 4]),
                        .a_zero (ad_zero[gm*LANE_N + gb]),
                        .a_inf  (ad_inf [gm*LANE_N + gb]),
                        .a_nan  (ad_nan [gm*LANE_N + gb]),
                        .b_sgn  (bd_sgn [gn*LANE_N + gb]),
                        .b_exp  (bd_exp [(gn*LANE_N + gb)*6 +: 6]),
                        .b_sig  (bd_sig [(gn*LANE_N + gb)*4 +: 4]),
                        .b_zero (bd_zero[gn*LANE_N + gb]),
                        .b_inf  (bd_inf [gn*LANE_N + gb]),
                        .b_nan  (bd_nan [gn*LANE_N + gb]),
                        .y      (prod[gb*ACC_W +: ACC_W])
                    );

                    // OPERAND B ONLY IS MUXED. Operand A is always lacc[gb],
                    // straight out of the flop, so the accumulate feedback path
                    // gains nothing. Named generate arms, and only the lanes
                    // that need extra sources get any mux at all: lanes 1 and 3
                    // are pure wires.
                    wire [ACC_W-1:0] opb;
                    if (gb == 0) begin : g_opb0
                        assign opb = ep0 ? lacc[1*ACC_W +: ACC_W]
                                   : ep1 ? lacc[2*ACC_W +: ACC_W]
                                   : ep2 ? cacc[gm][gn]
                                         : prod[0*ACC_W +: ACC_W];
                    end else if (gb == 2) begin : g_opb2
                        assign opb = ep0 ? lacc[3*ACC_W +: ACC_W]
                                         : prod[2*ACC_W +: ACC_W];
                    end else begin : g_opb_plain
                        assign opb = prod[gb*ACC_W +: ACC_W];
                    end

                    fp32_add u_add (
                        .a (lacc[gb*ACC_W +: ACC_W]),
                        .b (opb),
                        .y (sum[gb*ACC_W +: ACC_W])
                    );

                    // Lane write enables. Lane 0 also runs in EP0 and EP1, lane
                    // 2 in EP0; lanes 1 and 3 only accumulate. EP2's result goes
                    // to C, not to a lane.
                    //
                    // LANES 1 AND 3 ARE DEAD FROM EP0 ONWARD -- nothing reads
                    // them again, because EP0 consumes them combinationally on
                    // the same edge that overwrites lane 0 and lane 2. So
                    // enabling them during the epilogue is unobservable, which
                    // mutation testing confirmed: widening their enable to
                    // `acc_phase | ep0` passes every test. Keeping the enable
                    // tight is therefore an area and power choice, not a
                    // correctness one -- said plainly so the surviving mutation
                    // is not mistaken for a gap in the testbench.
                    if (gb == 0) begin : g_en0
                        assign len[gb] = acc_phase | ep0 | ep1;
                    end else if (gb == 2) begin : g_en2
                        assign len[gb] = acc_phase | ep0;
                    end else begin : g_en_plain
                        assign len[gb] = acc_phase;
                    end
                end

                // FLAT if/else-if PER LANE, never nested. yosys's flop inference
                // is shape-sensitive: a leading branch whose condition is a
                // plain load becomes the flop's enable rather than a data mux,
                // and nesting this cost 3.1x in cells when measured on
                // mac_array. Do not "tidy" it into a nested conditional.
                always @(posedge clk) begin
                    if (lane_clr)    lacc[0*ACC_W +: ACC_W] <= {ACC_W{1'b0}};
                    else if (len[0]) lacc[0*ACC_W +: ACC_W] <= sum[0*ACC_W +: ACC_W];
                    if (lane_clr)    lacc[1*ACC_W +: ACC_W] <= {ACC_W{1'b0}};
                    else if (len[1]) lacc[1*ACC_W +: ACC_W] <= sum[1*ACC_W +: ACC_W];
                    if (lane_clr)    lacc[2*ACC_W +: ACC_W] <= {ACC_W{1'b0}};
                    else if (len[2]) lacc[2*ACC_W +: ACC_W] <= sum[2*ACC_W +: ACC_W];
                    if (lane_clr)    lacc[3*ACC_W +: ACC_W] <= {ACC_W{1'b0}};
                    else if (len[3]) lacc[3*ACC_W +: ACC_W] <= sum[3*ACC_W +: ACC_W];
                end

                assign c_next = sum[0*ACC_W +: ACC_W];
                assign c_wr   = ep2;

              end else begin : g_fx
                //=============================================================
                // ACC=1 -- one wide truncating fixed-point accumulator.
                //=============================================================
                // Reference exponent for THIS element, combinational from the two
                // registered per-row / per-column maxima. 256 small adders rather
                // than 256 more registers.
                //
                // 8 bits signed: maxe is in [-15,16] per axis (E5M2's all-ones
                // exponent field reaches 16), so ref lands in [-29,33].
                wire signed [7:0] refe =
                      $signed({{2{maxe_a[gm*6+5]}}, maxe_a[gm*6 +: 6]})
                    + $signed({{2{maxe_b[gn*6+5]}}, maxe_b[gn*6 +: 6]})
                    + 8'sd1;
                // The accumulator's LSB position, which is fx2fp32's `low`.
                // ref - (FX_W-8), in [-73,-11] at FX_W=52.
                wire signed [9:0] lowe = $signed({{2{refe[7]}}, refe})
                                       - $signed(LOW_SUB);

                reg  [FX_W-1:0]        acc;
                reg                    saw_nan, saw_pinf, saw_ninf;
                wire [LANE_N*FX_W-1:0] term;
                wire [LANE_N-1:0]      l_nan, l_pinf, l_ninf;

                for (gb = 0; gb < LANE_N; gb = gb + 1) begin : g_lane
                    // NO fp8_mul HERE. The FP32 product is never used under
                    // ACC=1, so this arm takes sig4/exp straight from the shared
                    // edge decoders. The decoders themselves are common to both
                    // arms, which is what keeps the comparison about the
                    // accumulate rather than about operand delivery.
                    wire       asg = ad_sgn [gm*LANE_N + gb];
                    wire       bsg = bd_sgn [gn*LANE_N + gb];
                    wire [5:0] aex = ad_exp [(gm*LANE_N + gb)*6 +: 6];
                    wire [5:0] bex = bd_exp [(gn*LANE_N + gb)*6 +: 6];
                    wire [3:0] asi = ad_sig [(gm*LANE_N + gb)*4 +: 4];
                    wire [3:0] bsi = bd_sig [(gn*LANE_N + gb)*4 +: 4];
                    wire       azr = ad_zero[gm*LANE_N + gb];
                    wire       bzr = bd_zero[gn*LANE_N + gb];
                    wire       ain = ad_inf [gm*LANE_N + gb];
                    wire       bin = bd_inf [gn*LANE_N + gb];
                    wire       ana = ad_nan [gm*LANE_N + gb];
                    wire       bna = bd_nan [gn*LANE_N + gb];

                    // Classification in fp8_mul's precedence: NaN (which includes
                    // Inf*0) beats Inf, which beats zero. Matches fx_accumulate()
                    // in tb/fp8_golden.py, whose if/elif chain is the same order.
                    wire lsgn = asg ^ bsg;
                    assign l_nan[gb]  = ana | bna | (ain & bzr) | (bin & azr);
                    wire   l_inf      = (ain | bin) & ~l_nan[gb];
                    assign l_pinf[gb] = l_inf & ~lsgn;
                    assign l_ninf[gb] = l_inf &  lsgn;

                    // A term contributes ONLY when both operands are finite and
                    // nonzero. Gating the zeros is LOAD-BEARING: fp8_dec hands a
                    // DAZ zero sig4 = {1,mm,0}, which is not zero, so an ungated
                    // zero operand would inject a small bogus term into the
                    // accumulator. Gating the specials is unobservable, since a
                    // special overrides the result -- but the model skips them, so
                    // this does too.
                    wire skip = l_nan[gb] | l_inf | azr | bzr;

                    wire [7:0] prod8 = asi * bsi;         // 4x4, [64,225]
                    wire signed [8:0] sprod =
                          skip ? 9'sd0
                        : lsgn ? -$signed({1'b0, prod8})
                               :  $signed({1'b0, prod8});

                    // d = how many binades below the reference this product sits.
                    //   value = sprod * 2^(aex+bex-6), accumulator LSB at lowe, so
                    //   term = floor(sprod * 2^(FX_W-15-d)),  d = ref-1-(aex+bex).
                    //
                    // d >= 0 ALWAYS, and that is what makes the shifter
                    // unidirectional: ref-1 is maxeA+maxeB, and no byte's exponent
                    // field can exceed its own row's or column's maximum, because
                    // maxmag64 keys on byte[6:0] whose high bits ARE the exponent.
                    // d <= 60 for the widest case (both operands E5M2), so 6 bits
                    // is exact and not a truncation.
                    wire signed [7:0] eab = $signed({{2{aex[5]}}, aex})
                                          + $signed({{2{bex[5]}}, bex});
                    wire signed [7:0] dsh = refe - 8'sd1 - eab;

                    // Pre-shift LEFT by the constant FX_W-15, so the only variable
                    // shift is a right shift. A bidirectional shifter here would
                    // cost twice as much and buy nothing.
                    wire [PW-1:0] pre = {{(PW-9){sprod[8]}}, sprod} << (FX_W-15);
                    // ARITHMETIC shift, and this is not a detail: the model
                    // floor-divides, so a negative product too small to reach the
                    // window must contribute -1, not 0. A logical shift here is a
                    // silent accuracy bug on exactly the terms that are individually
                    // negligible and collectively are the reason for the extra width.
                    wire [PW-1:0] shf = $signed(pre) >>> dsh[5:0];
                    assign term[gb*FX_W +: FX_W] =
                               {{(FX_W-PW){shf[PW-1]}}, shf};
                end

                // ---- 3 CSA levels, then ONE carry-propagate add -------------
                // {t0,t1,t2,t3,acc} reduced to two vectors by carry-save, then a
                // single FX_W adder. Two gate levels per CSA stage, against
                // fp32_add's align + add + LZC + normalise + round -- that
                // replacement IS X2.
                //
                // The majority term is shifted left, dropping its top bit. That is
                // exact modulo 2^FX_W, and the FINAL sum fits (64 largest products
                // reach 0.879 x 2^(FX_W-1)), so every intermediate wrap cancels.
                //
                // Carry-save ACCUMULATION -- keeping acc redundant and never
                // propagating a carry in the loop at all -- would be faster still
                // and is deliberately NOT done here. It is the next rung, to be
                // taken only if this row shows the FX_W adder as the limiter.
                // Skipping a rung makes the result unattributable.
                wire [FX_W-1:0] t0 = term[0*FX_W +: FX_W];
                wire [FX_W-1:0] t1 = term[1*FX_W +: FX_W];
                wire [FX_W-1:0] t2 = term[2*FX_W +: FX_W];
                wire [FX_W-1:0] t3 = term[3*FX_W +: FX_W];

                wire [FX_W-1:0] s1 = t0 ^ t1 ^ t2;
                wire [FX_W-1:0] j1 = (t0 & t1) | (t1 & t2) | (t0 & t2);
                wire [FX_W-1:0] c1 = {j1[FX_W-2:0], 1'b0};
                wire [FX_W-1:0] s2 = s1 ^ c1 ^ t3;
                wire [FX_W-1:0] j2 = (s1 & c1) | (c1 & t3) | (s1 & t3);
                wire [FX_W-1:0] c2 = {j2[FX_W-2:0], 1'b0};
                wire [FX_W-1:0] s3 = s2 ^ c2 ^ acc;
                wire [FX_W-1:0] j3 = (s2 & c2) | (c2 & acc) | (s2 & acc);
                wire [FX_W-1:0] c3 = {j3[FX_W-2:0], 1'b0};
                wire [FX_W-1:0] acc_next = s3 + c3;

                // ---- epilogue ------------------------------------------------
                wire [31:0] fx_y;
                fx2fp32 #(.ACC_W(FX_W)) u_cvt (
                    .acc (acc),
                    .low (lowe),
                    .y   (fx_y)
                );

                // Specials override the accumulator outright. Order matches
                // fx_specials() in tb/fp8_golden.py: NaN (or both infinities)
                // first, then +Inf, then -Inf.
                wire [31:0] epi = (saw_nan | (saw_pinf & saw_ninf)) ? QNAN32
                                : saw_pinf                         ? PINF32
                                : saw_ninf                         ? NINF32
                                                                   : fx_y;

                // The accumulator is REUSED to hold the converted FP32 between
                // ccnt 16 and 17. It is dead after the conversion, so this costs
                // nothing and saves a 32-bit register in all 256 cells. It is also
                // why FX_W must be at least 33.
                //
                // Flat if/else-if, for the same flop-inference reason as ACC=0's
                // lane accumulators.
                always @(posedge clk) begin
                    if (lane_clr)       acc <= {FX_W{1'b0}};
                    else if (acc_phase) acc <= acc_next;
                    else if (ep_cvt)    acc <= {{(FX_W-32){1'b0}}, epi};
                end

                always @(posedge clk) begin
                    if (lane_clr)       saw_nan  <= 1'b0;
                    else if (acc_phase) saw_nan  <= saw_nan  | (|l_nan);
                    if (lane_clr)       saw_pinf <= 1'b0;
                    else if (acc_phase) saw_pinf <= saw_pinf | (|l_pinf);
                    if (lane_clr)       saw_ninf <= 1'b0;
                    else if (acc_phase) saw_ninf <= saw_ninf | (|l_ninf);
                end

                // ONE fp32_add per element for the += C, against ACC=0's 1024.
                // Operand order matches the model's add(s, C); fp32_add is
                // commutative here anyway and tb_fp32_add asserts it on every
                // vector, but matching the model costs nothing.
                wire [31:0] csum;
                fp32_add u_addc (
                    .a (acc[31:0]),
                    .b (cacc[gm][gn]),
                    .y (csum)
                );

                assign c_next = csum;
                assign c_wr   = ep_adc;
              end

                // C: a tile load, or whichever epilogue cycle this arm writes in.
                // Flat, same flop-inference reason.
                always @(posedge clk) begin
                    if (tile_we && tile_sel == SEL_C && tile_row == gm)
                        cacc[gm][gn] <= tile_wdata[gn*ACC_W +: ACC_W];
                    else if (c_wr)
                        cacc[gm][gn] <= c_next;
                end
            end
        end
    endgenerate

    // ---- tile read ----------------------------------------------------------
    integer ci;
    reg [511:0] c_row;
    always @* begin
        c_row = {512{1'b0}};
        for (ci = 0; ci < DWORDS; ci = ci + 1)
            c_row[ci*ACC_W +: ACC_W] = cacc[rd_row][ci];
    end

    reg [511:0] rd_mux;
    always @* begin
        case (rd_sel)
            SEL_A:   rd_mux = a_flat[rd_row*512 +: 512];
            SEL_B:   rd_mux = b_flat[rd_row*512 +: 512];
            default: rd_mux = c_row;
        endcase
    end

    // RD_REG places the flop AFTER the mux, which is the whole point: the mux is
    // 5 levels deep (a 16:1 row select plus the 3-way rd_sel case) and putting
    // the register before it would leave that depth on the output-port path,
    // where clock insertion delay cannot cancel.
    generate
        if (RD_REG != 0) begin : g_rd_reg
            always @(posedge clk) rd_data <= rd_mux;
        end else begin : g_rd_comb
            always @* rd_data = rd_mux;
        end
    endgenerate

    // ---- elaboration-time checks -------------------------------------------
    initial begin
        if (RD_REG != 0 && RD_REG != 1) begin
            $display("FATAL: RD_REG must be 0 or 1 (got %0d)", RD_REG);
            $finish;
        end
        if (COLSB != 4*DWORDS || KDW != DWORDS || LANE_N != 4) begin
            $display("FATAL: tile geometry is inconsistent (COLSB=%0d DWORDS=%0d KDW=%0d LANE_N=%0d)",
                     COLSB, DWORDS, KDW, LANE_N);
            $finish;
        end
        // ccnt must reach EP2. Sized from the bound rather than guessed.
        if ((1 << CW) <= EP2) begin
            $display("FATAL: ccnt is %0d bits, too narrow for EP2=%0d", CW, EP2);
            $finish;
        end
        if (ACC != 0 && ACC != 1) begin
            $display("FATAL: ACC must be 0 or 1 (got %0d)", ACC);
            $finish;
        end
        // FX_W's bounds are deliberately NOT checked here. They cannot be: below
        // 33 the epilogue's {{(FX_W-32){1'b0}}, epi} is a zero- or negative-width
        // replication and below 26 fx2fp32's own sticky range inverts, so
        // ELABORATION fails before any initial block runs. A check that can never
        // fire, under a comment claiming it guards, invites misplaced trust -- the
        // same dead guard was removed from rtl/fx2fp32.v for this reason.
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
