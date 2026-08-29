#!/usr/bin/env python3
"""
Independent reference model for mac_array.

The Verilog testbench already computes its own expected values, so this is a
SECOND opinion -- useful when a mismatch appears and you need to know which of
the two is wrong. Keep them independent: do not make one call the other.

    python3 tb/golden.py --n 4 --k 37 --seed 1

NAMING, matching rtl/mac_array.v. This module works in MEMORY coordinates:
`Amem` and `Bmem` are indexed [k][lane], one word per k, which is what
act_rdata/wgt_rdata deliver. The mathematical matrices are A and B, indexed
[row][col], and the layout the hardware requires is

    Amem[k] = column k of A   (so Amem = A-transpose)
    Bmem[k] = row    k of B   (so Bmem = B)

Hence what this file computes as `Amem-transpose @ Bmem` is the matrix product
A @ B. Only A is stored transposed, and that is forced by matmul itself: the
contraction index k is A's column index and B's row index.
"""
import argparse
import random


INT4_MIN, INT4_MAX = -8, 7


def to_int4(x: int) -> int:
    """Interpret the low 4 bits of x as a signed INT4."""
    x &= 0xF
    return x - 16 if x >= 8 else x


def outer_product_accumulate(Amem, Bmem, n, k_dim):
    """D[i][j] = sum_k Amem[k][i] * Bmem[k][j], i.e. the matrix product A @ B.

    Amem, Bmem are in MEMORY coordinates: lists of k_dim words, each word n INT4
    lanes -- exactly what act_rdata/wgt_rdata carry. Under the layout in this
    file's docstring (Amem[k] = column k of A, Bmem[k] = row k of B) this sum is
    sum_k A[i][k]*B[k][j], the textbook product. Loop order is k-outermost
    because that is what the hardware does: each k contributes a rank-1 update to
    all n*n outputs at once, rather than finishing one output at a time.

    Returns an n x n list of exact Python ints (no width limit) so that an
    overflow in the RTL shows up as a mismatch rather than being hidden.
    """
    D = [[0] * n for _ in range(n)]
    for k in range(k_dim):
        for i in range(n):
            for j in range(n):
                D[i][j] += Amem[k][i] * Bmem[k][j]
    return D


def accumulator_bound(k_max: int, tiles: int = 1, c_max: int = 0) -> int:
    """Worst-case |accumulator| for INT4 x INT4 over k_max terms.

    max |product| = |-8 * -8| = 64.  Run this before changing ACC_W.

    tiles -- chain depth for INIT_KEEP (D = A@B + D_prev). The whole point of
        chaining is that the sum SURVIVES across operations, so the bound scales
        with how many tiles you chain. A width that is safe for one tile can
        overflow on the fourth, and nothing in the RTL will tell you.
    c_max -- worst-case |C| for INIT_C. An externally supplied addend is not
        bounded by k_dim at all, so it has to be stated, not derived.
    """
    return 64 * k_max * tiles + abs(c_max)


def check_width(acc_w: int, k_max: int, tiles: int = 1, c_max: int = 0) -> bool:
    limit = (1 << (acc_w - 1)) - 1
    need = accumulator_bound(k_max, tiles, c_max)
    ok = need <= limit
    extra = ""
    if tiles != 1:
        extra += f", chained x{tiles}"
    if c_max:
        extra += f", |C|<={c_max:,}"
    print(f"ACC_W={acc_w}: need {need:,} <= {limit:,}{extra}"
          f"  -> {'OK' if ok else 'OVERFLOW'}"
          f"{'' if not ok else f' ({limit/need:.1f}x margin)'}")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=4)
    ap.add_argument("--k", type=int, default=37)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--acc-w", type=int, default=24)
    ap.add_argument("--kw", type=int, default=16)
    ap.add_argument("--tiles", type=int, default=1,
                    help="INIT_KEEP chain depth: the accumulator bound scales "
                         "with it, because chaining is the sum surviving")
    ap.add_argument("--c-max", type=int, default=0,
                    help="worst-case |C| for INIT_C; an external addend is not "
                         "bounded by k_dim")
    args = ap.parse_args()

    print(f"# width check for KW={args.kw}, ACC_W={args.acc_w}")
    check_width(args.acc_w, (1 << args.kw) - 1, args.tiles, args.c_max)

    # Random MEMORY contents -- k_dim words of n INT4 lanes, the shape the ports
    # carry. Amem[k] is column k of some A, Bmem[k] is row k of some B; which
    # A and B those are is not needed to check the arithmetic.
    rng = random.Random(args.seed)
    Amem = [[rng.randint(INT4_MIN, INT4_MAX) for _ in range(args.n)] for _ in range(args.k)]
    Bmem = [[rng.randint(INT4_MIN, INT4_MAX) for _ in range(args.n)] for _ in range(args.k)]
    D = outer_product_accumulate(Amem, Bmem, args.n, args.k)

    print(f"\n# D = Amem^T @ Bmem = A @ B  (n={args.n}, k_dim={args.k}, "
          f"seed={args.seed})")
    for i, row in enumerate(D):
        print(f"D[{i}] = {row}")

    flat = [v for row in D for v in row]
    print(f"\n# range observed: {min(flat)} .. {max(flat)}")
    print(f"# worst case at this k_dim: +/-{accumulator_bound(args.k, args.tiles, args.c_max):,}")


if __name__ == "__main__":
    main()
