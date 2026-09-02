//=============================================================================
// fp32_add -- IEEE-754 binary32 addition, round-to-nearest-even, DAZ inputs and
// FTZ results, with Inf/NaN handling. Purely combinational.
//
// WHY THIS IS ITS OWN MODULE. amx_fp8 instantiates it 1024 times, and reuses the
// very same adders for the epilogue that combines the four lane sums into C. A
// block that appears a thousand times and is the design's predicted critical
// path gets its own file and its own testbench (tb/tb_fp32_add.v). Finding a
// rounding bug 1024 instances deep, inside a 16-cycle accumulation, is the worst
// possible place to find one.
//
// WHY A GENERAL ADDER, when one operand in the accumulate step is an fp8 product
// with only 8 significant bits and could use a much narrower aligner: because
// the epilogue reuses these adders on two full FP32 operands (lane+lane, and
// lane+C). Sharing costs generality; the alternative was 768 more adders. The
// narrow-operand accumulate adder is a real optimisation and is deliberately NOT
// taken here -- measure the general one first.
//
//----------------------------------------------------------------- SEMANTICS
// DAZ: an input with exponent field 0 IS ZERO, subnormal payload and all. So
// there is no subnormal input decode anywhere in this design. That is the ISA's
// behaviour (Bochs sets DAZ+FTZ for the AMX-FP8 path), and it is also why the
// fp8 decoders upstream need no leading-zero logic.
//
// FTZ: a result that would be subnormal is flushed to a zero of the result's
// sign. Unreachable from fp8 products -- the smallest possible product magnitude
// is 2^-28 and FP32 subnormals start below 2^-126 -- but a preloaded C can get
// there, so it is implemented and tested rather than assumed away.
//
// NaN results are CANONICALISED to 0x7FC00000 rather than propagating a source
// NaN's payload. A stated deviation, not an oversight: the unit is bit-exact for
// every finite and infinite input, and payload muxing across 1024 adders buys
// nothing an ML datapath can use. tb/tb_fp32_add.v asserts the canonical value.
//
//------------------------------------------------------------ THE STRUCTURE
//   unpack -> magnitude swap -> align (5-stage) -> 28-bit add/sub
//          -> leading-zero count (5-stage) -> normalise (5-stage) -> round
//
// This is the design's floor, and the reason amx_fp8 clocks below the INT8
// designs at equal MAC count: amx_tdpbssd's accumulate loop is a 33-bit integer
// add and nothing else.
//
// WHERE THE TIME ACTUALLY GOES, measured rather than assumed -- flop to flop
// through this block, mapped to Nangate45 with no parasitics:
//
//   74 gate levels, 6.180 ns total
//   two NOR4_X1 gates alone     1.470 ns  = 24% of the path
//   all three barrel shifters   0.204 ns  =  3% of the path
//
// An earlier version of this comment blamed the three barrel shifters. THAT IS
// WRONG: at five MUX levels each they are 3% of the path. The cost is sheer
// DEPTH -- 74 levels of AOI/OAI -- plus two minimum-drive cells fanning out
// hard. Those two are an artefact of `abc -liberty` picking X1 cells with no
// load information, so OpenROAD's resizing may well recover some of that in a
// routed run. Do not quote 6.180 ns as the routed number: it is optimistic on
// wires and pessimistic on drive strength at the same time.
//
// The leading-zero count is written as an explicit 5-level BINARY SEARCH, not as
// a for-loop with a conditional assignment. The loop form is shorter and yosys
// turns it into a 27-deep mux chain -- correct, and a disaster in a block that
// appears 1024 times on the critical path.
//=============================================================================
module fp32_add (
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire [31:0] y
);
    localparam [31:0] QNAN     = 32'h7FC0_0000;
    localparam [31:0] POS_ZERO = 32'h0000_0000;

    // ---- unpack -------------------------------------------------------------
    wire        sa = a[31],        sb = b[31];
    wire [7:0]  ea = a[30:23],     eb = b[30:23];
    wire [22:0] fa = a[22:0],      fb = b[22:0];

    wire a_nan  = (ea == 8'hFF) && (fa != 23'd0);
    wire b_nan  = (eb == 8'hFF) && (fb != 23'd0);
    wire a_inf  = (ea == 8'hFF) && (fa == 23'd0);
    wire b_inf  = (eb == 8'hFF) && (fb == 23'd0);
    // DAZ: exponent field 0 is zero regardless of the fraction.
    wire a_zero = (ea == 8'd0);
    wire b_zero = (eb == 8'd0);

    // Significands with the implicit 1. Zero operands contribute nothing, and
    // forcing the significand to 0 here is what lets the ordinary datapath
    // handle "zero + normal" without a separate bypass.
    wire [23:0] ma = a_zero ? 24'd0 : {1'b1, fa};
    wire [23:0] mb = b_zero ? 24'd0 : {1'b1, fb};

    // ---- magnitude swap -----------------------------------------------------
    // {exp, frac} compares as an unsigned magnitude for like-signed floats, so
    // one 31-bit compare orders the operands. It is also correct when one side
    // is zero or subnormal: any normal has exp >= 1, so {eb,fb} >= 0x800000
    // while {0,fa} <= 0x7FFFFF, and the zero can never win.
    wire        a_bigger = ({ea, fa} >= {eb, fb});
    wire        big_s    = a_bigger ? sa : sb;
    wire [7:0]  big_e    = a_bigger ? ea : eb;
    wire [23:0] big_m    = a_bigger ? ma : mb;
    wire        small_s  = a_bigger ? sb : sa;
    wire [7:0]  small_e  = a_bigger ? eb : ea;
    wire [23:0] small_m  = a_bigger ? mb : ma;

    // ---- align --------------------------------------------------------------
    // Three low guard bits, so bit 0 is the sticky position. Anything shifted
    // past it is OR-ed back in -- that is what makes the rounding correct for
    // operands tens of binades apart.
    wire [26:0] big_ext   = {big_m,   3'b000};
    wire [26:0] small_ext = {small_m, 3'b000};

    wire [7:0]  ediff = big_e - small_e;
    // Past 26 the small operand is nothing but sticky, so the shifter is capped
    // instead of being 255 positions wide.
    //
    // 27 AND 26 ARE EQUIVALENT HERE, established by mutation rather than
    // assumed: a normal's significand always has bit 23 set, so shifting by 26
    // already lands that bit in the sticky position, and OR-ing the discarded
    // bits back in gives 1 either way. Capping at 25 or lower is NOT equivalent
    // and the testbench catches both. Recorded so a future reader does not
    // "tighten" it to 25, and does not mistake the surviving 26-mutation for a
    // hole in the tests.
    wire [4:0]  sh    = (ediff > 8'd26) ? 5'd27 : ediff[4:0];

    wire [26:0] shifted = small_ext >> sh;
    // Mask of the low `sh` bits: exactly the bits the shift discarded.
    wire [26:0] lost_mask = ~(~27'd0 << sh);
    wire        lost      = |(small_ext & lost_mask);
    wire [26:0] small_al  = {shifted[26:1], shifted[0] | lost};

    // ---- add or subtract ----------------------------------------------------
    // |big| >= |small| by construction, so the subtract cannot go negative and
    // the result sign is always big's.
    wire        sub = big_s ^ small_s;
    wire [27:0] raw = sub ? ({1'b0, big_ext} - {1'b0, small_al})
                          : ({1'b0, big_ext} + {1'b0, small_al});

    // ---- normalise ----------------------------------------------------------
    // Only an addition can carry out; a subtraction can cancel arbitrarily far,
    // which is what the leading-zero count is for.
    wire        carry = raw[27];
    wire [26:0] pre   = carry ? {raw[27:2], raw[1] | raw[0]}   // >>1, keep sticky
                              : raw[26:0];

    // 27-bit leading-zero count, five levels. Padded to 32 bits with low zeros
    // so the search is uniform; leading zeros are unchanged by low padding.
    wire [31:0] lzin = {pre, 5'b00000};
    wire [4:0]  lz;
    assign lz[4] = (lzin[31:16] == 16'd0);
    wire [15:0] lz_l3 = lz[4] ? lzin[15:0] : lzin[31:16];
    assign lz[3] = (lz_l3[15:8] == 8'd0);
    wire [7:0]  lz_l2 = lz[3] ? lz_l3[7:0] : lz_l3[15:8];
    assign lz[2] = (lz_l2[7:4] == 4'd0);
    wire [3:0]  lz_l1 = lz[2] ? lz_l2[3:0] : lz_l2[7:4];
    assign lz[1] = (lz_l1[3:2] == 2'd0);
    wire [1:0]  lz_l0 = lz[1] ? lz_l1[1:0] : lz_l1[3:2];
    assign lz[0] = ~lz_l0[1];

    wire [26:0] norm = pre << lz;

    // E = big_e + carry - lz. Derivation: big_ext = big_m << 3 so big's value is
    // big_ext * 2^(big_e-153); after the shift the value is norm * 2^(big_e +
    // carry - lz - 153), and taking norm[26:3] as the 24-bit significand moves
    // the scale to 2^(E-150), the FP32 convention. Signed and 10 bits wide
    // because E ranges over [-27, +256] before clamping.
    // Declared UNSIGNED even though it holds a two's-complement value, and the
    // two comparisons below apply $signed() explicitly instead. Addition and
    // subtraction give identical bits either way, so nothing is lost -- and a
    // `signed` port or wire that survives into the netlist makes OpenSTA's
    // Verilog reader fail with STA-0171. See rtl/fp8_mul.v, which lost a run to
    // exactly that.
    wire [9:0] e_norm = $signed({2'b00, big_e}) + $signed({9'd0, carry})
                                               - $signed({5'd0, lz});

    // ---- round to nearest, ties to even ------------------------------------
    wire        r_bit   = norm[2];
    wire        r_stick = |norm[1:0];
    wire        roundup = r_bit & (r_stick | norm[3]);
    wire [24:0] m_rnd   = {1'b0, norm[26:3]} + {24'd0, roundup};
    wire        m_ovf   = m_rnd[24];                 // rounded up to 2^24
    wire [23:0] m_fin   = m_ovf ? m_rnd[24:1] : m_rnd[23:0];
    wire [9:0] e_fin = $signed(e_norm) + $signed({9'd0, m_ovf});

    // ---- pack ---------------------------------------------------------------
    wire res_zero = (raw == 28'd0);
    // A zero out of exact cancellation is +0 under RNE. Only a sum of two zeros
    // keeps a sign, and only when both were negative.
    wire zero_sgn = (a_zero && b_zero) ? (sa && sb) : 1'b0;

    // $signed() on BOTH sides is load-bearing: e_fin is now an unsigned
    // declaration, and a mixed comparison in Verilog is evaluated UNSIGNED,
    // which would make every negative exponent look enormous and defeat FTZ.
    wire overflow  = ($signed(e_fin) >= $signed(10'd255));
    wire underflow = ($signed(e_fin) <= $signed(10'd0));      // FTZ

    wire [31:0] finite = res_zero  ? {zero_sgn, 31'd0}
                       : overflow  ? {big_s, 8'hFF, 23'd0}
                       : underflow ? {big_s, 31'd0}
                                   : {big_s, e_fin[7:0], m_fin[22:0]};

    // Specials take precedence over everything the datapath computed.
    assign y = (a_nan || b_nan)          ? QNAN
             : (a_inf && b_inf)          ? ((sa != sb) ? QNAN : a)
             : a_inf                     ? a
             : b_inf                     ? b
                                         : finite;

    // Silence "unused" on the zero-value tie-off; POS_ZERO documents intent.
    wire _unused = |POS_ZERO;
endmodule
