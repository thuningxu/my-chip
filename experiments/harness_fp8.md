# The harness — X generations for `amx_fp8`

**Append only.** A generation is never edited after its trials run; that would
destroy the evidence about it.

Separate file from `experiments/harness.md` because that one declares its target as
`amx_tdpbssd` and is itself append-only. Same rule applies here, and it is the only
reason the two axes mean anything:

| observation | what it implicates |
|---|---|
| a single **Y** fails or regresses | the **design** — try another Y |
| an entire **X row goes flat** | the **harness** — it kept proposing fixes from the wrong family, so more Y attempts cannot help |

**X advances when Y stops moving.**

Target design: `amx_fp8` (Intel AMX-FP8, all four mix-and-match variants, 1024 fp8
multipliers). Harness: Claude Code only.

Two conventions inherited from the `amx_tdpbssd` campaign and **not** re-litigated
here:

- **`sta_limiter.sh` runs before any frequency is quoted.** A frequency without a
  limiter class is not admissible. (`harness.md`, X4.)
- **No cross-target frequency claims.** Each Y is iterated to its own fixed point
  (`ws ≈ 0`), where `1000/(P − ws)` is self-consistent, or compared only at equal
  target. (`harness.md`, X4.)

---

## X1 — "bit-exact IEEE FP32 accumulation, and measure what it costs"

**Transcribed retrospectively.** X1 was run before this file existed, so its
declaration is reconstructed from two artifacts that predate the run: the plan file's
"What I expect to find, recorded now so it cannot be retrofitted" section, and the
merge commit `f7870b0`. The prediction below is quoted from the pre-run text, not
written after the result. Every number is from the row's own metrics JSON.

### Reports read

`sta_limiter.sh` first, then the stage metrics JSON, `5_route_drc.rpt`,
`report_path.sh` for the path shape.

### Bottleneck blamed

Nothing yet — X1 is the baseline generation. Its job was to establish the
conformant design and find out what limits it.

### Fix family

None. X1 builds the ISA reading from Intel's patent EP4398097A2: four **separately
rounded** IEEE FP32 lane accumulators per output element, RNE, DAZ in / FTZ out.
Deliberately unpipelined, so the first row measures the arithmetic and not a
pipelining choice.

### Harness-level knobs

| knob | value | why |
|---|---|---|
| `PERIOD` | **4.00 ns** | Second attempt. The first used 7.00 ns, from a leaf benchmark that turned out 2.5× pessimistic, and was **aborted before completing** because it would have closed with `\|TNS\| ≈ 0` and measured the constraint rather than the design |
| `HOLD_SLACK_MARGIN` | **0.05 ns** | Carried from `harness.md` X1's finding that hold closes with margin. Not rediscovered |

### The prediction, quoted from before the run

> the limiter will be the `lacc → fp32_add → lacc` feedback loop, and no amount of
> feed-forward pipelining will move it. […] I predict this design lands materially
> **below** 698.9 MHz. If instead the limiter is an operand mux or the readback path,
> the FP32 hypothesis is untested and the row says nothing about FP-vs-INT.

### X1 result — row p1, and the prediction was HALF REFUTED

| # | config | Period | Setup WS | reg→reg fmax | Limiter | DRC | Hold WS | stdcells | flops | area µm² |
|---|---|---|---|---|---|---|---|---|---|---|
| p1 | `ACC=0 RD_REG=1` | 4.00 ns | −1.7128 | **175.0 MHz** | `reg→reg` | **0** | **+0.0448** | 3,985,240 | 57,867 | 4,758,450 |

Head-to-head against `amx_tdpbssd` x4y0 at **identical MACs (16,384), identical
cycles (20) and identical operand delivery** — the controlled comparison the
`tpu_mmu` row could not claim:

| | INT8 | FP8 | ratio |
|---|---|---|---|
| reg→reg fmax | 698.9 MHz | 175.0 MHz | **0.25×** |
| throughput | 572.5 GMAC/s | 143.4 GMAC/s | **0.25×** |
| std cells | 532,445 | 3,985,240 | **7.48×** |
| flip-flops | 47,116 | 57,867 | 1.23× |

**Confirmed:** the endpoint is a lane accumulator
(`g_m[1].g_n[13].lacc[49]$_SDFFE_PP0P_`), the limiter class is `reg→reg` so the
frequency carries no I/O-delay inflation, and four separate optimisation stages each
failed to move `TNS = −60,409` — the signature of a real wall rather than an effort
limit. Flop count predicted 57,867, actual 57,867.

**Refuted:** the path *launches from `ccnt`*, not from the accumulator, so
"no feed-forward pipelining will move it" is wrong. Routed breakdown:

| segment | delay | gates |
|---|---|---|
| operand mux + buffers | 0.864 ns | 13 |
| `fp8_mul` | 1.157 ns | 19 |
| `fp32_add` | **3.306 ns** | **77** |
| data path from Q | 5.373 ns | 113 |

**38% of the data path is feed-forward.** One pipeline register at the adder input
would remove 2.021 ns.

### What X1 established for X2

`fp32_add` is 2,270 mapped cells and 77 of the 113 gate levels, and 1024 of them are
**58% of every output element**. Its cost is entirely the leading-zero count,
normalise shifter and rounder — which exist only to renormalise *every* add.

And a second finding, measured after the row and decisive for X2: **p1's arithmetic
is not merely expensive, it is inaccurate.** Against the exact rational sum over
2000 random K=64 E5M2 dot products:

| | worst rel. error | matches exact |
|---|---|---|
| p1 as built (4-lane FP32, 64 roundings) | 2.65e-05 | 52% |
| 48-bit truncating fixed-point accumulate | **1.1e-07** | **100%** |

64 sequential roundings accumulate more error than one truncation. The only thing p1
buys is bit-reproducibility against a defined reference — and the sources do not
agree on what that reference is: Bochs uses `float32 tmp[]`, while LLVM's
`amxfp8intrin.h` structure is accumulate-wide-then-round.

---

## X2 — "the accumulate does not need to renormalise every add"

**Declared before any RTL change.** Baseline is **X2-Y0**, not p1: p1 sits at a
*missed* 4.00 ns target, and X4's rule forbids the cross-target claim.

| | |
|---|---|
| **Reports read** | `sta_limiter.sh` **first**, then `FLW-0009`, the stage metrics JSON, `5_route_drc.rpt`, `report_path.sh` for path shape. **Never a running repair table** — during X1 that mistake produced three wrong area figures and one phantom "540× setup improvement" that was actually a hold table |
| **Bottleneck blamed** | `fp32_add`. 3.306 ns of p1's 5.373 ns data path, 77 of 113 gate levels, 58% of the cells. The LZC + normalise shifter + rounder are the cost, and they exist only because the ISA reading renormalises every add |
| **Fix family** | Replace the four rounded FP32 lane accumulators with **one wide truncating fixed-point accumulator**, aligned to a per-element reference computed *before* the accumulation starts. Exposed as `ACC` (0 = p1's arithmetic, 1 = fixed-point) and `ACC_W`, so every state stays buildable and testable |
| **Period** | Each Y iterated to its own fixed point (`ws ≈ 0`). Y0 starts at 5.75 ns (p1 needs 5.7128), Y1 at 3.00 ns |
| **Hold policy** | `--hold-margin 0.05`, unchanged. Met on p1 at +0.0448 |

### The two measurements that set the design

**Range.** Exhaustive over all 4 format pairs × 256 × 256: worst case E5M2×E5M2,
products span 2⁻³² … <2³², so an **exact** accumulator for 64 of them needs **71
bits**. That is real and not a loose bound — 32 terms of `0x7B×0x7B` against 31 of
its negation plus one offset by `0x05×0x05` cancels across **59 binades**, and a
64-bit accumulator already returns the wrong FP32 answer. But 71 bits answers
"represent the sum exactly", not "produce the correctly rounded FP32 sum", and the
latter is the requirement.

**The alignment reference is worth ~14 bits of width.** The cheap reference —
`max_exp(A row m) + max_exp(B col n) + 1`, derivable from the tiles before
accumulation starts, needing no pre-scan and no shifter in the loop — overestimates
the true max term by a median of 4 binades, p90 7, worst 13. Measured accuracy with
that reference, 1500 random dot products:

| `ACC_W` | worst rel. error | matches exact | verdict |
|---|---|---|---|
| 34 | 0.00297 | 46% | **worse than p1.** DeepSeek's "at least 34-bit" recommendation assumes an *ideal* reference |
| 40 | 2.78e-05 | 96% | parity with p1 |
| **48** | **1.1e-07** | **100%** | ~1 ULP. **Y1's width** |
| 56 | 0 | 100% | exact, and wasteful |

### What X2 CANNOT reach — declared now so a plateau is interpretable

X2 touches **nothing** in the feed-forward front end. p1's routed path is
`ccnt → operand mux (0.864) → fp8_mul (1.157) → fp32_add (3.306) → lacc`, and X2
shortens only the last segment.

**So X2's floor is ~2.02 ns plus whatever the new accumulate costs** — around
2.2–2.5 ns, roughly 400–450 MHz.

**Prediction:** X2 plateaus with the limiter **moved off the adder and onto the
operand mux or the multiplier**. If that happens, X3 must be a pipelining generation
— the `PIPE` register argued against during X1, which p1's own path breakdown has
already retrospectively justified. If instead the limiter stays on the accumulate
after `ACC=1`, the fixed-point path is not as short as claimed and X2's premise is
refuted.

X2 also **cannot** make the row ISA-bit-exact. That is the experiment, not an
oversight: `ACC=1` is a deliberate deviation in the same spirit as `SAT=1` in
`amx_tdpbssd`, and every row must carry it. It is *more accurate* than `ACC=0`, not
equal.

Nor can it touch wire delay. The die will still be large and buffering will still
dominate the instance count.

### The one thing every Y must not break

**`ACC=0` must stay bit-identical to p1.** The four golden cross-check constants in
`tb_amx_fp8.v` and the 42-mutation suite are the guard. If any `ACC=0` golden
constant moves, the parameterisation has corrupted the conformant path and the Y is
**void regardless of what its PPA says**.

### Y ladder

| Y | config | change | why |
|---|---|---|---|
| **Y0** | `ACC=0` @ ~5.75 ns | **no datapath change** — only the parameter is added | Mandatory, and not a comparison against p1. p1's target was missed, so it is not an admissible baseline. Y0 is the honest fixed point that Y1 is measured against |
| **Y1** | `ACC=1 ACC_W=48` @ ~3.00 ns | the fixed-point accumulate | The measured accuracy sweet spot |

Y2 (a second `ACC_W`) is deliberately **not** declared. It depends on whether Y1
confirms the premise — X advances when Y stops moving, and pre-declaring a width
sweep would prejudge that.

### Predicted flop count, to be checked rather than admired

`ACC=1 ACC_W=48`: tiles 24,576 + accumulators 256×48 = 12,288 + `maxmag` 224 +
specials 768 + `rd_data` 512 + control ≈ **38,379**, against `ACC=0`'s 57,867.
`trial.sh`'s `EXPECT_FF` checks it. During the `amx_tdpbssd` campaign an unchecked
flop count let a trial run for 17 minutes as a duplicate of its own baseline.

### CORRECTION to X2's width, appended before any trial ran

The `ACC_W` table above was measured with an **unbounded** Python accumulator, so it
modelled only low-end truncation. Real hardware also needs top-end carry headroom:
`max|product| ≤ 1.76 × 2^ref`, and 64 of them reach `2^(ref+6.8)`, so a two's
complement accumulator's top bit must sit at `2^(ref+7)`. That makes the LSB
`LOW = ref + 8 − ACC_W`, giving **`ACC_W − 8` bits below the reference** where the
first sweep assumed `ACC_W − 2`.

Re-measured with the true hardware model, 1500 random dot products, and an explicit
overflow check on every accumulation:

| `ACC_W` | worst rel. error | p99 | matches exact | overflows |
|---|---|---|---|---|
| 40 | 5.77e-04 | 1.27e-05 | 45% | 0 |
| 44 | 2.75e-05 | 6.57e-07 | 87% | 0 |
| 48 | 9.0e-07 | 7.8e-08 | 98% | 0 |
| **52** | **8.56e-08** | **0** | **100%** | **0** |
| 56 | 0 | 0 | 100% | 0 |

**Y1's width becomes `ACC_W = 52`**, not 48. 44 is p1 parity; 48 is 29× better than
p1 but not exact; 52 is ~1 ULP worst case and matches the exact rational sum on 100%
of trials. The accumulator is only `256 × ACC_W` flops, so 52 versus 48 costs ~1,000
flops out of ~39,000 — not worth trading accuracy for.

Zero overflows at every width confirms the `+8` headroom derivation empirically
rather than by algebra alone.

Revised flop prediction for **Y1** (`ACC=1 ACC_W=52`): tiles 24,576 + accumulators
256×52 = 13,312 + `maxmag` 224 + specials 768 + `rd_data` 512 + control ≈ **39,403**.

*This correction is appended rather than edited in because the original number is
evidence about the reasoning. It was caught because declaring the generation first
forced the width to be written down and therefore checked — before any RTL existed
and before a route was spent on it.*
