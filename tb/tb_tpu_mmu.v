`timescale 1ns/1ps
//=============================================================================
// tb_tpu_mmu -- regression for the weight-stationary systolic matrix unit.
//
// THE MODEL SPLIT, and why the cycle-accurate model is NOT reimplemented here.
//
// tb/amx_golden.py states the rule this repo follows: three models that agree are
// evidence, two models where one is derived from the other are one model. A
// Verilog transliteration of tpu_golden.py's systolic() would be exactly that --
// the same model typed twice, agreeing because it shares every assumption,
// including a wrong one. So the models are split by KIND, not by language:
//
//   model_matmul()   here, in Verilog. Textbook C += A*W triple loop. Knows
//                    nothing about skew, systole, cycles or hardware. This is
//                    what catches a schedule that is self-consistently wrong --
//                    an array that computes A' * W perfectly happily.
//
//   systolic()       in tb/tpu_golden.py. Cycle-accurate, and it threads the
//                    output row index through the array to ASSERT that every
//                    contribution landing in one accumulator came from the same
//                    row. That provenance proof is practical in Python and
//                    miserable in Verilog, so it lives there.
//
//   the constants    case T3 below hardcodes values produced by tpu_golden.py.
//                    That is the tie between the two languages: a misconception
//                    shared by the Verilog DUT and the Verilog model would still
//                    have to survive agreeing with an independently written
//                    Python cycle-accurate simulation.
//
// WHAT THE VALUE CHECKS ALONE WOULD MISS, and what covers it:
//
//   a transposed array (A'*W instead of A*W)  -> T1/T2/T3 use ASYMMETRIC operands
//                                               where A*W != W*A. With symmetric
//                                               test data every transpose passes.
//   a schedule shifted by one row             -> the hardcoded T3 constants, and
//                                               tpu_golden.py's own negative test
//   an array that is right but slower         -> check() compares cycles FIRST
//   accumulators that keep moving after done  -> check_settled()
//   psum too narrow                           -> E1 drives all -128, which lands
//                                               exactly on the N*16384 bound
//=============================================================================
module tb_tpu_mmu;

    // parameter, not localparam, so measure.sh can pass -Ptb_tpu_mmu.N=
    parameter integer N      = 32;
    // Readback register. Does not change the operation's cycle count -- it costs
    // a cycle of READBACK latency only -- so EXP_CYC is untouched by it.
    parameter integer RD_REG = 1;

    localparam integer AW     = $clog2(N);
    localparam integer ACC_W  = 32;
    localparam integer PSUM_W = 16 + $clog2(N);

    localparam [1:0] SEL_W = 2'd0, SEL_A = 2'd1, SEL_C = 2'd2;

    // Expected cycles from the start edge to done. The last accumulator fires at
    // ccnt = (N-1) + (N-1) + N = 3N-2, so ccnt takes 3N-1 values, plus one cycle
    // for the IDLE->RUN transition. An implementation that produced the right
    // answer in more cycles must FAIL, not pass quietly.
    localparam integer EXP_CYC = 3*N;

    reg clk = 1'b0;
    reg rst_n = 1'b0;

    reg                 tile_we;
    reg  [1:0]          tile_sel;
    reg  [AW-1:0]       tile_row;
    reg  [N*32-1:0]     tile_wdata;
    reg                 start;
    wire                busy;
    wire                done;
    reg  [AW-1:0]       rd_row;
    wire [N*32-1:0]     rd_data;

    tpu_mmu #(.N(N), .RD_REG(RD_REG)) dut (
        .clk(clk), .rst_n(rst_n),
        .tile_we(tile_we), .tile_sel(tile_sel),
        .tile_row(tile_row), .tile_wdata(tile_wdata),
        .start(start), .busy(busy), .done(done),
        .rd_row(rd_row), .rd_data(rd_data)
    );

    always #0.5 clk = ~clk;

    // ---- operands and results ----------------------------------------------
    reg signed [7:0]       a_log [0:N-1][0:N-1];   // A[m][i]
    reg signed [7:0]       w_log [0:N-1][0:N-1];   // W[i][j]
    reg signed [ACC_W-1:0] c_pre [0:N-1][0:N-1];   // C before the operation
    reg signed [ACC_W-1:0] exp_mm[0:N-1][0:N-1];   // textbook model
    reg signed [ACC_W-1:0] got   [0:N-1][0:N-1];   // read back from the DUT

    integer pass_count = 0;
    integer fail_count = 0;
    integer cyc_count;
    integer i, j, m, t;
    integer seed;

    // ---- model: textbook C += A*W ------------------------------------------
    // Deliberately the dumbest possible formulation. Wrapping is implicit in the
    // 32-bit signed accumulator, which is what the DUT does too.
    task model_matmul;
        integer mm, jj, ii;
        reg signed [ACC_W-1:0] s;
        begin
            for (mm = 0; mm < N; mm = mm + 1)
                for (jj = 0; jj < N; jj = jj + 1) begin
                    s = c_pre[mm][jj];
                    for (ii = 0; ii < N; ii = ii + 1)
                        s = s + a_log[mm][ii] * w_log[ii][jj];
                    exp_mm[mm][jj] = s;
                end
        end
    endtask

    // ---- operand generators -------------------------------------------------
    task fill_identity_w;
        begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1)
                    w_log[i][j] = (i == j) ? 8'sd1 : 8'sd0;
        end
    endtask

    task fill_zero_w;
        begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) w_log[i][j] = 8'sd0;
        end
    endtask

    // ASYMMETRIC on purpose, and the same formulas as tpu_golden.py's asym_a /
    // asym_w so the hardcoded T3 constants mean something. A != A' and W != W'
    // and A*W != W*A, so a transposed array cannot pass.
    task fill_asym_a;
        begin
            for (m = 0; m < N; m = m + 1)
                for (i = 0; i < N; i = i + 1)
                    a_log[m][i] = ((m * 7 + i * 3 + 1) % 251) - 125;
        end
    endtask

    task fill_asym_w;
        begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1)
                    w_log[i][j] = ((i * 5 + j * 11 + 2) % 251) - 125;
        end
    endtask

    task fill_random;
        begin
            for (m = 0; m < N; m = m + 1)
                for (i = 0; i < N; i = i + 1)
                    a_log[m][i] = $random(seed);
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1)
                    w_log[i][j] = $random(seed);
        end
    endtask

    task fill_const_a(input signed [7:0] v);
        begin
            for (m = 0; m < N; m = m + 1)
                for (i = 0; i < N; i = i + 1) a_log[m][i] = v;
        end
    endtask

    task fill_const_w(input signed [7:0] v);
        begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) w_log[i][j] = v;
        end
    endtask

    task set_c_zero;
        begin
            for (m = 0; m < N; m = m + 1)
                for (j = 0; j < N; j = j + 1) c_pre[m][j] = 0;
        end
    endtask

    // ---- driving the DUT ----------------------------------------------------
    task load_tiles;
        reg [N*32-1:0] wd;
        begin
            // W, one row per write. Only the low N*8 bits carry a byte tile.
            for (i = 0; i < N; i = i + 1) begin
                wd = {(N*32){1'b0}};
                for (j = 0; j < N; j = j + 1) wd[j*8 +: 8] = w_log[i][j];
                @(negedge clk);
                tile_we = 1'b1; tile_sel = SEL_W; tile_row = i[AW-1:0];
                tile_wdata = wd;
            end
            // A, one row per write.
            for (m = 0; m < N; m = m + 1) begin
                wd = {(N*32){1'b0}};
                for (i = 0; i < N; i = i + 1) wd[i*8 +: 8] = a_log[m][i];
                @(negedge clk);
                tile_we = 1'b1; tile_sel = SEL_A; tile_row = m[AW-1:0];
                tile_wdata = wd;
            end
            // C preload, full 32-bit lanes.
            for (m = 0; m < N; m = m + 1) begin
                wd = {(N*32){1'b0}};
                for (j = 0; j < N; j = j + 1) wd[j*32 +: 32] = c_pre[m][j];
                @(negedge clk);
                tile_we = 1'b1; tile_sel = SEL_C; tile_row = m[AW-1:0];
                tile_wdata = wd;
            end
            @(negedge clk);
            tile_we = 1'b0; tile_wdata = {(N*32){1'b0}};
        end
    endtask

    // Pulse start and count clock edges until done. The 4*N+64 guard stops a
    // hung DUT from wedging the whole run.
    task run_op;
        begin
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            cyc_count = 0;
            while (done !== 1'b1 && cyc_count < (4*N + 64)) begin
                @(posedge clk);
                cyc_count = cyc_count + 1;
            end
        end
    endtask

    task readback;
        begin
            for (m = 0; m < N; m = m + 1) begin
                @(negedge clk);
                rd_row = m[AW-1:0];
                // ALWAYS wait a full extra half-cycle before sampling, for BOTH
                // RD_REG settings. An earlier version waited only when RD_REG=1,
                // reasoning that a combinational rd_data needs no edge -- and it
                // read every row one late, because setting rd_row and sampling
                // rd_data in the same delta cycle races the `always @*` that
                // drives it. The symptom was C[m] returning acc[m-1] at every N.
                //
                // This does NOT assert readback latency: nothing here would catch
                // RD_REG=1 costing two cycles instead of one. Only the OPERATION's
                // cycle count is asserted, by check().
                @(negedge clk);
                for (j = 0; j < N; j = j + 1) got[m][j] = rd_data[j*32 +: 32];
            end
        end
    endtask

    // ---- checking -----------------------------------------------------------
    task check(input [8*30:1] name);
        integer bad, fm, fj;
        begin
            bad = 0; fm = -1; fj = -1;
            for (m = 0; m < N; m = m + 1)
                for (j = 0; j < N; j = j + 1)
                    if (got[m][j] !== exp_mm[m][j]) begin
                        bad = bad + 1;
                        if (fm < 0) begin fm = m; fj = j; end
                    end
            // Cycle count FIRST: a design that computes the right answer in more
            // cycles is a different design and must not pass.
            if (cyc_count !== EXP_CYC) begin
                $display("  [FAIL] %0s : %0d cycles, expected %0d",
                         name, cyc_count, EXP_CYC);
                fail_count = fail_count + 1;
            end else if (bad == 0) begin
                $display("  [PASS] %-30s cycles=%0d  (vs textbook A*W)",
                         name, cyc_count);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s : %0d/%0d wrong, first C[%0d][%0d] got %0d want %0d",
                         name, bad, N*N, fm, fj, got[fm][fj], exp_mm[fm][fj]);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // C must be STABLE after done. Found necessary on the amx design by mutation:
    // delaying the accumulate enable by one cycle too many was invisible to every
    // value check, because the values were still right when finally read.
    task check_settled(input [8*30:1] name);
        integer moved;
        reg signed [ACC_W-1:0] snap [0:N-1][0:N-1];
        begin
            for (m = 0; m < N; m = m + 1)
                for (j = 0; j < N; j = j + 1) snap[m][j] = got[m][j];
            repeat (6) @(posedge clk);
            readback;
            moved = 0;
            for (m = 0; m < N; m = m + 1)
                for (j = 0; j < N; j = j + 1)
                    if (got[m][j] !== snap[m][j]) moved = moved + 1;
            if (moved != 0) begin
                $display("  [FAIL] %0s : C MOVED after done -- %0d accumulators changed",
                         name, moved);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task do_case(input [8*30:1] name);
        begin
            model_matmul;
            load_tiles;
            run_op;
            readback;
            check(name);
            check_settled(name);
            repeat (2) @(posedge clk);
        end
    endtask

    // ---- the run ------------------------------------------------------------
    initial begin
        tile_we = 1'b0; tile_sel = 2'd0; tile_row = {AW{1'b0}};
        tile_wdata = {(N*32){1'b0}};
        start = 1'b0; rd_row = {AW{1'b0}};
        seed = 32'h1234_5678;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        $display("=== tb_tpu_mmu  N=%0d RD_REG=%0d  (MACs=%0d, psum=%0d b, EXP_CYC=%0d) ===",
                 N, RD_REG, N*N, PSUM_W, EXP_CYC);

        // ---- T: functional -------------------------------------------------
        // Identity W must pass A through unchanged. The cheapest possible check
        // that the row/column mapping is not transposed.
        fill_asym_a; fill_identity_w; set_c_zero;
        do_case("T1 identity W passes A");

        // A single non-zero weight localises a transpose: W[1][0]=1 must make
        // column 0 of C equal column 1 of A, not row 1.
        fill_asym_a; fill_zero_w; set_c_zero;
        w_log[1][0] = 8'sd1;
        do_case("T2 single weight element");

        // The asymmetric pair, tied to tpu_golden.py by the constants below.
        fill_asym_a; fill_asym_w; set_c_zero;
        do_case("T3 asymmetric A and W");

        // Cross-language tie. These come from tb/tpu_golden.py's cycle-accurate
        // systolic model, NOT from the Verilog model above:
        //   python3 tb/tpu_golden.py --print-asym N
        if (N == 32) begin
            if (got[0][0]  !== 32'sd153760 || got[0][1]  !== 32'sd126480 ||
                got[1][0]  !== 32'sd143568 || got[31][31] !== -32'sd139944) begin
                $display("  [FAIL] T3 golden : DUT disagrees with tpu_golden.py");
                $display("         got C[0][0]=%0d C[0][1]=%0d C[1][0]=%0d C[31][31]=%0d",
                         got[0][0], got[0][1], got[1][0], got[31][31]);
                fail_count = fail_count + 1;
            end else begin
                $display("  [PASS] %-30s (vs tpu_golden.py systolic model)",
                         "T3 golden cross-check");
                pass_count = pass_count + 1;
            end
        end

        fill_random; set_c_zero;
        do_case("T4 random seed A");
        fill_random; set_c_zero;
        do_case("T5 random seed B");

        // ---- E: numeric extremes -------------------------------------------
        // All -128 is the maximum-magnitude case: every product is +16384 and
        // every column sum is exactly N*16384, which is what the exact psum
        // width 16+clog2(N) is sized for. Narrow the psum by one bit and this
        // case is the one that breaks.
        fill_const_a(-8'sd128); fill_const_w(-8'sd128); set_c_zero;
        do_case("E1 all -128, psum bound");

        fill_const_a(8'sd127); fill_const_w(8'sd127); set_c_zero;
        do_case("E2 all +127");

        // Mixed sign, so cancellation inside the column sum is exercised.
        fill_const_a(-8'sd128); fill_const_w(8'sd127); set_c_zero;
        do_case("E3 -128 x +127");

        // ---- C: accumulation chains ----------------------------------------
        // Two identical operations must give exactly twice one. This is what
        // proves C += is an accumulate and not an overwrite, and it runs without
        // a reset in between.
        fill_asym_a; fill_asym_w; set_c_zero;
        do_case("C1 first accumulate");
        for (m = 0; m < N; m = m + 1)
            for (j = 0; j < N; j = j + 1) c_pre[m][j] = got[m][j];
        do_case("C2 second accumulate");

        // A weight reload between operations must take effect. Without this a
        // DUT that latched W once and ignored later writes would pass everything.
        fill_identity_w; set_c_zero;
        do_case("C3 weight reload takes effect");

        // ---- Z: degenerate --------------------------------------------------
        // Zero W with a preloaded C: C must come back untouched. Catches an
        // accumulator that clears itself on start.
        fill_asym_a; fill_zero_w;
        for (m = 0; m < N; m = m + 1)
            for (j = 0; j < N; j = j + 1) c_pre[m][j] = (m * 1000 + j) - 5000;
        do_case("Z1 zero W preserves C");

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
