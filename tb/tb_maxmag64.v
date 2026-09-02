//=============================================================================
// tb_maxmag64 -- leaf regression for rtl/maxmag64.v.
//
// A wrong alignment reference does not present as a reference bug. It presents as
// the fixed-point accumulator overflowing (reference too small) or losing low bits
// (too large), i.e. as an arithmetic bug several hundred cells away. Cheaper to
// catch here.
//
// The reference model is a plain loop -- deliberately the shape the RTL must NOT
// use, since a 63-deep running-max chain is what a for-loop synthesises to. Same
// arrangement as tb_fx2fp32: the model is structured unlike the DUT on purpose.
//=============================================================================
`timescale 1ns/1ps

module tb_maxmag64;

    parameter integer NRAND = 20000;

    reg  [511:0] bytes;
    wire [6:0]   mx;

    maxmag64 dut (.bytes(bytes), .mx(mx));

    reg [31:0] checks = 32'd0;
    reg [31:0] errors = 32'd0;
    reg [31:0] phase_base, err_base;

    // Reference: a running max over a loop. The RTL is a 6-level tree.
    function [6:0] ref_max;
        input [511:0] v;
        integer i;
        reg [6:0] m, c;
        begin
            m = 7'd0;
            for (i = 0; i < 64; i = i + 1) begin
                c = v[i*8 +: 7];
                if (c > m) m = c;
            end
            ref_max = m;
        end
    endfunction

    task check;
        input [511:0] v;
        input [255:0] why;
        reg [6:0] want;
        begin
            bytes = v; #1;
            want = ref_max(v);
            checks = checks + 1;
            if (mx !== want) begin
                errors = errors + 1;
                if (errors < 20)
                    $display("FAIL %0s: dut=%02h ref=%02h", why, mx, want);
            end
        end
    endtask

    integer i, j, k;
    reg [511:0] v;
    reg [7:0]   b;

    initial begin
        //---- phase 1: the max at every one of the 64 positions ---------------
        // A tree bug that mis-wires one branch shows up as a specific position
        // whose value never wins. Every position is made the unique winner once.
        phase_base = checks; err_base = errors;
        for (i = 0; i < 64; i = i + 1) begin
            v = {512{1'b0}};
            for (j = 0; j < 64; j = j + 1) begin
                b = (j == i) ? 8'h6A : 8'h11;
                v[j*8 +: 8] = b;
            end
            check(v, "unique winner");
            // and again with the sign bit set on the winner ONLY: bit 7 must be
            // ignored, so the answer must not change
            v[i*8 +: 8] = 8'hEA;
            check(v, "winner has sign bit");
            // and with the sign bit set on everything BUT the winner
            for (j = 0; j < 64; j = j + 1)
                if (j != i) v[j*8 +: 8] = 8'h91;
            check(v, "losers have sign bits");
        end
        $display("phase 1 (winner at each of 64) : %0d checks, %0d errors",
                 checks - phase_base, errors - err_base);

        //---- phase 2: degenerate inputs --------------------------------------
        phase_base = checks; err_base = errors;
        check({512{1'b0}},  "all zero");
        check({512{1'b1}},  "all ones -- sign bits must not leak into the max");
        check({64{8'h7F}},  "all 0x7F");
        check({64{8'hFF}},  "all 0xFF -> must still be 0x7F");
        check({64{8'h80}},  "sign only -> max is 0");
        // ties: every byte equal, at each of a few magnitudes
        for (i = 0; i < 128; i = i + 8)
            check({64{i[7:0]}}, "uniform tie");
        // exactly two winners, adjacent and distant
        v = {64{8'h05}}; v[0 +: 8] = 8'h70; v[8 +: 8] = 8'h70;
        check(v, "two adjacent winners");
        v = {64{8'h05}}; v[0 +: 8] = 8'h70; v[63*8 +: 8] = 8'h70;
        check(v, "winners at both ends");
        // one byte at each possible value, alone against zeros
        for (i = 0; i < 128; i = i + 1) begin
            v = {512{1'b0}};
            v[17*8 +: 8] = i[7:0];
            check(v, "single value sweep");
        end
        $display("phase 2 (degenerate + sweeps)  : %0d checks, %0d errors",
                 checks - phase_base, errors - err_base);

        //---- phase 3: the FP8 classes, since those are the real inputs -------
        // Specials must win (all-ones exponent field) and DAZ subnormals must lose
        // to any normal. Both facts are relied on by amx_fp8's reference.
        phase_base = checks; err_base = errors;
        // E5M2: 0x7C is +Inf, exponent field 31. A normal maxes at 0x7B.
        v = {64{8'h7B}}; v[9*8 +: 8] = 8'h7C;
        check(v, "E5M2 Inf beats max normal");
        // E5M2 subnormal 0x03 (field 0) against normal 0x04 (field 1)
        v = {64{8'h03}}; v[40*8 +: 8] = 8'h04;
        check(v, "E5M2 normal beats subnormal");
        // E4M3: 0x7F is the ONLY NaN; 0x7E = 448 is the max NORMAL and loses to it
        v = {64{8'h7E}}; v[3*8 +: 8] = 8'h7F;
        check(v, "E4M3 NaN beats 448");
        v = {64{8'h00}}; v[3*8 +: 8] = 8'h7E;
        check(v, "E4M3 448 against zeros");
        $display("phase 3 (fp8 classes)          : %0d checks, %0d errors",
                 checks - phase_base, errors - err_base);

        //---- phase 4: random -------------------------------------------------
        phase_base = checks; err_base = errors;
        for (i = 0; i < NRAND; i = i + 1) begin
            for (j = 0; j < 16; j = j + 1)
                v[j*32 +: 32] = $random;
            check(v, "rand");
            // and a sparse variant: mostly one value, so ties dominate
            for (j = 0; j < 64; j = j + 1) begin
                k = $random;
                v[j*8 +: 8] = ((k & 7) == 0) ? $random : 8'h20;
            end
            check(v, "rand sparse");
        end
        $display("phase 4 (%0d random x2)      : %0d checks, %0d errors",
                 NRAND, checks - phase_base, errors - err_base);

        $display("");
        $display("========================================");
        $display("tb_maxmag64");
        $display("  checks : %0d", checks);
        $display("  errors : %0d", errors);
        $display("========================================");
        if (errors != 0) begin
            $display("RESULT: FAIL");
            $display("*** FAILED ***");
            $fatal(1);
        end
        $display("RESULT: PASS");
        $display("*** PASSED ***");
        $finish;
    end

    initial begin
        #400000000;
        $display("RESULT: FAIL (global timeout)");
        $fatal(1);
    end
endmodule
