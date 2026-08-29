`timescale 1ns/1ps
//=============================================================================
// mac_array -- v0 BASELINE. Parameterised N x N signed INT4 outer-product MAC.
//
// Computes  D[i][j] = init[i][j] + sum over k of  A[k][i] * B[k][j]
//                     for k in [0, k_dim)
// where A[k] and B[k] are each N signed INT4 lanes packed into one memory word,
// and `init` is chosen by init_mode:
//
//   INIT_ZERO   init = 0        D = A@B          (bit-identical to the v0 design)
//   INIT_C      init = c_in     D = A@B + C      C supplied externally
//   INIT_KEEP   init = D_prev   D = A@B + D_prev chains k-tiles, no reset needed
//
// FEED A COLUMN-MAJOR AND THIS IS A MATRIX PRODUCT. With memory word k holding
// column k of A (lane i = A[i][k]) and word k of B holding row k of B, the sum
// above is sum_k A[i][k]*B[k][j] = (A@B)[i][j]. No transpose hardware exists or
// is needed; the layout requirement is on whoever fills the memories. Verified
// against an independent triple loop -- see tb case M1.
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
// This is deliberately the SIMPLEST CORRECT design, not a fast one. It exists
// to be the baseline you climb away from. Known costs, left in on purpose:
//
//   1. The full ACC_W-bit add sits in the per-cycle path (mult -> wide add ->
//      flop). This is the first thing that will limit fmax.
//   2. The drain reads acc[drow][dcol] with variable indices, which synthesises
//      to an N*N : 1 mux. Harmless at N=4 (16:1); becomes the critical path at
//      N=32 (1024:1). Fix by pipelining the readout before scaling up.
//   3. No pipelining anywhere. One element per cycle, which is bandwidth
//      optimal -- any pipelining you add will COST cycles to buy clock.
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
    // derived -- do not override
    parameter integer RAW    = $clog2(N),
    parameter integer OAW    = $clog2(N*N)
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

    // result write port
    output reg                          out_we,
    output reg  [OAW-1:0]               out_addr,
    // NOTE: deliberately NOT declared `signed`. Yosys preserves the signed
    // attribute into the netlist and OpenSTA's Verilog reader rejects it
    // ("syntax error" on the port line). The bits are two's complement either
    // way; consumers interpret them as signed. Do not "fix" this.
    output reg  [ACC_W-1:0]             out_wdata
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
                S_DRAIN: begin
                    out_we    <= 1'b1;
                    out_addr  <= {drow, dcol};
                    out_wdata <= acc[drow][dcol];   // N*N : 1 mux -- see header

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
