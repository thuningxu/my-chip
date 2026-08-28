# tb/ — verification

Two files, with different jobs:

| File | Role |
|---|---|
| `tb_mac_array.v` | the regression. Self-checking, computes its own expected values |
| `golden.py` | a **second opinion** + the accumulator-width checker |

## Why this directory is the most important one in the repo

`scripts/measure.sh` refuses to emit a PPA number unless `tb_mac_array.v`
passes. That gate exists because of a specific, documented failure mode: a
comparable project's headline result — the design labelled "best", used as the
baseline for every later comparison — computed `2·Σ − last` instead of a dot
product. The reason nobody noticed is the part worth internalising: **the
existing testbenches all targeted an earlier module, so that design was never
simulated at all.** A regression suite only protects the RTL it actually
instantiates.

**The physical flow does not care what your logic computes.** It will happily
route, close timing, and report beautiful PPA for a design that returns garbage.
The only thing standing between you and that outcome is this directory.

## Running it

```bash
make sim              # N=4
make sim N=8          # any power of two
make sim-all          # N = 4, 8, 16
make golden           # the Python reference
```

Currently 9/9 pass at N=4, N=8, and N=16.

## The nine cases — each maps to a bug that actually shipped

| Test | Catches |
|---|---|
| **T1** all-ones, K=4 | **double-accumulation.** An enable held one cycle too long returns `2·Σ − last`. Correct answer 4; a broken design returns 5 or 7 |
| **T2** K=1 | off-by-one in the launch/consume pipeline |
| **T3** K=0 | degenerate start — must drain zeros, not hang |
| **T4** max-negative | `−8 · −8 = +64`. Catches unsigned slicing of an INT4 lane |
| **T5** adversarial K=2048 | every product at its maximum. Catches an accumulator too narrow for its stated K |
| **T6** restart, no reset | **`DONE` as a terminal state** — first operation works, every later `start` silently ignored until a hard reset |
| **T7/T8** random K=37, K=1024 | general regression against an independent triple loop |

**Do not delete any of these.** T1, T5, and T6 each correspond to a bug that
was found in production RTL, in a project whose PPA numbers had already been
published.

## The independence rule

`tb_mac_array.v` computes `expected[]` itself, with a separate triple loop over
the same memory contents:

```verilog
for (kk = 0; kk < k; kk = kk + 1)
  for (ii = 0; ii < N; ii = ii + 1)
    for (jj = 0; jj < N; jj = jj + 1)
      expected[ii*N+jj] = expected[ii*N+jj] + (av * wv);
```

It does **not** call `golden.py`, and `golden.py` does not call it. That is
deliberate: when they disagree you need two independent opinions to work out
which one is wrong. Keep them independent.

`golden.py` also returns **exact Python ints with no width limit**, so an
overflow in the RTL shows up as a mismatch instead of being silently reproduced
by a reference model that wraps the same way.

## Validate the validator

A testbench that always passes is worse than no testbench. Verify it can fail,
by injecting the bug it is most important to catch:

```bash
sed 's/else if (state == S_RUN && rd_valid)/else if (state == S_RUN \&\& (rd_valid || act_req))/' \
    rtl/mac_array.v > /tmp/bugged.v
iverilog -g2005 -o /tmp/bug.vvp tb/tb_mac_array.v /tmp/bugged.v && vvp /tmp/bug.vvp
```

Expected result — **8 of 9 fail**, with T1 showing the over-accumulation
signature:

```
[FAIL] T1 all-ones K=4 : C[0][0] got 5 expected 4
[FAIL] T4 maxneg K=3   : C[0][0] got 256 expected 192
...
=== 1 passed, 8 failed ===
RESULT: FAIL
```

T3 (K=0) correctly still passes — there is nothing to over-accumulate. That is
not a gap in coverage.

**Re-run this injection whenever you add a case or restructure the checker.**

## Adding a case

1. Fill memory with `fill_const(a, w)` or `fill_random(seed)`.
2. Call `run_case("name", k)`. It computes expected, runs the DUT, compares, and
   prints PASS/FAIL with the cycle count.
3. Re-run the fault injection above to confirm the new case can actually fail.

Cycle counts are printed because throughput matters as much as frequency — a
change that buys clock by spending cycles must show both. At N=4, K=1024 takes
1043 cycles (`1024 + N² drain + 3 pipeline`); at N=16 it is 1283.

## golden.py's other job

```bash
python3 tb/golden.py --acc-w 24 --kw 16
# ACC_W=24: need 4,194,240 <= 8,388,607  -> OK (2.0x margin)
```

Run this **before** changing `ACC_W`, `KW`, or the operand width. It is the
check whose absence let a 12-bit accumulator be documented as safe to K=64 when
it overflowed at K=32.
