//=============================================================================
// fp8_dec / fp8_mul -- FP8 decode and the exact fp8 x fp8 -> FP32 product.
//
// Two formats, selected per operand by one bit, which is what makes the four
// AMX-FP8 instructions one datapath:
//
//   fmt = 0   BF8 = E5M2   S EEEEE MM   bias 15   max normal 57344 (S.11110.11)
//                          has Inf S.11111.00, NaN S.11111.{01,10,11}
//   fmt = 1   HF8 = E4M3   S EEEE MMM   bias  7   max normal   448 (S.1111.110)
//                          NO Inf; NaN is ONLY S.1111.111
//
// THE E4M3 TRAP, and it is the one thing in this file worth reading twice. In
// E4M3 the all-ones exponent field is NOT the special class. Only (exp==15,
// man==7) is NaN; (exp==15, man==0..6) are ordinary normals, and 1.110 x 2^8 =
// 448 is the format's maximum value. Treating exp==15 as Inf-or-NaN -- which is
// the reflex from every other float format -- silently discards the seven
// largest magnitudes the format has. tb/fp8_golden.py tests exactly this.
//
//------------------------------------------------------- ONE 4-BIT MULTIPLIER
// Both formats are decoded to a COMMON 4-bit left-aligned significand:
//
//   E5M2   1.mm   -> {1, mm, 0}      E4M3   1.mmm  -> {1, mmm}
//
// Both are integers in [8, 15] representing sig4/8, so ONE 4x4 unsigned
// multiplier serves all four instructions and the product is 8 bits. That is
// smaller than the INT8 design's 8x8 multiplier -- the cost of FP8 is not in the
// multiply at all, it is in fp32_add.
//
// DAZ: exponent field 0 is zero, subnormal payload and all. So there is no
// leading-zero detect and no exponent fixup anywhere in this decoder.
//
//---------------------------------------------------- THE PRODUCT NEVER ROUNDS
// With DAZ every operand is 1.mmm x 2^e, so:
//
//   significand   4 bits x 4 bits = 8 bits          inside FP32's 24
//   exponent      [-14,15] + [-14,15] = [-28,30]    inside FP32's [-126,127]
//
// so the FP32 product is EXACT for every one of the 4 x 256 x 256 input
// combinations. tb/fp8_golden.py proves that exhaustively against Fraction, and
// tb/tb_fp8_mul.v proves the RTL matches. It matters because it means every
// rounding error in amx_fp8 comes from an adder, and none from a multiplier.
//=============================================================================

//-----------------------------------------------------------------------------
// fp8_dec -- one fp8 byte to decoded fields. Combinational, ~40 cells.
//
// amx_fp8 instantiates this on the ARRAY EDGES (16 rows x 4 lanes for A, 16
// dwords x 4 lanes for B = 128 total) and shares the results across all 256
// cells, rather than decoding inside each of the 1024 multipliers. Same
// reasoning as sharing the operand mux: 128 decoders instead of 2048.
//-----------------------------------------------------------------------------
module fp8_dec (
    input  wire       [7:0] b_in,
    input  wire             fmt,      // 0 = BF8/E5M2, 1 = HF8/E4M3
    output wire             sgn,
    output wire signed [5:0] exp,     // unbiased: [-14,+15] BF8, [-6,+8] HF8
    output wire       [3:0] sig4,     // left-aligned significand, [8,15]
    output wire             is_zero,
    output wire             is_inf,
    output wire             is_nan
);
    // BF8 / E5M2 fields
    wire [4:0] e5 = b_in[6:2];
    wire [1:0] m2 = b_in[1:0];
    // HF8 / E4M3 fields
    wire [3:0] e4 = b_in[6:3];
    wire [2:0] m3 = b_in[2:0];

    assign sgn = b_in[7];

    // Unbiased exponent. 6 bits signed holds [-14,+15] and [-6,+8], and their
    // sum [-28,+30] still fits, which is why fp8_mul needs no widening.
    assign exp = fmt ? ($signed({2'b00, e4}) - $signed(6'd7))
                     : ($signed({1'b0,  e5}) - $signed(6'd15));

    // Common 4-bit significand. The implicit 1 is unconditional because DAZ
    // means a zero exponent field is a zero VALUE, never a subnormal.
    assign sig4 = fmt ? {1'b1, m3} : {1'b1, m2, 1'b0};

    // DAZ folds subnormals in with zero.
    assign is_zero = fmt ? (e4 == 4'd0)  : (e5 == 5'd0);
    // E4M3 HAS NO INFINITY. Not an omission.
    assign is_inf  = fmt ? 1'b0          : ((e5 == 5'd31) && (m2 == 2'd0));
    // E4M3's NaN is the single encoding S.1111.111; exp==15 with man<7 is a
    // NORMAL and must fall through to the arithmetic path.
    assign is_nan  = fmt ? ((e4 == 4'd15) && (m3 == 3'd7))
                         : ((e5 == 5'd31) && (m2 != 2'd0));
endmodule


//-----------------------------------------------------------------------------
// fp8_mul -- exact product of two DECODED fp8 operands, as an FP32 pattern.
//
// Takes decoded fields rather than raw bytes so the 128 edge decoders can be
// shared across the 1024 instances. See the fp8_dec header.
//-----------------------------------------------------------------------------
module fp8_mul (
    input  wire             a_sgn,
    input  wire signed [5:0] a_exp,
    input  wire       [3:0] a_sig,
    input  wire             a_zero,
    input  wire             a_inf,
    input  wire             a_nan,
    input  wire             b_sgn,
    input  wire signed [5:0] b_exp,
    input  wire       [3:0] b_sig,
    input  wire             b_zero,
    input  wire             b_inf,
    input  wire             b_nan,
    output wire      [31:0] y
);
    localparam [31:0] QNAN = 32'h7FC0_0000;

    wire sgn = a_sgn ^ b_sgn;

    // The whole multiplier: 4 bits x 4 bits. prod8 is in [64,225] for normals,
    // so its MSB is bit 7 or bit 6 and normalising costs one conditional shift.
    wire [7:0] prod8 = a_sig * b_sig;

    // value = prod8 * 2^(a_exp + b_exp - 6), because each sig4 carries a factor
    // of 1/8. Renormalise to 1.fffffff x 2^e:
    //   prod8 >= 128  ->  MSB at bit 7,  e = a_exp + b_exp + 1
    //   prod8 <  128  ->  MSB at bit 6,  e = a_exp + b_exp
    wire       hi   = prod8[7];
    wire [7:0] nrm  = hi ? prod8 : {prod8[6:0], 1'b0};

    // 8 bits signed: [-28,+30] plus the renormalise carry, then +127. The result
    // field lands in [99,158], so neither overflow nor underflow is reachable --
    // there is deliberately no clamp here to suggest otherwise.
    wire signed [8:0] e_unb = $signed({{3{a_exp[5]}}, a_exp})
                            + $signed({{3{b_exp[5]}}, b_exp})
                            + $signed({8'd0, hi});
    wire [7:0] e_fld = e_unb[7:0] + 8'd127;

    // nrm[7] is the implicit 1; nrm[6:0] are the only 7 fraction bits a product
    // of two 4-bit significands can have, so the low 16 are exactly zero. This
    // is where "the product never rounds" becomes visible in the RTL.
    wire [31:0] normal_y = {sgn, e_fld, nrm[6:0], 16'd0};

    // Inf x 0 is the case that must be NaN rather than Inf or zero. Ordering
    // matters: NaN, then Inf-times-zero, then Inf, then zero.
    wire any_nan  = a_nan | b_nan;
    wire inf_zero = (a_inf & b_zero) | (b_inf & a_zero);
    wire any_inf  = a_inf | b_inf;
    wire any_zero = a_zero | b_zero;

    assign y = (any_nan | inf_zero) ? QNAN
             : any_inf              ? {sgn, 8'hFF, 23'd0}
             : any_zero             ? {sgn, 31'd0}          // IEEE signed zero
                                    : normal_y;
endmodule
