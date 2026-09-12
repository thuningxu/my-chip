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
//   ccnt 0..15         k is SELECTED: operand mux, decode, fp8_mul
//   ccnt PIPE..15+PIPE adder b of cell (m,n):  lacc[b] <= lacc[b] + prod[b]
//   ccnt 16+PIPE       adder 0: lacc[0] + lacc[1] -> lacc[0]
//                      adder 2: lacc[2] + lacc[3] -> lacc[2]
//   ccnt 17+PIPE       adder 0: lacc[0] + lacc[2] -> lacc[0]
//   ccnt 18+PIPE       adder 0: lacc[0] + C[m][n] -> C[m][n]
//
// At PIPE=0 the first two rows are the same cycle and there is one enable. At
// PIPE=1 they are one cycle apart, the select window and the accumulate window
// overlap by 15 of their 16 cycles, and the epilogue slides with them -- see the
// PIPE parameter and EP0 for the two things that go wrong if it does not.
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
//=============================================================================
module amx_fp8 #(
    // Pipeline depth in the FEED-FORWARD chain. Latency becomes 20+PIPE cycles;
    // throughput is unchanged at one k-step per cycle either way.
    //
    //   0  nothing registered. ccnt -> operand mux -> fp8_mul -> fp32_add -> lacc
    //      is ONE combinational path, measured routed at 5.373 ns on row p1.
    //   1  register the product. Takes the 16:1 operand mux (0.864 ns) AND
    //      fp8_mul (1.157 ns) out of the accumulate path in one move, leaving the
    //      loop as lacc -> fp32_add -> lacc and nothing else. 2.021 ns of a
    //      5.373 ns path -- 38% -- was feed-forward logic sitting in front of a
    //      loop it does not belong to. See g_prod_reg for why the register is 16
    //      bits wide and not 32.
    //
    // ONLY 0..1 EXIST, and the absent rung is a decision rather than an
    // oversight. A PIPE=2 that also registered the decoded operands would split
    // what is left of the feed-forward path -- 0.340 ns of register overhead plus
    // 2.021 ns of logic = 2.361 ns, or 423.6 MHz -- when the accumulate loop it
    // competes with binds at 3.692 ns. There is 1.33 ns of headroom on the side
    // it would attack and none on the side that matters, so the rung would buy
    // nothing measurable and would exist as dead code with a name. The next real
    // move is pipelining fp32_add itself, and that needs interleaved
    // accumulators, because the adder is otherwise in a one-cycle loop.
    //
    // WHAT PIPELINING CANNOT REACH: the accumulate is a FEEDBACK loop,
    // lacc[b] -> fp32_add -> lacc[b], measured at 3.306 ns routed. Add the
    // 0.340 ns any register costs (launch CLK->Q + setup + the SDC's 0.1 ns
    // uncertainty, less useful skew) and the 0.046 ns tail and the floor is
    // 3.692 ns / 270.9 MHz. No value of PIPE goes below that.
    parameter integer PIPE = 0,
    // 1 registers rd_data, adding one cycle of READBACK latency.
    //
    // Defaulted ON because both prior designs MEASURED this: a multi-level
    // readback mux driving an output port becomes the critical path, and roughly
    // half of its arrival is clock insertion delay that CANNOT cancel, because a
    // port has no capture flop to contribute an offsetting delay. Carried from
    // the start rather than rediscovered a third time. Both states stay
    // buildable so the claim is re-measured here, not assumed.
    parameter integer RD_REG = 1,
    // X6: predecode the NEXT epilogue phase and register it per output cell.
    // No new datapath stage, no extra cycle, and no change to FP32 add order.
    parameter integer CTRL_REG = 0,
    // X7: accept a held next request on the current completion edge.
    // No internal queue; start/op obey the start_ready handshake below.
    parameter integer CHAIN = 0
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
    // Sample start && start_ready on a rising edge. Hold start/op until then.
    // With CHAIN=1, done may be high while busy stays high for the next op.
    output wire         start_ready,

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

    // Epilogue phases, pushed back by PIPE. ccnt reaches 18 at PIPE=0 and 19 at
    // PIPE=1, so 5 bits still hold it -- asserted below, not assumed.
    //
    // WHY THE EPILOGUE MOVES WITH PIPE, and it is not symmetry for its own sake.
    // The product register delays only ONE of the adder's two operands. Operand B
    // in the epilogue is muxed out of lacc/cacc (see g_opb0/g_opb2 below) and that
    // mux is NOT delayed -- it reads flops directly. So an EP0 left at ccnt=16
    // while the k=15 product was still inside the register would fold lacc[1] into
    // lacc[0] on the very edge that lacc[1] was still waiting for its last
    // product: lanes 0 and 2 would lose their k=15 term outright, because ep0
    // steals their operand-B mux, and lanes 1 and 3 would write a k=15 result
    // nothing ever reads again. That is a DROPPED k-step, not a reordered one, and
    // it is silent -- 15 of 16 products still land. EP0 = KDW + PIPE is the
    // statement "every accumulate has fully landed in lacc[b] before the tree
    // starts". tb case O1 is what fails if this is left at KDW.
    localparam integer EP0 = KDW + PIPE;        // 16+PIPE: lacc0+=lacc1, lacc2+=lacc3
    localparam integer EP1 = KDW + PIPE + 1;    // 17+PIPE: lacc0+=lacc2
    localparam integer EP2 = KDW + PIPE + 2;    // 18+PIPE: C += lacc0
    localparam integer CW  = 5;

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
    wire c_last = (ccnt == EP2[CW-1:0]);
    assign start_ready = rst_n && ((state == S_IDLE) || ((CHAIN != 0) && run && c_last));
    wire chain_accept = (CHAIN != 0) && run && c_last && start;

    // kcnt is only meaningful while sel_valid; in the epilogue, and during the
    // PIPE flush cycles, the low bits of ccnt select a k nobody accumulates.
    wire [3:0] kcnt      = ccnt[3:0];
    // WHICH k IS BEING SELECTED. This is the issue window, and at PIPE>=1 it is
    // NOT the accumulate enable -- the product lands a cycle later. At PIPE=0 the
    // two coincide, which is exactly why they were one signal before and why
    // conflating them is the defect this split exists to prevent.
    wire       sel_valid = run && (ccnt < KDW[CW-1:0]);
    wire       ep0       = run && (ccnt == EP0[CW-1:0]);
    wire       ep1       = run && (ccnt == EP1[CW-1:0]);
    wire       ep2       = run && (ccnt == EP2[CW-1:0]);

    // At an edge with ccnt=EPx-1, both ccnt and the registered phase advance
    // together. Delaying ep0/ep1/ep2 themselves would be one cycle TOO LATE.
    // run clears all three bits on the start edge and after the finish edge.
    localparam integer PRE_EP0 = EP0 - 1;
    localparam integer PRE_EP1 = EP1 - 1;
    localparam integer PRE_EP2 = EP2 - 1;
    wire [2:0] ep_next = {run && (ccnt == PRE_EP2[CW-1:0]),
                          run && (ccnt == PRE_EP1[CW-1:0]),
                          run && (ccnt == PRE_EP0[CW-1:0])};

    // Clearing the lane accumulators on the START edge costs no cycle: the edge
    // that moves IDLE->RUN is already there, and ccnt==0 executes on the edge
    // after it.
    // On a chained completion, C samples the OLD epilogue sum while the lane
    // registers clear for the next instruction on that same edge. NBA semantics
    // preserve the arithmetic; clearing one edge earlier would destroy the sum.
    wire lane_clr = ((state == S_IDLE) && start) || chain_accept;

    // sel_valid delayed, so lane b is enabled exactly when ITS product emerges
    // from the product register -- the same 16-pulse train, PIPE cycles later.
    // acc_phase keeps its name and every one of its existing uses (len[gb]
    // below), so the ladder is the only thing that moved.
    //
    // A SHIFT REGISTER, NOT A RE-DERIVATION FROM ccnt, and that choice IS the
    // correctness argument rather than a stylistic preference. FP32 addition is
    // not associative, so the per-lane k-order 0..15 is part of the
    // specification: tb/fp8_golden.py measures that merely reordering the four
    // lane sums moves 23.05% of output elements, and a permuted k moves results
    // by the same mechanism. A flop chain is order-preserving and gap-free by
    // construction -- it can only translate the pulse train in time, and cannot
    // reorder, drop or duplicate a pulse -- so k-order is guaranteed by the
    // SHAPE of the logic. `run && (ccnt >= PIPE) && (ccnt < KDW + PIPE)` computes
    // the same waveform today and guarantees nothing under a later edit, and the
    // failure it invites is a QUIET one. kcnt = ccnt[3:0] WRAPS, so a pulse landing
    // one cycle late selects k=0 again rather than selecting nothing: an
    // off-by-one bound REORDERS the sequence to 1..15,0 instead of visibly
    // truncating it, and all 16 products still land. That is amx_tdpbssd's acc_en
    // mutant, where every uniform-operand case passed and only the purpose-built S6
    // caught it.
    //
    // MEASURED here, by rotating kcnt one step so the k-order becomes exactly
    // 1..15,0 with nothing dropped: 11 of 29 checks fail and 18 SURVIVE at both
    // PIPE settings. The survivors are E1-E4, S1-S4, D1, D2, Z1, T1, T2 and X1 --
    // every case built on uniform, zero or single-k operands, which cannot see a
    // permutation even in principle. Of the eleven that do fail, ten fail on only
    // 21 to 47 of 256 elements, because they catch it by rounding luck. tb case O1
    // fails on 256 of 256, by construction, and is the only reason this is a caught
    // bug rather than a silent one.
    //
    // Gating on `run` alone instead of on a delayed sel_valid would accumulate
    // straight through the flush and epilogue cycles and corrupt the last
    // k-steps. That mutant fails ~everything in amx_tdpbssd's table, so it is the
    // easy one; the off-by-one is the dangerous one.
    //
    // v_sr IS RESET while the datapath's product register deliberately is NOT,
    // and the asymmetry is what makes the unreset register safe: pr holds X out of
    // power-up, but no X can reach an accumulator, because the enable that would
    // admit it is held at 0 until sel_valid has actually been high. One reset flop
    // per design buys 16,384 unreset ones.
    //
    // One bit, because the ladder has one rung. A second rung makes this
    // `reg [1:0] v_sr; ... v_sr <= {v_sr[0], sel_valid};` with the tap at
    // v_sr[PIPE-1], which is what amx_tdpbssd.v:200-205 already is.
    reg v_sr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) v_sr <= 1'b0;
        else        v_sr <= sel_valid;
    end
    wire acc_phase = (PIPE == 0) ? sel_valid : v_sr;

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
                        done  <= 1'b1;
                        if (CHAIN != 0 && start) begin
                            ccnt  <= {CW{1'b0}};
                            op_r  <= op;
                            state <= S_RUN;
                            busy  <= 1'b1;
                        end else begin
                            state <= S_IDLE;
                            busy  <= 1'b0;
                        end
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

    genvar gm, gn, gb;
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

    // ---- the 256 cells, four lanes each ------------------------------------
    generate
        for (gm = 0; gm < ROWS; gm = gm + 1) begin : g_m
            for (gn = 0; gn < DWORDS; gn = gn + 1) begin : g_n

                wire [2:0] ep_local;
                if (CTRL_REG != 0) begin : g_ctrl_reg
                    (* keep = 1 *) reg [2:0] ep_ctrl;
                    // The PROCESS attribute is essential: proc_dff copies it
                    // onto the cells, preventing opt_merge from collapsing 256
                    // identical banks into one global driver. A kept wire alone
                    // does not establish local replication. Verify after synth.
                    (* keep = 1 *) always @(posedge clk or negedge rst_n) begin
                        if (!rst_n) ep_ctrl <= 3'b000;
                        else        ep_ctrl <= ep_next;
                    end
                    assign ep_local = ep_ctrl;
                end else begin : g_ctrl_comb
                    assign ep_local = {ep2, ep1, ep0};
                end

                // Four FP32 lane accumulators, packed so ONE always block drives
                // them. Cleared to +0 on the start edge.
                reg  [LANE_N*ACC_W-1:0] lacc;
                wire [LANE_N*ACC_W-1:0] prod;
                wire [LANE_N*ACC_W-1:0] prod_e;   // prod as the ADDER sees it
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

                    // PIPE>=1 registers the product. This is the entire fix: it
                    // moves the 16:1 operand mux and fp8_mul off the accumulate
                    // path together, because both are upstream of this one wire.
                    //
                    // SIXTEEN BITS, NOT THIRTY-TWO, and the truncation is LOSSLESS
                    // -- not an approximation anyone has to accept. fp8_mul's
                    // normal result is literally normal_y = {sgn, e_fld, nrm[6:0],
                    // 16'd0} (rtl/fp8_mul.v:153): a product of two 4-bit
                    // significands has exactly 7 fraction bits, which is the same
                    // fact that makes the product never round. Every non-normal
                    // fp8_mul can return has zero low bits too -- QNAN
                    // 0x7FC00000, {sgn,8'hFF,23'd0} for Inf, {sgn,31'd0} for
                    // signed zero. So y[15:0] is identically zero and re-supplying
                    // 16'b0 on the far side reconstructs the value bit for bit,
                    // including the sign of zero and the NaN encoding.
                    //
                    // THAT IS NOT LEFT AS AN ARGUMENT. tb/tb_fp8_mul.v asserts
                    // "all 262144 products have y[15:0]==0" on every one of the
                    // 4 format pairs x 256 x 256 inputs, alongside its existing
                    // exactness check. If that check ever fails, THIS register is
                    // silently dropping product bits, and the two must be fixed
                    // together -- which is why the failure message there names
                    // this file.
                    //
                    // Cost: 16 bits x 4 lanes x 256 cells = 16,384 flops, against
                    // 32,768 for the naive full-width cut. +28.3% on the design's
                    // 57,867 rather than +57%, for identical timing, because the
                    // 16 bits removed are constants.
                    //
                    // No reset, like amx_tdpbssd's pipeline arms: see v_sr above
                    // for why an unreset datapath register cannot leak X.
                    if (PIPE >= 1) begin : g_prod_reg
                        reg [15:0] pr;
                        always @(posedge clk) pr <= prod[gb*ACC_W + 16 +: 16];
                        assign prod_e[gb*ACC_W +: ACC_W] = {pr, 16'b0};
                    end else begin : g_prod_comb
                        assign prod_e[gb*ACC_W +: ACC_W] = prod[gb*ACC_W +: ACC_W];
                    end

                    // OPERAND B ONLY IS MUXED. Operand A is always lacc[gb],
                    // straight out of the flop, so the accumulate feedback path
                    // gains nothing. Named generate arms, and only the lanes
                    // that need extra sources get any mux at all: lanes 1 and 3
                    // are pure wires.
                    // prod_e, never prod: the accumulate arm of every one of these
                    // muxes must be the DELAYED product, or the register would sit
                    // beside the datapath instead of in it. The epilogue arms stay
                    // undelayed on purpose -- lacc/cacc are already flops -- which
                    // is the whole reason EP0 had to move to KDW+PIPE.
                    wire [ACC_W-1:0] opb;
                    if (gb == 0) begin : g_opb0
                        assign opb = ep_local[0] ? lacc[1*ACC_W +: ACC_W]
                                   : ep_local[1] ? lacc[2*ACC_W +: ACC_W]
                                   : ep_local[2] ? cacc[gm][gn]
                                         : prod_e[0*ACC_W +: ACC_W];
                    end else if (gb == 2) begin : g_opb2
                        assign opb = ep_local[0] ? lacc[3*ACC_W +: ACC_W]
                                         : prod_e[2*ACC_W +: ACC_W];
                    end else begin : g_opb_plain
                        assign opb = prod_e[gb*ACC_W +: ACC_W];
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
                        assign len[gb] = acc_phase | ep_local[0] | ep_local[1];
                    end else if (gb == 2) begin : g_en2
                        assign len[gb] = acc_phase | ep_local[0];
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

                // C: a tile load, or the last epilogue cycle. Flat, same reason.
                always @(posedge clk) begin
                    if (tile_we && tile_sel == SEL_C && tile_row == gm)
                        cacc[gm][gn] <= tile_wdata[gn*ACC_W +: ACC_W];
                    else if (ep_local[2])
                        cacc[gm][gn] <= sum[0*ACC_W +: ACC_W];
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
        if (CHAIN != 0 && CHAIN != 1) begin
            $display("FATAL: CHAIN must be 0 or 1 (got %0d)", CHAIN);
            $finish;
        end
        if (CTRL_REG != 0 && CTRL_REG != 1) begin
            $display("FATAL: CTRL_REG must be 0 or 1 (got %0d)", CTRL_REG);
            $finish;
        end
        if (RD_REG != 0 && RD_REG != 1) begin
            $display("FATAL: RD_REG must be 0 or 1 (got %0d)", RD_REG);
            $finish;
        end
        if (COLSB != 4*DWORDS || KDW != DWORDS || LANE_N != 4) begin
            $display("FATAL: tile geometry is inconsistent (COLSB=%0d DWORDS=%0d KDW=%0d LANE_N=%0d)",
                     COLSB, DWORDS, KDW, LANE_N);
            $finish;
        end
        // Checked BEFORE the CW width test below, which is derived from EP2 and so
        // from PIPE: an out-of-range PIPE should be reported as an out-of-range
        // PIPE, not as a counter that is mysteriously too narrow. Only 0 and 1 are
        // built; the header says why 2 is absent rather than unimplemented.
        if (PIPE < 0 || PIPE > 1) begin
            $display("FATAL: PIPE must be 0..1 (got %0d)", PIPE);
            $finish;
        end
        // ccnt must reach EP2. Sized from the bound rather than guessed, so it
        // tracks PIPE automatically: EP2 is 18 at PIPE=0 and 19 at PIPE=1, both
        // inside 5 bits.
        if ((1 << CW) <= EP2) begin
            $display("FATAL: ccnt is %0d bits, too narrow for EP2=%0d", CW, EP2);
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
