`timescale 1ns/1ps
//=============================================================================
// mac_array -- v0 BASELINE. Parameterised N x N signed INT4 outer-product MAC.
//
// TWO NAMES, ONE CONVENTION. Read this before the formulas: "A" is ambiguous in
// matmul hardware, and picking the wrong reading transposes your result.
//
//   A, B         the MATHEMATICAL matrices, indexed [row][col] as usual.
//   Amem, Bmem   what the memories hold, indexed [k][lane] -- literally what
//                act_rdata and wgt_rdata deliver. One word per k, each word
//                N signed INT4 lanes.
//
// The required layout is  Amem[k] = column k of A,  Bmem[k] = row k of B.
// Equivalently Amem = A-transpose and Bmem = B: ONLY A IS STORED TRANSPOSED.
//
// In terms of what the ports actually see:
//
//   D[i][j] = init[i][j] + sum over k of  Amem[k][i] * Bmem[k][j]
//                          for k in [0, k_dim)
//
// Substituting the layout, that is sum_k A[i][k]*B[k][j], so
//
//   D = init + A@B
//
// a genuine matrix product with no transpose hardware anywhere. Verified
// against an independent textbook triple loop -- see tb case M1.
//
//   INIT_ZERO   init = 0        D = A@B          (bit-identical to the v0 design)
//   INIT_C      init = c_in     D = A@B + C      C supplied externally
//   INIT_KEEP   init = D_prev   D = A@B + D_prev chains k-tiles, no reset needed
//
// WHY ONLY A IS TRANSPOSED, AND WHY THAT IS NOT A DESIGN CHOICE. In
// C[i][j] = sum_k A[i][k]*B[k][j] the contraction index k is A's COLUMN index
// and B's ROW index. So ANY dataflow that iterates over k must walk A
// column-wise and B row-wise: the asymmetry is in the definition of matrix
// multiplication, not in this implementation, and no choice of architecture
// escapes it. What varies is which slices you take --
//
//   inner product   for each output (i,j): row i of A  . column j of B
//   outer product   for each k:            col k of A (x) row k of B, accumulated
//
// This design is the second: A@B = sum_k (col_k A)(row_k B), a sum of N rank-1
// updates, which is why one cycle touches all N*N accumulators at once instead
// of finishing one output at a time.
//
// The transpose is therefore not eliminated, it is RELOCATED to whoever fills
// the memories: gathering Amem[k] is a STRIDED read of A while Bmem[k] is
// CONTIGUOUS. Free in gates, not free in the data-prep step. See check_matmul
// in tb_mac_array.v for the packing that this module requires.
//
// COST OF THE ADDEND, measured (yosys generic synth, total cells, N=4):
//
//   config                              cells   accumulator flop   $_MUX_
//   v0, no addend ports at all           4937   384 $_SDFFE_           35
//   INIT_ZERO + INIT_KEEP  (C_PORT=0)    4935   384 $_SDFFE_           38
//   + INIT_C               (C_PORT=1)    5318   384 $_SDFFE_          421
//
// Chaining is FREE (-2 cells; abc just found a marginally better factoring).
// INIT_KEEP assigns nothing at all -- the flop holds -- so no data mux appears
// and the clear-to-zero keeps riding the flop's dedicated synchronous-reset pin.
//
// External C costs +381 cells, and that is ENTIRELY the data mux: +386 $_MUX_,
// i.e. one ACC_W-wide 2:1 mux per accumulator (N*N*ACC_W = 384 at N=4). Note
// the sync-reset pin SURVIVES -- see the comment on the flat if/else-if chain
// in the array below, which is what makes that true. Set C_PORT=0 to get the
// 381 cells back if you only ever chain.
//
// HOW RESULTS COME OUT -- chosen by OUT_PAR, and it decides the cycle count:
//
//   OUT_PAR=0  serial drain. One element per cycle through an N*N : 1 mux on
//              out_wdata, addressed by out_addr. Costs N*N cycles.
//   OUT_PAR=1  parallel. All N*N accumulators presented at once on out_all,
//              out_we a single-cycle strobe. Costs 1 cycle. No mux at all --
//              out_all is a plain concatenation of the accumulator outputs.
//
// Measured cycle counts fit exactly, over 20 cases with K from 0 to 2048:
//
//   cycles = K + N*N + 3      OUT_PAR=0, K >= 1
//   cycles = K + 4            OUT_PAR=1, K >= 1
//   (K == 0 costs one less: IDLE jumps straight to S_DRAIN, so the rd_valid
//    pipeline never fills. The tb asserts this model, it does not just print it.)
//
// The 3 is start-latch + SRAM read latency + done. WHY THIS MATTERS: the drain
// is a FIXED cost, so multiplier utilisation depends entirely on K --
//
//   K=1024, OUT_PAR=0   1043 cycles   drain 1.5% of the time    98.2% utilised
//   K=4,    OUT_PAR=0     23 cycles   drain 70% of the time     17.4% utilised
//   K=4,    OUT_PAR=1      8 cycles   drain 12% of the time     50.0% utilised
//
// So the serial drain is nearly free when streaming long K and catastrophic on
// the small tile a tensor core is defined by. Both modes are therefore
// PERMANENT, not a compatibility courtesy: out_all is N*N*ACC_W bits -- 384 at
// N=4 but 6,144 at N=16 -- so the parallel readout is only sane because a
// tensor-core tile is small. Keep the serial drain for large-N streaming.
//
// COST OF THE READOUT, measured (yosys generic synth, N=4):
//
//   C_PORT  OUT_PAR   cells   port bits   flops
//   0       0          4938         503     455
//   0       1          4027         886     422
//   1       0          5330         503     455
//   1       1          4418         886     422
//
// In GENERIC terms OUT_PAR=1 looks cheaper: -911 cells and -33 flops for +383
// port bits. The serial drain is not just a mux -- it is an N*N:1 mux plus two
// counters, an index multiply-add and an address decode, all to move data that
// out_all reaches with plain wires. The -33 flops are drow/dcol (4 bits, pruned
// outright) and out_addr/out_wdata (28 bits, which go constant and are folded
// away later; they still show up in a coarse `prep` dump).
//
// BUT DO NOT BELIEVE THE -911. Routed on Nangate45 the same change measures
// +99 stdcells (9158 -> 9257), because a 384-bit output port needs drivers and
// the flow inserted ~400 buffers to provide them (ORFS timing_repair_buffer
// 2804 -> 3189). The logic saving is real; the port eats it. This is the second
// time here that a wide top-level port has cost ~1000 stdcells of buffering
// invisible to generic synth -- c_in did the same thing in the other direction
// (+381 generic, +1170 routed). Generic cell deltas tell you about LOGIC, never
// about area. Cell area did fall (13664 -> 13482 um2): 33 flops are bigger than
// 400 buffers, so count and area moved opposite ways.
//
// DO NOT CLAIM AN fmax EFFECT EITHER WAY. It came out +39 MHz at C_PORT=1 and
// -9 MHz at C_PORT=0 -- same RTL change, opposite sign -- so it is placement,
// not design. That is consistent with the worst path having the same shape in
// every config measured (input port -> multiplier -> 24-bit accumulate -> acc
// flop, see 1 below): no drain logic is on it before or after, so there is no
// mechanism for OUT_PAR to change it. Quote the cycle count and the buffer cost
// from this parameter; do not quote its frequency.
//
// Fair warning on that table: OUT_PAR=0 measures 5330 where the pre-OUT_PAR
// design measured 5318. The flop count is IDENTICAL at 455 and the +12 is
// spread across gate types (+23 $_NOR_, -36 $_OR_, +13 $_AND_, ...), i.e. abc
// re-factoring the same logic after S_DRAIN was restructured -- not added
// hardware. Same phenomenon as the -2 cells noted for chaining above.
//
// This is deliberately the SIMPLEST CORRECT design, not a fast one. It exists
// to be the baseline you climb away from. Known costs, left in on purpose:
//
//   1. The full ACC_W-bit add sits in the per-cycle path (mult -> wide add ->
//      flop). This is the first thing that will limit fmax -- and MEASURED to
//      be so: the routed worst path at N=4 runs act_rdata -> multiplier
//      (FA/HA chain) -> 24-bit accumulate -> acc flop. Fix by registering the
//      product, which costs a cycle.
//   2. The drain reads acc[drow][dcol] with variable indices, which synthesises
//      to an N*N : 1 mux. Harmless at N=4 (16:1); becomes the critical path at
//      N=32 (1024:1). OUT_PAR=1 removes it entirely. Note it is NOT the
//      critical path at N=4 -- see 1 -- so OUT_PAR buys cycles, not clock.
//   3. No pipelining anywhere. One element per cycle, which is bandwidth
//      optimal -- any pipelining you add will COST cycles to buy clock.
//      A 4x4x4 INT4 tile is 128 operand bits and the ports deliver 32 bits per
//      cycle, so 4 cycles/tile is a hard floor. OUT_PAR=1 gets within 2x of it;
//      more multipliers cannot help without widening the memory interface.
//
// Memory contract: read data is registered and arrives ONE cycle after the
// request is asserted (ordinary synchronous SRAM).
//
// Accumulator sizing (do this arithmetic every time you change a width):
//   max |product| = |-8 * -8| = 64
//   worst case sum = (2^KW - 1) * 64
//   KW=16, ACC_W=24 -> 65535*64 = 4,194,240 <= 2^23-1 = 8,388,607.  OK, 2x margin.
//
// N must be a power of two.
//=============================================================================
module mac_array #(
    parameter integer N      = 4,  // array is N x N; N*N outputs
    parameter integer KW     = 16, // width of k_dim
    parameter integer ACC_W  = 24, // accumulator width
    // 1 = build the external-C preload path, so INIT_C works.
    // 0 = prune it. c_in is ignored, its N*N ACC_W-wide muxes disappear, and
    //     the clear goes back to riding the flop's free sync-reset pin. Driving
    //     INIT_C with C_PORT=0 is a design error and is caught below.
    parameter integer C_PORT = 1,
    // 0 = serial drain on out_wdata/out_addr, N*N cycles (the v0 behaviour).
    // 1 = parallel readout on out_all, 1 cycle. Prunes the N*N:1 mux and the
    //     drow/dcol counters; out_addr and out_wdata go unused.
    parameter integer OUT_PAR = 0,
    // derived -- do not override
    parameter integer RAW    = $clog2(N),
    parameter integer OAW    = $clog2(N*N),
    // Collapses to 1 bit when the parallel readout is not built, so OUT_PAR=0
    // gains ONE dead pin rather than N*N*ACC_W of them. That is deliberate:
    // 384 unused c_in pins measurably perturbed placement in an earlier run
    // (row f1b), so an unused port has to actually vanish or the area number
    // stops meaning what it says.
    parameter integer OUT_AW = (OUT_PAR != 0) ? N*N*ACC_W : 1
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // control
    input  wire                         start,
    input  wire [KW-1:0]                k_dim,

    // What the accumulators start from. Unlike k_dim (which must be held for the
    // whole operation because it is read live), init_mode and c_in are sampled
    // ONLY on the `start` edge and may change freely afterwards.
    input  wire [1:0]                   init_mode,
    // Row-major N x N tile of ACC_W-bit two's-complement addends: element [i][j]
    // occupies bit (i*N + j)*ACC_W, matching out_addr = {drow, dcol}. Ignored
    // unless init_mode == INIT_C.
    input  wire [N*N*ACC_W-1:0]         c_in,

    output reg                          busy,
    output reg                          done,

    // activation read port (mastered by this block)
    output reg                          act_req,
    output reg  [KW-1:0]                act_addr,
    input  wire [N*4-1:0]               act_rdata,

    // weight read port (mastered by this block)
    output reg                          wgt_req,
    output reg  [KW-1:0]                wgt_addr,
    input  wire [N*4-1:0]               wgt_rdata,

    // result write port.
    //
    // out_we means "result data is valid this cycle" in BOTH modes, which is why
    // there is no separate valid signal: at OUT_PAR=0 it pulses N*N times, once
    // per element; at OUT_PAR=1 it pulses once, for the whole tile.
    output reg                          out_we,
    // Serial readout (OUT_PAR=0). Unused, and held at 0, when OUT_PAR=1.
    output reg  [OAW-1:0]               out_addr,
    // NOTE: deliberately NOT declared `signed`. Yosys preserves the signed
    // attribute into the netlist and OpenSTA's Verilog reader rejects it
    // ("syntax error" on the port line). The bits are two's complement either
    // way; consumers interpret them as signed. Do not "fix" this.
    output reg  [ACC_W-1:0]             out_wdata,

    // Parallel readout (OUT_PAR=1), row-major: element [i][j] occupies bit
    // (i*N + j)*ACC_W -- the same layout as c_in and as out_addr = {drow, dcol},
    // so a tile read out here can be fed straight back into c_in. Combinational
    // on purpose: it is a concatenation of the accumulator outputs, so it costs
    // no mux and no flop. Registering it would add N*N*ACC_W flops (384 at N=4,
    // nearly doubling the design's 455) to buy nothing.
    // Width is 1 and the value is constant 0 when OUT_PAR=0.
    output wire [OUT_AW-1:0]            out_all
);
    // ---- derived widths -----------------------------------------------------
    localparam integer CLOG2_N  = RAW;
    localparam integer CLOG2_NN = OAW;

    localparam [1:0] S_IDLE  = 2'd0,
                     S_RUN   = 2'd1,
                     S_DRAIN = 2'd2;

    // init_mode encoding. INIT_ZERO is 0 so that tying the port low reproduces
    // the pre-addend design exactly -- which is what lets the original nine
    // regression cases stand unchanged as the backward-compatibility proof.
    localparam [1:0] INIT_ZERO = 2'd0,
                     INIT_C    = 2'd1,
                     INIT_KEEP = 2'd2;

    reg [1:0]           state;
    reg [KW-1:0]        issued;    // reads launched
    reg [KW-1:0]        consumed;  // elements accumulated
    reg                 rd_valid;  // read data is on the bus this cycle
    reg [CLOG2_N-1:0]   drow, dcol;

    reg signed [ACC_W-1:0] acc [0:N-1][0:N-1];

    integer i, j;

    // ---- request generation -------------------------------------------------
    // NOTE: `issued < k_dim` is a KW-bit comparator sitting combinationally on
    // an output port. That is a known future bottleneck -- replace with a
    // registered down-counter when you start chasing fmax.
    always @* begin
        act_req  = (state == S_RUN) && (issued < k_dim);
        wgt_req  = act_req;
        act_addr = issued;
        wgt_addr = issued;
    end

    // ---- control ------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            issued   <= {KW{1'b0}};
            consumed <= {KW{1'b0}};
            rd_valid <= 1'b0;
            drow     <= {CLOG2_N{1'b0}};
            dcol     <= {CLOG2_N{1'b0}};
            out_we   <= 1'b0;
            out_addr <= {CLOG2_NN{1'b0}};
            out_wdata<= {ACC_W{1'b0}};
            busy     <= 1'b0;
            done     <= 1'b0;
        end else begin
            out_we <= 1'b0;
            done   <= 1'b0;

            case (state)
                // -------------------------------------------------- IDLE
                S_IDLE: begin
                    rd_valid <= 1'b0;
                    // DONE must not be terminal: accepting `start` here is what
                    // makes the block restartable without a reset.
                    if (start) begin
                        busy     <= 1'b1;
                        issued   <= {KW{1'b0}};
                        consumed <= {KW{1'b0}};
                        drow     <= {CLOG2_N{1'b0}};
                        dcol     <= {CLOG2_N{1'b0}};
                        state    <= (k_dim == {KW{1'b0}}) ? S_DRAIN : S_RUN;
                    end
                end

                // -------------------------------------------------- RUN
                S_RUN: begin
                    // one read launched per cycle; data lands next cycle
                    rd_valid <= act_req;
                    if (act_req)
                        issued <= issued + 1'b1;

                    if (rd_valid) begin
                        consumed <= consumed + 1'b1;
                        if (consumed + 1'b1 == k_dim) begin
                            rd_valid <= 1'b0;
                            drow     <= {CLOG2_N{1'b0}};
                            dcol     <= {CLOG2_N{1'b0}};
                            state    <= S_DRAIN;
                        end
                    end
                end

                // -------------------------------------------------- DRAIN
                // NESTING IS SAFE HERE, unlike in the accumulator below. OUT_PAR
                // is an elaboration-time constant, so exactly one arm of this if
                // survives and no mux is built. The flat-if/else-if rule on the
                // accumulator exists because init_mode is a RUNTIME signal, where
                // the branch shape decides whether yosys can use the flop's
                // synchronous-reset pin. Do not generalise one to the other.
                S_DRAIN: begin
                    out_we <= 1'b1;         // "results valid", both modes

                    if (OUT_PAR != 0) begin
                        // out_all is already showing every accumulator. Strobe
                        // once and finish -- one cycle instead of N*N.
                        state <= S_IDLE;
                        busy  <= 1'b0;
                        done  <= 1'b1;
                    end else begin
                        out_addr  <= {drow, dcol};
                        out_wdata <= acc[drow][dcol]; // N*N : 1 mux -- see header

                        if (dcol == (N-1)) begin
                            dcol <= {CLOG2_N{1'b0}};
                            if (drow == (N-1)) begin
                                state <= S_IDLE;
                                busy  <= 1'b0;
                                done  <= 1'b1;
                            end else begin
                                drow <= drow + 1'b1;
                            end
                        end else begin
                            dcol <= dcol + 1'b1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ---- the array ----------------------------------------------------------
    // Lane i of the activation word feeds every column of row i; lane j of the
    // weight word feeds every row of column j. That is a BROADCAST array (not
    // systolic): each of the 2N lanes fans out to N multipliers. Fanout grows
    // with N, which is what eventually caps a broadcast design.
    genvar gr, gc;
    generate
        for (gr = 0; gr < N; gr = gr + 1) begin : g_row
            for (gc = 0; gc < N; gc = gc + 1) begin : g_col
                wire signed [3:0] a_lane = act_rdata[gr*4 +: 4];
                wire signed [3:0] w_lane = wgt_rdata[gc*4 +: 4];
                wire signed [7:0] product = a_lane * w_lane;

                // WRITE THIS AS A FLAT if/else-if CHAIN, NOT NESTED. Yosys's
                // flop inference is shape-sensitive: a leading branch whose
                // condition maps straight to a constant 0 becomes the flop's
                // dedicated synchronous-reset pin and costs nothing. Nesting the
                // three init modes inside one `if (state==S_IDLE && start)`
                // builds a data mux on D instead and forfeits that pin. Both
                // forms, yosys `synth -top mac_array` at N=4 C_PORT=1:
                //
                //   form     cells   vs v0's 4937   accumulator flop
                //   flat      5318   +381           384 $_SDFFE_PP0P_
                //   nested    6107   +1170          384 $_DFFE_PP_   <- no reset
                //
                // Identical logic, and nesting costs 3.1x as much for it: losing
                // the reset pin alone adds 1094 $_NAND_. Measured, not guessed --
                // do not "tidy" this.
                //
                // INIT_KEEP appears in no branch on purpose: falling through
                // every condition leaves the flop holding, which is why chaining
                // is nearly free.
                always @(posedge clk) begin
                    if (state == S_IDLE && start && init_mode == INIT_ZERO)
                        acc[gr][gc] <= {ACC_W{1'b0}};
                    else if (C_PORT != 0 && state == S_IDLE && start
                                         && init_mode == INIT_C)
                        acc[gr][gc] <= c_in[(gr*N + gc)*ACC_W +: ACC_W];
                    else if (state == S_RUN && rd_valid)
                        acc[gr][gc] <= acc[gr][gc]
                                     + {{(ACC_W-8){product[7]}}, product};
                end
            end
        end
    endgenerate

    // ---- parallel readout ---------------------------------------------------
    // The whole accumulator array flattened onto one bus. This is the entire
    // cost of OUT_PAR=1: no mux, no flop, no arithmetic -- every bit is a wire
    // from an accumulator's Q to an output pin. Contrast the serial drain, which
    // needs an N*N:1 mux, two counters, index arithmetic and an address decode
    // to move the same data out over N*N cycles.
    generate
        if (OUT_PAR != 0) begin : g_out_par
            genvar orow, ocol;
            for (orow = 0; orow < N; orow = orow + 1) begin : g_orow
                for (ocol = 0; ocol < N; ocol = ocol + 1) begin : g_ocol
                    assign out_all[(orow*N + ocol)*ACC_W +: ACC_W]
                             = acc[orow][ocol];
                end
            end
        end else begin : g_out_ser
            // OUT_AW is 1 here. Tie it off so the port has a driver.
            assign out_all = 1'b0;
        end
    endgenerate

    // ---- elaboration-time checks -------------------------------------------
    initial begin
        if (N < 2 || (N & (N-1)) != 0) begin
            $display("FATAL: N must be a power of two >= 2 (got %0d)", N);
            $finish;
        end
        if (ACC_W < 8 + KW) begin
            $display("WARNING: ACC_W=%0d may overflow for KW=%0d (need >= %0d)",
                     ACC_W, KW, 8 + KW);
        end
        if (C_PORT != 0 && C_PORT != 1) begin
            $display("FATAL: C_PORT must be 0 or 1 (got %0d)", C_PORT);
            $finish;
        end
        if (OUT_PAR != 0 && OUT_PAR != 1) begin
            $display("FATAL: OUT_PAR must be 0 or 1 (got %0d)", OUT_PAR);
            $finish;
        end
        // OUT_AW is derived. If someone overrides it the parallel readout
        // silently truncates -- results past the cut just never appear.
        if (OUT_AW != ((OUT_PAR != 0) ? N*N*ACC_W : 1)) begin
            $display("FATAL: OUT_AW is derived and must not be overridden (got %0d, expected %0d)",
                     OUT_AW, (OUT_PAR != 0) ? N*N*ACC_W : 1);
            $finish;
        end
    end

    // ---- runtime check: INIT_C without the hardware to serve it ------------
    // With C_PORT=0 the c_in path does not exist, so an INIT_C request matches
    // no branch above and the accumulator simply holds -- it silently behaves
    // like INIT_KEEP and returns a plausible wrong answer. That is exactly the
    // failure class this repo exists to prevent, so say so out loud.
    //
    // `ifndef YOSYS is load-bearing. Yosys defines YOSYS automatically, and
    // WITHOUT this guard it lowered the $display into a $print cell that
    // survived into the netlist (measured: 1 $print at N=4) -- a formal-only
    // cell with no standard-cell mapping, which would reach ORFS. Icarus does
    // not define YOSYS, so the check stays live in simulation, where it belongs.
`ifndef YOSYS
    always @(posedge clk) begin
        if (rst_n && C_PORT == 0 && state == S_IDLE && start
                  && init_mode == INIT_C)
            $display("FATAL: t=%0t init_mode=INIT_C but C_PORT=0 -- c_in is not built; accumulators HOLD instead of loading C.",
                     $time);
    end
`endif
endmodule
