#!/usr/bin/env python3
"""Reference models for tpu_mmu -- a TPU v1-style weight-stationary systolic array.

Computes C += A @ W, all N x N, INT8 x INT8 -> INT32 accumulate, wrapping.

TWO INDEPENDENT MODELS, and the independence is the whole point. From
tb/amx_golden.py: three models that agree are evidence, two models where one is
derived from the other are one model. So:

  matmul_ref()   textbook triple loop. Knows nothing about systole, skew, or
                 time. This is what catches a schedule that is self-consistently
                 wrong -- an array that computes A.T @ W perfectly happily.

  systolic()     cycle-accurate simulation of the actual hardware: a grid of PEs,
                 each holding one weight, passing activations right and partial
                 sums down, one register hop per cycle. This is what catches a
                 wrong delay bank, and it is the model the Verilog must match
                 cycle for cycle.

WHY THE CYCLE-ACCURATE MODEL EXISTS AT ALL. The output placement is an arithmetic
claim, and getting it off by one silently shifts or transposes the result. Rather
than trust the algebra, systolic() threads the row index m through the array
alongside every partial sum and ASSERTS that every contribution landing in one
accumulator came from the same m. That turns the schedule from a derivation into a
checked property, and it earned its place immediately: the hand algebra below is
off by one against the register-level behaviour.

THE DERIVATION (checked by verify_schedule, not assumed):

    a[m][i] enters row i at        t = m + i        input skew, by ROW
    a[m][i] reaches PE(i,j) at     t = m + i + j
    psum for C[m][j] is at row i   t = start_j + i
      => start_j + i = m + i + j  =>  start_j = m + j
    C[m][j] is COMPUTED during     t = m + j + N - 1
    C[m][j] is VISIBLE in p_reg    t = m + j + N        (one cycle later)

MIND THE SAMPLING POINT -- this is the off-by-one, and it is not a mistake in
either place:

    this model emits right after the state update, so it reads the NEW p_reg and
    places it at            m = t - j - (N-1)

    the RTL reads p_reg as a REGISTER during cycle ccnt, so it sees the value
    computed during ccnt-1 and must fire at   ccnt = m + j + N

The two differ by exactly one because they sample one cycle apart. Both are in the
code; neither is the other's typo.

The input side needs real delay registers: row i must be held back i cycles. The
output side needs none -- m is a closed form in t and j, and since both are
elaboration constants per accumulator in the RTL, it reduces to one constant
compare. De-skew registers would be the naive reading; TPU v1 addresses its
accumulator memory the same way.

PSUM WIDTH IS EXACT, NOT PADDED. Products lie in [-16256, +16384] because
-128 * -128 = +16384 is the largest and -128 * 127 = -16256 the smallest. N of
them reach N * 16384, so 16 + ceil(log2 N) bits of signed range always holds the
column sum:

    N=32   32 * 16384 =   524,288   21-bit signed holds +/-1,048,576   fits
    N=256 256 * 16384 = 4,194,304   24-bit signed holds +/-8,388,608   fits

The external accumulator is 32-bit and wraps, matching TPU v1 and plain matmul.
"""

import argparse
import random

INT8_MIN, INT8_MAX = -128, 127
INT32_MIN, INT32_MAX = -(2 ** 31), 2 ** 31 - 1


def wrap32(x):
    """Two's-complement INT32 wrap. TPU v1 and textbook matmul both wrap."""
    return ((x + 2 ** 31) % 2 ** 32) - 2 ** 31


def psum_width(n):
    """Exact bits needed for a column sum of n INT8 products. See module docstring."""
    return 16 + (n - 1).bit_length()


def psum_fits(n):
    """Prove the width claim rather than asserting it."""
    w = psum_width(n)
    lo, hi = -(2 ** (w - 1)), 2 ** (w - 1) - 1
    return n * (-128 * 127) >= lo and n * (-128 * -128) <= hi


# ---------------------------------------------------------------- model 1
def matmul_ref(a, w, c=None):
    """C += A @ W. Textbook. No notion of time, skew, or hardware."""
    n = len(a)
    out = [[0] * n for _ in range(n)] if c is None else [row[:] for row in c]
    for m in range(n):
        for j in range(n):
            acc = out[m][j]
            for i in range(n):
                acc += a[m][i] * w[i][j]
            out[m][j] = wrap32(acc)
    return out


# ---------------------------------------------------------------- model 2
def feed(a, i, t):
    """Activation entering row i at cycle t: A[t-i][i], or 0 outside the window.

    This IS the input skew -- row i is held back i cycles. In hardware it is a
    triangular bank of byte-wide shift registers, sum(i) = N(N-1)/2 deep.
    """
    n = len(a)
    m = t - i
    return a[m][i] if 0 <= m < n else 0


def systolic(a, w, c=None, cycles=None, tag_check=True):
    """Cycle-accurate weight-stationary systolic array.

    Returns (acc, emitted, last_cycle) where `emitted` is the raw bottom-edge
    stream as (t, j, psum, m_tag) so a caller can check placement independently.

    Every PE holds w[i][j] and, each cycle, registers BOTH the activation arriving
    from its left and the partial sum arriving from above plus its own product. So
    an activation advances one column per cycle and a partial sum advances one row
    per cycle -- that is what makes it systolic, and why no signal here fans out
    beyond a neighbour.
    """
    n = len(a)
    if cycles is None:
        # 3N-2 is the derived last-output cycle; +2 of slack so an off-by-one in
        # the derivation shows up as a MISSING output rather than a truncated run.
        cycles = 3 * n + 2

    acc = [[0] * n for _ in range(n)] if c is None else [row[:] for row in c]

    # PE state. a_reg passes right, p_reg passes down. m_reg is a simulation-only
    # provenance tag: which output row the partial sum in p_reg belongs to.
    a_reg = [[0] * n for _ in range(n)]
    p_reg = [[0] * n for _ in range(n)]
    m_reg = [[None] * n for _ in range(n)]

    emitted = []
    last_cycle = None

    for t in range(cycles):
        a_nxt = [[0] * n for _ in range(n)]
        p_nxt = [[0] * n for _ in range(n)]
        m_nxt = [[None] * n for _ in range(n)]

        for i in range(n):
            for j in range(n):
                a_in = feed(a, i, t) if j == 0 else a_reg[i][j - 1]
                p_in = 0 if i == 0 else p_reg[i - 1][j]
                # Provenance: row 0 starts a fresh sum, so the tag is whichever
                # output row the arriving activation belongs to. Deeper rows
                # inherit the tag flowing down and must AGREE with their own
                # arriving activation -- that agreement is the schedule proof.
                m_here = t - i - j        # from a[m][i] reaching PE(i,j) at m+i+j
                m_in = m_here if i == 0 else m_reg[i - 1][j]
                if tag_check and 0 <= m_here < n and m_in is not None:
                    assert m_in == m_here, (
                        "schedule broken at PE(%d,%d) t=%d: sum tagged m=%s met "
                        "activation for m=%d" % (i, j, t, m_in, m_here))
                a_nxt[i][j] = a_in
                p_nxt[i][j] = p_in + a_in * w[i][j]
                m_nxt[i][j] = m_in

        a_reg, p_reg, m_reg = a_nxt, p_nxt, m_nxt

        # Bottom edge. p_reg[N-1][j] now holds a COMPLETE column sum (it has been
        # through all N rows). Its output row is m = t - j - (N-1), because the
        # activation that started it entered at m and took (N-1) row hops plus j
        # column hops to get here. Written as t-j-N+1 to match the RTL's counter.
        for j in range(n):
            m = t - j - (n - 1)
            if 0 <= m < n:
                acc[m][j] = wrap32(acc[m][j] + p_reg[n - 1][j])
                emitted.append((t, j, p_reg[n - 1][j], m_reg[n - 1][j]))
                last_cycle = t

    return acc, emitted, last_cycle


def verify_schedule(n):
    """Confirm the closed form the RTL implements matches the tagged simulation.

    The RTL cannot carry provenance tags -- it has to compute the accumulator row
    from a counter. This checks that computing it (rather than tracking it) gives
    the same answer for every emitted value.
    """
    rng = random.Random(12345)
    a = [[rng.randint(INT8_MIN, INT8_MAX) for _ in range(n)] for _ in range(n)]
    w = [[rng.randint(INT8_MIN, INT8_MAX) for _ in range(n)] for _ in range(n)]
    _, emitted, last = systolic(a, w)
    bad = [(t, j, m_tag) for (t, j, _p, m_tag) in emitted
           if m_tag != t - j - (n - 1)]
    return len(emitted) == n * n, bad, last


# ---------------------------------------------------------------- generators
def rand_tile(rng, n):
    return [[rng.randint(INT8_MIN, INT8_MAX) for _ in range(n)] for _ in range(n)]


def zero_c(n):
    return [[0] * n for _ in range(n)]


def asym_a(n):
    """A that is neither symmetric nor commutative with asym_w.

    Without an asymmetric pair, a transposed array passes every value check --
    exactly the trap the amx A/B naming defect fell into.
    """
    return [[((m * 7 + i * 3 + 1) % 251) - 125 for i in range(n)] for m in range(n)]


def asym_w(n):
    return [[((i * 5 + j * 11 + 2) % 251) - 125 for j in range(n)] for i in range(n)]


def identity_w(n):
    return [[1 if i == j else 0 for j in range(n)] for i in range(n)]


def extreme_tile(n, val):
    return [[val] * n for _ in range(n)]


# ---------------------------------------------------------------- self-test
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--trials", type=int, default=4)
    ap.add_argument("--sizes", type=int, nargs="+", default=[2, 4, 8, 16, 32])
    # tb/tb_tpu_mmu.v hardcodes a few of these values as the cross-language tie
    # between the Verilog textbook model and this cycle-accurate one. The flag
    # exists so that tie is reproducible rather than a number someone typed once.
    ap.add_argument("--print-asym", type=int, metavar="N",
                    help="print C = asym_a(N) @ asym_w(N) corner values and exit")
    args = ap.parse_args()

    if args.print_asym:
        n = args.print_asym
        a, w = asym_a(n), asym_w(n)
        sysres, _, _ = systolic(a, w)
        if sysres != matmul_ref(a, w):
            print("MODELS DISAGREE at N=%d -- do not use these values" % n)
            return 1
        print("N=%d  C[0][0]=%d  C[0][1]=%d  C[1][0]=%d  C[%d][%d]=%d"
              % (n, sysres[0][0], sysres[0][1], sysres[1][0],
                 n - 1, n - 1, sysres[n - 1][n - 1]))
        return 0
    rng = random.Random(args.seed)
    fails = 0

    print("tpu_mmu reference models -- sizes %s, seed %d"
          % (args.sizes, args.seed))
    for n in args.sizes:
        print("  N=%-4d psum width %2d bits, column sum max %s"
              % (n, psum_width(n), format(n * 16384, ",")))
    print()

    # 1. the width claim
    bad = [n for n in args.sizes + [64, 128, 256] if not psum_fits(n)]
    print("  [%s] psum width 16+clog2(N) holds every column sum%s"
          % ("PASS" if not bad else "FAIL", "" if not bad else "  fails at %s" % bad))
    fails += bool(bad)

    # 2. THE SCHEDULE. Every emitted value's tracked provenance must equal the
    #    closed form m = t - j - (N-1), and exactly N*N values must come out.
    for n in args.sizes:
        complete, bad, last = verify_schedule(n)
        ok = complete and not bad
        exp_last = 3 * n - 3        # derived: last output at t = 3N-3 (0-indexed)
        note = ""
        if not complete:
            note = "  wrong count"
        elif bad:
            note = "  %d misplaced, first %s" % (len(bad), bad[0])
        elif last != exp_last:
            note = "  last output t=%s, derived %s" % (last, exp_last)
            ok = False
        print("  [%s] N=%-3d schedule: closed form matches tagged simulation%s"
              % ("PASS" if ok else "FAIL", n, note))
        fails += not ok

    # 3. the two models must agree
    for n in args.sizes:
        bad_n = 0
        for _ in range(args.trials):
            a, w = rand_tile(rng, n), rand_tile(rng, n)
            c = rand_tile(rng, n) if rng.random() < 0.5 else zero_c(n)
            got, _, _ = systolic(a, w, c)
            if got != matmul_ref(a, w, c):
                bad_n += 1
        print("  [%s] N=%-3d systolic == matmul_ref over %d random tiles%s"
              % ("PASS" if not bad_n else "FAIL", n, args.trials,
                 "" if not bad_n else "  %d mismatch" % bad_n))
        fails += bool(bad_n)

    # 4. identity and single-element -- localises a transpose
    for n in args.sizes:
        a = asym_a(n)
        ok_id = systolic(a, identity_w(n))[0] == a
        w1 = zero_c(n)
        w1[1 % n][0] = 1                      # W[1][0]=1 -> C[m][0] = A[m][1]
        exp = zero_c(n)
        for m in range(n):
            exp[m][0] = a[m][1 % n]
        ok_one = systolic(a, w1)[0] == exp
        print("  [%s] N=%-3d identity W passes A through; single W element picks "
              "the right A column" % ("PASS" if ok_id and ok_one else "FAIL", n))
        fails += not (ok_id and ok_one)

    # 5. asymmetric operands, and A@W must differ from W@A -- otherwise the test
    #    itself cannot detect a transposed array
    for n in args.sizes:
        if n < 2:
            continue
        a, w = asym_a(n), asym_w(n)
        fwd = matmul_ref(a, w)
        rev = matmul_ref(w, a)
        distinct = fwd != rev
        ok = systolic(a, w)[0] == fwd and distinct
        print("  [%s] N=%-3d asymmetric pair: A@W == ref, and A@W != W@A (test "
              "has teeth)%s" % ("PASS" if ok else "FAIL", n,
                                "" if distinct else "  A@W == W@A, USELESS TEST"))
        fails += not ok

    # 6. extremes against the exact width bound
    for n in args.sizes:
        a, w = extreme_tile(n, -128), extreme_tile(n, -128)
        got, _, _ = systolic(a, w)
        want = n * 16384
        ok = all(v == want for row in got for v in row)
        lim = 2 ** (psum_width(n) - 1) - 1
        print("  [%s] N=%-3d all -128: every C = %s, psum limit %s%s"
              % ("PASS" if ok else "FAIL", n, format(want, ","), format(lim, ","),
                 "" if ok else "  got %s" % got[0][0]))
        fails += not ok

    # 7. C += chains
    for n in args.sizes:
        a, w = asym_a(n), asym_w(n)
        c1, _, _ = systolic(a, w, zero_c(n))
        c2, _, _ = systolic(a, w, c1)
        ok = c2 == matmul_ref(a, w, matmul_ref(a, w, zero_c(n)))
        ok = ok and all(c2[m][j] == wrap32(2 * c1[m][j])
                        for m in range(n) for j in range(n))
        print("  [%s] N=%-3d two accumulations give exactly twice one"
              % ("PASS" if ok else "FAIL", n))
        fails += not ok

    # 8. NEGATIVE TEST: a deliberately wrong schedule must NOT agree. If shifting
    #    the accumulator row by one still matched, the checks above would be
    #    proving nothing about placement.
    for n in args.sizes:
        if n < 2:
            continue
        a, w = asym_a(n), asym_w(n)
        ref = matmul_ref(a, w)

        def wrong_offset(off):
            acc = zero_c(n)
            _, emitted, _ = systolic(a, w, tag_check=False)
            for (t, j, p, _m) in emitted:
                m = t - j - (n - 1) + off
                if 0 <= m < n:
                    acc[m][j] = wrap32(acc[m][j] + p)
            return acc

        caught = wrong_offset(1) != ref and wrong_offset(-1) != ref
        # and a transposed weight load must also be caught
        wt = [[w[j][i] for j in range(n)] for i in range(n)]
        caught_t = systolic(a, wt)[0] != ref
        ok = caught and caught_t
        print("  [%s] N=%-3d wrong placement (+/-1 row) and transposed W are both "
              "detected" % ("PASS" if ok else "FAIL", n))
        fails += not ok

    print("\nRESULT: %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
