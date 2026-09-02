//=============================================================================
// maxmag64 -- max of byte[6:0] over the 64 bytes of a tile row (or column).
//
// This computes the ALIGNMENT REFERENCE for amx_fp8's ACC=1 fixed-point
// accumulator. Get it wrong and the accumulator either overflows (reference too
// small) or throws away significance (too large) -- and neither failure looks like
// a reference bug from the outside, they look like arithmetic bugs. So it is a leaf
// with its own testbench.
//
//------------------------------------------------- WHY byte[6:0] IS THE RIGHT KEY
// The exponent field occupies the HIGH bits of [6:0] in both FP8 formats:
//
//   E5M2   S EEEEE MM     byte[6:2] is the exponent
//   E4M3   S EEEE  MMM    byte[6:3] is the exponent
//
// so the byte with the largest [6:0] also has the largest exponent field, in
// EITHER format. That is the whole trick: the max can be taken over raw bytes
// before `op` is known, and the format-dependent bias is subtracted afterwards on
// the single winner instead of on all 64 candidates. It also means one instance of
// this module serves A rows and B columns alike.
//
// Sign bit EXCLUDED deliberately -- [6:0], not [7:0]. The reference is about
// magnitude; including bit 7 would make every negative byte beat every positive
// one and the reference would track the sign pattern instead of the range.
//
//----------------------------------------------------------- SPECIALS ARE FINE
// An Inf or NaN byte has the all-ones exponent field, so it wins the max and
// produces a reference one or two binades above any finite byte's. That is
// harmless: any element whose products include a special has its result overridden
// by the special, so the accumulator value -- and therefore the reference -- is
// discarded. A too-LARGE reference is always the safe direction; it can only shift
// terms further right, never overflow.
//
// A DAZ subnormal (exponent field 0, nonzero mantissa) can win the max over an
// all-zero row and yield a nonsense reference. Also harmless, for a stronger
// reason: every product in such a row is zero, so the accumulator never leaves
// zero and fx2fp32 returns +0 whatever the reference says.
//
//------------------------------------------------------------------ STRUCTURE
// An explicit 6-level binary tree, 63 comparators. NOT a for-loop accumulating a
// running max: yosys turns that into a 63-deep comparator/mux chain. Same lesson
// as the leading-zero counts in rtl/fp32_add.v and rtl/fx2fp32.v, and it matters
// more here than it looks -- 32 instances of this sit on the reg-to-reg path that
// latches the reference on the start edge.
//=============================================================================
module maxmag64 (
    input  wire [511:0] bytes,   // 64 fp8 bytes, byte i at [i*8 +: 8]
    output wire [6:0]   mx       // max over byte[6:0]
);
    wire [64*7-1:0] l0;
    wire [32*7-1:0] l1;
    wire [16*7-1:0] l2;
    wire [ 8*7-1:0] l3;
    wire [ 4*7-1:0] l4;
    wire [ 2*7-1:0] l5;

    genvar i;
    generate
        for (i = 0; i < 64; i = i + 1) begin : g_l0
            assign l0[i*7 +: 7] = bytes[i*8 +: 7];      // drop bit 7, the sign
        end
        for (i = 0; i < 32; i = i + 1) begin : g_l1
            assign l1[i*7 +: 7] = (l0[(2*i)*7 +: 7] > l0[(2*i+1)*7 +: 7])
                                ?  l0[(2*i)*7 +: 7] :   l0[(2*i+1)*7 +: 7];
        end
        for (i = 0; i < 16; i = i + 1) begin : g_l2
            assign l2[i*7 +: 7] = (l1[(2*i)*7 +: 7] > l1[(2*i+1)*7 +: 7])
                                ?  l1[(2*i)*7 +: 7] :   l1[(2*i+1)*7 +: 7];
        end
        for (i = 0; i < 8; i = i + 1) begin : g_l3
            assign l3[i*7 +: 7] = (l2[(2*i)*7 +: 7] > l2[(2*i+1)*7 +: 7])
                                ?  l2[(2*i)*7 +: 7] :   l2[(2*i+1)*7 +: 7];
        end
        for (i = 0; i < 4; i = i + 1) begin : g_l4
            assign l4[i*7 +: 7] = (l3[(2*i)*7 +: 7] > l3[(2*i+1)*7 +: 7])
                                ?  l3[(2*i)*7 +: 7] :   l3[(2*i+1)*7 +: 7];
        end
        for (i = 0; i < 2; i = i + 1) begin : g_l5
            assign l5[i*7 +: 7] = (l4[(2*i)*7 +: 7] > l4[(2*i+1)*7 +: 7])
                                ?  l4[(2*i)*7 +: 7] :   l4[(2*i+1)*7 +: 7];
        end
    endgenerate

    assign mx = (l5[0 +: 7] > l5[7 +: 7]) ? l5[0 +: 7] : l5[7 +: 7];
endmodule
