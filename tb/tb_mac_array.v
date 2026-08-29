`timescale 1ns/1ps
//=============================================================================
// tb_mac_array -- self-checking regression for mac_array.
//
// Every directed case here corresponds to a bug that has actually shipped in a
// real accelerator design. Do not delete them:
//
//   T1 all-ones, K=4      -- catches double-accumulation. A design that keeps
//                            its accumulate enable asserted across two cycles
//                            returns 2*sum-last (7) instead of sum (4).
//   T2 K=1                -- catches off-by-one in the launch/consume pipeline.
//   T3 K=0                -- catches a degenerate start (must drain zeros, not hang).
//   T4 max-negative       -- -8 * -8 = +64. Catches unsigned slicing of INT4.
//   T5 adversarial K      -- all products at +64 for many K. Catches an
//                            accumulator that is too narrow for its stated K.
//   T6 restart, no reset  -- catches DONE being a terminal state.
//   T7/T8 random          -- general regression against an independent model.
//
// T1..T8 are the PRE-ADDEND suite and are called through the original two-arg
// run_case(). They must keep passing with identical cycle counts; that is the
// backward-compatibility proof for the init_mode/c_in work. Do not port them to
// run_case_m().
//
// The addend cases below were each confirmed to have teeth by mutating the RTL
// and checking that they, specifically, fail:
//
//   A1..A3 INIT_KEEP chain -- catch a chain that clears anyway.
//   A4 INIT_KEEP with K=0  -- the accumulator must not move at all.
//   A5 INIT_ZERO after KEEP-- THE negative test: adding chaining must not have
//                             turned the clear into a no-op. Nothing else
//                             catches a clear that silently stopped working
//                             only in the modes exercised after a chain.
//   B1 c=0                 -- INIT_C must be identical to INIT_ZERO here.
//   B2 c distinct, K=0     -- isolates the preload: nothing is accumulated, so
//                             D must equal C exactly. Catches a transposed
//                             c_in index -- which is why set_c_pattern is
//                             ASYMMETRIC. Uniform C would hide it completely.
//   B3 c distinct, K=4     -- preload plus real accumulation.
//   B4 c wide + negative   -- the ONLY case that catches a c_in slice which
//                             drops the top bit. Verified by mutation: that bug
//                             passes B1, B2, B3 and M2 and fails B4 alone.
//   M1/M2                  -- D = A@B (+C) against a TEXTBOOK triple loop over
//                             untransposed matrices, i.e. a third model beyond
//                             compute_expected. a_mat/b_mat are asymmetric on
//                             purpose: a symmetric A hides a lost transpose.
//
// The expected value is computed here from the same memory contents, by a
// separate triple loop. It is NOT taken from the DUT.
//=============================================================================
module tb_mac_array;

    // parameters (not localparams) so measure.sh can sweep N via -Ptb_mac_array.N=
    parameter integer N     = 4;
    parameter integer KW    = 16;
    parameter integer ACC_W = 24;
    // C_PORT=0 prunes the external-C hardware. The INIT_C cases below are
    // skipped in that build rather than silently reinterpreted -- driving
    // INIT_C with C_PORT=0 is a design error the DUT reports at runtime.
    parameter integer C_PORT = 1;
    // OUT_PAR=1 reads all N*N results out in one cycle on out_all instead of
    // draining them one per cycle. Every case below runs unchanged in both
    // modes: the collector is keyed on ADDRESS, not on arrival order, so how
    // the results arrive is the DUT's business and not the checker's.
    parameter integer OUT_PAR = 0;
    localparam integer DEPTH = 4096;
    // Expected total cycles for a case, from the FSM. The tb asserts this, so a
    // regression that still computes the right answer more slowly is a FAILURE
    // and not a silently-accepted cost. K=0 costs one less because S_IDLE jumps
    // straight to S_DRAIN and the rd_valid pipeline never fills.
    localparam integer DRAIN_CYC = (OUT_PAR != 0) ? 1 : N*N;
    localparam integer CYC_BASE  = DRAIN_CYC + 3;
    localparam integer NN    = N*N;
    localparam integer OAW   = (NN <= 2) ? 1 : $clog2(NN);

    // Mirrors the DUT's encoding. Verilog-2005 has no package mechanism, so this
    // duplication is unavoidable; INIT_ZERO must stay 0 so an undriven port
    // reproduces the pre-addend behaviour.
    localparam [1:0] INIT_ZERO = 2'd0,
                     INIT_C    = 2'd1,
                     INIT_KEEP = 2'd2;

    reg                      clk = 1'b0;
    reg                      rst_n = 1'b0;
    reg                      start = 1'b0;
    reg  [KW-1:0]            k_dim = {KW{1'b0}};
    reg  [1:0]               init_mode = INIT_ZERO;
    reg  [NN*ACC_W-1:0]      c_in = {(NN*ACC_W){1'b0}};
    // unpacked mirror of c_in, so the reference model and the packer cannot
    // disagree about the layout by construction
    reg signed [ACC_W-1:0]   c_val [0:NN-1];
    wire                     busy, done;

    wire                     act_req, wgt_req;
    wire [KW-1:0]            act_addr, wgt_addr;
    reg  [N*4-1:0]           act_rdata, wgt_rdata;

    wire                     out_we;
    wire [OAW-1:0]           out_addr;
    wire signed [ACC_W-1:0]  out_wdata;
    // Mirrors the DUT's derived OUT_AW. Collapses to 1 bit at OUT_PAR=0 so the
    // unused port is a single wire in both places.
    localparam integer OUT_AW = (OUT_PAR != 0) ? NN*ACC_W : 1;
    wire [OUT_AW-1:0]        out_all;

    // ---- behavioural 1-cycle-latency memories -------------------------------
    reg [N*4-1:0] amem [0:DEPTH-1];
    reg [N*4-1:0] wmem [0:DEPTH-1];

    always @(posedge clk) begin
        act_rdata <= amem[act_addr];
        wgt_rdata <= wmem[wgt_addr];
    end

    // ---- DUT ----------------------------------------------------------------
    // OUT_AW is deliberately NOT passed: it is derived in the DUT and the DUT
    // asserts that it was not overridden. Passing it from here would defeat that.
    mac_array #(.N(N), .KW(KW), .ACC_W(ACC_W), .C_PORT(C_PORT),
                .OUT_PAR(OUT_PAR)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .k_dim(k_dim), .busy(busy), .done(done),
        .init_mode(init_mode), .c_in(c_in),
        .act_req(act_req), .act_addr(act_addr), .act_rdata(act_rdata),
        .wgt_req(wgt_req), .wgt_addr(wgt_addr), .wgt_rdata(wgt_rdata),
        .out_we(out_we), .out_addr(out_addr), .out_wdata(out_wdata),
        .out_all(out_all)
    );

    always #0.5 clk = ~clk;

    // ---- result capture -----------------------------------------------------
    reg signed [ACC_W-1:0] got [0:NN-1];
    reg        [NN-1:0]    seen;

    // Keyed on ADDRESS, never on arrival order, and the wait below is "have I
    // seen them all" rather than "have N*N cycles elapsed". That is the only
    // reason OUT_PAR=1 needed no change to any of the 22 cases: how results
    // arrive is the DUT's business. OUT_PAR is elaboration-constant, so at 0
    // this reduces to exactly the pre-OUT_PAR block -- confirmed by every cycle
    // count being identical to the pre-OUT_PAR run.
    integer cap;
    always @(posedge clk) begin
        if (out_we) begin
            if (OUT_PAR != 0) begin
                for (cap = 0; cap < NN; cap = cap + 1)
                    got[cap] <= out_all[cap*ACC_W +: ACC_W];
                seen <= {NN{1'b1}};
            end else begin
                got[out_addr]  <= out_wdata;
                seen[out_addr] <= 1'b1;
            end
        end
    end

    // ---- independent reference ----------------------------------------------
    reg signed [ACC_W-1:0] expected [0:NN-1];

    // The starting value is now part of the model. INIT_KEEP deliberately leaves
    // expected[] untouched, so it carries over from the previous case -- which is
    // exactly the chaining semantics being tested, expressed as the absence of
    // an assignment in both the DUT and the reference.
    task compute_expected(input integer k, input [1:0] mode);
        integer kk, ii, jj;
        reg [N*4-1:0] aw, ww;
        reg signed [3:0] av, wv;
        begin
            for (ii = 0; ii < NN; ii = ii + 1) begin
                if (mode == INIT_ZERO)     expected[ii] = {ACC_W{1'b0}};
                else if (mode == INIT_C)   expected[ii] = c_val[ii];
                // INIT_KEEP: no assignment
            end
            for (kk = 0; kk < k; kk = kk + 1) begin
                aw = amem[kk];
                ww = wmem[kk];
                for (ii = 0; ii < N; ii = ii + 1) begin
                    for (jj = 0; jj < N; jj = jj + 1) begin
                        av = aw[ii*4 +: 4];
                        wv = ww[jj*4 +: 4];
                        expected[ii*N+jj] = expected[ii*N+jj] + (av * wv);
                    end
                end
            end
        end
    endtask

    // ---- bookkeeping --------------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;
    integer cyc_count;

    // Preserved signature: the original nine cases call this and must keep
    // passing byte-for-byte. That is the backward-compatibility proof for the
    // addend work, so do not fold these two tasks together.
    task run_case(input [8*24:1] name, input integer k);
        begin
            run_case_m(name, k, INIT_ZERO);
        end
    endtask

    task run_case_m(input [8*24:1] name, input integer k, input [1:0] mode);
        integer idx, guard, exp_cyc;
        begin
            compute_expected(k, mode);
            seen      = {NN{1'b0}};
            cyc_count = 0;

            k_dim     <= k[KW-1:0];
            init_mode <= mode;
            start     <= 1'b1;
            @(posedge clk);
            start <= 1'b0;

            guard = 0;
            while (seen !== {NN{1'b1}} && guard < 200000) begin
                @(posedge clk);
                guard     = guard + 1;
                cyc_count = cyc_count + 1;
            end

            if (guard >= 200000) begin
                $display("  [FAIL] %0s : timed out, seen=%b", name, seen);
                fail_count = fail_count + 1;
            end else begin
                idx = 0;
                for (idx = 0; idx < NN; idx = idx + 1) begin
                    if (got[idx] !== expected[idx]) begin
                        $display("  [FAIL] %0s : C[%0d][%0d] got %0d expected %0d",
                                 name, idx/N, idx%N, got[idx], expected[idx]);
                        fail_count = fail_count + 1;
                        idx = NN;   // report first mismatch only
                    end
                end
                if (fail_count == 0 || got[0] === expected[0]) begin
                    // recheck cleanly
                    idx = 0;
                    while (idx < NN && got[idx] === expected[idx]) idx = idx + 1;
                    if (idx == NN) begin
                        // A right answer delivered late is still a regression --
                        // cycle count is the whole point of OUT_PAR, so it is
                        // checked, not merely printed.
                        exp_cyc = (k == 0) ? CYC_BASE - 1 : k + CYC_BASE;
                        if (cyc_count !== exp_cyc) begin
                            $display("  [FAIL] %0s : %0d cycles, expected %0d (N=%0d OUT_PAR=%0d)",
                                     name, cyc_count, exp_cyc, N, OUT_PAR);
                            fail_count = fail_count + 1;
                        end else begin
                            $display("  [PASS] %-22s K=%-6d cycles=%0d", name, k, cyc_count);
                            pass_count = pass_count + 1;
                        end
                    end
                end
            end
            // settle back to IDLE
            repeat (4) @(posedge clk);
        end
    endtask

    // ---- memory fill helpers ------------------------------------------------
    task fill_const(input signed [3:0] av, input signed [3:0] wv);
        integer kk, ln;
        reg [N*4-1:0] aw, ww;
        begin
            for (kk = 0; kk < DEPTH; kk = kk + 1) begin
                aw = {(N*4){1'b0}};
                ww = {(N*4){1'b0}};
                for (ln = 0; ln < N; ln = ln + 1) begin
                    aw[ln*4 +: 4] = av;
                    ww[ln*4 +: 4] = wv;
                end
                amem[kk] = aw;
                wmem[kk] = ww;
            end
        end
    endtask

    task fill_random(input integer seed);
        integer kk;
        begin
            for (kk = 0; kk < DEPTH; kk = kk + 1) begin
                amem[kk] = $random(seed);
                wmem[kk] = $random;
            end
        end
    endtask

    // ---- C tile helpers -----------------------------------------------------
    // c_val is the single source of truth; c_in is packed from it, and the
    // reference model reads c_val. The packer and the model therefore cannot
    // disagree about the layout -- only the DUT can, which is the point.
    task pack_c;
        integer e;
        begin
            c_in = {(NN*ACC_W){1'b0}};
            for (e = 0; e < NN; e = e + 1)
                c_in[e*ACC_W +: ACC_W] = c_val[e];
        end
    endtask

    task set_c_zero;
        integer e;
        begin
            for (e = 0; e < NN; e = e + 1) c_val[e] = {ACC_W{1'b0}};
            pack_c;
        end
    endtask

    // Distinct per element AND asymmetric under (i,j)->(j,i): C[0][1] must
    // differ from C[1][0], or a transposed c_in packing passes unnoticed.
    task set_c_pattern;
        integer i, j;
        begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1)
                    c_val[i*N + j] = 1000*(i+1) + (j+1);
            pack_c;
        end
    endtask

    // Bits in the TOP byte of ACC_W, and both signs. Catches a c_in slice that
    // is too narrow (`+: 8` instead of `+: ACC_W`) and a zero-extended load.
    task set_c_extreme;
        integer e;
        begin
            for (e = 0; e < NN; e = e + 1)
                c_val[e] = (e % 2 == 0) ?   ((1 << (ACC_W-4)) + e)
                                        : - ((1 << (ACC_W-5)) + e);
            pack_c;
        end
    endtask

    // ---- the matrix-product claim ------------------------------------------
    // compute_expected models the outer-product accumulation. It and the DUT
    // could agree perfectly and the result still not be a matrix product. So
    // fill A COLUMN-major and B ROW-major, then check against a textbook triple
    // loop over the UNTRANSPOSED matrices. This is a third, independent model.
    reg signed [3:0] a_mat [0:N-1][0:N-1];
    reg signed [3:0] b_mat [0:N-1][0:N-1];

    task check_matmul(input [8*24:1] name, input [1:0] mode);
        integer i, j, k, e, bad;
        reg [N*4-1:0] w;
        reg signed [ACC_W-1:0] mm;
        begin
            // Asymmetric on purpose. If A were symmetric, a missing or doubled
            // transpose anywhere in the path would be completely invisible.
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    a_mat[i][j] = ((i*N + j)*5 + 3) % 16 - 8;
                    b_mat[i][j] = ((j*N + i)*7 + 1) % 16 - 8;
                end
            // THIS LOOP IS THE LAYOUT CONTRACT the RTL header describes, and it
            // is where the "transpose" actually lives. a_mat/b_mat are the
            // MATHEMATICAL matrices [row][col]; amem/wmem are memory words
            // indexed [k]. Note the asymmetry, and that it is not arbitrary:
            // k is A's column index and B's row index, so gathering a word of A
            // is a STRIDED read (a_mat[i][k], k fixed) while B is CONTIGUOUS
            // (b_mat[k][j]). No gate in the DUT does this; the cost is here.
            for (k = 0; k < N; k = k + 1) begin
                w = {(N*4){1'b0}};
                for (i = 0; i < N; i = i + 1) w[i*4 +: 4] = a_mat[i][k];
                amem[k] = w;                    // column k of A  -> amem = A^T
                w = {(N*4){1'b0}};
                for (j = 0; j < N; j = j + 1) w[j*4 +: 4] = b_mat[k][j];
                wmem[k] = w;                    // row    k of B  -> wmem = B
            end

            run_case_m(name, N, mode);                    // DUT vs outer-product

            bad = 0;
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    e  = i*N + j;
                    mm = (mode == INIT_C) ? c_val[e] : {ACC_W{1'b0}};
                    for (k = 0; k < N; k = k + 1)
                        mm = mm + a_mat[i][k] * b_mat[k][j];
                    if (got[e] !== mm) begin
                        if (bad == 0)
                            $display("  [FAIL] %0s : textbook mismatch D[%0d][%0d] got %0d expected %0d",
                                     name, i, j, got[e], mm);
                        bad = bad + 1;
                    end
                end
            if (bad == 0) begin
                $display("  [PASS] %-22s   ... and vs textbook A@B triple loop", name);
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
            end
        end
    endtask

    integer sd = 32'hC0FFEE;

    initial begin
        $display("=== tb_mac_array : N=%0d KW=%0d ACC_W=%0d ===", N, KW, ACC_W);

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // T1 -- the double-accumulate detector
        fill_const(4'sd1, 4'sd1);
        run_case("T1 all-ones K=4", 4);

        // T2 / T3 -- edges
        run_case("T2 all-ones K=1", 1);
        run_case("T3 all-ones K=0", 0);

        // T4 -- signedness
        fill_const(-4'sd8, -4'sd8);
        run_case("T4 maxneg K=3", 3);

        // T5 -- adversarial accumulation depth
        run_case("T5 maxneg K=2048", 2048);

        // T6 -- restart with no intervening reset
        fill_const(4'sd2, 4'sd3);
        run_case("T6 restart A K=17", 17);
        run_case("T6 restart B K=9", 9);

        // T7 / T8 -- random regression
        fill_random(sd);
        run_case("T7 random K=37", 37);
        run_case("T8 random K=1024", 1024);

        // ===== everything above is the pre-addend suite, unchanged. If any of
        // T1..T8 regresses, the addend work broke the baseline. =====

        // A-series -- INIT_KEEP, i.e. D = A@B + D_prev. Chaining k-tiles.
        fill_const(4'sd1, 4'sd1);
        run_case_m("A1 keep base K=4",   4, INIT_ZERO);   // -> 4
        run_case_m("A2 keep +K=4",       4, INIT_KEEP);   // -> 8
        run_case_m("A3 keep +K=4 again", 4, INIT_KEEP);   // -> 12
        run_case_m("A4 keep K=0 noop",   0, INIT_KEEP);   // -> 12, must not move
        run_case_m("A5 zero re-clears",  4, INIT_ZERO);   // -> 4. THE negative
        //   test: chaining must not have turned the clear into a no-op.

        // B-series -- INIT_C, i.e. D = A@B + c_in with C supplied externally.
        if (C_PORT != 0) begin
            set_c_zero;
            run_case_m("B1 c=0 K=4",         4, INIT_C);  // must equal INIT_ZERO
            set_c_pattern;
            run_case_m("B2 c=distinct K=0",  0, INIT_C);  // D == C exactly:
            //   with K=0 nothing is accumulated, so this isolates the preload
            //   path. An index swap, a short slice or a dropped element shows
            //   up here and nowhere else.
            run_case_m("B3 c=distinct K=4",  4, INIT_C);
            set_c_extreme;
            run_case_m("B4 c=wide+neg K=3",  3, INIT_C);
            set_c_zero;
        end else begin
            $display("  [SKIP] B-series (INIT_C) -- built with C_PORT=0");
        end

        // M-series -- the matrix-product claim, against a third model.
        check_matmul("M1 D=A@B", INIT_ZERO);
        if (C_PORT != 0) begin
            set_c_pattern;
            check_matmul("M2 D=A@B+C", INIT_C);
            set_c_zero;
        end

        $display("=== %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count != 0) $display("RESULT: FAIL");
        else                 $display("RESULT: PASS");
        $finish;
    end

    initial begin
        #4000000;
        $display("RESULT: FAIL (global timeout)");
        $finish;
    end
endmodule
