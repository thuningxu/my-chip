//=============================================================================
// tpu_mmu -- a TPU v1-style weight-stationary systolic matrix multiply unit.
//
// Computes C += A * W, all N x N, INT8 x INT8 -> INT32 wrapping accumulate.
//
// WHY THIS EXISTS. rtl/amx_tdpbssd.v is a BROADCAST array: one 512-bit operand
// row fans out to all 16 rows every cycle and each row drives a 16:1 mux. Its
// campaign measured what that costs -- wide ports needing ~1000 cells of
// buffering, the cheapest win in the whole pipelining ladder being the register
// that cut the operand mux off the front of the multiply, and an accumulate loop
// that could not be pipelined at all because the accumulator lives INSIDE the
// cell.
//
// TPU v1 (Jouppi et al., ISCA 2017: 256x256 = 65,536 INT8 MACs, 700 MHz, 92
// TOPS, 75 W TDP, 28 nm) makes the opposite choice on both axes. Weights are
// stationary in the PEs; every operand hop is register-to-register between
// NEIGHBOURS, so nothing fans out further than one cell; and the accumulators sit
// OUTSIDE the array, which leaves the array itself pure feed-forward.
//
// N defaults to 32 because N*N = 1024 INT8 multipliers is exactly the multiplier
// count of amx_tdpbssd. Matched arithmetic makes systolic-vs-broadcast a
// controlled experiment rather than a comparison across two scales, which is the
// error that cost the previous campaign a day of retractions.
//
//   PE(i,j) holds w[i][j].  Each cycle it registers the activation arriving from
//   its left and the partial sum arriving from above plus its own product:
//
//        a_reg[i][j] <= a_in                       (passes right)
//        p_reg[i][j] <= p_in + a_in * w[i][j]      (passes down)
//
//   so an activation advances one column per cycle and a partial sum advances one
//   row per cycle. That is what makes it systolic.
//
// THE SCHEDULE. Derived, then CHECKED against a cycle-accurate model that threads
// the output row index through the array and asserts every contribution to one
// accumulator came from the same row -- see tb/tpu_golden.py, systolic() and
// verify_schedule(). Do not re-derive this by hand and trust it; the algebraic
// derivation is off by one against the register-level behaviour, which is exactly
// how the model earned its place.
//
//        a[m][i] enters row i at      t = m + i        input skew, by ROW
//        a[m][i] reaches PE(i,j) at   t = m + i + j
//        C[m][j] is COMPLETE in p_reg[N-1][j] during cycle t = m + j + N
//
// Two consequences shape the code below:
//
//   The INPUT side needs real delay registers. Row i must be held back i cycles,
//   a triangular bank of sum(i) = N(N-1)/2 bytes -- 3,968 flops at N=32. There is
//   no way around this: the cells physically need their operands at staggered
//   times.
//
//   The OUTPUT side needs NONE. Because m = t - j - N is known per column, and m
//   and j are elaboration constants inside the generate loops, accumulator (m,j)
//   simply enables when its cycle counter reaches the constant m + j + N. No
//   de-skew registers (which would be ~16,000 flops at N=32), no subtract, no
//   variable index -- one constant compare per accumulator. TPU v1 addresses its
//   accumulator memory the same way; de-skew registers are the naive reading of
//   "handle the skew in hardware".
//
// PSUM WIDTH IS EXACT. Products lie in [-16256, +16384] (-128 * -128 = +16384 is
// the largest, -128 * 127 = -16256 the smallest), so N of them reach N * 16384
// and 16 + clog2(N) bits of signed range always holds the column sum: at N=32,
// 524,288 against a 21-bit limit of 1,048,575. tb/tpu_golden.py proves the bound
// rather than asserting it, and the testbench drives all -128 to hit it.
//
// A tapering psum -- PE(i,j) only ever holds i+1 products, so it needs
// 16 + clog2(i+1) bits, not 16 + clog2(N) -- would save roughly 5k flops at N=32.
// Deliberately NOT done here: it is an optimisation to measure against a working
// baseline, not to fold into the first version.
//=============================================================================
module tpu_mmu #(
    // Array dimension. MACs = N*N. N=32 gives 1024, matching amx_tdpbssd.
    // Must be a power of two and at least 2 -- checked at elaboration.
    parameter integer N = 32,

    // 1 registers rd_data, putting a flop AFTER the readback mux. Carried from
    // the start rather than discovered: the amx campaign measured that a
    // multi-level readback mux driving an output port becomes the critical path,
    // with 64% of its arrival being clock insertion delay that CANNOT cancel
    // because an output port has no capture flop to cancel it against. The mux
    // here is clog2(N) = 5 levels deep at N=32, so the same trap applies. Both
    // states stay buildable, so this is re-measured here rather than assumed.
    parameter integer RD_REG = 1
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // ---- tile load, one row per write ------------------------------------
    // Mirrors amx_tdpbssd's load port deliberately: one wide write port with a
    // selector, not three narrow ones. tile_sel: 0=W, 1=A, 2=C.
    // W and A are byte tiles and use only the low N*8 bits of tile_wdata.
    input  wire                  tile_we,
    input  wire [1:0]            tile_sel,
    input  wire [$clog2(N)-1:0]  tile_row,
    input  wire [N*32-1:0]       tile_wdata,

    // ---- execute ----------------------------------------------------------
    input  wire                  start,
    output reg                   busy,
    output reg                   done,

    // ---- accumulator read, one row per cycle -----------------------------
    input  wire [$clog2(N)-1:0]  rd_row,
    output reg  [N*32-1:0]       rd_data
);
    localparam integer AW     = $clog2(N);
    localparam integer ACC_W  = 32;
    // Exact, not padded. See the header.
    localparam integer PSUM_W = 16 + $clog2(N);

    localparam [1:0] SEL_W = 2'd0, SEL_A = 2'd1, SEL_C = 2'd2;

    localparam [1:0] S_IDLE = 2'd0,
                     S_RUN  = 2'd1;

    // Cycle counter must reach the last accumulate at (N-1)+(N-1)+N = 3N-2, so
    // it needs clog2(3N-1) bits. Sized from the bound rather than guessed.
    localparam integer CW = $clog2(3*N);

    // ---- tile storage -------------------------------------------------------
    // FLAT PACKED VECTORS, not unpacked arrays. An unpacked array is inferred as
    // a MEMORY, which trips ORFS's SYNTH_MEMORY_MAX_BITS and is wrong in
    // principle anyway: every one of the N*N PEs reads its own weight byte in the
    // SAME cycle, so this would need N*N concurrent read ports. No SRAM has that.
    // Same reasoning as rtl/amx_tdpbssd.v:164-181.
    reg [N*N*8-1:0] w_flat;   // the stationary weight plane, w[i][j] at (i*N+j)*8
    reg [N*N*8-1:0] a_flat;   // the A tile, a[m][i] at (m*N+i)*8

    // The accumulator stays an UNPACKED 2-D array for the opposite reason: each
    // element needs exactly ONE procedural driver. Packing it would put N always
    // blocks on different bit ranges of the same vector, which is not something
    // to rely on a synthesis tool to accept. Reads are by constant genvar index,
    // so nothing here can be inferred as a memory.
    reg signed [ACC_W-1:0] acc [0:N-1][0:N-1];

    reg [1:0]     state;
    reg [CW-1:0]  ccnt;

    // ---- control ------------------------------------------------------------
    wire run    = (state == S_RUN);
    // Last cycle in which any accumulator can fire: m=N-1, j=N-1 gives
    // (N-1) + (N-1) + N = 3N-2.
    wire c_last = (ccnt == (3*N - 2));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            ccnt  <= {CW{1'b0}};
            busy  <= 1'b0;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    // done is not terminal: accepting start here is what makes
                    // back-to-back C += chains work without a reset.
                    if (start) begin
                        ccnt  <= {CW{1'b0}};
                        busy  <= 1'b1;
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
    // W and A have one driver each and no read-modify-write, so one block serves
    // both. C's loads live with C's accumulate below, because they share drivers.
    always @(posedge clk) begin
        if (tile_we && tile_sel == SEL_W)
            w_flat[tile_row*N*8 +: N*8] <= tile_wdata[N*8-1:0];
        if (tile_we && tile_sel == SEL_A)
            a_flat[tile_row*N*8 +: N*8] <= tile_wdata[N*8-1:0];
    end

    // ---- the input skew bank ------------------------------------------------
    // One row of A enters the array per cycle, and row i of the array must see it
    // i cycles late. Feeding a per-row delay chain from a SINGLE wide row select
    // costs one N:1 mux of N*8 bits; reading a[t-i][i] per row directly would
    // instead put an N:1 byte mux in front of every row -- N muxes where one will
    // do, and a mux on the array's input edge is precisely what a systolic design
    // exists to avoid.
    //
    // The `ccnt < N` bound is an AREA guard, not a correctness guard, and the
    // distinction was established by mutation rather than assumed. Removing it
    // passes every functional test at every N, because the activation PE(i,j)
    // consumes at cycle t is A[t-i-j][i] and t-i-j is exactly the output row m --
    // so out-of-range activations only ever feed partial sums whose m is outside
    // [0,N-1], and no accumulator is ever enabled for those. (An out-of-range
    // part-select of a packed vector reads as x in iverilog, not 0, and even
    // those x's are harmless for the same reason.)
    //
    // What the bound actually buys is the size of the operand mux: ccnt reaches
    // 3N-2, so without it the tool must build a select over 3N-1 rows of A where
    // N will do. That is an area and timing regression a functional testbench
    // cannot see, which is what the flop-count prediction and cell counts in
    // scripts/trial.sh are for.
    wire [N*8-1:0] a_row = (run && ccnt < N)
                             ? a_flat[ccnt*N*8 +: N*8]
                             : {(N*8){1'b0}};

    // skew_out[i] is a[ccnt-i][i]: row i's activation for this cycle.
    wire [7:0] skew_out [0:N-1];

    genvar gi, gj, gd;
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : g_skew
            if (gi == 0) begin : g_direct
                // Row 0 needs no delay at all.
                assign skew_out[0] = a_row[7:0];
            end else if (gi == 1) begin : g_delay1
                // Depth 1 is its own arm because the general shift expression
                // below reduces to sr[7:8] here, an empty part-select, which is
                // an elaboration ERROR in Verilog whether or not the branch is
                // ever taken. A ternary on a constant would not have helped.
                reg [7:0] sr;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) sr <= 8'd0;
                    else        sr <= a_row[8 +: 8];
                end
                assign skew_out[1] = sr;
            end else begin : g_delay
                // A gi-deep byte shift register as a FLAT vector: an unpacked
                // reg [7:0] sr [0:gi-1] would be inferred as a memory again.
                // Byte 0 is the oldest and is what row gi sees this cycle; the
                // arriving byte enters at the top.
                reg [gi*8-1:0] sr;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) sr <= {(gi*8){1'b0}};
                    else        sr <= {a_row[gi*8 +: 8], sr[gi*8-1:8]};
                end
                assign skew_out[gi] = sr[7:0];
            end
        end
    endgenerate

    // ---- the N*N systolic array ---------------------------------------------
    // a_reg passes right, p_reg passes down, both one hop per cycle. Every read
    // below is by constant genvar index, so no mux and no memory is implied.
    reg  [7:0]              a_reg [0:N-1][0:N-1];
    reg  signed [PSUM_W-1:0] p_reg [0:N-1][0:N-1];

    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : g_row
            for (gj = 0; gj < N; gj = gj + 1) begin : g_col
                // Operands arriving THIS cycle. Column 0 takes the skew bank,
                // row 0 starts a fresh sum at zero.
                //
                // These are generate-ifs, not ternaries on a constant. A ternary
                // still ELABORATES its untaken branch, so `a_reg[gi][gj-1]` at
                // gj=0 becomes a read of a_reg[gi][-1]: iverilog warns and
                // returns 'bx, and nothing guarantees another tool treats an
                // out-of-range array read the same way. Both arms named so yosys
                // selection paths stay stable.
                wire [7:0] a_in;
                wire signed [PSUM_W-1:0] p_in;
                if (gj == 0) begin : g_a_edge
                    assign a_in = skew_out[gi];
                end else begin : g_a_left
                    assign a_in = a_reg[gi][gj-1];
                end
                if (gi == 0) begin : g_p_top
                    assign p_in = {PSUM_W{1'b0}};
                end else begin : g_p_above
                    assign p_in = p_reg[gi-1][gj];
                end

                // The weight byte, sliced at a constant offset. Declared signed
                // so the sign extension is a property of the declaration and
                // cannot be lost by editing the expression -- the INT8 slicing
                // lesson from amx_tdpbssd.
                wire signed [7:0] w_b = w_flat[(gi*N + gj)*8 +: 8];
                wire signed [7:0] a_b = a_in;
                wire signed [15:0] prod = a_b * w_b;

                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        a_reg[gi][gj] <= 8'd0;
                        p_reg[gi][gj] <= {PSUM_W{1'b0}};
                    end else begin
                        a_reg[gi][gj] <= a_in;
                        p_reg[gi][gj] <= p_in + {{(PSUM_W-16){prod[15]}}, prod};
                    end
                end
            end
        end
    endgenerate

    // ---- the accumulator bank, OUTSIDE the array ----------------------------
    // This is the structural difference from amx_tdpbssd that matters most: the
    // array above is pure feed-forward, so every stage in it is pipelinable. The
    // only feedback in this design is acc <= acc + psum, and it sits here, one
    // adder deep, not wrapped around a multiply and an adder tree.
    //
    // Accumulator (m,j) completes at cycle m + j + N. m and j are genvars, so
    // that is a compare against an ELABORATION CONSTANT -- no subtract, no
    // variable index, no de-skew registers.
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : g_acc_m
            for (gj = 0; gj < N; gj = gj + 1) begin : g_acc_j
                wire fire = run && (ccnt == (gi + gj + N));
                // FLAT if/else-if, NOT NESTED. yosys's flop inference is
                // shape-sensitive: a leading branch whose condition is a plain
                // load becomes the flop's enable rather than a data mux. Nesting
                // this cost 3.1x in cells when measured on mac_array. Do not
                // "tidy" it into a nested conditional.
                always @(posedge clk) begin
                    if (tile_we && tile_sel == SEL_C && tile_row == gi)
                        acc[gi][gj] <= tile_wdata[gj*ACC_W +: ACC_W];
                    else if (fire)
                        // Wrapping INT32 add, matching TPU v1 and plain matmul.
                        // Sign-extend the narrower psum into the accumulator.
                        acc[gi][gj] <= acc[gi][gj]
                                     + {{(ACC_W-PSUM_W){p_reg[N-1][gj][PSUM_W-1]}},
                                        p_reg[N-1][gj]};
                end
            end
        end
    endgenerate

    // ---- accumulator read ---------------------------------------------------
    // An N:1 mux of N*ACC_W bits, clog2(N) = 5 levels deep at N=32.
    wire [N*ACC_W-1:0] rd_mux;
    generate
        for (gj = 0; gj < N; gj = gj + 1) begin : g_rdmux
            assign rd_mux[gj*ACC_W +: ACC_W] = acc[rd_row][gj];
        end
    endgenerate

    // RD_REG puts the flop AFTER the mux, which is the whole point: registering
    // before it would leave all clog2(N) levels on the output-port path, where
    // clock insertion delay cannot cancel.
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
        if (N < 2) begin
            $display("FATAL: N must be at least 2 (got %0d)", N);
            $finish;
        end
        // Power of two: the row address is clog2(N) bits wide and a non-power-of-
        // two N would leave decodable rows that address nothing.
        if ((N & (N - 1)) != 0) begin
            $display("FATAL: N must be a power of two (got %0d)", N);
            $finish;
        end
    end
endmodule
