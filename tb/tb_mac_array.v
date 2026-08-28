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
// The expected value is computed here from the same memory contents, by a
// separate triple loop. It is NOT taken from the DUT.
//=============================================================================
module tb_mac_array;

    // parameters (not localparams) so measure.sh can sweep N via -Ptb_mac_array.N=
    parameter integer N     = 4;
    parameter integer KW    = 16;
    parameter integer ACC_W = 24;
    localparam integer DEPTH = 4096;
    localparam integer NN    = N*N;
    localparam integer OAW   = (NN <= 2) ? 1 : $clog2(NN);

    reg                      clk = 1'b0;
    reg                      rst_n = 1'b0;
    reg                      start = 1'b0;
    reg  [KW-1:0]            k_dim = {KW{1'b0}};
    wire                     busy, done;

    wire                     act_req, wgt_req;
    wire [KW-1:0]            act_addr, wgt_addr;
    reg  [N*4-1:0]           act_rdata, wgt_rdata;

    wire                     out_we;
    wire [OAW-1:0]           out_addr;
    wire signed [ACC_W-1:0]  out_wdata;

    // ---- behavioural 1-cycle-latency memories -------------------------------
    reg [N*4-1:0] amem [0:DEPTH-1];
    reg [N*4-1:0] wmem [0:DEPTH-1];

    always @(posedge clk) begin
        act_rdata <= amem[act_addr];
        wgt_rdata <= wmem[wgt_addr];
    end

    // ---- DUT ----------------------------------------------------------------
    mac_array #(.N(N), .KW(KW), .ACC_W(ACC_W)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .k_dim(k_dim), .busy(busy), .done(done),
        .act_req(act_req), .act_addr(act_addr), .act_rdata(act_rdata),
        .wgt_req(wgt_req), .wgt_addr(wgt_addr), .wgt_rdata(wgt_rdata),
        .out_we(out_we), .out_addr(out_addr), .out_wdata(out_wdata)
    );

    always #0.5 clk = ~clk;

    // ---- result capture -----------------------------------------------------
    reg signed [ACC_W-1:0] got [0:NN-1];
    reg        [NN-1:0]    seen;

    always @(posedge clk) begin
        if (out_we) begin
            got[out_addr]  <= out_wdata;
            seen[out_addr] <= 1'b1;
        end
    end

    // ---- independent reference ----------------------------------------------
    reg signed [ACC_W-1:0] expected [0:NN-1];

    task compute_expected(input integer k);
        integer kk, ii, jj;
        reg [N*4-1:0] aw, ww;
        reg signed [3:0] av, wv;
        begin
            for (ii = 0; ii < NN; ii = ii + 1)
                expected[ii] = {ACC_W{1'b0}};
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

    task run_case(input [8*24:1] name, input integer k);
        integer idx, guard;
        begin
            compute_expected(k);
            seen      = {NN{1'b0}};
            cyc_count = 0;

            k_dim <= k[KW-1:0];
            start <= 1'b1;
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
                        $display("  [PASS] %-22s K=%-6d cycles=%0d", name, k, cyc_count);
                        pass_count = pass_count + 1;
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
