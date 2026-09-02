//=============================================================================
// fx2fp32 -- a wide two's-complement fixed-point value to IEEE binary32, with a
// single round-to-nearest-even. Purely combinational.
//
// This is the X2 epilogue: the one place the fixed-point accumulator rounds. Its
// whole reason to exist is that ACC=1 does the rounding ONCE per output element
// instead of 64 times per element, so there are 256 of these where ACC=0 has
// 1024 fp32_add instances doing it every cycle.
//
//   value = $signed(acc) * 2^low
//
// `low` is the accumulator's LSB position, `ref + 8 - ACC_W` in amx_fp8. It is an
// input rather than a parameter because it is per-output-element: each element
// aligns to its own reference exponent.
//
//------------------------------------------------------------------ STRUCTURE
//   negate if negative -> count leading zeros -> normalise -> round -> pack
//
// Compare rtl/fp32_add.v, which needs all of that PLUS an alignment shifter and
// an operand swap, on every single add. Here the LZC and normalise shifter appear
// once per instruction rather than once per accumulation, which is the entire
// arithmetic argument of X2.
//
// The leading-zero count is an explicit 6-level BINARY SEARCH over a 64-bit
// left-justified copy, not a loop with a conditional assignment: yosys turns the
// loop form into a mux chain as deep as the operand, and that lesson is already
// recorded in rtl/fp32_add.v.
//
//---------------------------------------------------------- ONE SUBTLE POINT
// Negating the most-negative value -2^(ACC_W-1) overflows in ACC_W bits, and the
// result is the bit pattern 100...0. Read as UNSIGNED that pattern IS 2^(ACC_W-1),
// which is exactly |acc| -- so treating the magnitude as unsigned makes the
// pathological case fall out correctly with no special handling. amx_fp8's +8
// headroom means the value is unreachable there anyway, but a leaf that is only
// correct for the inputs its current caller happens to produce is a trap.
//
// Overflow to Inf and FTZ underflow are implemented and tested even though
// amx_fp8 cannot reach them (its `low` lands in [-73,-13], so the result exponent
// field stays inside [54,165]). Same reason.
//=============================================================================
module fx2fp32 #(
    // Accumulator width. Must be at least 26: the significand needs 24 bits plus
    // a round bit and at least one sticky bit below it.
    parameter integer ACC_W = 52
)(
    input  wire signed [ACC_W-1:0] acc,
    input  wire signed [9:0]       low,   // value = acc * 2^low
    output wire        [31:0]      y
);
    localparam integer LZW = 6;           // ceil(log2(64)), the padded LZC width
    // Sized so the exponent arithmetic below stays 12 bits. Written as a sized
    // localparam rather than inline `12'd0 + (ACC_W-1)`, which Verilog widens to
    // 32 bits and then truncates -- correct here, but the kind of accidental
    // width promotion that is a bug the moment someone edits the expression.
    localparam [11:0] E_OFF = ACC_W - 1;  // MSB position after normalising

    // ---- magnitude ----------------------------------------------------------
    wire sgn = acc[ACC_W-1];
    // Unsigned on purpose -- see the header note on -2^(ACC_W-1).
    wire [ACC_W-1:0] mag = sgn ? (~acc + {{(ACC_W-1){1'b0}}, 1'b1}) : acc;
    wire is_zero = (mag == {ACC_W{1'b0}});

    // ---- leading-zero count, 6 levels ---------------------------------------
    // mag is LEFT-justified into 64 bits, so the padding is on the low side and
    // the 64-bit leading-zero count equals mag's own.
    wire [63:0] lzin = {mag, {(64-ACC_W){1'b0}}};
    wire [LZW-1:0] lz;
    assign lz[5] = (lzin[63:32] == 32'd0);
    wire [31:0] l4 = lz[5] ? lzin[31:0]  : lzin[63:32];
    assign lz[4] = (l4[31:16] == 16'd0);
    wire [15:0] l3 = lz[4] ? l4[15:0]    : l4[31:16];
    assign lz[3] = (l3[15:8] == 8'd0);
    wire [7:0]  l2 = lz[3] ? l3[7:0]     : l3[15:8];
    assign lz[2] = (l2[7:4] == 4'd0);
    wire [3:0]  l1 = lz[2] ? l2[3:0]     : l2[7:4];
    assign lz[1] = (l1[3:2] == 2'd0);
    wire [1:0]  l0 = lz[1] ? l1[1:0]     : l1[3:2];
    assign lz[0] = ~l0[1];

    // ---- normalise ----------------------------------------------------------
    // After this the MSB of a nonzero magnitude sits at bit ACC_W-1.
    wire [ACC_W-1:0] norm = mag << lz;

    // The value's unbiased exponent: MSB was at ACC_W-1-lz, and the LSB is at
    // `low`, so the exponent is low + (ACC_W-1-lz).
    wire signed [11:0] e_unb = $signed({{2{low[9]}}, low})
                             + $signed(E_OFF)
                             - $signed({{(12-LZW){1'b0}}, lz});

    // ---- round to nearest, ties to even ------------------------------------
    wire [23:0] sig24  = norm[ACC_W-1 -: 24];
    wire        r_bit  = norm[ACC_W-25];
    wire        sticky = |norm[ACC_W-26:0];
    wire        roundup = r_bit & (sticky | sig24[0]);
    wire [24:0] m_rnd  = {1'b0, sig24} + {24'd0, roundup};
    wire        m_ovf  = m_rnd[24];                    // rounded up to 2^24
    wire [23:0] m_fin  = m_ovf ? m_rnd[24:1] : m_rnd[23:0];
    wire signed [11:0] e_fin = e_unb + $signed({11'd0, m_ovf});

    // ---- pack ---------------------------------------------------------------
    wire signed [11:0] ef = e_fin + $signed(12'd127);
    wire overflow  = (ef >= $signed(12'd255));
    wire underflow = (ef <= $signed(12'd0));           // FTZ

    // The zero branch is +0, NOT {sgn, 31'd0}: mag==0 only when acc==0, and then
    // acc[ACC_W-1] is 0 by construction, so the two expressions are the same
    // logic. Written the simple way and asserted in the testbench (all 1024 `low`
    // values give 0x00000000) so the equivalence is a checked fact rather than an
    // argument in a comment.
    //
    // Negative zero is still produced by this module -- from the FTZ branch, where
    // sgn is genuinely live. For acc = -1 that happens at 386 of 1024 `low` values.
    assign y = is_zero   ? 32'd0
             : overflow  ? {sgn, 8'hFF, 23'd0}
             : underflow ? {sgn, 31'd0}               // FTZ keeps the sign
                         : {sgn, ef[7:0], m_fin[22:0]};

    // ---- ACC_W bounds ------------------------------------------------------
    // 26 <= ACC_W <= 64, and both bounds are enforced by ELABORATION rather than by
    // a runtime check. There used to be an `initial` block here that displayed a
    // message and called $finish; it was dead code, because the range expressions
    // above fail first and harder:
    //
    //   ACC_W = 25 -> "part select norm[-1:0] is out of order"     (the sticky OR)
    //   ACC_W = 65 -> negative replication in {mag, {(64-ACC_W){1'b0}}}
    //
    // A guard that cannot fire, sitting under a comment claiming it guards, is worse
    // than no guard: it invites the reader to trust it. Verified at 34/40/44/48/52/
    // 56/64 (all pass) and 25 (refused at elaboration).
endmodule
