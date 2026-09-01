# tb/ — verification

Six files, three designs, and a deliberate independence structure:

| File | Role |
|---|---|
| `tb_mac_array.v` | the `mac_array` regression. Self-checking, computes its own expected values |
| `golden.py` | a **second opinion** on `mac_array` + the accumulator-width checker |
| `tb_amx_tdpbssd.v` | the `amx_tdpbssd` (Intel `TDPBSSD`) regression — **three** models in one file |
| `amx_golden.py` | a **fourth** opinion on TDPBSSD: VNNI pack/unpack and both saturation modes |
| `tb_tpu_mmu.v` | the `tpu_mmu` systolic regression — 12 cases plus a cross-language tie |
| `tpu_golden.py` | the systolic **schedule proof** — a cycle-accurate model that threads the output row index through the array and asserts every contribution to one accumulator came from the same row |

`tpu_golden.py` splits its models by **kind, not language**, and the reason is the
rule stated in `amx_golden.py`: three models that agree are evidence, two models
where one is derived from the other are one model. A Verilog transliteration of the
Python systolic model would be the same model typed twice, agreeing because it
shares every assumption including a wrong one. So the Verilog testbench carries the
*textbook* model (which knows nothing about time or skew) and the Python carries the
*cycle-accurate* one, tied together by hardcoded constants in case T3.

That split paid immediately. The output placement has **three** different correct
forms depending on where you sample:

| | form |
|---|---|
| hand algebra | `m = t − j − N` |
| the Python model, which emits after the state update | `m = t − j − (N−1)` |
| the RTL, which reads `p_reg` as a register one cycle later | `ccnt == m + j + N` |

None is the others' typo. Writing the Python model *first* meant finding that in
seconds instead of while debugging Verilog.

`tb_amx_tdpbssd.v` carries three models rather than one because the AMX tile
layout has two independent ways to be wrong:

| model | reads | catches |
|---|---|---|
| the DUT | physical tiles | — |
| `model_isa` | physical tiles — the ISA pseudocode, transcribed | a wrong reading of the layout by the RTL |
| `model_matmul` | **logical** matrices — a textbook triple loop that never mentions dwords or interleaving | a wrong `pack_tiles()`, which `model_isa` cannot see |

A bug in the packing makes the DUT and `model_isa` agree with each other and both
disagree with `model_matmul`. A bug in the RTL makes the DUT disagree with
`model_isa`. Two failures, two distinct signatures — a single expected-value
model could not tell them apart, and a VNNI interleave is exactly the kind of
mistake that produces plausible numbers. `amx_golden.py` is tied in through one
fixed vector, so all four families are pinned together.

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
make sim              # mac_array, N=4
make sim N=8          # any power of two
make sim-all          # N = 4, 8, 16
make sim OUTPAR=1     # parallel readout
make sim-amx          # amx_tdpbssd, SAT=1
make sim-amx SAT=0    # ...and bit-exact Intel wrapping
make sim-matrix       # BOTH designs, every parameter state -- 14 configs
make golden           # both Python references
```

Current state: **22/22** for `mac_array` at N=4/8/16 × `C_PORT` × `OUT_PAR`
(16/16 at `C_PORT=0`, where the `INIT_C` cases are skipped rather than silently
reinterpreted), and **14/14** for `amx_tdpbssd` at both `SAT` settings.

`make sim-matrix` builds every parameter in both states on purpose: a parameter
that only ever ships in one configuration is dead code with a name.

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

### The AMX suite, mutation-tested the same way

Four mutations were injected into `rtl/amx_tdpbssd.v`, and the results are worth
keeping because two of them are instructive:

| mutation | `SAT=0` | `SAT=1` | caught by |
|---|---|---|---|
| reverse B's byte pairing (`3-b`) | 4 fail | 4 fail | T3, T5, S5 |
| transpose the accumulator index | 5 fail | 5 fail | T3, T5, S5, C1 |
| read A's byte lanes unsigned | 6 fail | 7 fail | T3, T4, T5, S5 |
| `ovf = raw[32]`, dropping `^ raw[31]` | **survives** | 7 fail | S2, S4, T3, T5 |

1. **T1, T2 and T4 all pass the byte-reversal mutant.** Uniform tiles cannot
   detect a reordering, and T4's pattern is period-2 in `b` so its four-byte sum
   is *invariant* under reversal. Only the asymmetric and random cases catch it —
   deleting `fill_asym` would quietly remove the interleave coverage entirely.
   Same shape of lesson as `mac_array`'s T4 being unable to catch unsigned INT4
   slicing, because `−8×−8` and `8×8` are bit-identical.

2. **The overflow-detect mutant surviving at `SAT=0` is correct, not a gap.** The
   fold is `((SAT != 0) && ovf) ? rail : raw[31:0]`, so at `SAT=0` `ovf` is dead
   logic that the parameter prunes. A mutation in pruned hardware has nothing to
   detect — and a suite that "caught" it would be reporting on a signal the
   netlist does not contain.

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
