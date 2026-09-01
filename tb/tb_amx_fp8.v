`timescale 1ns/1ps
//=============================================================================
// tb_amx_fp8 -- regression for the AMX-FP8 tile dot product, all four variants.
//
//------------------------------------------------------- WHAT THIS TESTS, AND
//------------------------------------------------------- WHAT IT DOES NOT
// The arithmetic is ALREADY PROVEN, elsewhere and exhaustively:
//
//   tb/tb_fp8_mul.v    all 4 format pairs x 256 x 256 = 262,144 cases against an
//                      independently written model, four checksums tied to
//                      tb/fp8_golden.py, and every product shown to be exact.
//   tb/tb_fp32_add.v   121k checks: RNE ties both parities, the alignment cap,
//                      deep cancellation, DAZ, FTZ, the whole Inf/NaN matrix,
//                      commutativity. 14 mutations, all caught.
//
// So this testbench is about the things only the ARRAY can get wrong: the VNNI
// interleave, the k schedule, which lane feeds which accumulator, the epilogue
// order, the cycle count, and the format plumbing that turns op[1:0] into two
// decoder settings.
//
// It therefore uses THE PROVEN LEAF BLOCKS AS ITS ORACLE -- one fp8_dec pair,
// one fp8_mul and one fp32_add, instantiated outside the DUT and sequenced by
// tasks. That is compositional verification, not circularity: the leaves are
// established against independent models, and reusing them here means a
// mismatch can only be a schedule or layout fault, which is exactly the
// localisation you want. Writing a third Verilog FP32 adder would have added a
// possible bug, not a possible catch.
//
// The tie to a FULLY INDEPENDENT implementation is the golden block in case T3:
// corner values produced by tb/fp8_golden.py, which is two independent models of
// its own (exact-integer, and libc FP64 rounded to FP32).
//
//------------------------------------------------------------ THE TEETH
//   a transposed array (A@B vs B@A)   -> asymmetric A and B, and all four ops
//                                        must give DIFFERENT answers
//   a wrong VNNI interleave           -> case X1 packs 4b+k on purpose and
//                                        asserts the result CHANGES
//   swapped fmt_a/fmt_b               -> TDPBHF8PS and TDPHBF8PS compared
//   lanes summed into one accumulator -> the epilogue order is checked by the
//                                        golden constants, which differ by ~23%
//                                        of elements between orderings
//   right answer, more cycles         -> check() compares cycles FIRST
//   C moving after done               -> check_settled()
//=============================================================================
module tb_amx_fp8;

    // parameter, not localparam, so measure.sh can pass -Ptb_amx_fp8.RD_REG=
    parameter integer RD_REG = 1;

    localparam integer ROWS   = 16;
    localparam integer COLSB  = 64;
    localparam integer DWORDS = 16;
    localparam integer KDW    = 16;
    localparam integer LANE_N = 4;

    // 16 accumulate cycles + 3 epilogue + 1 for the IDLE->RUN transition. An
    // implementation that gets the right answer in more cycles is a different
    // design and must FAIL, not pass quietly.
    localparam integer EXP_CYC = KDW + 3 + 1;

    localparam [1:0] SEL_A = 2'd0, SEL_B = 2'd1, SEL_C = 2'd2;
    localparam [1:0] OP_BB = 2'b00,   // TDPBF8PS
                     OP_BH = 2'b01,   // TDPBHF8PS
                     OP_HB = 2'b10,   // TDPHBF8PS
                     OP_HH = 2'b11;   // TDPHF8PS
    localparam FMT_BF8 = 1'b0, FMT_HF8 = 1'b1;

    reg clk = 1'b0;
    reg rst_n = 1'b0;

    reg         tile_we;
    reg  [1:0]  tile_sel;
    reg  [3:0]  tile_row;
    reg  [511:0] tile_wdata;
    reg  [1:0]  op;
    reg         start;
    wire        busy, done;
    reg  [1:0]  rd_sel;
    reg  [3:0]  rd_row;
    wire [511:0] rd_data;

    amx_fp8 #(.RD_REG(RD_REG)) dut (
        .clk(clk), .rst_n(rst_n),
        .tile_we(tile_we), .tile_sel(tile_sel),
        .tile_row(tile_row), .tile_wdata(tile_wdata),
        .op(op), .start(start), .busy(busy), .done(done),
        .rd_sel(rd_sel), .rd_row(rd_row), .rd_data(rd_data)
    );

    // THE CLOCK IS GATED WHILE THE MODEL RUNS, and this is a 7x speedup rather
    // than a nicety. The oracle below settles combinational logic with #1, and
    // the clock period is also 1 ns -- so every one of the ~34,000 oracle
    // evaluations per case was advancing time across a clock edge and
    // re-clocking all 1024 accumulators in the DUT for nothing. Freezing the
    // clock during model_c drops the case from ~3 s to well under half of that.
    // model_c always runs before load_tiles, so the DUT is idle either way.
    reg clk_run = 1'b1;
    always #0.5 if (clk_run) clk = ~clk;

    // ---- the oracle: proven leaf blocks, driven combinationally ------------
    reg  [7:0] o_ab, o_bb;
    reg        o_fa, o_fb;
    wire       oa_sgn, oa_zero, oa_inf, oa_nan, ob_sgn, ob_zero, ob_inf, ob_nan;
    wire signed [5:0] oa_exp, ob_exp;
    wire [3:0] oa_sig, ob_sig;
    wire [31:0] o_prod;
    reg  [31:0] o_x, o_y;
    wire [31:0] o_sum;

    fp8_dec o_da (.b_in(o_ab), .fmt(o_fa), .sgn(oa_sgn), .exp(oa_exp),
                  .sig4(oa_sig), .is_zero(oa_zero), .is_inf(oa_inf), .is_nan(oa_nan));
    fp8_dec o_db (.b_in(o_bb), .fmt(o_fb), .sgn(ob_sgn), .exp(ob_exp),
                  .sig4(ob_sig), .is_zero(ob_zero), .is_inf(ob_inf), .is_nan(ob_nan));
    fp8_mul o_mul (.a_sgn(oa_sgn), .a_exp(oa_exp), .a_sig(oa_sig),
                   .a_zero(oa_zero), .a_inf(oa_inf), .a_nan(oa_nan),
                   .b_sgn(ob_sgn), .b_exp(ob_exp), .b_sig(ob_sig),
                   .b_zero(ob_zero), .b_inf(ob_inf), .b_nan(ob_nan), .y(o_prod));
    fp32_add o_add (.a(o_x), .b(o_y), .y(o_sum));

    // ---- operands, expectation, result -------------------------------------
    reg [7:0]  a_log [0:ROWS-1][0:COLSB-1];    // A[m][K], K = 0..63
    reg [7:0]  b_log [0:COLSB-1][0:DWORDS-1];  // B[K][n]
    reg [31:0] c_pre [0:ROWS-1][0:DWORDS-1];
    reg [31:0] exp_c [0:ROWS-1][0:DWORDS-1];
    reg [31:0] got   [0:ROWS-1][0:DWORDS-1];

    // the finite-byte pools, built once; index space matches fp8_golden.py's
    // _finite_bytes() so asym_a/asym_b generate the same tiles in both languages
    reg [7:0] pool_tab [0:1][0:255];
    integer   pool_n   [0:1];

    integer pass_count = 0;
    integer fail_count = 0;
    integer cyc_count;
    integer seed;
    integer mi, ni, ki, bi, Ki;
    reg [3:0] rsel;
    reg [7:0] vb;

    // ---- pools --------------------------------------------------------------
    function is_fin;
        input [7:0] v;
        input       fmt;
        begin
            if (!fmt) is_fin = (((v >> 2) & 8'h1F) != 8'h1F);           // E5M2
            else      is_fin = !((((v >> 3) & 8'h0F) == 8'h0F)
                                 && ((v & 8'h07) == 8'h07));           // E4M3
        end
    endfunction

    task build_pools;
        integer f, v, c;
        reg [7:0] bv;
        begin
            for (f = 0; f < 2; f = f + 1) begin
                c = 0;
                for (v = 0; v < 256; v = v + 1) begin
                    bv = v;
                    if (is_fin(bv, f[0])) begin
                        pool_tab[f][c] = bv;
                        c = c + 1;
                    end
                end
                pool_n[f] = c;
            end
        end
    endtask

    function fmt_of_a; input [1:0] o; begin fmt_of_a = o[1]; end endfunction
    function fmt_of_b; input [1:0] o; begin fmt_of_b = o[0]; end endfunction

    // ---- generators. asym_* mirror tb/fp8_golden.py exactly ---------------
    task fill_asym_a(input fmt);
        integer m, K;
        begin
            for (m = 0; m < ROWS; m = m + 1)
                for (K = 0; K < COLSB; K = K + 1)
                    a_log[m][K] = pool_tab[fmt][(m*7 + K*3 + 1) % pool_n[fmt]];
        end
    endtask

    task fill_asym_b(input fmt);
        integer n, K;
        begin
            for (K = 0; K < COLSB; K = K + 1)
                for (n = 0; n < DWORDS; n = n + 1)
                    b_log[K][n] = pool_tab[fmt][(n*5 + K*11 + 2) % pool_n[fmt]];
        end
    endtask

    task fill_const_a(input [7:0] v);
        integer m, K;
        begin
            for (m = 0; m < ROWS; m = m + 1)
                for (K = 0; K < COLSB; K = K + 1) a_log[m][K] = v;
        end
    endtask

    task fill_const_b(input [7:0] v);
        integer n, K;
        begin
            for (K = 0; K < COLSB; K = K + 1)
                for (n = 0; n < DWORDS; n = n + 1) b_log[K][n] = v;
        end
    endtask

    // B = I: C must come back as A widened to FP32 (up to the sign of zero).
    task fill_identity_b(input fmt);
        integer n, K;
        reg [7:0] one;
        begin
            one = fmt ? 8'h38 : 8'h3C;          // +1.0 in E4M3 / E5M2
            for (K = 0; K < COLSB; K = K + 1)
                for (n = 0; n < DWORDS; n = n + 1)
                    b_log[K][n] = (K == n) ? one : 8'h00;
        end
    endtask

    task fill_random(input fmt);
        integer m, n, K, r;
        begin
            for (m = 0; m < ROWS; m = m + 1)
                for (K = 0; K < COLSB; K = K + 1) begin
                    r = $random(seed);
                    if (r < 0) r = -r;
                    a_log[m][K] = pool_tab[fmt][r % pool_n[fmt]];
                end
            for (K = 0; K < COLSB; K = K + 1)
                for (n = 0; n < DWORDS; n = n + 1) begin
                    r = $random(seed);
                    if (r < 0) r = -r;
                    b_log[K][n] = pool_tab[fmt][r % pool_n[fmt]];
                end
        end
    endtask

    task set_c_zero;
        integer m, n;
        begin
            for (m = 0; m < ROWS; m = m + 1)
                for (n = 0; n < DWORDS; n = n + 1) c_pre[m][n] = 32'h0;
        end
    endtask

    // ---- oracle helpers ----------------------------------------------------
    task orc_mul(input [7:0] av, input [7:0] bv, output [31:0] p);
        begin
            o_ab = av; o_bb = bv; #1; p = o_prod;
        end
    endtask

    task orc_add(input [31:0] x, input [31:0] y, output [31:0] s);
        begin
            o_x = x; o_y = y; #1; s = o_sum;
        end
    endtask

    // The model: four independent lane accumulators, then the balanced-tree
    // epilogue, then one add into C -- mirroring the RTL's cycle schedule
    // exactly, including which operand lands on which port.
    task model_c(input [1:0] o);
        integer m, n, k, b;
        reg [31:0] lane [0:3];
        reg [31:0] p, t0, t1, s, tmp;
        begin
            clk_run = 1'b0;             // see the clock declaration
            o_fa = fmt_of_a(o);
            o_fb = fmt_of_b(o);
            for (m = 0; m < ROWS; m = m + 1)
                for (n = 0; n < DWORDS; n = n + 1) begin
                    for (b = 0; b < LANE_N; b = b + 1) lane[b] = 32'h0;
                    for (k = 0; k < KDW; k = k + 1)
                        for (b = 0; b < LANE_N; b = b + 1) begin
                            orc_mul(a_log[m][4*k+b], b_log[4*k+b][n], p);
                            orc_add(lane[b], p, tmp);
                            lane[b] = tmp;
                        end
                    orc_add(lane[0], lane[1], t0);
                    orc_add(lane[2], lane[3], t1);
                    orc_add(t0, t1, s);
                    orc_add(s, c_pre[m][n], exp_c[m][n]);
                end
            clk_run = 1'b1;
        end
    endtask

    // ---- driving -----------------------------------------------------------
    // `bad_pack` deliberately interleaves B as 4b+k instead of 4k+b, so case X1
    // can prove the interleave test has teeth.
    task load_tiles(input bad_pack);
        reg [511:0] wd;
        integer m, k, n, K, bb;
        begin
            for (m = 0; m < ROWS; m = m + 1) begin
                wd = {512{1'b0}};
                for (K = 0; K < COLSB; K = K + 1) wd[K*8 +: 8] = a_log[m][K];
                @(negedge clk);
                rsel = m;
                tile_we = 1'b1; tile_sel = SEL_A; tile_row = rsel; tile_wdata = wd;
            end
            for (k = 0; k < KDW; k = k + 1) begin
                wd = {512{1'b0}};
                for (n = 0; n < DWORDS; n = n + 1)
                    for (bb = 0; bb < LANE_N; bb = bb + 1)
                        wd[(n*4 + bb)*8 +: 8] = bad_pack ? b_log[4*bb + k][n]
                                                         : b_log[4*k + bb][n];
                @(negedge clk);
                rsel = k;
                tile_we = 1'b1; tile_sel = SEL_B; tile_row = rsel; tile_wdata = wd;
            end
            for (m = 0; m < ROWS; m = m + 1) begin
                wd = {512{1'b0}};
                for (n = 0; n < DWORDS; n = n + 1) wd[n*32 +: 32] = c_pre[m][n];
                @(negedge clk);
                rsel = m;
                tile_we = 1'b1; tile_sel = SEL_C; tile_row = rsel; tile_wdata = wd;
            end
            @(negedge clk);
            tile_we = 1'b0; tile_wdata = {512{1'b0}};
        end
    endtask

    task run_op(input [1:0] o);
        begin
            @(negedge clk); op = o; start = 1'b1;
            @(negedge clk); start = 1'b0;
            cyc_count = 0;
            while (done !== 1'b1 && cyc_count < (4*KDW + 64)) begin
                @(posedge clk);
                cyc_count = cyc_count + 1;
            end
        end
    endtask

    // Same as run_op, but scribbles a DIFFERENT op onto the input two cycles in.
    // Exists because op_r is otherwise untestable: run_op holds op steady for the
    // whole instruction, so an implementation that read the live op input instead
    // of the latched copy behaved identically and survived mutation.
    task run_op_scribble(input [1:0] o, input [1:0] other);
        begin
            @(negedge clk); op = o; start = 1'b1;
            @(negedge clk); start = 1'b0;
            cyc_count = 0;
            while (done !== 1'b1 && cyc_count < (4*KDW + 64)) begin
                @(posedge clk);
                cyc_count = cyc_count + 1;
                if (cyc_count == 2) op = other;
            end
        end
    endtask

    task readback;
        integer m, n;
        begin
            rd_sel = SEL_C;
            for (m = 0; m < ROWS; m = m + 1) begin
                @(negedge clk);
                rsel = m;
                rd_row = rsel;
                // ALWAYS a second half-cycle, for BOTH RD_REG settings. Setting
                // rd_row and sampling a combinational rd_data in the same delta
                // races the always @* that drives it; on tpu_mmu that read every
                // row one late. This does NOT assert readback latency -- only the
                // OPERATION's cycle count is asserted, by check().
                @(negedge clk);
                for (n = 0; n < DWORDS; n = n + 1) got[m][n] = rd_data[n*32 +: 32];
            end
        end
    endtask

    // ---- checking ----------------------------------------------------------
    task check(input [8*34:1] name);
        integer bad, fm, fn, m, n;
        begin
            bad = 0; fm = -1; fn = -1;
            for (m = 0; m < ROWS; m = m + 1)
                for (n = 0; n < DWORDS; n = n + 1)
                    if (got[m][n] !== exp_c[m][n]) begin
                        bad = bad + 1;
                        if (fm < 0) begin fm = m; fn = n; end
                    end
            if (cyc_count !== EXP_CYC) begin
                $display("  [FAIL] %0s : %0d cycles, expected %0d",
                         name, cyc_count, EXP_CYC);
                fail_count = fail_count + 1;
            end else if (bad == 0) begin
                $display("  [PASS] %-34s cycles=%0d", name, cyc_count);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] %0s : %0d/%0d wrong, first C[%0d][%0d] got %08h want %08h",
                         name, bad, ROWS*DWORDS, fm, fn, got[fm][fn], exp_c[fm][fn]);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task check_settled(input [8*34:1] name);
        integer moved, m, n;
        reg [31:0] snap [0:ROWS-1][0:DWORDS-1];
        begin
            for (m = 0; m < ROWS; m = m + 1)
                for (n = 0; n < DWORDS; n = n + 1) snap[m][n] = got[m][n];
            repeat (6) @(posedge clk);
            readback;
            moved = 0;
            for (m = 0; m < ROWS; m = m + 1)
                for (n = 0; n < DWORDS; n = n + 1)
                    if (got[m][n] !== snap[m][n]) moved = moved + 1;
            if (moved != 0) begin
                $display("  [FAIL] %0s : C MOVED after done -- %0d accumulators changed",
                         name, moved);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task do_case(input [1:0] o, input [8*34:1] name);
        begin
            model_c(o);
            load_tiles(1'b0);
            run_op(o);
            readback;
            check(name);
            check_settled(name);
            repeat (2) @(posedge clk);
        end
    endtask

    // ---- the run -----------------------------------------------------------
    initial begin
        tile_we = 1'b0; tile_sel = 2'd0; tile_row = 4'd0;
        tile_wdata = {512{1'b0}};
        op = 2'd0; start = 1'b0; rd_sel = SEL_C; rd_row = 4'd0;
        seed = 32'h0BAD_F00D;
        o_ab = 8'h00; o_bb = 8'h00; o_fa = 1'b0; o_fb = 1'b0;
        o_x = 32'h0; o_y = 32'h0;
        build_pools;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        $display("=== tb_amx_fp8  RD_REG=%0d  (%0d MACs/instruction, EXP_CYC=%0d) ===",
                 RD_REG, ROWS*DWORDS*COLSB, EXP_CYC);
        $display("    pools: BF8 %0d finite bytes, HF8 %0d", pool_n[0], pool_n[1]);

        // ---- T: functional, all four instructions --------------------------
        fill_asym_a(FMT_BF8); fill_identity_b(FMT_BF8); set_c_zero;
        do_case(OP_BB, "T1 identity B passes A through");

        fill_asym_a(FMT_BF8); fill_const_b(8'h00); set_c_zero;
        b_log[1][0] = 8'h3C;                 // B[1][0]=1 -> C[m][0]=A[m][1]
        do_case(OP_BB, "T2 single B element");

        // The asymmetric pair, once per instruction. Same A/B byte patterns are
        // NOT used across ops -- each op draws from its own format's pool, which
        // is what fp8_golden.py's --print-golden does.
        fill_asym_a(FMT_BF8); fill_asym_b(FMT_BF8); set_c_zero;
        do_case(OP_BB, "T3a TDPBF8PS  asymmetric");
        if (got[0][0] !== 32'h4bad642a || got[0][1] !== 32'h4c50a68d ||
            got[1][0] !== 32'h4c98569f || got[15][15] !== 32'h4e819292) begin
            $display("  [FAIL] T3a golden : DUT disagrees with tb/fp8_golden.py");
            $display("         got %08h %08h %08h %08h", got[0][0], got[0][1],
                     got[1][0], got[15][15]);
            fail_count = fail_count + 1;
        end else begin
            $display("  [PASS] %-34s (vs fp8_golden.py)", "T3a golden cross-check");
            pass_count = pass_count + 1;
        end

        fill_asym_a(FMT_BF8); fill_asym_b(FMT_HF8); set_c_zero;
        do_case(OP_BH, "T3b TDPBHF8PS asymmetric");
        if (got[0][0] !== 32'h491e647b || got[15][15] !== 32'h4b030b7f) begin
            $display("  [FAIL] T3b golden : got %08h %08h", got[0][0], got[15][15]);
            fail_count = fail_count + 1;
        end else begin
            $display("  [PASS] %-34s (vs fp8_golden.py)", "T3b golden cross-check");
            pass_count = pass_count + 1;
        end

        fill_asym_a(FMT_HF8); fill_asym_b(FMT_BF8); set_c_zero;
        do_case(OP_HB, "T3c TDPHBF8PS asymmetric");
        if (got[0][0] !== 32'h496fa178 || got[15][15] !== 32'hca8e4508) begin
            $display("  [FAIL] T3c golden : got %08h %08h", got[0][0], got[15][15]);
            fail_count = fail_count + 1;
        end else begin
            $display("  [PASS] %-34s (vs fp8_golden.py)", "T3c golden cross-check");
            pass_count = pass_count + 1;
        end

        fill_asym_a(FMT_HF8); fill_asym_b(FMT_HF8); set_c_zero;
        do_case(OP_HH, "T3d TDPHF8PS  asymmetric");
        if (got[0][0] !== 32'h46be0730 || got[15][15] !== 32'h4742425c) begin
            $display("  [FAIL] T3d golden : got %08h %08h", got[0][0], got[15][15]);
            fail_count = fail_count + 1;
        end else begin
            $display("  [PASS] %-34s (vs fp8_golden.py)", "T3d golden cross-check");
            pass_count = pass_count + 1;
        end

        fill_random(FMT_BF8); set_c_zero;
        do_case(OP_BB, "T4 random BF8");
        fill_random(FMT_HF8); set_c_zero;
        do_case(OP_HH, "T5 random HF8");

        // ---- E: numeric extremes -------------------------------------------
        // 57344 x 57344 x 64 = 49*2^32 exactly. Nothing here can overflow FP32,
        // which is the range argument the design leans on.
        fill_const_a(8'h7B); fill_const_b(8'h7B); set_c_zero;
        do_case(OP_BB, "E1 max BF8 x max BF8");
        fill_const_a(8'h7E); fill_const_b(8'h7E); set_c_zero;
        do_case(OP_HH, "E2 max HF8 x max HF8 (448)");
        fill_const_a(8'h7B); fill_const_b(8'h7E); set_c_zero;
        do_case(OP_BH, "E3 max BF8 x max HF8 mixed");
        // min normals, at the other end of the range
        fill_const_a(8'h04); fill_const_b(8'h04); set_c_zero;
        do_case(OP_BB, "E4 min normal BF8 squared");

        // ---- D: DAZ, and signed zero ---------------------------------------
        // Subnormal inputs must read as zero, so C must be untouched.
        fill_const_a(8'h01); fill_asym_b(FMT_BF8);
        for (mi = 0; mi < ROWS; mi = mi + 1)
            for (ni = 0; ni < DWORDS; ni = ni + 1)
                c_pre[mi][ni] = 32'h3F800000 + mi*16 + ni;
        do_case(OP_BB, "D1 subnormal A is zero (DAZ)");
        fill_asym_a(FMT_HF8); fill_const_b(8'h81);
        do_case(OP_HH, "D2 negative subnormal B (DAZ)");

        // ---- S: specials ----------------------------------------------------
        // Inf x finite -> Inf, and Inf x 0 -> NaN, propagated through 64 adds.
        fill_const_a(8'h7C); fill_const_b(8'h3C); set_c_zero;   // Inf x 1
        do_case(OP_BB, "S1 Inf A gives Inf");
        fill_const_a(8'h7C); fill_const_b(8'h00); set_c_zero;   // Inf x 0
        do_case(OP_BB, "S2 Inf x 0 gives NaN");
        fill_const_a(8'h7D); fill_asym_b(FMT_BF8); set_c_zero;  // NaN A
        do_case(OP_BB, "S3 NaN A propagates");
        // E4M3's exp==15 normals must NOT be read as specials: 448 x 1 = 448.
        fill_const_a(8'h7E); fill_identity_b(FMT_HF8); set_c_zero;
        do_case(OP_HH, "S4 E4M3 exp==15 is a normal");

        // ---- C: accumulation chains ----------------------------------------
        fill_asym_a(FMT_BF8); fill_asym_b(FMT_BF8); set_c_zero;
        do_case(OP_BB, "C1 first accumulate");
        for (mi = 0; mi < ROWS; mi = mi + 1)
            for (ni = 0; ni < DWORDS; ni = ni + 1) c_pre[mi][ni] = got[mi][ni];
        do_case(OP_BB, "C2 second accumulate onto it");

        // A DIFFERENT INSTRUCTION on the next call, without a reset. Proves op
        // is latched per instruction and both decoders re-configure.
        fill_asym_a(FMT_HF8); fill_asym_b(FMT_HF8); set_c_zero;
        do_case(OP_HH, "C3 op switches between ops");

        // op must be LATCHED at start. Drive TDPHF8PS, then scribble TDPBF8PS
        // onto the input two cycles in: the result must still be TDPHF8PS. The
        // HF8 pool contains 7C/7D/7E, which are Inf and NaN when misread as BF8,
        // so a DUT that follows the live input cannot come close.
        fill_asym_a(FMT_HF8); fill_asym_b(FMT_HF8); set_c_zero;
        model_c(OP_HH);
        load_tiles(1'b0);
        run_op_scribble(OP_HH, OP_BB);
        readback;
        check("C4 op is latched at start");

        // ---- Z: degenerate --------------------------------------------------
        fill_asym_a(FMT_BF8); fill_const_b(8'h00);
        for (mi = 0; mi < ROWS; mi = mi + 1)
            for (ni = 0; ni < DWORDS; ni = ni + 1)
                c_pre[mi][ni] = 32'hC1200000 + mi*32 + ni;
        do_case(OP_BB, "Z1 zero B preserves C");

        // ---- X: the interleave test must have teeth ------------------------
        // Pack B as 4b+k instead of 4k+b and require the answer to CHANGE. If it
        // did not, every check above would be blind to the VNNI layout.
        fill_asym_a(FMT_BF8); fill_asym_b(FMT_BF8); set_c_zero;
        model_c(OP_BB);
        load_tiles(1'b1);                    // deliberately wrong interleave
        run_op(OP_BB);
        readback;
        mi = 0;
        for (ni = 0; ni < DWORDS; ni = ni + 1)
            if (got[0][ni] !== exp_c[0][ni]) mi = mi + 1;
        if (mi == 0) begin
            $display("  [FAIL] X1 a 4b+k interleave was NOT detected -- the layout is untested");
            fail_count = fail_count + 1;
        end else begin
            $display("  [PASS] %-34s (%0d/%0d row-0 elements differ)",
                     "X1 wrong interleave is detected", mi, DWORDS);
            pass_count = pass_count + 1;
        end

        $display("=== %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count != 0) $display("RESULT: FAIL");
        else                 $display("RESULT: PASS");
        $finish;
    end

    initial begin
        #500000000;
        $display("RESULT: FAIL (global timeout)");
        $finish;
    end
endmodule
