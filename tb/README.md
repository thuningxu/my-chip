# tb/ — verification

Ten files, four designs, and a deliberate independence structure:

| File | Role |
|---|---|
| `tb_mac_array.v` | the `mac_array` regression. Self-checking, computes its own expected values |
| `golden.py` | a **second opinion** on `mac_array` + the accumulator-width checker |
| `tb_amx_tdpbssd.v` | the `amx_tdpbssd` (Intel `TDPBSSD`) regression — **three** models in one file |
| `amx_golden.py` | a **fourth** opinion on TDPBSSD: VNNI pack/unpack and both saturation modes |
| `tb_tpu_mmu.v` | the `tpu_mmu` systolic regression — 12 cases plus a cross-language tie |
| `tpu_golden.py` | the systolic **schedule proof** — a cycle-accurate model that threads the output row index through the array and asserts every contribution to one accumulator came from the same row |
| `tb_fp32_add.v` | the FP32 adder, **alone**: 121,376 checks. Runs *before* the array regression on purpose |
| `tb_fp8_mul.v` | the fp8 multiplier, **exhaustively**: all 4 format pairs × 256 × 256 = 262,144 cases, 262,162 checks |
| `tb_amx_fp8.v` | the `amx_fp8` array regression — **29 cases** × `RD_REG` 0/1 × `PIPE` 0/1, all four instructions. The 29th is **O1**, the only one that catches a permuted k-sequence by construction rather than by rounding luck |
| `fp8_golden.py` | **two** independent FP32 adders plus an exact rational yardstick, and the one number that quantifies what the ISA does not say |

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

## amx_fp8: verify the leaves first, then only the schedule

The FP8 design inverts the usual order, because its arithmetic is the risk. A
rounding bug in `fp32_add` would appear 1024 instances deep inside a 16-cycle
accumulation, presenting as "some matrix elements are off by an ulp" — which is
indistinguishable from a schedule bug, a lane-mapping bug, or a format-decode
bug. So the leaves are proven first and in isolation:

| gate | what it establishes |
|---|---|
| `tb_fp8_mul.v` | **the entire input space.** 4 format pairs × 256 × 256, against a model that takes a longer route (24×24 significand multiply, not the DUT's 4×4), four checksums tied to `fp8_golden.py`, every product shown to be **exact**, and `y[15:0] == 0` on all 262,144 — 262,162 checks in total |
| `tb_fp32_add.v` | RNE ties at both parities, the alignment cap, deep cancellation, DAZ, the FTZ boundary at `e=0/1/2`, the full Inf/NaN matrix, and **commutativity on every single vector** — which is what catches a broken magnitude swap |
| `tb_amx_fp8.v` | only then the array: VNNI interleave, k schedule, lane→accumulator mapping, epilogue order, cycle count, format plumbing |

`tb_fp8_mul.v`'s **`y[15:0] == 0`** assertion is there for a different file. At
`PIPE=1`, `rtl/amx_fp8.v` registers only `prod[31:16]` and re-supplies `16'b0` on
the far side, which halves that cut from 32,768 flops to 16,384. The
justification is that `fp8_mul` returns `{sgn, e_fld, nrm[6:0], 16'd0}` — a
product of two 4-bit significands has exactly 7 fraction bits — and that every
special it can return (`0x7FC00000`, Inf, signed zero) also has zero low bits.
Reading the RTL and believing that is not the same as checking it on all 262,144
inputs, so it is checked, **on the DUT's output rather than the model's**: it is
the RTL that has to have zero low bits, not a model that agrees with it. If it
ever fails, the register in `rtl/amx_fp8.v` is silently dropping product bits — a
wrong answer in the array with nothing wrong in the multiplier — and the check
names that file in its failure message for exactly that reason.

Because the leaves are proven, `tb_amx_fp8.v` uses **them** as its oracle — one
`fp8_dec` pair, one `fp8_mul`, one `fp32_add`, instantiated outside the DUT and
sequenced by tasks. That is compositional verification, not circularity: a
mismatch can then only be a schedule or layout fault, which is exactly the
localisation you want. Writing a third Verilog FP32 adder would have added a
possible bug, not a possible catch. The tie to a *fully* independent
implementation is the golden block in case T3, whose constants come from
`fp8_golden.py`.

`fp8_golden.py`'s second adder is worth naming, because it looks like cheating
and is not: it converts to Python floats, adds in FP64, and rounds to FP32. For a
**single** addition of two FP32 values that is provably identical to a direct FP32
RNE add, because 53 ≥ 2p+2 = 50 (innocuous double rounding). The theorem excludes
overflow and underflow, so both are refused loudly rather than returned wrong.
That model reaches the C library's adder — hardware nobody in this repo wrote.

### The one number that admits what the ISA does not say

Three sources disagree on how AMX-FP8 accumulates, and `fp8_golden.py` does not
paper over it. Intel's patent says four separate lane sums; Bochs keeps two
halves; LLVM's header shows one wide accumulator with `INT64` casts pasted from
the INT8 file. The patent reading is implemented — but the *order the four lane
sums are combined* is genuinely unspecified, so the self-test computes both
orderings and prints how far apart they are:

```
[INFO] epilogue order UNRESOLVED in the sources: balanced tree vs
       sequential differ in 118/512 elements (23.05%)
```

23% is not a rounding curiosity, it is a quarter of the output. Printing it on
every run is the difference between a documented gap and a silent assumption.

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
make sim-fp8          # amx_fp8, PIPE=0
make sim-fp8 PIPE=1   # ...and with the product registered
make sim-matrix       # ALL FOUR designs, every parameter state -- 34 configs
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

Six mutations were injected into `rtl/amx_tdpbssd.v`, and the results are worth
keeping because three of them are instructive:

| mutation | `SAT=0` | `SAT=1` | caught by |
|---|---|---|---|
| reverse B's byte pairing (`3-b`) | 4 fail | 4 fail | T3, T5, S5 |
| transpose the accumulator index | 5 fail | 5 fail | T3, T5, S5, C1 |
| read A's byte lanes unsigned | 6 fail | 7 fail | T3, T4, T5, S5 |
| `ovf = raw[32]`, dropping `^ raw[31]` | **survives** | 7 fail | S2, S4, T3, T5 |
| `acc_en` delayed one cycle too far | **survives** | 2 fail | **S6 only** |
| accumulate gated on `run`, not `acc_en` | 14 fail | 12 fail | nearly everything |

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

3. **`acc_en` one cycle late is caught by S6 and by nothing else.** It does not
   drop a `k` — it *permutes* the sequence — and INT32 addition with a clamp in it
   is not associative, so order is part of the specification. S6 was added
   because that mutation survived everything else: `sum4` is `+4` for `k=0..7`
   then `−4` for `k=8..15`, with C starting 10 below the rail, so a correct
   machine clamps partway through, walks back down, and lands on `INT32_MAX−32`;
   rotating `k` by one lands on `−28`. **No other case in the suite could see
   it.** This is the lesson `amx_fp8`'s O1 exists to reuse.

### The FP8 suite: 18 of 29 checks are blind to a permuted k

Same mutation, same lesson, one design later. `rtl/amx_fp8.v`'s `kcnt` was
rotated one step — `kcnt = ccnt[3:0] + 1`, so the order becomes `1..15,0` with no
`k` dropped or duplicated. A **pure permutation** is the only mutation that
isolates order from count, and FP32 addition is not associative, so the per-lane
k-sequence `0..15` is part of the specification:

| checks | `PIPE=0` | `PIPE=1` |
|---|---|---|
| **O1** | **256/256 elements wrong** | **256/256 wrong** |
| T3a/T3b/T3c/T3d | 31 / 25 / 47 / 24 | same |
| T4, T5 | 27, 36 | same |
| C1–C4 | 31, 21, 24, 24 | same |
| E1–E4, S1–S4, D1, D2, Z1, T1, T2 | **SURVIVE** | **SURVIVE** |
| | 18 pass, 11 fail | 18 pass, 11 fail |

Read that table the right way round. **The 18 survivors are blind by
construction, not by accident:** E1–E4 and S1–S3 give every `k` the *same*
product, so permuting equal values is undetectable rather than merely
undetected; T1 and S4 use an identity B, so exactly one `k` per lane is non-zero;
T2, D1, D2 and Z1 produce only zeros or only NaNs, and a `+0` accumulator absorbs
those in any order. The ten that do fail fail on 21 to 47 of 256 elements — 8% to
18% — by **rounding luck**, which would evaporate the next time `fill_asym`'s
stride constants moved. Only O1 fails by construction, and it fails on all 256.

O1's mechanism, per lane: `2^24` at `k=0`, then `1.0` for `k=1..15`, both
reachable in E5M2 (`4096.0 = 0x6C` squared is `2^24`; `1.0 = 0x3C` squared is
`1.0`). The ulp at `2^24` is 2, so **in order** every `1.0` vanishes — `2^24 + 1`
is an exact tie between `2^24` and `2^24+2`, and RNE takes the even significand,
which is `2^24` itself, every single time — giving `0x4B800000`. **Permuted** to
`1..15,0`, the fifteen ones sum to `15.0` first and then *survive*: `2^24 + 15`
ties between `2^24+14` (odd) and `2^24+16` (even), so RNE rounds up. `0x4B800008`.
One ulp apart per lane, and the balanced-tree epilogue preserves the difference
exactly, so C comes back `0x4C800000` against `0x4C800008`. Nothing is hardcoded:
the expectation comes from `model_c` like every other case, because O1's
contribution is the **stimulus** and the oracle stays the single source of truth.

`PIPE=1` is what earns this case now. It makes the accumulate enable's *timing*
load-bearing — `acc_phase` becomes `v_sr` rather than `sel_valid` — which is
precisely the class of bug that S6 caught in `amx_tdpbssd` and that `amx_fp8` had
no case for. One caveat before trusting the obvious mutant here: `amx_fp8` has an
epilogue, so delaying `acc_phase` a second time at `PIPE=1` puts the 16th pulse on
`EP0`, where `ep0` has already taken operand B of lanes 0 and 2. That mutation
**drops** `k` for those lanes instead of permuting them, and it is loud — 22 of 29
checks fail, O1 reading `0x42700000` (60.0, the fifteen ones tree-summed) against
`0x4C800000`. It is the `kcnt` rotation above that proves O1 has teeth, because
that one changes order and nothing else.

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
