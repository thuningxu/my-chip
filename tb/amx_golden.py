#!/usr/bin/env python3
"""
Independent reference model for amx_tdpbssd -- Intel AMX TDPBSSD.

Two jobs, and they are deliberately separate models:

  tdpbssd()    a direct transcription of the Intel ISA pseudocode, working on
               PHYSICAL tiles (16 rows x 64 bytes). This is the conformance
               model.
  matmul_ref() a textbook triple loop on LOGICAL matrices. This is the sanity
               model, and it is what catches a wrong VNNI interleave -- the
               pseudocode model would happily agree with a transposed unpack,
               because it never names a logical matrix at all.

Keep them independent. Do not make one call the other, and do not make the
Verilog testbench call either: three models that agree are evidence, two models
where one is derived from the other are one model.

    python3 tb/amx_golden.py            # self-test, layout + both SAT modes
    python3 tb/amx_golden.py --seed 7

------------------------------------------------------------------ THE LAYOUT
The physical tile shape is NOT the logical shape, and this is the whole trap.
All three tmm registers are 16 rows x 64 bytes. "B is 64x16" is a statement
about the LOGICAL matrix; the pseudocode indexes tsrc2.row[k] with k in 0..15,
so B is VNNI-INTERLEAVED into the same 16x64 register as A:

    tmm0  A  A_phys[m].byte[4k+b] = A[m][4k+b]     plain row-major, 16 x 64 INT8
    tmm1  B  B_phys[k].byte[4n+b] = B[4k+b][n]     INTERLEAVED,     64 x 16 INT8
    tmm2  C  C_phys[m].dword[n]   = C[m][n]        row-major,       16 x 16 INT32

With K = 4k+b that is C[m][n] += sum_{K=0}^{63} A[m][K]*B[K][n], i.e.
(16,64) @ (64,16) -> (16,16). A wrong interleave still produces plausible
numbers, so it is the primary thing the tests exist to catch.

--------------------------------------------------------------- ON SATURATION
Intel's DPBD is plain modular INT32: "c := c + p0+p1+p2+p3", no clamp. SAT=1
here is a DELIBERATE DEVIATION, so both modes are modelled and both are built.

Saturating adds are NOT associative, so WHERE the clamp goes is part of the
specification, not an implementation detail. It goes once per k-step, which is
exactly Intel's DPBD call boundary. Consequence worth stating: for a fixed
(m,n) the k sequence is 0,1,..,15 in BOTH the ISA's loop nest (m outer, k
middle) and in the hardware's (k outer, m/n parallel), because m and n index
independent accumulators. So the two orders agree bit-for-bit in both SAT
modes -- which is the only reason a k-outer machine may claim conformance to an
m-outer specification.

Also note: one TDPBSSD starting from C=0 reaches at most 64*16384 = 1,048,576,
which is 21 bits. A SINGLE INSTRUCTION CANNOT OVERFLOW INT32. Saturation only
ever matters for the C += chain across instructions, so a test that wants to
exercise it has to preload C near the limits.
"""
import argparse
import random

INT8_MIN, INT8_MAX = -128, 127
INT32_MIN, INT32_MAX = -(1 << 31), (1 << 31) - 1

ROWS = 16      # tile rows            (tmm rows)
COLSB = 64     # tile row bytes       (tmm colsb)
DWORDS = COLSB // 4   # 16 dwords per row
KDW = COLSB // 4      # 16 k-steps, each covering 4 logical K
KLOG = COLSB          # 64 logical K values


def wrap32(x: int) -> int:
    """Two's-complement INT32 wraparound -- Intel's actual behaviour."""
    return ((x + (1 << 31)) & ((1 << 32) - 1)) - (1 << 31)


def clamp32(x: int) -> int:
    """Saturate to INT32 -- the requested deviation."""
    return INT32_MAX if x > INT32_MAX else INT32_MIN if x < INT32_MIN else x


# ----------------------------------------------------------------- packing
def pack_a(A):
    """Logical A (ROWS x KLOG INT8) -> physical tmm0 (ROWS x COLSB bytes).

    Plain row-major: byte 4k+b of physical row m is A[m][4k+b]. So this is the
    identity on the byte grid, and is written out longhand anyway so the
    asymmetry with pack_b is visible rather than implied.
    """
    return [[A[m][4 * k + b] for k in range(KDW) for b in range(4)]
            for m in range(ROWS)]


def pack_b(B):
    """Logical B (KLOG x ROWS INT8) -> physical tmm1 (ROWS x COLSB bytes), VNNI.

    B_phys[k].byte[4n+b] = B[4k+b][n].  Four CONSECUTIVE logical rows of B
    (4k..4k+3) are interleaved into one physical row, so that byte b of dword n
    lines up with byte b of A's dword k.
    """
    out = [[0] * COLSB for _ in range(KDW)]
    for k in range(KDW):
        for n in range(DWORDS):
            for b in range(4):
                out[k][4 * n + b] = B[4 * k + b][n]
    return out


def unpack_b(B_phys):
    """Inverse of pack_b. Exists so the tests can prove the round trip."""
    B = [[0] * DWORDS for _ in range(KLOG)]
    for k in range(KDW):
        for n in range(DWORDS):
            for b in range(4):
                B[4 * k + b][n] = B_phys[k][4 * n + b]
    return B


def unpack_a(A_phys):
    """Inverse of pack_a."""
    return [list(row) for row in A_phys]


# ------------------------------------------------- model 1: the ISA pseudocode
def tdpbssd(C_phys, A_phys, B_phys, sat=False):
    """Intel TDPBSSD, transcribed. Operates on PHYSICAL tiles; returns a new C.

    C_phys : ROWS x DWORDS  INT32   (tsrcdest, tmm2)
    A_phys : ROWS x COLSB   INT8    (tsrc1,    tmm0)
    B_phys : KDW  x COLSB   INT8    (tsrc2,    tmm1)

    Mirrors the reference exactly:
        for m: tmp = C.row[m]
               for k: for n: DPBD(tmp.dword[n], A.row[m].dword[k], B.row[k].dword[n])
               C.row[m] = tmp
        DPBD(c,x,y): c += sum_b sext32(x.byte[b]) * sext32(y.byte[b])
    """
    fold = clamp32 if sat else wrap32
    out = [list(row) for row in C_phys]
    for m in range(ROWS):
        tmp = list(out[m])
        for k in range(KDW):
            for n in range(DWORDS):
                acc = 0
                for b in range(4):
                    acc += A_phys[m][4 * k + b] * B_phys[k][4 * n + b]
                # The clamp/wrap lands HERE -- one fold per DPBD call, which is
                # one k-step. Not after a tree over all k; see module docstring.
                tmp[n] = fold(tmp[n] + acc)
        out[m] = tmp
    return out


# --------------------------------------------- model 2: textbook, independent
def matmul_ref(A, B, C=None, sat=False):
    """D[m][n] = C[m][n] + sum_K A[m][K]*B[K][n], on LOGICAL matrices.

    Deliberately knows nothing about tiles, dwords or interleaving. The k-step
    fold boundary is reproduced (a fold every 4 K) so that the SAT=1 comparison
    against tdpbssd() is apples to apples -- with sat=False the grouping is
    irrelevant, since wrapping addition is associative.
    """
    fold = clamp32 if sat else wrap32
    n_rows, n_cols = len(A), len(B[0])
    out = [[0] * n_cols for _ in range(n_rows)]
    for m in range(n_rows):
        for n in range(n_cols):
            acc = 0 if C is None else C[m][n]
            for k in range(len(B) // 4):
                grp = sum(A[m][4 * k + b] * B[4 * k + b][n] for b in range(4))
                acc = fold(acc + grp)
            out[m][n] = acc
    return out


# ----------------------------------------------------------------- generators
def rand_a(rng):
    return [[rng.randint(INT8_MIN, INT8_MAX) for _ in range(KLOG)]
            for _ in range(ROWS)]


def rand_b(rng):
    return [[rng.randint(INT8_MIN, INT8_MAX) for _ in range(DWORDS)]
            for _ in range(KLOG)]


def zero_c():
    return [[0] * DWORDS for _ in range(ROWS)]


def asym_a():
    """Asymmetric on purpose: a symmetric tile hides a lost or doubled
    interleave completely, which is the same lesson as mac_array's M1/M2."""
    return [[((m * KLOG + K) * 5 + 3) % 256 - 128 for K in range(KLOG)]
            for m in range(ROWS)]


def asym_b():
    return [[((n * KLOG + K) * 7 + 1) % 256 - 128 for n in range(DWORDS)]
            for K in range(KLOG)]


def accumulator_bound(k_logical=KLOG, instructions=1):
    """Worst-case |accumulator| for INT8 x INT8 over k_logical terms.

    max |product| = |-128 * -128| = 16384. Run this before changing widths.
    `instructions` is the C += chain depth: the bound scales with it, which is
    the only way INT32 can ever be exceeded.
    """
    return 16384 * k_logical * instructions


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--trials", type=int, default=8)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    fails = 0

    print(f"# TDPBSSD reference self-test  (seed={args.seed}, "
          f"trials={args.trials})")
    print(f"# tiles: A {ROWS}x{KLOG} INT8, B {KLOG}x{DWORDS} INT8, "
          f"C {ROWS}x{DWORDS} INT32   ({ROWS*DWORDS*KLOG:,} MACs)")

    b = accumulator_bound()
    print(f"# one instruction from C=0: max |acc| = {b:,} "
          f"<= INT32_MAX {INT32_MAX:,} -> cannot overflow "
          f"({INT32_MAX // b}x margin)")

    # 1. packing round-trips
    for name, A, B in [("random", rand_a(rng), rand_b(rng)),
                       ("asymmetric", asym_a(), asym_b())]:
        ok = unpack_a(pack_a(A)) == A and unpack_b(pack_b(B)) == B
        print(f"  [{'PASS' if ok else 'FAIL'}] pack/unpack round-trip, {name}")
        fails += not ok

    # 2. the two models must agree, both SAT modes, C=0
    for sat in (False, True):
        bad = 0
        for _ in range(args.trials):
            A, B = rand_a(rng), rand_b(rng)
            isa = tdpbssd(zero_c(), pack_a(A), pack_b(B), sat)
            ref = matmul_ref(A, B, None, sat)
            bad += isa != ref
        ok = bad == 0
        print(f"  [{'PASS' if ok else 'FAIL'}] ISA pseudocode == textbook "
              f"matmul, SAT={int(sat)}, {args.trials} random tiles")
        fails += not ok

    # 3. with C=0 and one instruction, saturation must be a no-op
    A, B = rand_a(rng), rand_b(rng)
    w = tdpbssd(zero_c(), pack_a(A), pack_b(B), False)
    s = tdpbssd(zero_c(), pack_a(A), pack_b(B), True)
    ok = w == s
    print(f"  [{'PASS' if ok else 'FAIL'}] SAT=0 == SAT=1 when no overflow "
          f"is possible")
    fails += not ok

    # 4. and near the rails it must NOT be
    hi = [[INT32_MAX - 5] * DWORDS for _ in range(ROWS)]
    lo = [[INT32_MIN + 5] * DWORDS for _ in range(ROWS)]
    ones = [[1] * KLOG for _ in range(ROWS)]
    pos = [[1] * DWORDS for _ in range(KLOG)]
    neg = [[-1] * DWORDS for _ in range(KLOG)]
    for tag, Cpre, Bx, want in [("high rail, +", hi, pos, INT32_MAX),
                                ("low rail,  -", lo, neg, INT32_MIN)]:
        sa = tdpbssd(Cpre, pack_a(ones), pack_b(Bx), True)
        wr = tdpbssd(Cpre, pack_a(ones), pack_b(Bx), False)
        clamped = all(v == want for row in sa for v in row)
        wrapped = any(v != want for row in wr for v in row)
        ok = clamped and wrapped
        print(f"  [{'PASS' if ok else 'FAIL'}] {tag} SAT=1 clamps to "
              f"{want}, SAT=0 wraps instead")
        fails += not ok

    # 5. the interleave has teeth: a wrong pack must change the answer
    A, B = asym_a(), asym_b()
    good = tdpbssd(zero_c(), pack_a(A), pack_b(B), False)
    bad_phys = [[0] * COLSB for _ in range(KDW)]
    for k in range(KDW):
        for n in range(DWORDS):
            for bb in range(4):
                bad_phys[k][4 * n + bb] = B[4 * bb + k][n]   # 4b+k, not 4k+b
    ok = tdpbssd(zero_c(), pack_a(A), bad_phys, False) != good
    print(f"  [{'PASS' if ok else 'FAIL'}] a 4b+k interleave is DETECTED "
          f"(asymmetric tiles)")
    fails += not ok

    print(f"\nRESULT: {'PASS' if fails == 0 else f'FAIL ({fails})'}")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
