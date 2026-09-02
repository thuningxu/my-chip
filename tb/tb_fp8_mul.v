`timescale 1ns/1ps
//=============================================================================
// tb_fp8_mul -- EXHAUSTIVE regression for fp8_dec + fp8_mul.
//
// The input space is 4 format pairs x 256 x 256 = 262,144 cases, which is small
// enough to test completely. So this testbench does not sample: it proves.
//
//------------------------------------------------- THE MODEL TAKES A LONGER ROUTE
// The DUT multiplies two 4-BIT significands and renormalises an 8-bit product.
// The model widens each fp8 to a full FP32 pattern first, then multiplies two
// 24-BIT significands into 48 bits and renormalises that. Same answers, different
// widths and a different normalisation, so a mistake in the DUT's 4-bit shortcut
// has nowhere to hide.
//
// The model ALSO asserts exactness on every case: after taking 24 significand
// bits out of the 48-bit product, the discarded bits must all be zero. That is
// the RTL-level proof of the claim the whole design rests on -- fp8 x fp8 never
// rounds, so every rounding error in amx_fp8 comes from an adder.
//
//-------------------------------------------------------- CROSS-LANGUAGE TIE
// Two ties to tb/fp8_golden.py, which is itself two independent models:
//   18 directed vectors, including all the format traps
//   a 32-bit checksum over EVERY one of the 65,536 pairs, per format pair
//
// The checksum has one blind spot, stated rather than discovered later: the two
// MIXED format pairs sum to the same value, because the checksum runs over all
// (x,y) and multiplication is commutative. So the checksum cannot catch fmt_a
// and fmt_b being swapped. The directed vectors can and do -- vec(8'h7B, BF8,
// 8'h7E, HF8) is 57344 x 448, but read with the formats swapped 8'h7E becomes an
// E5M2 NaN, which is not a subtle difference.
//=============================================================================
module tb_fp8_mul;

    reg  [7:0] a_byte, b_byte;
    reg        fmt_a, fmt_b;
    wire [31:0] y_out;

    wire        a_sgn, a_zero, a_inf, a_nan;
    wire signed [5:0] a_exp;
    wire [3:0]  a_sig;
    wire        b_sgn, b_zero, b_inf, b_nan;
    wire signed [5:0] b_exp;
    wire [3:0]  b_sig;

    fp8_dec da (.b_in(a_byte), .fmt(fmt_a), .sgn(a_sgn), .exp(a_exp),
                .sig4(a_sig), .is_zero(a_zero), .is_inf(a_inf), .is_nan(a_nan));
    fp8_dec db (.b_in(b_byte), .fmt(fmt_b), .sgn(b_sgn), .exp(b_exp),
                .sig4(b_sig), .is_zero(b_zero), .is_inf(b_inf), .is_nan(b_nan));

    fp8_mul dut (
        .a_sgn(a_sgn), .a_exp(a_exp), .a_sig(a_sig),
        .a_zero(a_zero), .a_inf(a_inf), .a_nan(a_nan),
        .b_sgn(b_sgn), .b_exp(b_exp), .b_sig(b_sig),
        .b_zero(b_zero), .b_inf(b_inf), .b_nan(b_nan),
        .y(y_out));

    integer pass_count = 0;
    integer fail_count = 0;
    integer inexact    = 0;
    integer shown      = 0;

    // ---- model step 1: fp8 -> FP32, written without reference to fp8_dec ----
    function [31:0] fp8_ref;
        input [7:0] v;
        input       fmt;
        reg        s;
        reg [4:0]  e5;
        reg [1:0]  m2;
        reg [3:0]  e4;
        reg [2:0]  m3;
        integer    eu;
        begin
            s = v[7];
            if (!fmt) begin                          // BF8 / E5M2
                e5 = v[6:2]; m2 = v[1:0];
                if (e5 == 5'd0)       fp8_ref = {s, 31'd0};              // DAZ
                else if (e5 == 5'd31) fp8_ref = (m2 == 2'd0)
                                              ? {s, 8'hFF, 23'd0}
                                              : 32'h7FC0_0000;
                else begin
                    eu = e5 - 15 + 127;
                    fp8_ref = {s, eu[7:0], m2, 21'd0};
                end
            end else begin                           // HF8 / E4M3
                e4 = v[6:3]; m3 = v[2:0];
                // exp==15 is NOT the special class here; only man==7 is NaN.
                if (e4 == 4'd0)                          fp8_ref = {s, 31'd0};
                else if (e4 == 4'd15 && m3 == 3'd7)      fp8_ref = 32'h7FC0_0000;
                else begin
                    eu = e4 - 7 + 127;
                    fp8_ref = {s, eu[7:0], m3, 20'd0};
                end
            end
        end
    endfunction

    // ---- model step 2: exact FP32 x FP32 via a 24x24 -> 48 multiply ---------
    function [31:0] fp32_mul_ref;
        input [31:0] a;
        input [31:0] b;
        reg        sa, sb, sgn;
        reg [7:0]  ea, eb;
        reg [22:0] fa, fb;
        reg [23:0] ma, mb;
        reg [47:0] p;
        integer    eu;
        begin
            sa = a[31]; ea = a[30:23]; fa = a[22:0];
            sb = b[31]; eb = b[30:23]; fb = b[22:0];
            sgn = sa ^ sb;
            if ((ea == 8'hFF && fa != 0) || (eb == 8'hFF && fb != 0))
                fp32_mul_ref = 32'h7FC0_0000;                       // NaN in
            else if ((ea == 8'hFF && eb == 8'd0) || (eb == 8'hFF && ea == 8'd0))
                fp32_mul_ref = 32'h7FC0_0000;                       // Inf x 0
            else if (ea == 8'hFF || eb == 8'hFF)
                fp32_mul_ref = {sgn, 8'hFF, 23'd0};
            else if (ea == 8'd0 || eb == 8'd0)
                fp32_mul_ref = {sgn, 31'd0};                        // signed zero
            else begin
                ma = {1'b1, fa};
                mb = {1'b1, fb};
                p  = ma * mb;                    // [2^46, 2^48)
                if (p[47]) begin
                    eu = ea + eb - 126;
                    fp32_mul_ref = {sgn, eu[7:0], p[46:24]};
                end else begin
                    eu = ea + eb - 127;
                    fp32_mul_ref = {sgn, eu[7:0], p[45:23]};
                end
            end
        end
    endfunction

    // The exactness claim, checked separately so the model above stays a pure
    // function: whatever the 48-bit product drops must be zero.
    function prod_exact;
        input [31:0] a;
        input [31:0] b;
        reg [7:0]  ea, eb;
        reg [23:0] ma, mb;
        reg [47:0] p;
        begin
            ea = a[30:23]; eb = b[30:23];
            if (ea == 8'hFF || eb == 8'hFF || ea == 8'd0 || eb == 8'd0)
                prod_exact = 1'b1;              // no significand arithmetic
            else begin
                ma = {1'b1, a[22:0]};
                mb = {1'b1, b[22:0]};
                p  = ma * mb;
                prod_exact = p[47] ? (p[23:0] == 24'd0) : (p[22:0] == 23'd0);
            end
        end
    endfunction

    // ---- checkers -----------------------------------------------------------
    task drive(input [7:0] av, input fa, input [7:0] bv, input fb);
        begin
            a_byte = av; fmt_a = fa; b_byte = bv; fmt_b = fb; #1;
        end
    endtask

    // Directed vector against a tb/fp8_golden.py constant. Checks the DUT AND
    // the local model, so the model is validated before the sweep leans on it.
    task vec(input [7:0] av, input fa, input [7:0] bv, input fb, input [31:0] want);
        reg [31:0] mdl;
        begin
            drive(av, fa, bv, fb);
            mdl = fp32_mul_ref(fp8_ref(av, fa), fp8_ref(bv, fb));
            if (y_out !== want) begin
                fail_count = fail_count + 1;
                $display("  [FAIL] directed %02h(f%0d) x %02h(f%0d) : got %08h want %08h",
                         av, fa, bv, fb, y_out, want);
            end else pass_count = pass_count + 1;
            if (mdl !== want) begin
                fail_count = fail_count + 1;
                $display("  [FAIL] MODEL disagrees with python %02h(f%0d) x %02h(f%0d) : model %08h want %08h",
                         av, fa, bv, fb, mdl, want);
            end
        end
    endtask

    integer fa_i, fb_i, xi, yi;
    reg [31:0] sum, want_sum, mdl;

    initial begin
        $display("=== tb_fp8_mul  (exhaustive: 4 format pairs x 256 x 256) ===");

        // ---- directed, cross-language tie ----------------------------------
        vec(8'h3C, 1'b0, 8'h3C, 1'b0, 32'h3F800000);  // 1.0 x 1.0 (BF8)
        vec(8'h38, 1'b1, 8'h38, 1'b1, 32'h3F800000);  // 1.0 x 1.0 (HF8)
        vec(8'h7B, 1'b0, 8'h7B, 1'b0, 32'h4F440000);  // 57344 x 57344 max BF8
        vec(8'h7E, 1'b1, 8'h7E, 1'b1, 32'h48440000);  // 448 x 448 max HF8
        vec(8'h7B, 1'b0, 8'h7E, 1'b1, 32'h4BC40000);  // 57344 x 448 mixed
        vec(8'h78, 1'b1, 8'h38, 1'b1, 32'h43800000);  // E4M3 exp15 man0 NORMAL (256)
        vec(8'h7D, 1'b1, 8'h38, 1'b1, 32'h43D00000);  // E4M3 exp15 man5 NORMAL
        vec(8'h7F, 1'b1, 8'h38, 1'b1, 32'h7FC00000);  // E4M3 S.1111.111 the ONLY NaN
        vec(8'h04, 1'b0, 8'h3C, 1'b0, 32'h38800000);  // BF8 min normal 2^-14
        vec(8'h08, 1'b1, 8'h38, 1'b1, 32'h3C800000);  // HF8 min normal 2^-6
        vec(8'h04, 1'b0, 8'h04, 1'b0, 32'h31800000);  // 2^-28, smallest product
        vec(8'h7C, 1'b0, 8'h3C, 1'b0, 32'h7F800000);  // Inf x 1 = Inf
        vec(8'h7C, 1'b0, 8'h00, 1'b0, 32'h7FC00000);  // Inf x 0 = NaN
        vec(8'h7C, 1'b0, 8'h01, 1'b0, 32'h7FC00000);  // Inf x subnormal(DAZ) = NaN
        vec(8'hBC, 1'b0, 8'h3C, 1'b0, 32'hBF800000);  // -1 x 1 = -1
        vec(8'h80, 1'b0, 8'h3C, 1'b0, 32'h80000000);  // -0 x 1 = -0
        vec(8'h01, 1'b0, 8'h3C, 1'b0, 32'h00000000);  // subnormal x 1 = +0 (DAZ)
        vec(8'h81, 1'b0, 8'h3C, 1'b0, 32'h80000000);  // -subnormal x 1 = -0 (DAZ)
        $display("  18 directed vectors done (%0d fail)", fail_count);

        // ---- exhaustive ----------------------------------------------------
        for (fa_i = 0; fa_i < 2; fa_i = fa_i + 1)
            for (fb_i = 0; fb_i < 2; fb_i = fb_i + 1) begin
                sum = 32'd0;
                for (xi = 0; xi < 256; xi = xi + 1)
                    for (yi = 0; yi < 256; yi = yi + 1) begin
                        drive(xi[7:0], fa_i[0], yi[7:0], fb_i[0]);
                        mdl = fp32_mul_ref(fp8_ref(xi[7:0], fa_i[0]),
                                           fp8_ref(yi[7:0], fb_i[0]));
                        if (y_out !== mdl) begin
                            fail_count = fail_count + 1;
                            if (shown < 20) begin
                                shown = shown + 1;
                                $display("  [FAIL] %02h(f%0d) x %02h(f%0d) : got %08h model %08h",
                                         xi[7:0], fa_i[0], yi[7:0], fb_i[0], y_out, mdl);
                            end
                        end else pass_count = pass_count + 1;
                        if (!prod_exact(fp8_ref(xi[7:0], fa_i[0]),
                                        fp8_ref(yi[7:0], fb_i[0])))
                            inexact = inexact + 1;
                        sum = sum + y_out;
                    end
                // checksums generated by tb/fp8_golden.py over all 65,536 pairs
                case ({fa_i[0], fb_i[0]})
                    2'b00:   want_sum = 32'hFD400000;   // BF8 x BF8
                    2'b01:   want_sum = 32'h5C100000;   // BF8 x HF8
                    2'b10:   want_sum = 32'h5C100000;   // HF8 x BF8  (equal, see header)
                    default: want_sum = 32'hBD6C0000;   // HF8 x HF8
                endcase
                if (sum !== want_sum) begin
                    fail_count = fail_count + 1;
                    $display("  [FAIL] checksum fmt_a=%0d fmt_b=%0d : got %08h want %08h",
                             fa_i, fb_i, sum, want_sum);
                end else
                    $display("  [PASS] fmt_a=%0d fmt_b=%0d : 65536 pairs, checksum %08h",
                             fa_i, fb_i, sum);
            end

        // The load-bearing claim of the whole design.
        if (inexact != 0) begin
            $display("  [FAIL] %0d products were INEXACT in FP32 -- the design's core claim is false",
                     inexact);
            fail_count = fail_count + 1;
        end else
            $display("  [PASS] all 262144 products are EXACT in FP32 (nothing dropped)");

        $display("=== %0d checks passed, %0d failed ===", pass_count, fail_count);
        if (fail_count != 0) $display("RESULT: FAIL");
        else                 $display("RESULT: PASS");
        $finish;
    end

    initial begin
        #200000000;
        $display("RESULT: FAIL (global timeout)");
        $finish;
    end
endmodule
