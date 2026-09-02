#!/usr/bin/env python3
"""
Reference models for amx_fp8 -- Intel AMX-FP8, all four mix-and-match variants.

    TDPBF8PS   src1 BF8  src2 BF8      BF8 = E5M2
    TDPBHF8PS  src1 BF8  src2 HF8      HF8 = E4M3
    TDPHBF8PS  src1 HF8  src2 BF8
    TDPHF8PS   src1 HF8  src2 HF8

C[16][16] fp32 += A[16][64] fp8 @ B[64][16] fp8, i.e. 16,384 MACs per instruction.

    python3 tb/fp8_golden.py                 # self-test
    python3 tb/fp8_golden.py --print-golden   # constants for tb_amx_fp8.v

--------------------------------------------------------- WHAT THE ISA SAYS
Established by reading three sources this session. They do NOT agree, and the
disagreement is about arithmetic, not presentation:

  Intel patent EP4398097A2  the four byte-lane products are accumulated
                            "separately" -- a sum of K first products, a sum of
                            K second products, and so on, combined with C at the
                            end. FOUR RUNNING SUMS. This is what is modelled.
  Bochs cpu/avx/amx.cc      two running fp32 halves with a pairwise tree inside
                            each k-step. Almost certainly Bochs carrying its
                            BF16 shape (2 elements/dword -> 2 accumulators) over
                            to FP8's 4 elements.
  LLVM amxfp8intrin.h       one wide accumulator, single FP32() conversion. Its
                            operands are wrapped in INT64(...), copy-pasted
                            verbatim from the INT8 header -- you cannot compute
                            an fp8 dot product with INT64 casts. Discarded.

The patent is Intel describing its own hardware, and four lanes -> four
accumulators mirrors BF16's two -> two. So: four independent FP32 accumulators
per output element, RNE rounding, DAZ on inputs, FTZ on results.

STILL UNKNOWN, and deliberately not papered over: the order the four lane sums
are combined at the end. A balanced tree (l0+l1)+(l2+l3) is implemented; the
sequential order is ALSO computed by lane_combine_differs() and the self-test
reports how often the two disagree, so the residual risk is a number rather
than a shrug.

-------------------------------------------------------- THREE MODELS, AND WHY
From tb/amx_golden.py: three models that agree are evidence, two models where one
is derived from the other are one model. These three share no code path:

  fp32_add_exact()   computes the EXACT sum as an arbitrary-precision integer,
                     then rounds once. That is the definition of IEEE addition,
                     not a transliteration of a hardware pipeline, so it cannot
                     inherit a bug from the align/normalise/round structure the
                     RTL uses.

  fp32_add_native()  converts to Python floats, adds in FP64, rounds to FP32 via
                     struct. LEGITIMATE, NOT LAZY: for a SINGLE addition of two
                     FP32 values, rounding to 53 bits and then to 24 gives the
                     same answer as rounding once to 24, because 53 >= 2p+2 = 50
                     (innocuous double rounding). Overflow and underflow break
                     that guarantee, so both are checked for explicitly. This
                     model reaches the C library's adder, i.e. hardware nobody
                     here wrote.

  exact_dot()        fractions.Fraction. No rounding anywhere. Not a conformance
                     model -- it is the yardstick that says how much the spec's
                     per-add rounding actually costs, and it is what proves the
                     products are exact.

  matmul_ref()       textbook triple loop on LOGICAL matrices. Catches a wrong
                     VNNI interleave, which the physical-tile model cannot: that
                     one never names a logical matrix at all. It necessarily
                     reproduces the four-lane rounding structure, because FP32
                     addition is not associative and a differently-grouped sum
                     would disagree for reasons that have nothing to do with
                     packing. Its independence is of the LAYOUT, and only that.

------------------------------------------------------ PRODUCTS ARE EXACT
With DAZ there are no subnormal inputs, so every operand is 1.mmm x 2^e. Left-
aligning both formats into a common 4-bit significand field makes the product
significand 8 bits -- far inside FP32's 24 -- and the exponent sum lands in
[-28, +30], far inside FP32's [-126, +127]:

    E5M2  1.mm  -> {1,mm,0}   e in [-14, +15]   max normal 57344
    E4M3  1.mmm -> {1,mmm}    e in [-6,  +8]    max normal 448

So THE MULTIPLY NEVER ROUNDS. Every rounding in this unit happens in an adder.
That is a load-bearing claim, so test 3 proves it against Fraction rather than
asserting it in a comment.

-------------------------------------------------------------- ONE DEVIATION
NaN results are canonicalised to 0x7FC00000 rather than propagating an input
NaN's payload. Stated here because it is a real difference: the design is
bit-exact for every finite and infinite input, and returns a canonical quiet NaN
where the ISA would return a quieted source NaN. Payload muxing across 1024
adders buys nothing an ML datapath can use.
"""
import argparse
import random
import struct
from fractions import Fraction

# ---- tile geometry, identical to amx_tdpbssd: both are 1-byte element types --
ROWS = 16              # tmm rows
COLSB = 64             # tmm bytes per row
DWORDS = COLSB // 4    # 16 dwords per row -> the n axis
KDW = COLSB // 4       # 16 k-steps, each covering 4 logical K
KLOG = COLSB           # 64 logical K values
LANES = 4              # fp8 elements per dword -> four independent accumulators

# ---- formats. The bit is "is this operand HF8?", which makes op[1:0] below
#      read directly as the mnemonic.
FMT_BF8 = 0            # E5M2
FMT_HF8 = 1            # E4M3

# op[1] = src1/A is HF8, op[0] = src2/B is HF8
OP_TDPBF8PS = 0b00     # BF8 x BF8
OP_TDPBHF8PS = 0b01    # BF8 x HF8
OP_TDPHBF8PS = 0b10    # HF8 x BF8
OP_TDPHF8PS = 0b11     # HF8 x HF8

OP_NAMES = {OP_TDPBF8PS: "TDPBF8PS", OP_TDPBHF8PS: "TDPBHF8PS",
            OP_TDPHBF8PS: "TDPHBF8PS", OP_TDPHF8PS: "TDPHF8PS"}


def op_formats(op):
    """op -> (fmt_a, fmt_b). This is the whole instruction decode."""
    return (FMT_HF8 if (op >> 1) & 1 else FMT_BF8,
            FMT_HF8 if op & 1 else FMT_BF8)


# ---- FP32 bit patterns ------------------------------------------------------
POS_ZERO = 0x00000000
NEG_ZERO = 0x80000000
POS_INF = 0x7F800000
NEG_INF = 0xFF800000
QNAN = 0x7FC00000


def _parts(x):
    return (x >> 31) & 1, (x >> 23) & 0xFF, x & 0x7FFFFF


def is_nan(x):
    _, e, f = _parts(x)
    return e == 0xFF and f != 0


def is_inf(x):
    _, e, f = _parts(x)
    return e == 0xFF and f == 0


def _round_pack(sign, mag, k):
    """Round |value| = mag * 2**k to FP32 with RNE. Applies FTZ and overflow.

    mag is a non-negative Python int of any size and k any int, so the caller
    hands over the EXACT value and all of the rounding happens here, once.
    """
    if mag == 0:
        return sign << 31
    nb = mag.bit_length()
    exp = k + nb - 1                    # unbiased exponent of the value
    drop = nb - 24                      # bits of mag that do not fit
    if drop <= 0:
        m24 = mag << (-drop)
        rbit = sticky = 0
    else:
        m24 = mag >> drop
        rbit = (mag >> (drop - 1)) & 1
        sticky = 1 if (mag & ((1 << (drop - 1)) - 1)) else 0
    if rbit and (sticky or (m24 & 1)):  # round to nearest, ties to even
        m24 += 1
        if m24 == (1 << 24):
            m24 >>= 1
            exp += 1
    ef = exp + 127
    if ef >= 0xFF:
        return (sign << 31) | (0xFF << 23)      # overflow -> Inf
    if ef <= 0:
        return sign << 31                       # FTZ -> signed zero
    return (sign << 31) | (ef << 23) | (m24 & 0x7FFFFF)


def _daz_value(x):
    """DAZ decode: exact value of an FP32 bit pattern as (sign, mag, k).

    Input subnormals are zero, which is what DAZ means. Returns mag == 0 for any
    zero. Callers must have handled Inf and NaN already.
    """
    s, e, f = _parts(x)
    if e == 0:
        return s, 0, 0                  # zero, or a subnormal flushed to zero
    return s, (1 << 23) | f, e - 150    # value = mag * 2**(e-127-23)


def fp32_add_exact(a, b):
    """MODEL 1. Exact arbitrary-precision sum, rounded once. RNE, DAZ, FTZ."""
    if is_nan(a) or is_nan(b):
        return QNAN
    if is_inf(a) and is_inf(b):
        return QNAN if ((a >> 31) != (b >> 31)) else a
    if is_inf(a):
        return a
    if is_inf(b):
        return b
    sa, ma, ka = _daz_value(a)
    sb, mb, kb = _daz_value(b)
    if ma == 0 and mb == 0:
        # IEEE: signed zeros add to -0 only when both are -0; otherwise +0.
        return NEG_ZERO if (sa and sb) else POS_ZERO
    k = min(ka, kb)
    v = ((-ma if sa else ma) << (ka - k)) + ((-mb if sb else mb) << (kb - k))
    if v == 0:
        return POS_ZERO                 # exact cancellation is +0 under RNE
    return _round_pack(1 if v < 0 else 0, abs(v), k)


def bits_to_f64(x):
    """FP32 bit pattern -> Python float. Exact: FP32 is a subset of FP64."""
    return struct.unpack("<f", struct.pack("<I", x & 0xFFFFFFFF))[0]


def f64_to_bits_f32(v):
    """Python float -> FP32 bits, RNE, with FTZ. Raises on FP32 overflow."""
    packed = struct.pack("<f", v)       # struct rounds FP64 -> FP32 with RNE
    bits = struct.unpack("<I", packed)[0]
    if is_inf(bits) and v not in (float("inf"), float("-inf")):
        raise OverflowError("FP32 overflow: %r" % v)
    _, e, f = _parts(bits)
    if e == 0 and f != 0:
        return bits & 0x80000000        # FTZ
    return bits


def fp32_add_native(a, b):
    """MODEL 2. FP64 add via the C library, rounded to FP32.

    Sound for a SINGLE add because 53 >= 2*24+2: rounding to FP64 then to FP32
    matches rounding once to FP32. That theorem excludes overflow and underflow,
    so both are refused loudly instead of returning a quietly wrong answer.
    """
    if is_nan(a) or is_nan(b):
        return QNAN
    if is_inf(a) and is_inf(b):
        return QNAN if ((a >> 31) != (b >> 31)) else a
    if is_inf(a):
        return a
    if is_inf(b):
        return b
    sa, ma, _ = _daz_value(a)
    sb, mb, _ = _daz_value(b)
    if ma == 0 and mb == 0:
        return NEG_ZERO if (sa and sb) else POS_ZERO
    # Re-materialise the DAZ'd operands, so a subnormal input really is zero.
    fa = 0.0 if ma == 0 else bits_to_f64(a)
    fb = 0.0 if mb == 0 else bits_to_f64(b)
    if ma == 0:
        fa = -0.0 if sa else 0.0
    if mb == 0:
        fb = -0.0 if sb else 0.0
    return f64_to_bits_f32(fa + fb)


# ---- fp8 decode and the exact multiply --------------------------------------
# Layout per format. mbits is the stored fraction width; the significand is
# left-aligned into 4 bits so both formats share one multiplier.
_FMT = {
    #        ebits mbits bias  emax
    FMT_BF8: (5, 2, 15, 31),
    FMT_HF8: (4, 3, 7, 15),
}


def fp8_fields(byte, fmt):
    """(sign, exp_field, man_field) for an fp8 byte in the given format."""
    ebits, mbits, _, _ = _FMT[fmt]
    return (byte >> 7) & 1, (byte >> mbits) & ((1 << ebits) - 1), byte & ((1 << mbits) - 1)


def fp8_class(byte, fmt):
    """'zero' | 'normal' | 'inf' | 'nan'. DAZ, so subnormals are zero.

    The E4M3 trap lives here: exp == 15 is NOT all-specials. Only (15, man==7)
    is NaN; (15, man<7) is an ordinary normal, and 1.110 x 2^8 = 448 is the
    format's maximum. E4M3 has no infinity at all.
    """
    _, e, m = fp8_fields(byte, fmt)
    _, _, _, emax = _FMT[fmt]
    if e == 0:
        return "zero"                   # DAZ: subnormals included
    if fmt == FMT_BF8 and e == emax:
        return "inf" if m == 0 else "nan"
    if fmt == FMT_HF8 and e == emax and m == 7:
        return "nan"
    return "normal"


def fp8_sig4_exp(byte, fmt):
    """Normal fp8 -> (sign, sig4, e) with value = (sig4 / 8) * 2**e.

    sig4 is the 4-bit left-aligned significand: {1,mmm} for E4M3 and {1,mm,0}
    for E5M2. Both are integers in [8, 15], so sig4_a * sig4_b is 8 bits.
    """
    _, mbits, bias, _ = _FMT[fmt]
    s, e, m = fp8_fields(byte, fmt)
    sig4 = (1 << 3) | (m << (3 - mbits))
    return s, sig4, e - bias


def fp8_to_fp32_bits(byte, fmt):
    """fp8 byte -> FP32 bit pattern. Exact for every input."""
    cls = fp8_class(byte, fmt)
    s = (byte >> 7) & 1
    if cls == "nan":
        return QNAN
    if cls == "inf":
        return (s << 31) | (0xFF << 23)
    if cls == "zero":
        return s << 31                  # DAZ keeps the sign
    _, sig4, e = fp8_sig4_exp(byte, fmt)
    return _round_pack(s, sig4, e - 3)  # value = sig4 * 2**(e-3)


def fp8_mul_bits(a_byte, fmt_a, b_byte, fmt_b):
    """Exact fp8 x fp8 -> FP32 bit pattern. Never rounds; test 3 proves it."""
    ca, cb = fp8_class(a_byte, fmt_a), fp8_class(b_byte, fmt_b)
    sign = ((a_byte >> 7) & 1) ^ ((b_byte >> 7) & 1)
    if ca == "nan" or cb == "nan":
        return QNAN
    if ca == "inf" or cb == "inf":
        # Inf * 0 is the one case that must NOT be Inf.
        if ca == "zero" or cb == "zero":
            return QNAN
        return (sign << 31) | (0xFF << 23)
    if ca == "zero" or cb == "zero":
        return sign << 31               # signed zero, per IEEE
    _, sa4, ea = fp8_sig4_exp(a_byte, fmt_a)
    _, sb4, eb = fp8_sig4_exp(b_byte, fmt_b)
    return _round_pack(sign, sa4 * sb4, ea + eb - 6)


def fp8_exact(byte, fmt):
    """fp8 byte -> Fraction. Raises on Inf/NaN, which have no rational value."""
    cls = fp8_class(byte, fmt)
    if cls in ("inf", "nan"):
        raise ValueError("%s has no rational value" % cls)
    if cls == "zero":
        return Fraction(0)
    s, sig4, e = fp8_sig4_exp(byte, fmt)
    v = Fraction(sig4, 8) * Fraction(2) ** e
    return -v if s else v


def fp32_exact(x):
    """FP32 bits -> Fraction, with DAZ. Raises on Inf/NaN."""
    if is_nan(x) or is_inf(x):
        raise ValueError("not finite")
    s, mag, k = _daz_value(x)
    v = Fraction(mag) * Fraction(2) ** k
    return -v if s else v


# ---- packing, identical to amx_golden.py ------------------------------------
def pack_a(A):
    """Logical A (ROWS x KLOG) -> physical tmm (ROWS x COLSB). Row-major.

    The identity on the byte grid, written longhand so the asymmetry with
    pack_b is visible rather than implied.
    """
    return [[A[m][4 * k + b] for k in range(KDW) for b in range(4)]
            for m in range(ROWS)]


def pack_b(B):
    """Logical B (KLOG x DWORDS) -> physical tmm (KDW x COLSB), VNNI-4.

    B_phys[k].byte[4n+b] = B[4k+b][n]: four CONSECUTIVE logical rows of B share
    one physical row, so byte b of dword n lines up with byte b of A's dword k.
    """
    out = [[0] * COLSB for _ in range(KDW)]
    for k in range(KDW):
        for n in range(DWORDS):
            for b in range(4):
                out[k][4 * n + b] = B[4 * k + b][n]
    return out


def unpack_a(A_phys):
    return [list(r) for r in A_phys]


def unpack_b(B_phys):
    B = [[0] * DWORDS for _ in range(KLOG)]
    for k in range(KDW):
        for n in range(DWORDS):
            for b in range(4):
                B[4 * k + b][n] = B_phys[k][4 * n + b]
    return B


# ---- model: the instruction, on physical tiles ------------------------------
def tdp_fp8(C, A_phys, B_phys, op, add=fp32_add_exact, sequential_combine=False):
    """The four AMX-FP8 instructions. C is ROWS x DWORDS of FP32 bit patterns.

    Four independent lane accumulators per output element, exactly as the RTL:
        lane[b] += prod[b]        for every k        (rounds here, 64 times)
        s = (lane0+lane1) + (lane2+lane3)            (the balanced tree)
        C = s + C
    `sequential_combine` swaps the tree for ((l0+l1)+l2)+l3, which is the
    reading the sources do not settle. Both are computed by the self-test.
    """
    fmt_a, fmt_b = op_formats(op)
    out = [list(r) for r in C]
    for m in range(ROWS):
        for n in range(DWORDS):
            lane = [POS_ZERO] * LANES
            for k in range(KDW):
                for b in range(LANES):
                    p = fp8_mul_bits(A_phys[m][4 * k + b], fmt_a,
                                     B_phys[k][4 * n + b], fmt_b)
                    lane[b] = add(lane[b], p)
            if sequential_combine:
                s = lane[0]
                for b in range(1, LANES):
                    s = add(s, lane[b])
            else:
                s = add(add(lane[0], lane[1]), add(lane[2], lane[3]))
            # Mirrors the RTL's last epilogue cycle: adder 0 computes
            # lane[0] + C. FP32 add is commutative here, zeros included.
            out[m][n] = add(s, out[m][n])
    return out


# ------------------------------ ACC=1: the X2 wide fixed-point accumulator ----
# One WIDE TRUNCATING accumulator per output element instead of four separately
# rounded FP32 lanes. Declared in experiments/harness_fp8.md as X2.
#
# THE WINDOW, derived rather than guessed, because an off-by-one here is invisible
# to random testing and shows up only as a wrong last bit:
#
#     ref = max_exp(A row m) + max_exp(B col n) + 1
#     low = ref + 8 - acc_w                       the accumulator's LSB position
#
# ref is an UPPER BOUND on any product's MSB. A product is
# sig4_a*sig4_b * 2^(ea+eb-6) with each sig4 in [8,15], so it lies in
# [1, 3.52) * 2^(ea+eb) and its MSB sits at ea+eb or ea+eb+1, hence <= ref.
# Sixty-four of them reach 64 * 1.76 * 2^ref = 2^(ref+6.8), so the accumulator's
# top bit must sit at 2^(ref+7) -- which is +8 once the sign bit is counted.
#
# That leaves acc_w - 8 bits below the reference, NOT acc_w - 2. The first width
# sweep in harness_fp8.md assumed the latter and was optimistic by 6 bits; the
# correction is appended there rather than edited in.
#
# Truncation is toward MINUS INFINITY, because that is what an arithmetic right
# shift does. No round-to-nearest and no sticky bit: dropping the sticky is the
# whole point of the generation.


def maxmag_rows(A_phys):
    """max of byte[6:0] over each physical A row -- 16 values of 7 bits.

    byte[6:0] rather than the exponent field, because the field's POSITION depends
    on the format while the tiles are written before `op` is latched. It works
    because the exponent occupies the high bits of [6:0] in both formats, so the
    byte with the largest [6:0] also has the largest exponent, which is all the
    reference needs. The bias is subtracted later, once the format is known.
    """
    return [max(b & 0x7F for b in row) for row in A_phys]


def maxmag_cols(B_phys):
    """max of byte[6:0] over each LOGICAL B column n: bytes 4n..4n+3 of every
    physical row. In hardware this is a running max across all 16 B writes."""
    return [max(B_phys[k][4 * n + b] & 0x7F
                for k in range(KDW) for b in range(LANES))
            for n in range(DWORDS)]


def ref_exp(maxmag, fmt):
    """Unbiased exponent of a max-magnitude byte. An all-zero row yields a
    harmlessly negative reference: every product is then zero and the accumulator
    never leaves 0, so the value is unused."""
    ebits, mbits, bias, _ = _FMT[fmt]
    return ((maxmag >> mbits) & ((1 << ebits) - 1)) - bias


def fx_accumulate(a_row, b_col, fmt_a, fmt_b, ref, acc_w):
    """One output element's fixed-point accumulation.

    Returns (acc_int, (saw_nan, saw_pinf, saw_ninf)). Specials cannot pass through
    a fixed-point accumulator, so they are tracked beside it and override at the
    end -- which is also what ACC=0 does semantically, since there an Inf product
    poisons its lane and the combine tree propagates it.
    """
    low = ref + 8 - acc_w
    scale = Fraction(2) ** low
    acc = 0
    saw_nan = saw_pinf = saw_ninf = False
    for K in range(KLOG):
        xb, yb = a_row[K], b_col[K]
        ca, cb = fp8_class(xb, fmt_a), fp8_class(yb, fmt_b)
        sign = ((xb >> 7) & 1) ^ ((yb >> 7) & 1)
        inf_times_zero = ((ca == "inf" and cb == "zero")
                          or (cb == "inf" and ca == "zero"))
        if ca == "nan" or cb == "nan" or inf_times_zero:
            saw_nan = True
        elif ca == "inf" or cb == "inf":
            if sign:
                saw_ninf = True
            else:
                saw_pinf = True
        elif ca == "zero" or cb == "zero":
            pass                                    # contributes nothing
        else:
            acc += fp8_exact(xb, fmt_a) * fp8_exact(yb, fmt_b) // scale
    return acc, (saw_nan, saw_pinf, saw_ninf)


def fx_to_fp32(acc, ref, acc_w):
    """The accumulator's exact value, rounded ONCE to FP32 with RNE."""
    if acc == 0:
        return POS_ZERO
    return _round_pack(1 if acc < 0 else 0, abs(acc), ref + 8 - acc_w)


def frac_to_fp32(ex):
    """Correctly-rounded FP32 of an exact dyadic rational. The yardstick every
    accumulator width is measured against -- NOT the exact value itself, which is
    usually unrepresentable."""
    if ex == 0:
        return POS_ZERO
    a = abs(ex)
    return _round_pack(1 if ex < 0 else 0, a.numerator,
                       -(a.denominator.bit_length() - 1))


def fx_specials(flags):
    """The special-value override, or None to use the accumulator."""
    saw_nan, saw_pinf, saw_ninf = flags
    if saw_nan or (saw_pinf and saw_ninf):
        return QNAN
    if saw_pinf:
        return POS_INF
    if saw_ninf:
        return NEG_INF
    return None


def tdp_fp8_fx(C, A_phys, B_phys, op, acc_w=52, add=fp32_add_exact):
    """ACC=1. C += A@B with ONE wide truncating accumulator per output element.

    A DELIBERATE DEVIATION from the ISA reading tdp_fp8() implements, in the same
    spirit as SAT=1 in amx_tdpbssd -- and it is MORE accurate, not equal, because
    one truncation beats 64 sequential roundings.
    """
    fmt_a, fmt_b = op_formats(op)
    mm_a, mm_b = maxmag_rows(A_phys), maxmag_cols(B_phys)
    out = [list(r) for r in C]
    for m in range(ROWS):
        a_row = [A_phys[m][K] for K in range(KLOG)]
        for n in range(DWORDS):
            b_col = [B_phys[K // 4][4 * n + (K % 4)] for K in range(KLOG)]
            ref = ref_exp(mm_a[m], fmt_a) + ref_exp(mm_b[n], fmt_b) + 1
            acc, flags = fx_accumulate(a_row, b_col, fmt_a, fmt_b, ref, acc_w)
            sp = fx_specials(flags)
            s = sp if sp is not None else fx_to_fp32(acc, ref, acc_w)
            out[m][n] = add(s, out[m][n])
    return out


def fx_overflows(A_phys, B_phys, op, acc_w):
    """True if any element's accumulation leaves the acc_w-bit two's complement
    range. The +8 headroom is supposed to make this impossible; the self-test
    checks it rather than trusting the algebra."""
    fmt_a, fmt_b = op_formats(op)
    mm_a, mm_b = maxmag_rows(A_phys), maxmag_cols(B_phys)
    lim = 1 << (acc_w - 1)
    for m in range(ROWS):
        a_row = [A_phys[m][K] for K in range(KLOG)]
        for n in range(DWORDS):
            b_col = [B_phys[K // 4][4 * n + (K % 4)] for K in range(KLOG)]
            ref = ref_exp(mm_a[m], fmt_a) + ref_exp(mm_b[n], fmt_b) + 1
            acc, _ = fx_accumulate(a_row, b_col, fmt_a, fmt_b, ref, acc_w)
            if acc >= lim or acc < -lim:
                return True
    return False


def matmul_ref(A, B, C=None, op=OP_TDPBF8PS, add=fp32_add_exact):
    """Textbook, on LOGICAL matrices. Independent of the LAYOUT, only that.

    Reproduces the four-lane grouping deliberately: FP32 addition is not
    associative, so a differently-grouped sum would disagree for reasons that
    say nothing about the VNNI interleave this exists to check.
    """
    fmt_a, fmt_b = op_formats(op)
    n_rows, n_cols = len(A), len(B[0])
    out = [[POS_ZERO] * n_cols for _ in range(n_rows)]
    for m in range(n_rows):
        for n in range(n_cols):
            lane = [POS_ZERO] * LANES
            for k in range(len(B) // LANES):
                for b in range(LANES):
                    p = fp8_mul_bits(A[m][4 * k + b], fmt_a, B[4 * k + b][n], fmt_b)
                    lane[b] = add(lane[b], p)
            s = add(add(lane[0], lane[1]), add(lane[2], lane[3]))
            out[m][n] = add(s, POS_ZERO if C is None else C[m][n])
    return out


def exact_dot(A, B, m, n, op):
    """Fraction dot product for one output element. No rounding anywhere."""
    fmt_a, fmt_b = op_formats(op)
    acc = Fraction(0)
    for K in range(len(B)):
        acc += fp8_exact(A[m][K], fmt_a) * fp8_exact(B[K][n], fmt_b)
    return acc


# ---- generators -------------------------------------------------------------
def _finite_bytes(fmt):
    """Every byte that is a finite value in this format. DAZ folds subnormals
    to zero, so those are legal inputs too -- they just mean zero."""
    return [v for v in range(256) if fp8_class(v, fmt) in ("zero", "normal")]


def rand_a(rng, fmt):
    pool = _finite_bytes(fmt)
    return [[rng.choice(pool) for _ in range(KLOG)] for _ in range(ROWS)]


def rand_b(rng, fmt):
    pool = _finite_bytes(fmt)
    return [[rng.choice(pool) for _ in range(DWORDS)] for _ in range(KLOG)]


def zero_c():
    return [[POS_ZERO] * DWORDS for _ in range(ROWS)]


def one_byte(fmt):
    """The encoding of +1.0: significand 1.000, exponent 0 -> field = bias."""
    _, mbits, bias, _ = _FMT[fmt]
    return bias << mbits


def max_byte(fmt):
    """The largest finite value: 57344 (E5M2) or 448 (E4M3)."""
    ebits, mbits, _, emax = _FMT[fmt]
    if fmt == FMT_BF8:
        return ((emax - 1) << mbits) | ((1 << mbits) - 1)   # S.11110.11
    return (emax << mbits) | ((1 << mbits) - 2)             # S.1111.110


def asym_a(fmt):
    """Asymmetric on purpose: with symmetric tiles a transposed array passes
    every value check, which is the trap the amx A/B naming defect fell into."""
    pool = _finite_bytes(fmt)
    return [[pool[(m * 7 + K * 3 + 1) % len(pool)] for K in range(KLOG)]
            for m in range(ROWS)]


def asym_b(fmt):
    pool = _finite_bytes(fmt)
    return [[pool[(n * 5 + K * 11 + 2) % len(pool)] for n in range(DWORDS)]
            for K in range(KLOG)]


def identity_b(fmt):
    """B = I, so C must come back equal to A widened to FP32."""
    one = one_byte(fmt)
    return [[one if K == n else 0 for n in range(DWORDS)] for K in range(KLOG)]


# ---- self-test --------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--trials", type=int, default=2)
    ap.add_argument("--acc-w", type=int, default=52, dest="acc_w",
                    help="ACC=1 accumulator width for --print-golden")
    ap.add_argument("--print-golden", action="store_true",
                    help="print constants for tb/tb_amx_fp8.v and exit")
    args = ap.parse_args()

    if args.print_golden:
        for op in (OP_TDPBF8PS, OP_TDPBHF8PS, OP_TDPHBF8PS, OP_TDPHF8PS):
            fa, fb = op_formats(op)
            got = tdp_fp8(zero_c(), pack_a(asym_a(fa)), pack_b(asym_b(fb)), op)
            print("op=%d %-10s C[0][0]=%08x C[0][1]=%08x C[1][0]=%08x C[15][15]=%08x"
                  % (op, OP_NAMES[op], got[0][0], got[0][1], got[1][0], got[15][15]))
        print()
        print("# ACC=1 (X2 fixed-point), acc_w=%d" % args.acc_w)
        for op in (OP_TDPBF8PS, OP_TDPBHF8PS, OP_TDPHBF8PS, OP_TDPHF8PS):
            fa, fb = op_formats(op)
            got = tdp_fp8_fx(zero_c(), pack_a(asym_a(fa)), pack_b(asym_b(fb)),
                             op, args.acc_w)
            print("op=%d %-10s C[0][0]=%08x C[0][1]=%08x C[1][0]=%08x C[15][15]=%08x"
                  % (op, OP_NAMES[op], got[0][0], got[0][1], got[1][0], got[15][15]))
        return 0

    rng = random.Random(args.seed)
    fails = 0
    print("# AMX-FP8 reference self-test  (seed=%d, trials=%d)" % (args.seed, args.trials))
    print("# A %dx%d fp8, B %dx%d fp8, C %dx%d fp32   (%s MACs/instruction)"
          % (ROWS, KLOG, KLOG, DWORDS, ROWS, DWORDS, format(ROWS * DWORDS * KLOG, ",")))
    print("# BF8=E5M2 max %g   HF8=E4M3 max %g"
          % (bits_to_f64(fp8_to_fp32_bits(max_byte(FMT_BF8), FMT_BF8)),
             bits_to_f64(fp8_to_fp32_bits(max_byte(FMT_HF8), FMT_HF8))))

    # 1. packing round-trips
    for name, fmt in (("BF8", FMT_BF8), ("HF8", FMT_HF8)):
        A, B = asym_a(fmt), asym_b(fmt)
        ok = unpack_a(pack_a(A)) == A and unpack_b(pack_b(B)) == B
        print("  [%s] pack/unpack round-trip, %s" % ("PASS" if ok else "FAIL", name))
        fails += not ok

    # 2. THE TWO FP32 ADDERS MUST AGREE. Exhaustive on directed edges, then
    #    random. Disagreement here invalidates every test below it.
    edges = [POS_ZERO, NEG_ZERO, 0x3F800000, 0xBF800000, 0x00800000, 0x00000001,
             0x7F7FFFFF, 0xFF7FFFFF, 0x33000000, 0x4B000000, 0x3F7FFFFF,
             0x40000000, 0x33800000, 0x00000000 | 0x007FFFFF]
    bad = 0
    for a in edges:
        for b in edges:
            try:
                n = fp32_add_native(a, b)
            except OverflowError:
                continue
            if fp32_add_exact(a, b) != n:
                bad += 1
    for _ in range(4000):
        a = rng.getrandbits(32)
        b = rng.getrandbits(32)
        if is_inf(a) or is_inf(b) or is_nan(a) or is_nan(b):
            continue
        try:
            n = fp32_add_native(a, b)
        except OverflowError:
            continue
        if fp32_add_exact(a, b) != n:
            bad += 1
    print("  [%s] fp32_add_exact == fp32_add_native (exact-then-round vs "
          "libc FP64+RNE)%s" % ("PASS" if not bad else "FAIL", ""
                                if not bad else "  %d disagree" % bad))
    fails += bool(bad)

    # 3. PRODUCTS ARE EXACT IN FP32 -- exhaustive over all 4 format pairs and
    #    all 256x256 byte pairs. This is a load-bearing claim of the design, so
    #    it is proved against Fraction, not asserted in a comment.
    bad = 0
    for fa in (FMT_BF8, FMT_HF8):
        for fb in (FMT_BF8, FMT_HF8):
            for x in _finite_bytes(fa):
                for y in _finite_bytes(fb):
                    got = fp8_mul_bits(x, fa, y, fb)
                    want = fp8_exact(x, fa) * fp8_exact(y, fb)
                    if fp32_exact(got) != want:
                        bad += 1
    print("  [%s] every fp8 x fp8 product is EXACT in FP32, all 4 format pairs%s"
          % ("PASS" if not bad else "FAIL", "" if not bad else "  %d inexact" % bad))
    fails += bool(bad)

    # 4. format decode: the documented extremes must decode to the documented
    #    values, and the E4M3 trap (exp==15, man<7 is NORMAL) must hold.
    checks = [
        (max_byte(FMT_BF8), FMT_BF8, 57344.0, "E5M2 max normal S.11110.11"),
        (max_byte(FMT_HF8), FMT_HF8, 448.0, "E4M3 max normal S.1111.110"),
        (0x7C, FMT_BF8, float("inf"), "E5M2 S.11111.00 is Inf"),
        # THE E4M3 TRAP. Every one of these has exp == 15, the all-ones field
        # that in every other float format means Inf-or-NaN. In E4M3 only man==7
        # is NaN; 0..6 are ordinary normals, and 1.110 x 2^8 = 448 is the
        # format's maximum. Decoding exp==15 as a special class loses 7 of the
        # 8 largest magnitudes the format has.
        (0x78, FMT_HF8, 256.0, "E4M3 S.1111.000 is a NORMAL (256), not Inf"),
        (0x7E, FMT_HF8, 448.0, "E4M3 S.1111.110 is the max normal (448)"),
        (one_byte(FMT_BF8), FMT_BF8, 1.0, "E5M2 +1.0"),
        (one_byte(FMT_HF8), FMT_HF8, 1.0, "E4M3 +1.0"),
        (0x01, FMT_BF8, 0.0, "E5M2 subnormal -> 0 (DAZ)"),
        (0x01, FMT_HF8, 0.0, "E4M3 subnormal -> 0 (DAZ)"),
    ]
    bad = []
    for byte, fmt, want, why in checks:
        got = bits_to_f64(fp8_to_fp32_bits(byte, fmt))
        if got != want:
            bad.append("%s: got %g want %g" % (why, got, want))
    nan_ok = (fp8_class(0x7F, FMT_HF8) == "nan" and fp8_class(0x7D, FMT_BF8) == "nan"
              and fp8_class(0x7E, FMT_HF8) == "normal")
    ok = not bad and nan_ok
    print("  [%s] fp8 decode: documented extremes, DAZ, and E4M3's exp==15 "
          "normals%s" % ("PASS" if ok else "FAIL", "" if ok else "  " + "; ".join(bad)))
    fails += not ok

    # 5. the physical-tile model and the logical model must agree, all 4 ops
    for op in (OP_TDPBF8PS, OP_TDPBHF8PS, OP_TDPHBF8PS, OP_TDPHF8PS):
        fa, fb = op_formats(op)
        bad_n = 0
        for _ in range(args.trials):
            A, B = rand_a(rng, fa), rand_b(rng, fb)
            isa = tdp_fp8(zero_c(), pack_a(A), pack_b(B), op)
            ref = matmul_ref(A, B, None, op)
            bad_n += isa != ref
        print("  [%s] %-10s physical-tile model == logical matmul, %d tiles"
              % ("PASS" if not bad_n else "FAIL", OP_NAMES[op], args.trials))
        fails += bool(bad_n)

    # 6. the interleave has teeth: a 4b+k pack must change the answer
    A, B = asym_a(FMT_BF8), asym_b(FMT_BF8)
    good = tdp_fp8(zero_c(), pack_a(A), pack_b(B), OP_TDPBF8PS)
    wrong = [[0] * COLSB for _ in range(KDW)]
    for k in range(KDW):
        for n in range(DWORDS):
            for b in range(4):
                wrong[k][4 * n + b] = B[4 * b + k][n]     # 4b+k, not 4k+b
    ok = tdp_fp8(zero_c(), pack_a(A), wrong, OP_TDPBF8PS) != good
    print("  [%s] a 4b+k interleave is DETECTED (asymmetric tiles)"
          % ("PASS" if ok else "FAIL"))
    fails += not ok

    # 7. THE MIXED OPS MUST DIFFER FROM EACH OTHER. If TDPBHF8PS and TDPHBF8PS
    #    agreed on the test data, no test could tell a swapped fmt_a/fmt_b from
    #    a correct decode -- the format plumbing would be untested.
    Ax, Bx = asym_a(FMT_BF8), asym_b(FMT_BF8)
    res = {op: tdp_fp8(zero_c(), pack_a(Ax), pack_b(Bx), op)
           for op in OP_NAMES}
    distinct = len({tuple(tuple(r) for r in v) for v in res.values()}) == 4
    print("  [%s] all four ops give DIFFERENT results on one byte pattern "
          "(format plumbing is testable)%s"
          % ("PASS" if distinct else "FAIL", "" if distinct else
             "  some ops coincide -- tests would not catch a swapped format"))
    fails += not distinct

    # 8. identity B passes A through, and a single element localises a transpose.
    #
    #    UP TO THE SIGN OF ZERO, and that is IEEE rather than a fudge. A source
    #    byte with exp==0 and sign==1 is -0 under DAZ, so its product is -0; the
    #    lane accumulator starts at +0, and (+0) + (-0) = +0 under RNE. So a -0
    #    in A comes back +0. Normalising the EXPECTATION is correct here;
    #    normalising the model would be hiding a real behaviour.
    def zap_neg_zero(v):
        return POS_ZERO if v == NEG_ZERO else v

    for fmt, op in ((FMT_BF8, OP_TDPBF8PS), (FMT_HF8, OP_TDPHF8PS)):
        A = asym_a(fmt)
        got = tdp_fp8(zero_c(), pack_a(A), pack_b(identity_b(fmt)), op)
        want = [[zap_neg_zero(fp8_to_fp32_bits(A[m][n], fmt)) for n in range(DWORDS)]
                for m in range(ROWS)]
        ok_id = got == want
        B1 = [[0] * DWORDS for _ in range(KLOG)]
        B1[1][0] = one_byte(fmt)                     # B[1][0]=1 -> C[m][0]=A[m][1]
        g1 = tdp_fp8(zero_c(), pack_a(A), pack_b(B1), op)
        ok_one = all(g1[m][0] == zap_neg_zero(fp8_to_fp32_bits(A[m][1], fmt))
                     for m in range(ROWS))
        print("  [%s] %-10s identity B passes A through (up to the sign of zero); "
              "single B element picks the right A column"
              % ("PASS" if ok_id and ok_one else "FAIL", OP_NAMES[op]))
        fails += not (ok_id and ok_one)

    # 9. C += chains. Two identical instructions must give the FP32 sum of one
    #    with itself -- not "twice", because FP32 doubling is exact but the
    #    claim worth testing is that C is read, added and written back.
    A, B = asym_a(FMT_HF8), asym_b(FMT_HF8)
    c1 = tdp_fp8(zero_c(), pack_a(A), pack_b(B), OP_TDPHF8PS)
    c2 = tdp_fp8(c1, pack_a(A), pack_b(B), OP_TDPHF8PS)
    ok = all(c2[m][n] == fp32_add_exact(c1[m][n], c1[m][n])
             for m in range(ROWS) for n in range(DWORDS))
    print("  [%s] C += chains: second instruction adds onto the first"
          % ("PASS" if ok else "FAIL"))
    fails += not ok

    # 10. specials. Inf x 0 -> NaN is the case a naive multiplier gets wrong.
    inf_b, nan_b = 0x7C, 0x7D                        # E5M2 Inf, E5M2 NaN
    one = one_byte(FMT_BF8)
    cases = [
        (inf_b, one, POS_INF, "Inf x 1 = Inf"),
        (inf_b, 0x00, QNAN, "Inf x 0 = NaN"),
        (nan_b, one, QNAN, "NaN x 1 = NaN"),
        (nan_b, 0x00, QNAN, "NaN x 0 = NaN"),
        (inf_b, 0x80 | one, NEG_INF, "Inf x -1 = -Inf"),
    ]
    bad = [why for x, y, want, why in cases
           if fp8_mul_bits(x, FMT_BF8, y, FMT_BF8) != want]
    add_bad = []
    if fp32_add_exact(POS_INF, NEG_INF) != QNAN:
        add_bad.append("(+Inf)+(-Inf) should be NaN")
    if fp32_add_exact(NEG_ZERO, NEG_ZERO) != NEG_ZERO:
        add_bad.append("(-0)+(-0) should be -0")
    if fp32_add_exact(NEG_ZERO, POS_ZERO) != POS_ZERO:
        add_bad.append("(-0)+(+0) should be +0")
    if fp32_add_exact(0x3F800000, 0xBF800000) != POS_ZERO:
        add_bad.append("1 + (-1) should be +0")
    ok = not bad and not add_bad
    print("  [%s] specials: Inf x 0 -> NaN, NaN propagation, signed-zero rules%s"
          % ("PASS" if ok else "FAIL", "" if ok else "  " + "; ".join(bad + add_bad)))
    fails += not ok

    # 11. THE RANGE ARGUMENT, and it is stronger than the amx_tdpbssd analogue.
    #     The largest instruction a full E5M2 tile can produce is
    #     64 * 57344^2 = 49 * 2^32 ~ 2.1e11, exactly representable. One ULP at
    #     the FP32 rail is 2^104 ~ 2.0e31, so the biggest possible addend is
    #     ~1e-20 of a single ULP up there: a C sitting near the rail is returned
    #     BIT-IDENTICAL. So overflow to Inf is not merely hard to reach from
    #     finite inputs, it is unreachable -- it requires an Inf or NaN in C.
    #     (amx_tdpbssd's INT32 accumulator only had 2047x of margin, so its
    #     saturation logic was reachable by a chain of instructions. This is not.)
    mx = max_byte(FMT_BF8)
    Am = [[mx] * KLOG for _ in range(ROWS)]
    Bm = [[mx] * DWORDS for _ in range(KLOG)]
    got = tdp_fp8(zero_c(), pack_a(Am), pack_b(Bm), OP_TDPBF8PS)
    want_v = Fraction(49) * Fraction(2) ** 32              # 64 * 57344^2
    ok = (not any(is_inf(v) or is_nan(v) for r in got for v in r)
          and all(fp32_exact(v) == want_v for r in got for v in r))
    rail = [[0x7F7FFFFF] * DWORDS for _ in range(ROWS)]
    ok = ok and tdp_fp8(rail, pack_a(Am), pack_b(Bm), OP_TDPBF8PS) == rail
    inf_c = [[POS_INF] * DWORDS for _ in range(ROWS)]
    ok = ok and all(v == POS_INF for r in tdp_fp8(inf_c, pack_a(Am), pack_b(Bm),
                                                  OP_TDPBF8PS) for v in r)
    nan_c = [[QNAN] * DWORDS for _ in range(ROWS)]
    ok = ok and all(is_nan(v) for r in tdp_fp8(nan_c, pack_a(Am), pack_b(Bm),
                                               OP_TDPBF8PS) for v in r)
    ulp_frac = float(want_v / (Fraction(2) ** 104))
    print("  [%s] max x max = 49*2^32 exactly; that is %.2e of one ULP at the "
          "FP32 rail, so C near the rail is UNCHANGED -- Inf needs Inf in"
          % ("PASS" if ok else "FAIL", ulp_frac))
    fails += not ok

    # 12. WHAT THE SPEC'S ROUNDING COSTS, against Fraction. Not a pass/fail on
    #     accuracy -- it is the yardstick, and it also proves exact_dot is
    #     reachable at all.
    A, B = asym_a(FMT_BF8), asym_b(FMT_BF8)
    got = tdp_fp8(zero_c(), pack_a(A), pack_b(B), OP_TDPBF8PS)
    worst = 0.0
    for m in range(ROWS):
        for n in range(DWORDS):
            ex = exact_dot(A, B, m, n, OP_TDPBF8PS)
            if ex != 0:
                rel = abs((fp32_exact(got[m][n]) - ex) / ex)
                worst = max(worst, float(rel))
    ok = worst < 2 ** -20        # 64 rounded adds cannot drift further than this
    print("  [%s] worst relative error vs EXACT rational dot product: %.3e "
          "(bound 2^-20)" % ("PASS" if ok else "FAIL", worst))
    fails += not ok

    # 13. THE UNRESOLVED QUESTION, quantified. The sources do not settle how the
    #     four lane sums are combined. Report how often the balanced tree and
    #     the sequential order disagree, so the risk is a number.
    diff = 0
    total = 0
    for _ in range(args.trials):
        A, B = rand_a(rng, FMT_BF8), rand_b(rng, FMT_BF8)
        bal = tdp_fp8(zero_c(), pack_a(A), pack_b(B), OP_TDPBF8PS)
        seq = tdp_fp8(zero_c(), pack_a(A), pack_b(B), OP_TDPBF8PS,
                      sequential_combine=True)
        for m in range(ROWS):
            for n in range(DWORDS):
                total += 1
                diff += bal[m][n] != seq[m][n]
    print("  [INFO] epilogue order UNRESOLVED in the sources: balanced tree vs "
          "sequential differ in %d/%d elements (%.2f%%)"
          % (diff, total, 100.0 * diff / total if total else 0.0))

    # ---- ACC=1 (X2): the wide fixed-point accumulator ---------------------
    # 14. THE CLAIM harness_fp8.md makes: at acc_w=52 the fixed-point path equals
    #     the correctly-rounded EXACT rational dot product on every element.
    # The right comparison is against the CORRECTLY ROUNDED FP32 of the exact sum,
    # not against the exact sum itself -- those differ by up to half an ulp
    # whenever the exact sum is not representable, which is most of the time.
    for fmt, op in ((FMT_BF8, OP_TDPBF8PS), (FMT_HF8, OP_TDPHF8PS)):
        A, B = asym_a(fmt), asym_b(fmt)
        got = tdp_fp8_fx(zero_c(), pack_a(A), pack_b(B), op, 52)
        ref0 = tdp_fp8(zero_c(), pack_a(A), pack_b(B), op)
        bad_n = 0
        w_fx = w_lane = 0.0
        for m in range(ROWS):
            for n in range(DWORDS):
                ex = exact_dot(A, B, m, n, op)
                if got[m][n] != frac_to_fp32(ex):
                    bad_n += 1
                if ex != 0:
                    w_fx = max(w_fx, abs(float((fp32_exact(got[m][n]) - ex) / ex)))
                    w_lane = max(w_lane,
                                 abs(float((fp32_exact(ref0[m][n]) - ex) / ex)))
        # The bar is that ACC=1 beats ACC=0 on the same data. Claiming "always
        # correctly rounded" would be stronger than the measurement supports.
        ok = w_fx <= w_lane
        print("  [%s] %-10s ACC=1 acc_w=52 vs exact: worst %.3g (ACC=0 was %.3g), "
              "%d/%d not correctly rounded"
              % ("PASS" if ok else "FAIL", OP_NAMES[op], w_fx, w_lane,
                 bad_n, ROWS * DWORDS))
        fails += not ok

    # 15. the width sweep must be MONOTONIC and must bracket ACC=0. If a narrower
    #     accumulator were not worse, the width would not be a real parameter.
    A, B = asym_a(FMT_BF8), asym_b(FMT_BF8)
    pa, pb = pack_a(A), pack_b(B)
    worst = {}
    for w in (40, 44, 48, 52):
        got = tdp_fp8_fx(zero_c(), pa, pb, OP_TDPBF8PS, w)
        e = 0.0
        for m in range(ROWS):
            for n in range(DWORDS):
                ex = exact_dot(A, B, m, n, OP_TDPBF8PS)
                if ex != 0:
                    e = max(e, abs(float((fp32_exact(got[m][n]) - ex) / ex)))
        worst[w] = e
    mono = all(worst[a] >= worst[b] for a, b in ((40, 44), (44, 48), (48, 52)))
    print("  [%s] ACC=1 width sweep is monotonic: %s"
          % ("PASS" if mono else "FAIL",
             "  ".join("w%d=%.2g" % (w, worst[w]) for w in sorted(worst))))
    fails += not mono

    # 16. ACC=1 MUST differ from ACC=0. It is a deviation, not an optimisation,
    #     and a test suite that could not tell them apart would prove nothing.
    c0 = tdp_fp8(zero_c(), pa, pb, OP_TDPBF8PS)
    c1 = tdp_fp8_fx(zero_c(), pa, pb, OP_TDPBF8PS, 52)
    ndiff = sum(1 for m in range(ROWS) for n in range(DWORDS)
                if c0[m][n] != c1[m][n])
    print("  [%s] ACC=1 differs from ACC=0 in %d/%d elements (it is a DEVIATION)"
          % ("PASS" if ndiff else "FAIL", ndiff, ROWS * DWORDS))
    fails += not ndiff

    # 17. the +8 headroom must make overflow impossible, at every width
    ovf = [w for w in (40, 44, 48, 52, 56)
           if fx_overflows(pa, pb, OP_TDPBF8PS, w)]
    print("  [%s] no accumulator overflow at any width (+8 headroom holds)%s"
          % ("PASS" if not ovf else "FAIL",
             "" if not ovf else "  overflows at %s" % ovf))
    fails += bool(ovf)

    # 18. specials cannot pass through fixed point, so they ride beside it
    one = one_byte(FMT_BF8)
    cases = [(0x7C, one, POS_INF, "Inf x 1 -> Inf"),
             (0x7C, 0x00, QNAN, "Inf x 0 -> NaN"),
             (0x7D, one, QNAN, "NaN propagates"),
             (0x7C, 0x80 | one, NEG_INF, "Inf x -1 -> -Inf")]
    bad = []
    for xb, yb, want, why in cases:
        Ax = [[xb] * KLOG for _ in range(ROWS)]
        Bx = [[yb] * DWORDS for _ in range(KLOG)]
        r = tdp_fp8_fx(zero_c(), pack_a(Ax), pack_b(Bx), OP_TDPBF8PS, 52)
        if any(v != want for row in r for v in row):
            bad.append("%s: got %08x" % (why, r[0][0]))
    # and +Inf together with -Inf must be NaN, not either infinity
    Ax = [[0x7C] * KLOG for _ in range(ROWS)]
    Bx = [[one if K % 2 else (0x80 | one) for _ in range(DWORDS)]
          for K in range(KLOG)]
    r = tdp_fp8_fx(zero_c(), pack_a(Ax), pack_b(Bx), OP_TDPBF8PS, 52)
    if any(not is_nan(v) for row in r for v in row):
        bad.append("(+Inf)+(-Inf) should be NaN")
    print("  [%s] ACC=1 specials override the accumulator%s"
          % ("PASS" if not bad else "FAIL",
             "" if not bad else "  " + "; ".join(bad)))
    fails += bool(bad)

    print("\nRESULT: %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
