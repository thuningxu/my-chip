`timescale 1ns/1ps
//=============================================================================
// tb_amx_tdpbssd -- self-checking regression for amx_tdpbssd (Intel TDPBSSD).
//
// THREE MODELS, TWO INDEPENDENT AXES. This is the whole design of this file.
//
//   the DUT      reads the PHYSICAL tiles
//   exp_isa      the ISA pseudocode, transcribed, also on the PHYSICAL tiles
//   exp_mm       a textbook triple loop on the LOGICAL matrices, which never
//                mentions dwords or interleaving at all
//
// So a bug in pack_tiles() makes the DUT and exp_isa agree with each other and
// both disagree with exp_mm; a bug in the DUT's reading of the layout makes it
// disagree with exp_isa. Two different failures, two different signatures. A
// single expected-value model could not tell them apart, and a VNNI interleave
// is exactly the kind of mistake that produces plausible numbers.
//
// The Python model in tb/amx_golden.py is a FOURTH, independent opinion. Do not
// make any of them call another.
//
// Cases, and the bug each one exists to catch:
//
//   T1 all +1            -- smoke: every product 1, so C[m][n] == 64 exactly.
//   T2 all -128          -- -128 * -128 = +16384. NOTE this does NOT catch
//                           unsigned byte slicing: unsigned 128*128 is also
//                           16384, bit-identical. Same trap as mac_array's T4.
//                           T4 below is what actually catches it.
//   T3 asymmetric        -- a lost, doubled or transposed VNNI interleave.
//                           Symmetric tiles hide all three completely.
//   T4 mixed sign        -- contains -1 against +1, where unsigned slicing
//                           gives 255 instead of -1. THE sign-extension test.
//   T5 random            -- general regression against both models.
//   C1 C += chain        -- two instructions back to back with no reset, so
//                           DONE must not be terminal and C must survive.
//   S1/S2 high rail      -- SAT=1 must clamp to INT32_MAX; SAT=0 must wrap.
//   S3/S4 low rail       -- same at INT32_MIN.
//   S5 no-overflow       -- SAT=0 and SAT=1 must agree bit-for-bit when nothing
//                           overflows, which is always true for one instruction
//                           from C=0 (max |acc| = 1,048,576, 21 bits).
//   S6 fold ORDER        -- THE case that makes the k-SEQUENCE observable, not
//                           merely the fold's existence. sum4 is +4 for k=0..7
//                           then -4 for k=8..15, with C starting 10 below the
//                           rail, so the accumulator clamps partway through and
//                           then walks back down. Correct order lands on
//                           INT32_MAX-32; ANY permutation of k lands elsewhere
//                           (rotating by one gives -28). Added because a real
//                           mutation survived everything else -- see below.
//
// check_settled() also runs after every case: C must not move over 6 idle cycles
// after `done`. readback is combinational and happens before any further clock
// edge, so without this a design that keeps accumulating past `done` is invisible.
//
// Cycle count is ASSERTED, not printed: 16 k-steps plus fixed overhead. An
// implementation that computed the right answer in more cycles would otherwise
// pass silently.
//
// WHICH CASES HAVE TEETH -- measured by mutating the RTL, not assumed:
//
//   mutation                            SAT=0        SAT=1     caught by
//   reverse B's byte pairing (3-b)      4 fail       4 fail    T3, T5, S5
//   transpose the accumulator index     5 fail       5 fail    T3, T5, S5, C1
//   read A's byte lanes unsigned        6 fail       7 fail    T3, T4, T5, S5
//   ovf = raw[32] (not raw[32]^[31])    SURVIVES     7 fail    S2, S4, T3, T5
//   acc_en delayed one cycle too far    SURVIVES     2 fail    S6 ONLY
//   accumulate gated on run, not acc_en 14 fail     12 fail    nearly everything
//
// Three findings worth keeping:
//
// 1. T1, T2 and T4 all PASS the byte-reversal mutant. Uniform tiles cannot
//    detect a reordering, and T4's pattern happens to be period-2 in b so its
//    four-byte sum is invariant under reversal. ONLY the asymmetric and random
//    cases catch it -- which is why fill_asym exists and why deleting it would
//    quietly remove the interleave coverage.
//
// 2. The overflow-detect mutant surviving at SAT=0 is CORRECT, not a gap: the
//    fold is `((SAT != 0) && ovf) ? rail : raw[31:0]`, so at SAT=0 `ovf` is dead
//    logic and the parameter prunes it. A mutation in pruned hardware has
//    nothing to detect.
//
// 3. THE acc_en MUTANT EXPOSED A REAL HOLE, and S6 exists because of it. Delaying
//    the accumulate enable by one cycle does not DROP a k-step, it PERMUTES the
//    sequence (k=1..15 then k=0, the last landing in an idle cycle). Every test
//    here was blind to that:
//      - SAT=0 can NEVER see it -- wrapping addition is associative and
//        commutative, so a permutation is not merely undetected but undetectable.
//      - S1..S4 could not see it -- they use UNIFORM operands, and permuting
//        equal values changes nothing.
//      - The T-series could not see it -- C=0 and one instruction cannot overflow,
//        so no clamp ever occurs and order is irrelevant.
//    The suite tested that the fold HAPPENS and never that it happens in the
//    right ORDER, while the order is the specification. S6 is the fix, and it
//    catches the mutant at SAT=1 with exactly the predicted value.
//=============================================================================
module tb_amx_tdpbssd;

    // parameter, not localparam, so measure.sh can pass -Ptb_amx_tdpbssd.SAT=
    parameter integer SAT = 1;
    // Feed-forward pipeline depth. Adds latency, NOT cycles per k-step, so the
    // cycle model gains exactly PIPE.
    parameter integer PIPE = 0;
    // 1 = rd_data is registered, so readback needs a clock edge. Costs a cycle of
    // READBACK latency only -- it does not change the operation's cycle count, so
    // EXP_CYC is untouched.
    parameter integer RD_REG = 0;

    localparam integer ROWS   = 16;
    localparam integer COLSB  = 64;
    localparam integer DWORDS = 16;
    localparam integer KDW    = 16;
    localparam integer ACC_W  = 32;
    localparam integer KLOG   = 64;    // logical K

    localparam [1:0] SEL_A = 2'd0, SEL_B = 2'd1, SEL_C = 2'd2;

    // Expected cycles from start edge to done. 16 k-steps plus the IDLE->RUN
    // transition; `done` is observed the cycle after the last k-step.
    localparam integer EXP_CYC = KDW + 1 + PIPE;

    reg          clk = 1'b0;
    reg          rst_n = 1'b0;
    reg          tile_we = 1'b0;
    reg  [1:0]   tile_sel = 2'd0;
    reg  [3:0]   tile_row = 4'd0;
    reg  [511:0] tile_wdata = {512{1'b0}};
    reg          start = 1'b0;
    wire         busy, done;
    reg  [1:0]   rd_sel = SEL_C;
    reg  [3:0]   rd_row = 4'd0;
    wire [511:0] rd_data;

    amx_tdpbssd #(.SAT(SAT), .PIPE(PIPE), .RD_REG(RD_REG)) dut (
        .clk(clk), .rst_n(rst_n),
        .tile_we(tile_we), .tile_sel(tile_sel), .tile_row(tile_row),
        .tile_wdata(tile_wdata),
        .start(start), .busy(busy), .done(done),
        .rd_sel(rd_sel), .rd_row(rd_row), .rd_data(rd_data)
    );

    always #0.5 clk = ~clk;

    // ---- logical operands (the source of truth) -----------------------------
    reg signed [7:0]       a_log [0:ROWS-1][0:KLOG-1];    // A[m][K]
    reg signed [7:0]       b_log [0:KLOG-1][0:DWORDS-1];  // B[K][n]
    reg signed [ACC_W-1:0] c_pre [0:ROWS-1][0:DWORDS-1];  // C before the op

    // ---- physical tiles ----------------------------------------------------
    reg [511:0] a_phys [0:ROWS-1];
    reg [511:0] b_phys [0:KDW-1];

    // ---- models and capture ------------------------------------------------
    reg signed [ACC_W-1:0] exp_isa [0:ROWS-1][0:DWORDS-1];
    reg signed [ACC_W-1:0] exp_mm  [0:ROWS-1][0:DWORDS-1];
    reg signed [ACC_W-1:0] got     [0:ROWS-1][0:DWORDS-1];

    integer pass_count = 0;
    integer fail_count = 0;
    integer cyc_count;

    // ---- the fold ----------------------------------------------------------
    // Deliberately formulated DIFFERENTLY from the RTL. The DUT detects overflow
    // from the top two bits of a 33-bit sum; this compares against the rails at
    // 41 bits, where no overflow is possible at all. If the DUT's bit trick were
    // wrong, an identical formulation here would agree with it and prove nothing.
    function signed [ACC_W-1:0] fold;
        input signed [ACC_W-1:0] acc;
        input signed [17:0]      add;
        reg   signed [40:0]      wide;
        begin
            wide = acc + add;
            if (SAT != 0 && wide > 41'sd2147483647)
                fold = 32'h7FFF_FFFF;
            else if (SAT != 0 && wide < -41'sd2147483648)
                fold = 32'h8000_0000;
            else
                fold = wide[ACC_W-1:0];   // truncation IS wraparound
        end
    endfunction

    // ---- packing: logical -> physical --------------------------------------
    // THE LAYOUT CONTRACT. Note the asymmetry and that it is not arbitrary:
    // A is plain row-major, B is VNNI-interleaved so that byte b of B's dword n
    // lines up with byte b of A's dword k.
    task pack_tiles;
        integer m, k, n, b;
        begin
            for (m = 0; m < ROWS; m = m + 1) begin
                a_phys[m] = {512{1'b0}};
                for (k = 0; k < KDW; k = k + 1)
                    for (b = 0; b < 4; b = b + 1)
                        a_phys[m][(k*4+b)*8 +: 8] = a_log[m][k*4+b];
            end
            for (k = 0; k < KDW; k = k + 1) begin
                b_phys[k] = {512{1'b0}};
                for (n = 0; n < DWORDS; n = n + 1)
                    for (b = 0; b < 4; b = b + 1)
                        b_phys[k][(n*4+b)*8 +: 8] = b_log[k*4+b][n];
            end
        end
    endtask

    function [511:0] c_pre_row;
        input integer m;
        integer n;
        begin
            c_pre_row = {512{1'b0}};
            for (n = 0; n < DWORDS; n = n + 1)
                c_pre_row[n*32 +: 32] = c_pre[m][n];
        end
    endfunction

    // ---- model 1: the ISA pseudocode, on PHYSICAL tiles --------------------
    task model_isa;
        integer m, k, n, b;
        reg signed [7:0]  av, bv;
        reg signed [15:0] p;
        reg signed [17:0] s4;
        begin
            for (m = 0; m < ROWS; m = m + 1)
                for (n = 0; n < DWORDS; n = n + 1)
                    exp_isa[m][n] = c_pre[m][n];
            for (m = 0; m < ROWS; m = m + 1)
                for (k = 0; k < KDW; k = k + 1)
                    for (n = 0; n < DWORDS; n = n + 1) begin
                        s4 = 18'sd0;
                        for (b = 0; b < 4; b = b + 1) begin
                            av = a_phys[m][(k*4+b)*8 +: 8];
                            bv = b_phys[k][(n*4+b)*8 +: 8];
                            p  = av * bv;
                            s4 = s4 + p;
                        end
                        // one fold per DPBD call == one k-step
                        exp_isa[m][n] = fold(exp_isa[m][n], s4);
                    end
        end
    endtask

    // ---- model 2: textbook matmul, on LOGICAL matrices --------------------
    // Knows nothing about tiles, dwords or interleaving. This is what catches a
    // wrong pack_tiles(), which model 1 cannot.
    task model_matmul;
        integer m, n, k, b;
        reg signed [15:0] p;
        reg signed [17:0] grp;
        begin
            for (m = 0; m < ROWS; m = m + 1)
                for (n = 0; n < DWORDS; n = n + 1) begin
                    exp_mm[m][n] = c_pre[m][n];
                    for (k = 0; k < KDW; k = k + 1) begin
                        grp = 18'sd0;
                        for (b = 0; b < 4; b = b + 1) begin
                            p   = a_log[m][k*4+b] * b_log[k*4+b][n];
                            grp = grp + p;
                        end
                        exp_mm[m][n] = fold(exp_mm[m][n], grp);
                    end
                end
        end
    endtask

    // ---- bus activity ------------------------------------------------------
    task tile_write(input [1:0] sel, input integer row, input [511:0] data);
        begin
            tile_sel   <= sel;
            tile_row   <= row[3:0];
            tile_wdata <= data;
            tile_we    <= 1'b1;
            @(posedge clk);
            tile_we    <= 1'b0;
        end
    endtask

    task load_tiles;
        integer r;
        begin
            for (r = 0; r < ROWS; r = r + 1) tile_write(SEL_A, r, a_phys[r]);
            for (r = 0; r < KDW;  r = r + 1) tile_write(SEL_B, r, b_phys[r]);
            for (r = 0; r < ROWS; r = r + 1) tile_write(SEL_C, r, c_pre_row(r));
            @(posedge clk);
        end
    endtask

    task run_op;
        integer guard;
        begin
            cyc_count = 0;
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            guard = 0;
            while (!done && guard < 1000) begin
                @(posedge clk);
                guard     = guard + 1;
                cyc_count = cyc_count + 1;
            end
            if (guard >= 1000) begin
                $display("  [FAIL] timed out waiting for done");
                fail_count = fail_count + 1;
            end
        end
    endtask

    task readback;
        integer m, n;
        begin
            rd_sel = SEL_C;
            for (m = 0; m < ROWS; m = m + 1) begin
                rd_row = m[3:0];
                // One clock edge, which serves BOTH modes: at RD_REG=1 it is the
                // edge that captures rd_data, and at RD_REG=0 the combinational
                // value is already stable so sampling after an edge is equally
                // valid. Keeping one path means the two modes cannot silently
                // diverge in how they are read.
                @(posedge clk);
                #0.1;
                for (n = 0; n < DWORDS; n = n + 1)
                    got[m][n] = rd_data[n*32 +: 32];
            end
        end
    endtask

    // ---- the check ---------------------------------------------------------
    task check(input [8*28:1] name);
        integer m, n, bad_isa, bad_mm;
        begin
            bad_isa = 0; bad_mm = 0;
            for (m = 0; m < ROWS; m = m + 1)
                for (n = 0; n < DWORDS; n = n + 1) begin
                    if (got[m][n] !== exp_isa[m][n]) begin
                        if (bad_isa == 0)
                            $display("  [FAIL] %0s : vs ISA pseudocode, C[%0d][%0d] got %0d expected %0d",
                                     name, m, n, got[m][n], exp_isa[m][n]);
                        bad_isa = bad_isa + 1;
                    end
                    if (got[m][n] !== exp_mm[m][n]) begin
                        if (bad_mm == 0)
                            $display("  [FAIL] %0s : vs textbook matmul, C[%0d][%0d] got %0d expected %0d",
                                     name, m, n, got[m][n], exp_mm[m][n]);
                        bad_mm = bad_mm + 1;
                    end
                end
            if (cyc_count !== EXP_CYC) begin
                $display("  [FAIL] %0s : %0d cycles, expected %0d",
                         name, cyc_count, EXP_CYC);
                fail_count = fail_count + 1;
            end else if (bad_isa == 0 && bad_mm == 0) begin
                $display("  [PASS] %-26s cycles=%0d  (vs ISA and vs textbook)",
                         name, cyc_count);
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
            end
        end
    endtask

    // C must be STABLE after done. Without this, a design that keeps accumulating
    // past `done` passes silently, because readback is combinational and happens
    // before any further clock edge. Found by mutation: delaying the accumulate
    // enable one cycle too many was INVISIBLE to every other check in this file.
    task check_settled(input [8*28:1] name);
        integer m, n, moved;
        reg signed [ACC_W-1:0] before [0:ROWS-1][0:DWORDS-1];
        begin
            for (m = 0; m < ROWS; m = m + 1)
                for (n = 0; n < DWORDS; n = n + 1) before[m][n] = got[m][n];
            repeat (6) @(posedge clk);      // well past any PIPE flush
            readback;
            moved = 0;
            for (m = 0; m < ROWS; m = m + 1)
                for (n = 0; n < DWORDS; n = n + 1)
                    if (got[m][n] !== before[m][n]) moved = moved + 1;
            if (moved != 0) begin
                $display("  [FAIL] %0s : C MOVED after done -- %0d accumulators changed over 6 idle cycles",
                         name, moved);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // one full operation: pack, load, model, run, read, compare, prove settled
    task do_case(input [8*28:1] name);
        begin
            pack_tiles;
            load_tiles;
            model_isa;
            model_matmul;
            run_op;
            readback;
            check(name);
            check_settled(name);
            repeat (2) @(posedge clk);
        end
    endtask

    // ---- operand generators ------------------------------------------------
    task fill_const(input signed [7:0] av, input signed [7:0] bv);
        integer m, n, k;
        begin
            for (m = 0; m < ROWS; m = m + 1)
                for (k = 0; k < KLOG; k = k + 1) a_log[m][k] = av;
            for (k = 0; k < KLOG; k = k + 1)
                for (n = 0; n < DWORDS; n = n + 1) b_log[k][n] = bv;
        end
    endtask

    // Asymmetric on purpose. A symmetric A or B hides a lost, doubled or
    // transposed interleave completely -- the same lesson as mac_array's M1/M2.
    task fill_asym;
        integer m, n, k;
        begin
            for (m = 0; m < ROWS; m = m + 1)
                for (k = 0; k < KLOG; k = k + 1)
                    a_log[m][k] = ((m*KLOG + k)*5 + 3) % 256 - 128;
            for (k = 0; k < KLOG; k = k + 1)
                for (n = 0; n < DWORDS; n = n + 1)
                    b_log[k][n] = ((n*KLOG + k)*7 + 1) % 256 - 128;
        end
    endtask

    task fill_random(input integer seed_in);
        integer m, n, k, sd;
        begin
            sd = seed_in;
            for (m = 0; m < ROWS; m = m + 1)
                for (k = 0; k < KLOG; k = k + 1)
                    a_log[m][k] = $random(sd);
            for (k = 0; k < KLOG; k = k + 1)
                for (n = 0; n < DWORDS; n = n + 1)
                    b_log[k][n] = $random(sd);
        end
    endtask

    // Mixed sign, and the ONLY case that catches unsigned byte slicing:
    // A holds -1 where unsigned would read 255. All-(-128) cannot catch it,
    // because -128*-128 and 128*128 are both +16384.
    task fill_mixed_sign;
        integer m, n, k;
        begin
            for (m = 0; m < ROWS; m = m + 1)
                for (k = 0; k < KLOG; k = k + 1)
                    a_log[m][k] = (k % 2) ? -8'sd1 : 8'sd2;
            for (k = 0; k < KLOG; k = k + 1)
                for (n = 0; n < DWORDS; n = n + 1)
                    b_log[k][n] = (n % 3) ? 8'sd3 : -8'sd5;
        end
    endtask

    // sum4(k) = +4 for k=0..7 and -4 for k=8..15. THE point is that it varies
    // with k: every other saturation case here uses uniform operands, and a
    // permutation of equal values is undetectable by construction.
    task fill_sign_flip_over_k;
        integer m, n, k;
        begin
            for (m = 0; m < ROWS; m = m + 1)
                for (k = 0; k < KLOG; k = k + 1)
                    a_log[m][k] = (k < (KLOG/2)) ? 8'sd1 : -8'sd1;
            for (k = 0; k < KLOG; k = k + 1)
                for (n = 0; n < DWORDS; n = n + 1) b_log[k][n] = 8'sd1;
        end
    endtask

    task set_c_const(input signed [ACC_W-1:0] v);
        integer m, n;
        begin
            for (m = 0; m < ROWS; m = m + 1)
                for (n = 0; n < DWORDS; n = n + 1) c_pre[m][n] = v;
        end
    endtask

    // ---- saturation probe ---------------------------------------------------
    // Confirms the DUT lands exactly on a rail (SAT=1) or does not (SAT=0). A
    // separate assertion from check(), because "clamped" is a stronger claim
    // than "matches the model" -- a model that also failed to clamp would agree.
    task expect_rail(input [8*28:1] name, input signed [ACC_W-1:0] rail,
                     input want_clamped);
        integer m, n, on_rail;
        begin
            on_rail = 0;
            for (m = 0; m < ROWS; m = m + 1)
                for (n = 0; n < DWORDS; n = n + 1)
                    if (got[m][n] === rail) on_rail = on_rail + 1;
            if (want_clamped && on_rail != ROWS*DWORDS) begin
                $display("  [FAIL] %0s : only %0d of %0d accumulators reached the rail %0d",
                         name, on_rail, ROWS*DWORDS, rail);
                fail_count = fail_count + 1;
            end else if (!want_clamped && on_rail == ROWS*DWORDS) begin
                $display("  [FAIL] %0s : SAT=0 must NOT clamp, but every accumulator sits on %0d",
                         name, rail);
                fail_count = fail_count + 1;
            end else begin
                $display("  [PASS] %-26s %0d/%0d on rail %0d (%0s)",
                         name, on_rail, ROWS*DWORDS, rail,
                         want_clamped ? "clamped, as required" : "wrapped, as required");
                pass_count = pass_count + 1;
            end
        end
    endtask

    // ---- stimulus ----------------------------------------------------------
    integer m_i, n_i;
    reg signed [ACC_W-1:0] snap [0:ROWS-1][0:DWORDS-1];
    reg signed [ACC_W-1:0] s6_want;

    initial begin
        $display("=== tb_amx_tdpbssd : TDPBSSD 16x64 @ 64x16 -> 16x16, SAT=%0d PIPE=%0d RD_REG=%0d ===", SAT, PIPE, RD_REG);
        $display("    %0d INT8 MACs per instruction, %0d multipliers, %0d k-steps",
                 ROWS*DWORDS*KLOG, ROWS*DWORDS*4, KDW);

        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);

        // ---- functional ---------------------------------------------------
        set_c_const(0);
        fill_const(8'sd1, 8'sd1);        do_case("T1 all +1, C=0");
        // every product 1 over K=64 -> exactly 64
        if (got[0][0] !== 64) begin
            $display("  [FAIL] T1 sanity: C[0][0]=%0d, expected 64", got[0][0]);
            fail_count = fail_count + 1;
        end

        fill_const(-8'sd128, -8'sd128);  do_case("T2 all -128 (=+16384)");

        fill_asym;                       do_case("T3 asymmetric tiles");
        // CROSS-FAMILY LINK. tb/amx_golden.py's asym_a()/asym_b() use the
        // identical formulas, so these four values tie the Verilog models to the
        // Python ones. Independently computed by
        //   python3 -c "import sys;sys.path.insert(0,'tb');from amx_golden import *; \
        //               print(tdpbssd(zero_c(),pack_a(asym_a()),pack_b(asym_b()),False)[0][:4])"
        if (got[0][0] !== 41632 || got[0][1] !== 63904 ||
            got[0][2] !== 22432 || got[0][3] !== -118880 ||
            got[15][15] !== 22176) begin
            $display("  [FAIL] T3 cross-check vs amx_golden.py: got %0d %0d %0d %0d / %0d",
                     got[0][0], got[0][1], got[0][2], got[0][3], got[15][15]);
            fail_count = fail_count + 1;
        end else begin
            $display("  [PASS] T3 cross-check vs amx_golden.py (4 models agree)");
            pass_count = pass_count + 1;
        end
        fill_mixed_sign;                 do_case("T4 mixed sign (-1 vs 255)");
        fill_random(32'h1234_5678);      do_case("T5 random");
        fill_random(32'h0BAD_C0DE);      do_case("T5 random, second seed");

        // ---- C += chain, no reset between ---------------------------------
        // The second instruction must accumulate onto the first's result, which
        // means DONE cannot be terminal and C must survive in place.
        set_c_const(0);
        fill_const(8'sd1, 8'sd1);        do_case("C1 chain, first op");
        for (m_i = 0; m_i < ROWS; m_i = m_i + 1)
            for (n_i = 0; n_i < DWORDS; n_i = n_i + 1) snap[m_i][n_i] = got[m_i][n_i];
        for (m_i = 0; m_i < ROWS; m_i = m_i + 1)
            for (n_i = 0; n_i < DWORDS; n_i = n_i + 1) c_pre[m_i][n_i] = snap[m_i][n_i];
        fill_const(8'sd1, 8'sd1);        do_case("C1 chain, second op");
        if (got[0][0] !== 128) begin
            $display("  [FAIL] C1: chained C[0][0]=%0d, expected 128", got[0][0]);
            fail_count = fail_count + 1;
        end

        // ---- saturation ----------------------------------------------------
        // One instruction from C=0 tops out at 1,048,576, so the rails can only
        // be reached by PRELOADING C. That is the point of these cases.
        set_c_const(32'h7FFF_FFFF - 32'sd5);
        fill_const(8'sd1, 8'sd1);        do_case("S1 high rail, +ve products");
        expect_rail("S2 high rail check", 32'h7FFF_FFFF, SAT != 0);

        set_c_const(32'h8000_0000 + 32'sd5);
        fill_const(8'sd1, -8'sd1);       do_case("S3 low rail, -ve products");
        expect_rail("S4 low rail check", 32'h8000_0000, SAT != 0);

        // SAT must be a no-op when nothing can overflow.
        set_c_const(0);
        fill_random(32'hFEED_BEEF);      do_case("S5 no overflow possible");

        // S6 -- FOLD ORDER, not just fold existence. THE case that makes the
        // k-sequence observable. sum4 is +4 for k=0..7 then -4 for k=8..15, and C
        // starts 10 below the rail, so the accumulator clamps partway through and
        // then walks back down. Any PERMUTATION of the k order lands somewhere
        // else: correct is INT32_MAX-32, while rotating k by one gives MAX-28.
        //
        // Found necessary by mutation. Delaying the accumulate enable by one
        // cycle permutes the sequence, and S1-S4 could not see it because they
        // use uniform operands, while SAT=0 can NEVER see it because wrapping
        // addition is associative. Without this case, pipelining could silently
        // reorder the fold and every other test would still pass.
        set_c_const(32'h7FFF_FFFF - 32'sd10);
        fill_sign_flip_over_k;           do_case("S6 fold ORDER, mixed sign");
        // Both modes get a hardcoded expectation, and they differ for a reason:
        //   SAT=1  clamps partway, so the +32 is partly lost and it ends MAX-32.
        //          A permutation of k lands on MAX-28 instead. THE order check.
        //   SAT=0  never clamps, the +32 and -32 cancel exactly, so it must come
        //          back to MAX-10. That also proves no spurious clamp occurred.
        s6_want = (SAT != 0) ? (32'h7FFF_FFFF - 32'sd32)
                             : (32'h7FFF_FFFF - 32'sd10);
        if (got[0][0] !== s6_want) begin
            $display("  [FAIL] S6 : C[0][0]=%0d, expected %0d (SAT=%0d) -- k-fold order or clamping is wrong",
                     got[0][0], s6_want, SAT);
            fail_count = fail_count + 1;
        end else if (SAT != 0) begin
            $display("  [PASS] S6 fold ORDER lands on INT32_MAX-32 (any k permutation gives -28)");
            pass_count = pass_count + 1;
        end else begin
            $display("  [PASS] S6 SAT=0 never clamps: +32 and -32 cancel back to INT32_MAX-10");
            pass_count = pass_count + 1;
        end

        $display("=== %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count != 0) $display("RESULT: FAIL");
        else                 $display("RESULT: PASS");
        $finish;
    end

    initial begin
        #2000000;
        $display("RESULT: FAIL (global timeout)");
        $finish;
    end
endmodule
