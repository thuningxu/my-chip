# The harness — X generations

**Append only.** A generation is never edited after its trials run; that would
destroy the evidence about it.

This is the *outer* loop. The inner loop writes RTL and reads back frequency, area
and DRC. This loop changes **how the design is reasoned about**: which reports get
read, which bottleneck gets blamed, which family of fix gets proposed. Each such
change is a new generation.

## The rule that makes this worth doing

| observation | what it implicates |
|---|---|
| a single **Y** fails or regresses | the **design** — try another Y |
| an entire **X row goes flat** | the **harness** — it kept proposing fixes from the wrong family, so more Y attempts cannot help |

**X advances when Y stops moving.** A flat row is evidence about the reasoning, not
about the RTL.

Because of that rule, a generation is only useful if it is written down *before* its
trials run and specific enough to be wrong. "Make it faster" is not a generation.
Each X below therefore declares what it reads, what it blames, what it proposes,
and — importantly — **what it cannot reach**, so that a plateau is interpretable
rather than merely disappointing.

Target designs, in order: **X1–X4** climbed `amx_tdpbssd` (Intel AMX `TDPBSSD`,
INT8, 1024 multipliers) and closed at X4. **X5 onward** targets `amx_fp8` (Intel
AMX-FP8, fp8 in, IEEE FP32 accumulate, 1024 multipliers and 1024 FP32 adders). The
target is named again in each generation, because a generation that does not say
what it is climbing cannot be checked against the row it produced.

Harness: Claude Code only. One agent runs both loops.

`scripts/trials.py` keeps the two designs' grids and ladders apart. A delta between
two designs is a number with no referent — an `amx_fp8` `PIPE=1` row ranked against
an `amx_tdpbssd` `PIPE=1` row shares a knob name and nothing else — and the X axis
does not save you, since nothing stops two designs reusing an X number.

---

## X1 — "the whole datapath is one combinational path; pipeline it"

Declared before any RTL change. Baseline is row **a1**: setup −1.8171 ns at a
1.00 ns target (needs 2.817 ns → 355 MHz), hold **violated** at −0.0349 ns,
519,820 stdcells, DRC clean.

### Reports read

| report | for |
|---|---|
| `[INFO FLW-0009]` in the stage log | **the slack.** Not an optimizer's progress table — reading `repair_timing`'s per-iteration `WNS` on a1 produced two wrong answers in a row, because that column tracks the endpoint batch being repaired, not the design's worst path. Cross-validated: for `mac_array` f2b, FLW-0009 said −0.259 and the routed value was −0.2581 |
| `6_report.json` | every PPA figure. Never transcribed from a summary line |
| `report_path.sh` | the *shape* of the worst path — startpoint, endpoint, cell classes |
| `5_route_drc.rpt` | DRC. Empty file or the trial does not count |

### Bottleneck blamed

Everything from `kcnt` to `cacc` is **one combinational path**:

```
kcnt → 16:1 operand select → 8×8 multiply → 3-level adder tree → 33-bit add → saturating fold
```

Measured on a1: startpoint `kcnt[1]`, endpoint `cacc[98][2]`, arrival **3.316 ns**,
45 cells of which 9 are adders and **14 are buffers**.

### Fix family

**Pipeline the feed-forward chain.** Spend latency cycles to buy clock. Expressed
as a parameter `PIPE`, so every depth stays buildable and testable.

### Harness-level knobs, held constant across all Y in X1

| knob | value | why |
|---|---|---|
| `PERIOD` | **2.80 ns** | Set from a1's *measured* need of 2.817 ns, not guessed. At 1.00 ns the optimizer thrashed 9,429 endpoints and spent 127,028 buffers without closing; a target near the real limit lets it converge and makes slack readable |
| `HOLD_SLACK_MARGIN` | **0.05 ns** | Hold went 1129 → 34 endpoints under the default margin of 0, so this is plausibly repair *effort*, not a design flaw. Giving `repair_timing` headroom tests that. **If hold is still violated with margin, that is an X-level finding** — it means hold is structural and belongs to a later generation |

### What X1 CANNOT reach — declared now so a plateau is interpretable

The accumulate is a **feedback loop** and cannot be pipelined without changing the
arithmetic:

```
cacc → 33-bit add → ovf/rail/fold → cacc        IRREDUCIBLE
```

So X1's floor is that loop's delay. It also cannot touch **wire delay** — 14 of the
45 cells on a1's worst path are buffers driving a 1554.8 µm die, ten times
`mac_array`'s edge length. Pipelining does nothing about distance.

**Prediction:** X1 plateaus once the accumulate loop dominates. If the row goes flat
while slack is still well above the loop's own delay, the residual is wire and X2
must be a physical/structural generation, not another pipelining one.

### The one thing every Y must not break

`SAT=1` folds **once per k-step**, and that ordering *is* the specification —
saturating addition is not associative. A pipelined feed-forward must still deliver
`sum4(k)` to each accumulator in `k = 0…15` order. Get it wrong and the arithmetic
changes silently at `SAT=1` while `SAT=0` keeps passing, because wrapping addition
*is* associative. The S-series cases are the guard.

### Y ladder

| Y | `PIPE` | change | cycles |
|---|---|---|---|
| Y0 | 0 | **no RTL change.** Re-baseline at the X1 knobs | 17 |
| Y1 | 1 | register `sum4` — cuts mux + multiply + tree out of the loop's path | 18 |
| Y2 | 2 | also register `prod[]` — splits multiply from tree | 19 |
| Y3 | 3 | also register the selected operands — splits the mux from the multiply | 20 |

**Y0 is mandatory and is not a comparison against a1.** Two harness knobs changed
(period and hold margin), so a1 → Y0 is not one variable. Y0 exists to be the
comparison point for Y1…Y3, which share its knobs exactly.

### X1-Y0 result — what the harness knobs bought, before any RTL changed

Y0 changed **no RTL**. It only applied X1's two harness-level knobs. Against a1:

| | a1 (1.00 ns, no margin) | X1-Y0 (2.80 ns, margin 0.05) | Δ |
|---|---|---|---|
| setup WS | −1.8171 | −0.0565 | |
| **hold WS** | **−0.0349, 34 viol** | **+0.0399, 0 viol** | **met** |
| implied fmax | 355 MHz | 350 MHz | −5 |
| stdcells | 519,820 | 509,176 | **−10,644** |
| `timing_repair_buffer` | 127,028 | 116,591 | −10,437 |
| area µm² | 1,109,920 | 1,086,640 | −23,280 |
| power W | 35.99 | **19.00** | **−47%** |

**Hold was not structural.** That was the open question X1 declared, and it is
answered: hold closes with margin. **But two knobs moved at once**, so the fix is
not attributable to the margin alone — a relaxed setup target also makes the tool
size cells less aggressively, which eases hold independently. What is established
is that hold is *achievable*, not which knob achieved it. Separating them would
cost another 40-minute run and does not block the climb, so it is left open and
labelled rather than quietly credited to the margin.

**fmax is period-robust.** 355 → 350 MHz for a 2.8× change in the target. The −5
is far inside the 48 MHz attribution noise this project already measured (rows
f2a/f2b). So `implied_fmax = 1/(period − slack)` is a fair metric across periods,
and measuring at a realistic target costs nothing in fidelity.

**The cell saving is entirely optimizer thrash.** −10,644 stdcells against −10,437
timing-repair buffers: the same cells. Half the power and 2% fewer cells for the
same speed, purely from not asking the tool to hit a target the design cannot
reach. This is the "set the target from measured slack" heuristic paying off, and
it is a HARNESS-level gain — no RTL was involved.

**Known bias, stated:** the period is held at 2.80 ns for all Y in X1 so the rows
are one variable apart. A Y that closes with large *positive* slack will therefore
have its fmax **understated**, because the optimizer stops once it meets the
target. That biases against a successful Y, so a reported gain is a lower bound —
acceptable. A winning Y deserves a follow-up run at a tighter period to find its
actual limit, and that is a new X, not another Y.

### X1-Y1, first attempt — FAILED, and it was the HARNESS, not the design

`trials.jsonl` carries an `X1-Y1 result=FAIL` record with no metrics. That record
is true — the trial did fail — but under the X-Y rule a Y failure implicates the
**design**, and this one did not. It was tooling, and conflating the two would
corrupt the only diagnostic this scheme has.

**What happened.** `PIPE` was added to the RTL, to the testbench, to `SIM_PARAMS`
and to the Makefile — but **not to `TOP_PARAMS`**. So `measure.sh` gated on a
simulation of `PIPE=1` and then handed synthesis `VERILOG_TOP_PARAMS = SAT 1`,
building `PIPE=0`. The trial was measuring a duplicate of its own baseline while
preparing to log it as `PIPE=1`.

**How it was caught.** Not by the flow, which was perfectly happy. By checking the
synthesised flop count against the prediction: `PIPE=1` must add 4,608 flops
(18 bits × 256 accumulators) and the netlist showed **+1**. The arithmetic not
matching is what exposed it. Had the prediction not been written down first, a
duplicate row would have entered the log as a pipelining result.

**The irony, recorded deliberately.** `measure.sh` already carried this comment:

> Every parameter that changes the hardware must be passed here too. Gating on a
> simulation of a DIFFERENT configuration than the one being synthesised would
> make the gate decorative.

The warning was right, sat directly above the code, and did not prevent the bug.
**A comment is not a check.**

**The structural fix**, not just patching the two call sites: `measure.sh` now
cross-checks that every `-Ptb_*.NAME=VALUE` given to the sim gate appears with the
same value in `TOP_PARAMS`, and aborts if not. Verified to fire on exactly this
bug and to pass for both designs. Any future parameter added to a testbench but
forgotten in the synthesis parameters is now a hard failure rather than a silently
wrong row.

**Second-order lesson for the harness itself:** the per-trial record should assert
the prediction where one exists. Y1 predicted +4,608 flops; the flop count was
already being logged; nothing compared them. Cheap to add, and it would have
failed the trial in seconds instead of costing 17 minutes of routing.

### X1-Y1 retry — the hardware is right, and the flop accounting is exact

Synthesis: **29,194 flip-flops**, and that number decomposes exactly:

```
  24,576   three tile registers (3 x 16 x 512)
   4,608   sum4 registers -- what PIPE=1 adds (256 units x 18 bits)
      10   control: state(2) + ccnt(5) + busy(1) + done(1) + v_sr(1)
  ------
  29,194
```

The goal string predicted **29,192**, because it counted only the datapath and
forgot two control flops that the same change introduced: `ccnt` is one bit wider
than the `kcnt` it replaced (it must reach `KDW+PIPE-1`), and `v_sr[0]` is the
delayed accumulate enable. `v_sr[1:3]` are unused at PIPE=1 and pruned.

**So the prediction was off by 2 and the hardware is correct** — the opposite of
the first attempt, where the prediction was right and the hardware was wrong.

**This exposed a flaw in the check added an hour earlier.** It was exact-match, so
`--expect-flops 29192` would have demoted this correct trial to
`OK_BUT_WRONG_HARDWARE` over a 2-flop arithmetic slip. A false failure in the log
is as corrosive as a false success. The check is now tolerant —
`max(32, 1% of expected)` — because the failure it exists to catch is "the
parameter had no effect", which is by construction a large fraction (the real bug
was 15.8% off), not a handful of control bits.

### Calibration: FLW-0009 is optimistic on a large die, by about the size of the effect

X1 declared `FLW-0009` as the report to read for slack, cross-validated on
`mac_array` f2b where it matched the routed value to 0.001 ns. On this design it
does not:

| design | die | FLW-0009 | final routed | shift |
|---|---|---|---|---|
| `mac_array` f2b | 156 µm | −0.2590 | −0.2581 | **+0.0009** |
| `amx` a1 | 1555 µm | −1.7850 | −1.8171 | **−0.0321** |
| `amx` X1-Y0 | 1554 µm | −0.0240 | −0.0565 | **−0.0325** |

Consistently **~−0.032 ns on the 1.55 mm die and ~0 on the 156 µm one**. That is
detailed routing adding wire delay which global-route parasitics underestimated,
and it scales with distance. So FLW-0009 remains the right thing to read *during*
a run — it is the design's worst path, unlike an optimizer's progress table — but
it is not the final number on a die this size.

**The uncomfortable part:** 0.032 ns is the same order as the entire Y0→Y1
improvement seen at global route (0.042 ns). The correction is as large as the
effect being measured. At this die size a few MHz is below the flow's own
stage-to-stage resolution, which independently justifies `FLAT_MHZ = 10` in
`trials.py` — a threshold picked earlier from the f2a/f2b attribution noise, now
supported by a second, unrelated measurement.

Practical consequence for reading the X1 row: only a **large** Y step means
anything. A 5 MHz move is not a result.

---

## X2 — "X1's fix family was right; its MEASUREMENT was blind"

X1 is not being abandoned because its fix family failed. The path report proves the
family worked. X1 is being superseded because **its measurement procedure could not
see its own Y's effect**, which is a harness fault by definition.

### The evidence that X1's procedure was blind

X1-Y1's worst path, post-route:

```
Startpoint: ccnt[1]$_DFFE_PN0P_
Endpoint:   g_m[13].g_n[2].g_sum4_reg.s4r[17]$_DFF_P_
arrival 3.394   required 3.340   slack -0.054
```

It ends at **`s4r`** — the register `PIPE=1` created. So the accumulate loop is no
longer critical and X1's declared floor was never reached. The feed-forward stage
is still the longest, which is exactly what `PIPE=2` targets.

But WNS is unchanged from Y0 (−0.054 vs −0.057) for a path that is *logically
shorter*. The tool simply relaxed it: TNS −35.958 → −0.763, violating endpoints
2,812 → 41, and 51,786 buffer cells it therefore never inserted. **A fixed period
across a ladder that changes the design's speed measures the target, not the
design.**

### What changes (this is the harness delta)

| | X1 | X2 |
|---|---|---|
| period | **fixed** at 2.80 for the whole generation, from the a1 baseline | **derived per trial** from the previous trial's measured need |
| saturation check | none — relied on slack going positive, which never happened | **read TNS and violating-endpoint count.** TNS collapsing at unchanged WNS *is* the saturation signal |
| clock cost | not tracked | **track `clock__skew__setup`.** Pipelining added 4,610 flops → 1,170 clock buffers → skew +0.082 ns. Pipelining trades logic delay for skew, and that must be visible |

Reports read, bottleneck blamed and fix family are otherwise **unchanged from X1** —
the path report says they were correct.

### What X2 CANNOT reach

Fixed per-cycle overhead is now a hard floor: **skew 0.2547 + SDC uncertainty
0.100 + setup ≈ 0.04 = ~0.39 ns**, and skew *grows* with every pipeline stage
because each adds flops to the clock tree. So the ladder is self-limiting in a way
X1 did not anticipate: each `PIPE` step buys logic delay and spends skew.

Wire is still untouched — 9 of the ~34 cells on Y1's worst path are buffers.

### Y ladder

| Y | RTL | period | purpose |
|---|---|---|---|
| Y0 | `PIPE=1` (X1's best) | **2.00 ns** | re-baseline the SAME RTL at a target that does not hide it. ~30% tighter; if it closes easily, tighten again |
| Y1 | `PIPE=2` | from Y0's need | register `prod[]` — splits multiply from tree. +16,384 flops, the expensive cut |
| Y2 | `PIPE=3` | from Y1's need | register the operands — splits the mux off the front. +1,024 flops |

**X2-Y0 is the same RTL as X1-Y1.** If its fmax is materially higher, that alone
proves X1's row was measurement-limited rather than design-limited — and it costs
one run to know.

### X2-Y0 result — X1's row was measurement-limited, and the cost was a 15% gain

Same RTL as X1-Y1. Only the target moved.

| trial | PIPE | target | setup WS | needs | fmax | cells | area µm² | skew | TNS |
|---|---|---|---|---|---|---|---|---|---|
| X1-Y0 | 0 | 2.80 | −0.0565 | 2.857 | 350.1 | 509,176 | 1,086,640 | 0.1727 | −36.0 |
| X1-Y1 | 1 | 2.80 | −0.0539 | 2.854 | 350.4 | 457,390 | 920,220 | 0.2547 | −0.8 |
| **X2-Y0** | **1** | **2.00** | −0.4702 | 2.470 | **404.8** | 492,398 | 971,277 | 0.2140 | −1067.8 |

**`PIPE=1` is worth +54.7 MHz (+15.6%). X1 reported it as +0.3 MHz.**

The comparison is fair, and it is worth saying why rather than assuming it:
`PIPE=0` at 2.80 had TNS −36.0 across 2,812 straining endpoints, so it was *not*
saturated — 350.1 really is its limit. Independently, a1 measured `PIPE=0` at a
1.00 ns target and got 355 MHz. Two targets 2.8× apart agree, so the `PIPE=0`
baseline is solid and the +15.6% is real.

**TNS behaved exactly as X2 designed it to.** −0.8 when saturated, **−1067.8** when
the tool is actually working. That is the signal X1 lacked, and it is what
distinguishes "the design cannot go faster" from "nobody asked it to".

**The speed/area curve for one RTL.** X1-Y1 and X2-Y0 are the same Verilog:
350 MHz for 457k cells, or 405 MHz for 492k. ~55 MHz of headroom costs ~35k cells.
Neither number is "the" answer — which is the deeper reason a fixed period per
generation was the wrong procedure.

**Hold survived the tighter target** (+0.0227, 0 violations, down from +0.0402).
Worth noting because it was a live risk: tightening setup makes the tool size cells
up, which shortens min-delay paths.

### Correction: the FLW-0009 shift is NOT a constant

Earlier this file claimed "consistently ~−0.032 ns on the large die". That was
fitted to two points and the third breaks it:

| design | die | FLW-0009 | routed | shift |
|---|---|---|---|---|
| `mac_array` f2b | 156 µm | −0.2590 | −0.2581 | +0.0009 |
| `amx` a1 | 1555 µm | −1.7850 | −1.8171 | −0.0321 |
| `amx` X1-Y0 | 1554 µm | −0.0240 | −0.0565 | −0.0325 |
| `amx` X2-Y0 | 1554 µm | −0.4630 | −0.4702 | **−0.0072** |

The shift ranges 0 to −0.033. **FLW-0009 is an upper bound on the final slack, not
a value with a fixed offset.** The 401 MHz predicted for X2-Y0 against 404.8 actual
was right in direction and close in magnitude, but for an over-fitted reason —
recorded because a calibration believed too precisely is how the next wrong
confident number gets made.

### X2-Y1 (PIPE=2) — the ladder is still climbing, and my prediction was wrong

| PIPE | best at | fmax | Δ | flops | Δ flops | MHz per 1k flops |
|---|---|---|---|---|---|---|
| 0 | X1Y0 | 350.1 | — | 24,584 | — | — |
| 1 | X2Y0 | 404.8 | +54.7 | 29,194 | +4,610 | **+11.87** |
| 2 | X2Y1 | **482.7** | **+77.9** | 45,579 | +16,385 | **+4.75** |

**+37.9% cumulative over `PIPE=0`**, hold met (+0.0353, 0 viol), DRC clean, and the
flop prediction hit exactly (45,579).

**The prediction in Y1's goal string was wrong**, and it is worth saying how: it
said *"the multiply still dominates the split so the gain should be smaller than
PIPE=1's +54.7 MHz"*. The gain is **larger**, +77.9. So the adder tree was a bigger
fraction of that stage than assumed — the multiply does not dominate it as much as
the gate counts suggested (an 8×8 multiply is ~407 gates against a 4-input tree of
~250, and depth is evidently distributed differently from gate count).

**Absolute gain and efficiency now point in opposite directions**, which is
precisely why the cost-per-gain view was worth building: the ladder is climbing
*harder* (+77.9 vs +54.7) while getting **2.5× less efficient** per flop. Neither
number alone would say what to do next.

**1.80 ns is not saturating `PIPE=2`** — TNS −906.0, the tool working hard. That
validates the deliberate deviation of running `PIPE=3` at the same target: the two
are a fair one-variable comparison, unless `PIPE=3` is fast enough to saturate
1.80, which its own TNS will reveal.

**What `PIPE=3` has to beat**, at only +1,024 flops:

| to beat | it needs |
|---|---|
| `PIPE=2` efficiency (+4.75 MHz/1k) | **+4.9 MHz** |
| `PIPE=1` efficiency (+11.87 MHz/1k) | +12.2 MHz |

So the cheapest rung is likely the best *value* even if its absolute gain is small —
a conclusion the fmax column alone would never produce.

### X2-Y2 (PIPE=3) — the cheapest rung is the best value, and it DOMINATES PIPE=2

| PIPE | best at | fmax | Δ | flops | Δ flops | MHz per 1k flops | stdcells |
|---|---|---|---|---|---|---|---|
| 0 | X1Y0 | 350.1 | — | 24,584 | — | — | 509,176 |
| 1 | X2Y0 | 404.8 | +54.7 | 29,194 | +4,610 | +11.87 | 492,398 |
| 2 | X2Y1 | 482.7 | +77.9 | 45,579 | +16,385 | +4.75 | 577,348 |
| **3** | **X2Y2** | **511.4** | +28.7 | 46,604 | **+1,025** | **+28.00** | **514,700** |

**+46.1% frequency over the baseline for +1.1% cells** (509,176 → 514,700), both
measured near their respective limits. Hold met throughout, DRC clean throughout,
and the flop prediction exact for the third consecutive trial.

**The prediction in Y2's goal string was right:** the cheapest rung would be the
best value. It needed +4.9 MHz to beat `PIPE=2`'s efficiency and delivered +28.7,
at **+28.00 MHz per 1k flops** — 2.4× better than `PIPE=1` and 5.9× better than
`PIPE=2`.

**`PIPE=3` is faster AND smaller than `PIPE=2`**, which is the counterintuitive
part and the mechanism is exact:

| | PIPE=2 | PIPE=3 | Δ |
|---|---|---|---|
| stdcells | 577,348 | 514,700 | **−62,648** |
| `timing_repair_buffer` | 127,433 | 65,593 | **−61,840** |
| setup TNS | −906.0 | −31.6 | +874.5 |

The buffer collapse *is* the cell saving — they match to within 800 cells. **+1,025
flops let the tool skip ~62,000 repair buffers**, because the shortened stage no
longer needs sizing and buffering to hit the target. Adding registers made the
design smaller.

Practical consequence: `PIPE` is cumulative, so `PIPE=3` is not an alternative to
`PIPE=2` but a superset of it. The recommendation is therefore **do not stop at
`PIPE=2`** — that intermediate point is strictly worse on both axes than paying
1,025 more flops to finish the job.

**Caveat, flagged not buried: `PIPE=3` may itself be measurement-limited.** Its TNS
is −31.6, an order of magnitude closer to saturation than `PIPE=2`'s −906, and it
needs 1.955 ns against a 1.80 target. That is the same shape as the X1 trap: not
saturated by the |TNS| < 5 test, but no longer straining either. So 511.4 MHz
should be read as a **lower bound** until it is re-measured at a tighter target.
The calibration already running for `PIPE=2` (X2-Y3, at 1.50 ns) tests exactly this
class of doubt, and `PIPE=3` deserves the same treatment.

### X2-Y3 (calibration) — every fmax in this project is a LOWER BOUND

Same `PIPE=2` RTL, two targets:

| target | setup WS | need | fmax | TNS | cells |
|---|---|---|---|---|---|
| 1.80 | −0.2717 | 2.0717 | 482.7 | −906 | 577,348 |
| **1.50** | −0.4788 | **1.9788** | **505.4** | −3,550 | 583,132 |

**+22.7 MHz for 5,784 cells, from the same Verilog.** `PIPE=2` was
effort-limited, not design-limited — and it was *not* saturated (TNS −906), so the
`|TNS| < 5` saturation test does **not** catch this. It is a second, distinct
failure mode.

**Two failure modes, not one:**

| | signature | remedy |
|---|---|---|
| **saturated** | \|TNS\| small; the tool met the target and stopped | tighten the target |
| **effort-limited** | TNS large and negative, yet a tighter target still improves it | tighten the target *further*, or accept a floor |

`repair_timing` works *to the target*, so a tighter ask buys more optimisation
effort. Which means **fmax in this flow is not a property of a design** — it is a
function of how hard the flow was asked.

**This generalises beyond the campaign.** Every row in `EXPERIMENTS.md` is "fmax at
the effort implied by its target", not "the fmax of this design". The saving grace:
rows sharing a target stay comparable, and v0/f1a/f1b/f2a/f2b are all at 1.00 ns,
so their relative ordering stands. The absolutes are floors.

**The design conclusion survives, which is what matters.** Against `PIPE=2`'s
*improved* number:

- `PIPE=2` best known: 505.4 MHz, 583,132 cells
- `PIPE=3` best known: 511.4 MHz, 514,700 cells — **and not yet pushed**

`PIPE=3` is still faster *and* 68,432 cells smaller. The dominance holds, and the
ordering `PIPE=3 > 2 > 1 > 0` is robust even though every magnitude is a floor.

**Where this stops, deliberately.** Establishing a true fmax per variant needs a
binary search per variant — roughly eight more runs — to refine numbers that do not
change the recommendation. The proportionate answer is to label them lower bounds,
state that the ordering is robust, and stop. Chasing exact limits here would be
precision without decision value.

### X2-Y4 — the calibration corrects a claim made two commits ago

`PIPE=3` at 1.60: **514.9 MHz**, needs 1.942 (was 511.4 / 1.955 at a 1.80 target).

**The two variants were effort-limited by very different amounts:**

| variant | tightening | gain |
|---|---|---|
| `PIPE=2` | 1.80 → 1.50 | **+22.7 MHz** |
| `PIPE=3` | 1.80 → 1.60 | **+3.5 MHz** |

`PIPE=2` was heavily effort-limited; `PIPE=3` was barely. That has a mechanism: the
more pipelined the design, the less optimisation headroom remains in its already
short stages, so a given target lands nearer the true limit. Effort-limitation is
therefore **not a uniform offset** — it shrinks as the design improves, which means
it cannot be corrected for with a constant and must be measured per variant.

**RETRACTION.** Two commits ago this file recorded, and it was reported as a
headline, that `PIPE=3` was *"the best value rung by a wide margin"* at
**+28.00 MHz/1k flops, 5.9× better than `PIPE=2`**. That was an artifact of
comparing `PIPE=3` against `PIPE=2`'s **floor**. With both properly pushed:

| PIPE | MHz/1k flops | as previously claimed |
|---|---|---|
| 1 | **+11.87** | +11.87 — unchanged, and actually the best value |
| 2 | +6.14 | +4.75 — was understated |
| 3 | +9.27 | **+28.00 — inflated 3×** |

So `PIPE=1` is the best-value rung, and `PIPE=3` beats `PIPE=2` by **1.5×, not
5.9×**. The error was structural, not arithmetic: an efficiency ratio between two
variants is only meaningful when *both* are measured at comparable effort, and
nothing in the tooling enforced that. `trials.py` grouping by "best per variant"
made it look rigorous while the underlying numbers were not comparable.

**What survives, and it is the part that matters:**

- **Dominance holds, more strongly than before.** `PIPE=3` (514.9 MHz, 519,051
  cells) versus `PIPE=2` (505.4 MHz, 583,132 cells): faster by 9.5 MHz *and*
  smaller by 64,081 cells. Since `PIPE` is cumulative, **do not stop at `PIPE=2`**.
- **The ordering `PIPE=3 > 2 > 1 > 0` is unchanged.**
- **Cumulative: 350.1 → 514.9 MHz = +47.1%**, for +1.9% cells (509,176 → 519,051)
  and +22,020 flops. Hold met and DRC clean at every rung.

**Lesson for the harness, which is the point of writing this down:** the ladder
economics view was added to stop fmax-alone from misleading, and it then misled in
its own way by comparing unequal-effort measurements. A derived metric inherits
every weakness of its inputs and adds the appearance of rigour. The cost-per-gain
column should refuse to compare variants whose effort-limitation has not been
measured — otherwise it is confident nonsense.

---

## X3 — "the compute datapath is no longer critical; the READBACK PORT is"

Declared before any RTL change, from X2-Y4's measured path. **Both of the X3
candidates reasoned out in advance were wrong**, which is worth stating first: X2
declared its ceilings as clock skew and wire delay, and the leading guesses for X3
were a physical/floorplanning generation or an internal split of the 8×8 multiply.
The path report says neither. Declaring X3 from X2's stated ceiling would have
spent hours optimising something that no longer limits the design — the exact
"wrong fix family" failure the X-Y rule exists to catch.

### The measurement

X2-Y4's worst path, at a 1.60 ns target:

```
a_flat[2420]/CK   <- clock network delay 0.717
a_flat[2420]/Q -> MUX2 x4 -> BUF x2 -> MUX2 -> NOR2 -> AOI21 -> BUF -> rd_data[372]
arrival 1.522    slack -0.342
```

| term | ns | share |
|---|---|---|
| **clock network delay (uncompensated)** | **0.717** | **47%** |
| 16:1 `rd_row` mux tree (4× MUX2) | 0.256 | 17% |
| wire (6× BUF) | 0.284 | 19% |
| `rd_sel` case + logic | 0.172 | 11% |
| flop Q | 0.089 | 6% |

**It is the tile READ port, not the datapath.** And the dominant term is clock
insertion delay that **does not cancel**, because the path ends at an *output port*:
with no capture flop the capture side contributes 0.000 clock network delay
(confirmed in the report), so the 0.717 launch delay is pure cost. On any
flop-to-flop path that same 0.717 appears on both sides and vanishes. That is
precisely why this path took over while the datapath did not.

### Reports read — the change from X2

| report | why it is new here |
|---|---|
| paths ending at **output ports**, specifically | X1 and X2 only ever examined flop-to-flop datapath endpoints, and so could not have seen this |
| **clock network delay** on the launch side | the dominant term, and invisible unless the path is decomposed |
| `set_output_delay` in the SDC | 20% of the period is consumed by an I/O assumption before any gate switches |

### Bottleneck blamed

`rd_data`'s combinational path from the tile registers: a 16:1 row mux plus a 3-way
`rd_sel` case, driven straight to an output port so the clock insertion delay is
uncompensated.

### Fix family — pipeline the I/O, not the datapath

**Register `rd_data`.** One flop stage, +512 flops, behind a parameter `RD_REG`
following the proven `SAT`/`PIPE` pattern so both states stay buildable and
testable. That converts an output-port path into flop→mux→flop, where the 0.717
cancels, and leaves a short flop→port path behind it.

The cost is one cycle of **readback** latency, which is not throughput-critical:
readback is a separate operation from the multiply, and the `mac_array` `OUT_PAR`
work already established that a drain is only expensive when it scales with the
work (there, `N²` cycles), not when it is a fixed extra cycle.

### What X3 CANNOT reach

It cannot help the datapath, and it should not be expected to. If registering the
readback works, the design becomes limited by the compute path again — which is the
*correct* place to be limited, and the point at which the pipelining ceiling X2
declared (fixed overhead ~0.33 ns, growing per stage) becomes the real wall.

Wire and skew remain untouched. They are still the eventual answer; they are simply
not the *current* answer, and X3 exists because the measurement said so.

### Y ladder

| Y | change | period | purpose |
|---|---|---|---|
| Y0 | `RD_REG=1` on top of `PIPE=3` | 1.60 | same target as X2-Y4, so it is one variable |
| Y1 | derived from Y0's need | — | only if Y0 moves the limiter back to the datapath |

**Prediction:** the worst path moves off `rd_data` and back onto the compute
datapath. If fmax does **not** improve, then `rd_data` was not really the binding
constraint and something else at similar delay takes over — which would itself be
worth knowing, since it would mean the design has a cluster of paths at ~1.5 ns
rather than one limiter.

---

## X3-Y0 result — the fix worked, and the metric was broken

`RD_REG=1` on `PIPE=3` at the same 1.60 ns target. Flop prediction exact: 47,116
predicted, 47,116 built.

| | X2-Y4 | X3-Y0 |
|---|---|---|
| setup WS | −0.3422 | **−0.0108** |
| TNS | −114.64 | **−0.013** |
| reported fmax | 514.9 | **620.8** |
| cells / flops | 519,051 / 46,604 | 522,690 / 47,116 |
| area / power | 1,029,960 µm² / 2.2166 W | **1,029,030 / 2.0984** |

Area and power fell while 512 flops were added — the buffering collapse already
seen at PIPE=3 vs PIPE=2. Hold met, DRC clean.

### The prediction was half right

The path did **not** move to the datapath. It is still `rd_data`, just shorter:

```
0.7630  clock network delay    64% of arrival, CANNOT cancel (no capture flop)
0.1884  flop Q
0.2393  two buffers to the pad
1.1908  arrival        vs required 1.180 = 0.8*P − 0.100
```

Registering the port removed five mux levels but not the *structural* problem: an
output port has no capture flop, so clock insertion delay is charged in full.

### THE DEFECT — this is an X-level finding, not a Y-level one

`constraint.sdc.in` budgets I/O as a **fraction of the period**:

```tcl
set_input_delay  [expr $clk_period * 0.2] ...
set_output_delay [expr $clk_period * 0.2] ...
```

For a path ending at an output port:

```
slack          = 0.8P − 0.1 − arrival
implied period = P − slack = 0.2P + 0.1 + arrival
```

The `0.2P` term **shrinks as the target tightens**, so `1000/(P − ws)` rises with
byte-identical hardware: 620.7 MHz at P=1.60, 636.5 at 1.40, 653.2 at 1.20, 670.7
at 1.00. The model reproduces the tool exactly (predicted required 1.180 vs
reported 1.180), so this is confirmed. A combinational input-port → output-port
path is charged `0.4P + 0.1` — twice as bad.

**The harness read a frequency for eight trials without ever recording where the
limiting path ENDED.** That is the defect. The fix family in X3 was right; the
instrument was not.

### Recovered, not re-measured

Every trial's `6_final.odb/.sdc/.spef` was still on disk, so the honest metric was
re-derived with read-only STA — minutes, not eight × ~40-minute re-runs. Every
recovered overall-WS matched its logged value within 0.002 ns, which is what makes
the retroactive correction legitimate rather than a guess.

| row | PIPE/RD | target | reported | limiter | reg→reg WS | **corrected** |
|---|---|---|---|---|---|---|
| X1-Y0 | 0 | 2.80 | 350.1 | reg→reg | −0.0565 | 350.1 ✓ |
| X1-Y1 | 1 | 2.80 | 350.4 | reg→reg | −0.0539 | 350.4 ✓ |
| X2-Y0 | 1 | 2.00 | 404.8 | reg→reg | −0.4702 | 404.8 ✓ |
| X2-Y1 | 2 | 1.80 | 482.7 | reg→reg | −0.2717 | 482.7 ✓ |
| X2-Y2 | 3 | 1.80 | 511.4 | **IN→OUT** | +0.1341 | **600.3** |
| X2-Y3 | 2 | 1.50 | 505.4 | reg→reg | −0.4788 | 505.4 ✓ |
| X2-Y4 | 3 | 1.60 | 514.9 | **OUT-PORT** | +0.0456 | **643.3** |
| X3-Y0 | 3+RD | 1.60 | 620.8 | **OUT-PORT** | +0.0818 | **658.7** |

**Five of eight rows were never contaminated** — their limiter was register-to-
register, where insertion delay cancels and no I/O term applies. The tainted three
are exactly the PIPE=3 rows, which is causally sensible: PIPE=3 shortened the
compute path enough that the readback path took over, and from that point the
metric stopped describing the design.

### Retractions

1. **X2-Y2 was 600.3 MHz, not 511.4.** Its compute datapath met 1.80 ns with
   +0.134 ns spare. PIPE=3 was undersold by ~90 MHz for the rest of the campaign,
   and subsequent reasoning about PIPE=3 used a number that was measuring the
   readback mux.
2. **"X2-Y4 (514.9) beat X2-Y2 (511.4)" is void.** Corrected: 643.3 @1.60 vs
   600.3 @1.80 — same RTL, different targets, so the gap is optimizer effort, not
   design. The earlier retraction of this comparison was right for the wrong reason.
3. **RD_REG bought ~15 MHz of compute, not ~106.** 643.3 → 658.7 at equal target.
   The reported +105.9 was ~85% removal of a measurement artifact. RD_REG is still
   a genuine fix — it is what lets the design close at 1.60 ns at all (−0.342 →
   −0.011) — but not for the reason the metric claimed.
4. **The `350.1 → 620.8` ladder is not a like-for-like ladder.** It spans 2.80 →
   1.60 ns. Even among clean rows, optimizer effort differs by target.
5. **X1's prediction that the accumulate feedback loop would become the floor is
   wrong.** The tightest real path is the multiplier carry chain
   (`a_dw_r → 6× FA/HA → ~8 levels AOI/OAI → pr`). The loop has *more* slack.

Also fixed: `mktemp /tmp/f.XXXXXX.tcl` in `report_path.sh` and `gds.sh`. macOS
only substitutes X's at the **end** of a template, so that form creates a file
named literally `f.XXXXXX.tcl` and a second CONCURRENT call dies with "File
exists", leaving the variable empty. It left exactly one survivor per batch and
looked convincingly like an OOM kill — I diagnosed it as one, wrongly, on the
strength of a real-but-irrelevant 2.66 GB-per-process measurement.

---

## X4 — measure the design, not the pad boundary

| | |
|---|---|
| **Reports read** | `sta_limiter.sh` **first**: limiter class + reg→reg slack. Then `FLW-0009`, `6_report.json`, `5_route_drc.rpt`. A frequency without a limiter class is not admissible |
| **Bottleneck blamed** | The multiplier carry chain, `a_dw_r → 6× FA/HA → ~8 AOI/OAI → pr`. It is the worst reg→reg path in both X2-Y4 (+0.0456) and X3-Y0 (+0.0818), i.e. the same limiter survived the RD_REG change |
| **Fix family** | Shorten the multiply→accumulate arithmetic itself: carry-save accumulation so the adder tree's carry propagation stops being resolved every cycle |
| **Period** | Each variant iterated to its **own fixed point** (`ws ≈ 0`), where `1000/(P−ws)` is self-consistent, OR compared only at equal target. No more cross-target claims |
| **Hold policy** | Unchanged: `HOLD_SLACK_MARGIN=0.05`, met on every row so far |

### What X4 can and cannot reach

It cannot make the reported `implied_fmax` honest while the limiter is an I/O path.
`RD_REG=1` leaves a residual flop→2-buffer→port path whose arrival is 64% clock
insertion delay, and no RTL change touches that — it is a floorplan/pad-boundary
property. **So X4 tracks `regreg_fmax_mhz` as the objective** and treats
`implied_fmax_mhz` as a signoff question, not a design one.

The deliberate decision NOT taken: switching the SDC to absolute I/O delays. That
is the cleaner convention and a one-line change, but it would invalidate the only
comparison chain that is currently sound. The instrument is now recorded per row,
which is enough to interpret both conventions.

---

## X4 result — the premise was refuted, then confirmed, and the row closes

Three trials, **one RTL** (`PIPE=3 RD_REG=1`), three targets. Flop count 47,116 on
every row — the guard that nothing drifted.

| target | reg→reg fmax | Δ | TNS | limiter | cells | power |
|---|---|---|---|---|---|---|
| 1.60 (X3-Y0) | 658.7 | — | −0.01 sat | OUT-PORT | 522,690 | 2.098 W |
| 1.40 (X4-Y0) | 698.9 | **+40.2** | −1.56 sat | OUT-PORT | 532,445 | 2.436 W |
| 1.20 (X4-Y1) | 702.9 | **+4.0** | **−558.27** | **reg→reg** | 567,769 | 3.069 W |

### X4-Y0 refuted X4's premise

X4 blamed the multiplier carry chain. At 1.60 that path had **+0.0818 ns of slack**
— it had never been observed to fail, so the blame was unfalsified, not confirmed.
Y0 retargeted with no RTL change and gained **+40.2 MHz**. The path was
**effort-limited**, not at its wall, and carry-save would have optimised something
that was not binding. Spending Y0 on a measurement instead of an RTL change is the
only reason that was caught.

**Both of Y0's timing predictions were wrong.** Predicted reg→reg ≈ 659 (unchanged);
actual 698.9. Predicted `implied_fmax` ≈ 637 by treating the output-port arrival as
period-independent; it is not — the tool shortened it 1.191 → 1.085 when pushed, so
`implied_fmax` mixes the pad-boundary artifact with real optimisation and the
earlier "670.7 MHz at P=1.00 with identical hardware" projection was too crude. The
artifact is real; that quantification of it was not.

### X4-Y1 confirmed the wall

The stated stopping condition — *large TNS with a stalled objective* — fired
exactly: TNS blew up **357×** while the objective moved **+4.0 MHz**, and the
limiter finally flipped to `reg→reg`. That is a real limit rather than a target.
**The wall is ~703 MHz.**

### The binding path, and a correction to X4's fix family

`regreg_endpoint` is `pr[14]` on all three rows (different `g_m`/`g_n` instances,
same bit): `a_dw_r → 6× FA/HA → ~8 levels AOI21/OAI21 → pr[14]`. That is
partial-product reduction followed by the multiplier's **final carry-propagate
adder**, and bit 14 of a 16-bit product is where carries arrive last.

So X4's declared fix — "carry-save **accumulation**" — named the wrong stage. The
binding stage is **multiply→`pr`**, not the accumulate loop, which has more slack.

### Why the row closes instead of spending Y2

1. **`SAT=1` structurally blocks full carry-save.** The fold must clamp once per
   k-step against the true value, so the accumulator cannot stay redundant across
   k-steps — it would need a resolve every cycle, defeating the purpose. Carry-save
   can only move the resolve from the multiply stage into the tree stage, i.e.
   rebalance, not eliminate.
2. **The cost is ~+16k flops, +35%.** `pr` is 16,384 flops (16 bits × 1024);
   redundant form roughly doubles it.
3. **The headroom being chased is ~4 MHz past a knee already located.**

### The knee — the finding that actually matters for use

| step | Δ fmax | Δ power |
|---|---|---|
| 1.60 → 1.40 | +40.2 | +16% |
| 1.40 → 1.20 | +4.0 | **+26%** |

**1.40 ns / 698.9 MHz / 2.436 W is the operating point**, and there the compute path
is not even binding — it is still OUT-PORT limited. Past it, power is the cost and
frequency is not the return.

### What the campaign is entitled to claim

Only equal-target pairs are like-for-like:

| pair | target | change | Δ reg→reg |
|---|---|---|---|
| X2-Y1 → X2-Y2 | 1.80 | `PIPE` 2→3 | **+117.6** |
| X2-Y4 → X3-Y0 | 1.60 | `RD_REG` 0→1 | **+15.4** |
| X1-Y0 → X1-Y1 | 2.80 | `PIPE` 0→1 | +0.3 (saturated) |

The end-to-end **350.1 → 698.9 MHz** spans 2.80 → 1.40 ns. X1-Y0's TNS was −36.0,
i.e. **not** saturated, so 350.1 is the tool's best effort at 2.80 and PIPE=0's true
capability at a tighter target is unmeasured — exactly the effect that turned
PIPE=3's 658.7 into 698.9. So "+99.6%" is **indicative, not a measurement**, and it
overstates the gain by an unknown amount. Closing the row does not license the
headline the old metric would have produced.

X4 closes. The design is limited by a multiplier carry-propagate at ~703 MHz, is
efficient at ~699, and the next real gain is an arithmetic redesign whose cost was
measured and judged not worth it.

### Found at close: the X1 row was never flat

X1 was declared flat because fmax moved **+0.3 MHz** (350.1 → 350.4). At the same
2.80 ns target and the same speed, registering `sum4` also did this:

| | X1-Y0 (PIPE=0) | X1-Y1 (PIPE=1) | |
|---|---|---|---|
| power | **19.0014 W** | **0.9921 W** | **−94.8%, 19.2×** |
| cells | 509,176 | 457,390 | −10.2% |
| area µm² | 1,086,640 | 920,220 | −15.3% |
| reg→reg fmax | 350.1 | 350.4 | +0.3 |

Verified against `finish__power__total` in both raw `6_report.json` files, not
transcribed. Equal target, equal limiter class (`reg→reg` both), one variable.

Mechanism: `PIPE=0` is one enormous combinational path — `kcnt` → 16:1 mux → 1024
multipliers → adder trees → 33-bit add → fold → `cacc`. Glitches propagate the full
depth, so every multiplier output toggles repeatedly before settling. One register
after `sum4` truncates that propagation.

**This is the same defect as the fmax metric, in a second dimension.** X1 watched
frequency, saw +0.3 MHz, and correctly concluded the row was flat *in the quantity
it was watching* — while a 19× power win sat in the same `6_report.json` it had
already parsed. The harness was not wrong about its number; it was wrong about
which number mattered. A hillclimb that ranks on one scalar cannot see a
Pareto move, and nothing in X1 through X3 would ever have surfaced this.

Note the 19 W figure also means `PIPE=0` was never a viable configuration on any
axis — it is 6.2× the power of the 698.9 MHz operating point while being half its
speed. The pipelining ladder's real justification was never the +99.6% frequency.

---

## X5 — "the adder is the floor, and everything ahead of it is one register away"

**The target design changes here.** X1–X4 climbed `amx_tdpbssd` and that campaign is
closed. X5 targets **`amx_fp8`**, whose baseline is row **p1** in `EXPERIMENTS.md`:
`RD_REG=1`, 4.00 ns target, setup WS **−1.7128**, reg→reg **175.0 MHz**, 57,867
flops, 3,985,240 stdcells, 40.35 W, DRC 0, hold **+0.0448** met.

Declared before any trial runs, as the protocol requires.

### Reports read

Unchanged from X4 in *what* is trusted — `6_report.json` for every PPA figure,
`sta_limiter.sh` for the limiter class, `report_path.sh` for path shape,
`5_route_drc.rpt` for DRC — with **one deliberate addition**:

| report | for |
|---|---|
| `finish__power__total` | **ranked, not a footnote.** X4's closing finding was a 19.2× power win at constant frequency that X1–X3 could not see, because a hillclimb that ranks on one scalar cannot see a Pareto move. This generation registers a signal ahead of 1024 FP32 adders, which is structurally the same glitch-truncation that produced that win, so power is a column the ladder is ranked on |

### Bottleneck blamed

p1's routed worst path launches from `ccnt` and ends at `g_m[1].g_n[13].lacc[49]`,
113 gate levels, and its segments are measured rather than inferred:

```
ccnt --> operand mux 0.864 --> fp8_mul 1.157 --> fp32_add 3.306 --> lacc  (0.046 tail)
         \_______________ 2.021 ns feed-forward, 38% _______________/
```

The accumulate loop is only the 3.306 ns adder. **2.021 ns of a 5.373 ns data path
is feed-forward logic sitting in front of a loop it does not belong to.** p1's own
write-up predicted no feed-forward register could help and was wrong about that;
this generation is the consequence.

### Fix family

**Register the product**, expressed as a cumulative `PIPE` parameter so every depth
stays buildable and testable — the same ladder shape `amx_tdpbssd` uses, and for the
same reason.

**The register is 16 bits per lane, not 32.** `fp8_mul` builds
`normal_y = {sgn, e_fld, nrm[6:0], 16'd0}`, and every special value it can return
(`0x7FC00000`, `{sgn,8'hFF,23'd0}`, `{sgn,31'd0}`) also has zero low bits: a product
of two 4-bit significands has exactly 7 fraction bits, which is the RTL's own stated
reason the product never rounds. So `y[15:0] == 0` for all 4×256×256 inputs, the cut
costs **16,384 flops (+28.3%)** rather than 32,768 (+57%), and `tb_fp8_mul` is
extended to **assert** that exhaustively rather than leaving it as an argument.

### Harness-level knobs, held constant across all Y in X5

| knob | value | why |
|---|---|---|
| `PERIOD` | **4.00 ns** | p1's value, kept so Y0 → Y1 is one variable. Note this *violates* X1's "set the target from measured slack" heuristic on purpose: p1 needs 5.713 ns, so PIPE=0 is measured against a target it cannot reach. That is what makes its TNS −60,409 readable as a real wall, and it is also why Y1 is expected to saturate — see the Y ladder |
| `HOLD_SLACK_MARGIN` | **0.05 ns** | what p1 used. Hold was clean at +0.0448 with 49,454 hold buffers, so this is a knob that is already known to work on this design |

### What X5 CANNOT reach — declared now so a plateau is interpretable

**The loop.** `lacc → fp32_add → lacc` is 3.306 ns routed and no feed-forward
register shortens it. p1's own numbers price the floor exactly: its implied period
of 5.7128 ns exceeds its 5.373 ns data path by **0.340 ns**, which is the launch
flop's CLK→Q plus setup plus the SDC's 0.1 ns uncertainty, less useful skew. That
overhead is paid by any register, so

```
floor = 0.340 + 3.306 + 0.046 = 3.692 ns  ->  270.9 MHz
```

**This corrects p1's own projection.** p1 wrote "putting the design near ~3.5 ns /
~285 MHz"; that figure omits the pipeline register's overhead, which p1 had already
measured. The reachable number is ~271 MHz, not ~285.

X5 also cannot touch **wire delay** on a 3065 × 3065 µm die, and cannot touch the
**epilogue's** three cycles or its balanced-tree order.

### Prediction, stated to be falsifiable

1. **Y1 lands at the floor, not short of it.** After the cut the feed-forward path is
   `0.340 + 2.021 = 2.361 ns` → 423.6 MHz, so it stops being the limiter by a wide
   margin and the adder loop binds. Expect **3.6–3.8 ns, ~263–278 MHz, +50% to +59%**
   over 175.0. A result materially *above* 278 MHz means the adder segment itself
   moved under re-placement and the loop was never as measured.
2. **Flops: 57,867 → 74,252**, +16,385. Asserted by `trial.sh --expect-flops`,
   not logged beside the result.

   Corrected from 74,251 **before any trial ran**, and the correction is itself
   worth recording because it is the same class of error X1 made: 16,384 is the
   product register, and the +1 is `v_sr`, the enable shift register this
   generation's own fix family requires. I predicted the datapath and forgot the
   control. Measured by yosys RTL flop inference at both settings —
   **PIPE=0 = 57,867 exactly**, which is the figure p1 predicted and hit, so
   `opt_clean` prunes `v_sr` at PIPE=0 and X5's "the parameter is free at PIPE=0"
   holds precisely rather than approximately.
3. **Cycles 20 → 21.** Latency, not throughput: one k-step per cycle either way.
4. **A further rung is worthless.** Registering the decoded operands too (PIPE=2)
   would split a 2.361 ns path that is already 1.33 ns clear of the binding loop. If
   Y1's limiter comes back `reg→reg` inside the adder, X5 is closed by that fact and
   the next generation must pipeline `fp32_add` itself — which needs interleaved
   accumulators, because the adder is otherwise in a one-cycle loop.
5. **Power should fall substantially** at constant frequency, by the X4 mechanism:
   1024 multiplier outputs currently glitch straight into 1024 FP32 adders every
   cycle. No number is predicted, because p1's 40.35 W is not credible in absolute
   terms and this log's rows span 19.0 W to 0.99 W for one design at one target.

### The one thing every Y must not break

**FP32 addition is not associative**, so per-lane k-order `0..15` *is* the
specification, exactly as the saturating fold's per-k-step boundary was in X1. Two
distinct orderings are load-bearing here, not one:

1. the k-sequence into each `lacc[b]`, and
2. the **balanced-tree epilogue** (`lacc0+=lacc1`, `lacc2+=lacc3`, then
   `lacc0+=lacc2`), which `EXPERIMENTS.md` records as genuinely unresolved in the
   sources and which differs from a sequential chain on **23.05%** of output elements.

The delay must therefore be an order-preserving shift register on the *enable*, never
a re-derivation from the counter, and the epilogue must not begin until the last
accumulate has landed — `EP0 = KDW + PIPE`, not `KDW`.

X1's mutation table is the warning that matters: delaying `acc_en` by one cycle
*permutes* k rather than dropping it, every uniform-operand case is blind to that by
construction, and in `amx_tdpbssd` only the purpose-built S6 caught it. `tb_amx_fp8`
has **no equivalent case today**, so one is added — varying contributions where FP32
rounding can see a permutation — and the mutant is run to prove the suite catches it
*before* any trial is logged.

### Y ladder

| Y | `PIPE` | change | cycles | flops |
|---|---|---|---|---|
| Y0 | 0 | **no functional change.** Re-baseline p1's configuration on this machine, on the *same RTL bytes* Y1 uses, so Y0 → Y1 differs in one parameter and nothing else | 20 | 57,867 |
| Y1 | 1 | register the 16 significant bits of each `prod`, moving the mux and the multiply out of the accumulate path | 21 | 74,252 |

**Y0 is mandatory and is not a comparison against p1.** The platform changed — p1 was
measured on macOS/arm64, this machine is Linux/x86_64 with gcc 11.5 — and the
calibration run recorded in `EXPERIMENTS.md`'s Environment section shows the platform
alone moves stdcells and power. Y0 also proves the `PIPE` parameter is free at
PIPE=0: its flop count must be 57,867, the figure p1 predicted and hit exactly.

**Y1 is expected to SATURATE at this target and its reported fmax to be a lower
bound.** If Y1 needs ~3.69 ns it will close at 4.00 with roughly +0.3 ns of slack,
and the optimiser stops once it meets the target — the exact defect that first
measured `amx_tdpbssd`'s PIPE=1 as worth +0.3 MHz when it was worth +54.7. So Y1 is
also measured at **3.40 ns**, below its predicted need, to find where it actually
stops. That second row crosses targets and is labelled as such: only the 4.00 ns pair
is like-for-like.

### X5-Y0 result — the platform, isolated before anything was claimed

Y0 changed no RTL. It re-measured p1's exact configuration on the second platform,
so that every later delta is same-platform. Against p1:

| | p1 (macOS/arm64) | X5-Y0 (Linux/x86_64) | Δ |
|---|---|---|---|
| flip-flops | 57,867 | **57,867** | **exact** |
| stdcells | 3,985,240 | 3,974,058 | −0.28% |
| area µm² | 4,758,450 | 4,745,090 | −0.28% |
| power W | 40.3523 | 40.2251 | −0.32% |
| reg→reg fmax | 175.0 | 176.5 | +0.84% |
| hold WS | +0.0448 | +0.0423 | both met |

**The platform is not a variable for this design**, and that had to be measured
rather than assumed — on `mac_array` the same platform change moved power 11% and
pushed one endpoint into hold violation. Here everything agrees inside 0.32%. So p1
and the X5 rows are comparable after all, and the caveat that hung over every
number until this row landed is retired.

Y0 also discharges the "PIPE is free at PIPE=0" claim, at two levels. Synthesis:
57,867 flops and an **identical cell histogram** to the pre-parameter RTL (26 cell
types, 116,911 cells). Routed: 57,867 flops again. So the parameter's control
restructuring constant-folds exactly, and Y0 → Y1 is one variable.

### X5-Y1 result — the change works, the prediction does not

| | Y0 `PIPE=0` | Y1 `PIPE=1` | Δ |
|---|---|---|---|
| reg→reg fmax | 176.5 MHz | **212.6 MHz** | +20.5% |
| cycles | 20 | 21 | +5% |
| **throughput** | 144.6 GMAC/s | **165.9 GMAC/s** | **+14.7%** |
| power | 40.2251 W | **14.0894 W** | **−65.0%** |
| energy efficiency | 3.59 GMAC/J | **11.77 GMAC/J** | **3.28×** |
| stdcells | 3,974,058 | 3,454,124 | −13.1% |
| flip-flops | 57,867 | **74,252** | +28.3% |
| TNS | −59,371.7 | −12,285.5 | 4.8× |

Predictions 2, 3 and 5 held. Flops **74,252 against 74,252**, checked by
`--expect-flops` rather than logged beside the result. Cycles 20 → 21. Power fell
substantially, which is what prediction 5 asked for.

**But the area saving is optimiser effort, not the mechanism X4 identified**, and
this generation nearly credited it to the wrong cause. The cell-class breakdown:
`timing_repair_buffer` 1,141,280 → 631,196 µm², a **−510,084** saving that
*exceeds* the −383,750 total, with `sequential_cell` +74,094 for the new flops and
+52,254 elsewhere balancing it exactly. `PIPE=0` misses its target by 1.6654 ns and
`PIPE=1` by 0.7041, so the tool buys half a million µm² of buffers for the harder
one. That is X1-Y0's signature — "the same cells" — showing up in an RTL change
rather than a target change, and it is a warning that the two are not
distinguishable from a cell count alone.

Power is not settled by this pair: −65.0% against −10.8% area is out of proportion
to the buffers removed, so glitch truncation plausibly accounts for the remainder,
and X1 measured −94.8% from this change shape at equal target. The two effects are
**not separated here** and the row says so rather than claiming the mechanism it
would prefer. Ranking power in the report list is still what made the effect visible.

**Prediction 1 FAILED.** Declared floor 3.692 ns / 270.9 MHz, predicted Y1 would
land on it. Measured **4.7041 ns / 212.6 MHz** — 1.012 ns short.

The declared falsifier was "a result materially *above* 278 MHz means the adder
segment itself moved under re-placement." It came in *below* the range instead, and
the path report says the adder did not move at all: **3.299 → 3.315 ns**.

| region | Y0 | Y1 |
|---|---|---|
| `ccnt` fanout + operand/epilogue muxes | 0.952 ns | 1.087 ns |
| `fp8_mul` | 1.006 ns | **0 — registered out** |
| `fp32_add` | 3.299 ns | 3.315 ns |
| **data path from Q** | **5.257 ns** | **4.402 ns** |

The register did exactly what it was built to do. The floor was wrong about **which
path**: it assumed `pr → fp32_add → lacc`, and the worst path launches from
**`ccnt[2]`**, spends 1.087 ns in a buffer tree and through mux *select* pins, and
only then reaches the adder. A data-side register cannot shorten a path that arrives
at a mux on its control input.

### X5 closes, and its "CANNOT reach" section was wrong

X5 declared `lacc → fp32_add → lacc` to be the floor. That loop is irreducible, and
it is **not what binds**. All three routed runs — p1, Y0, Y1 — launch from `ccnt`, at
both `PIPE` settings and on both platforms; only the lane moves with placement (p1
lane 1, Y0 lane 2, Y1 lane 0). The generation was right about the arithmetic and
wrong about the topology.

Prediction 4 — that a further datapath rung is worthless — **stands, and for a
better reason than the one given.** It was argued from headroom: 2.361 ns of
feed-forward against a 3.692 ns loop. The real reason is that the loop was never the
limiter, so registering more of the datapath cannot help either. `PIPE=2` is
correctly absent from the RTL.

**Why this is a Y-level failure and not an X-level one.** The rule at the top of this
document says a single Y failing implicates the design and a whole row going flat
implicates the harness. Y1 did not go flat — +20.5% clock, −65% power, 3.28× energy
efficiency, and a Pareto move on every axis but flops. What failed was the
generation's *model* of where the time goes, and X5's own report list is what caught
it: reading the startpoint, which X1 added to the harness after `repair_timing`'s
per-iteration WNS produced two wrong answers in a row. A generation that had only
watched fmax would have recorded +20.5% and moved on with the wrong mental model
intact.

### What X6 must be, and it is not more of this

**Register the control that `ccnt` drives.** `ep0/ep1/ep2` are decoded from `ccnt`
and fan out to the mux in front of 1024 adders across a 3065 µm die, which is what
the 1.087 ns buys. Registered and replicated near its consumers, the binding path
would begin adjacent to the adder: ~0.34 ns of register overhead + ~3.32 ns of adder
+ tail ≈ **3.7 ns / ~270 MHz**, for a few hundred flops against the 16,384 this rung
cost.

Note that this is the number X5 predicted for Y1 — the floor was right about the
*value* and wrong about which change reaches it. That is worth stating plainly rather
than quietly reusing the figure.

X6 is a **control**-pipelining generation. The fix family is different from X5's, the
report it reads is the path startpoint rather than the segment table, and its
declared limit is the same adder loop — this time with evidence that the loop is
actually what is left.

## X6 — completed MAC throughput, with registered epilogue control

Declared 2026-09-06, before either X6 trial. Branch:
`exp/fp8-x6-throughput`. This generation targets `amx_fp8` only.

### Objective and scope

Rank **completed resident-tile MAC throughput**, not MHz or active-cycle peak:

```
GMAC/s = 16384 * regreg_fmax_MHz / (1000 * initiation_interval_cycles)
```

The initiation interval must be measured by consecutive operations with no
readback or reload between them. Report start-to-completion latency separately.
This excludes tile transfers; it is not end-to-end memory-system throughput.
Keep all four FP8 format combinations, per-lane k order, balanced epilogue,
RNE/DAZ/FTZ, and canonical NaN behavior unchanged. No reassociation of sums.

The existing X5-Y1 artifacts give 212.6 MHz and a documented 21-cycle interval,
or 165.9 GMAC/s. The new back-to-back test must verify that interval rather than
infer it from the old single-operation latency checker.

### Evidence, hypothesis, and limits

`work/reports/nangate45/fp8_x5y1/base/6_finish.rpt` names `ccnt[2]` as the
worst reg-to-reg startpoint and lane 0 of cell (14,12) as the endpoint. Decode,
distribution buffers, and three mux levels precede `fp32_add`. X5's region
attribution assigns 1.087 ns to control/muxes and 3.315 ns to the adder.

Predecode the **next** epilogue phase and register three control bits per output
cell (256 copies), using them for both operand selection and epilogue writes.
This retimes control without shifting the phase schedule: 21 cycles stays 21.
The 768 registers must survive synthesis; keeping only a wire name does not
prevent identical drivers from merging. Check the synthesized register count.
Placement locality is a hypothesis, not something RTL hierarchy guarantees.

Prediction: Y1 improves GMAC/s and moves the startpoint off `ccnt`'s epilogue
decode. The prior 3.692 ns loop estimate corresponds to roughly 211 GMAC/s at
II=21, an **optimistic bound, not a promised result**: local clock-to-Q, mux
levels, lane-to-lane epilogue paths, and routing still cost time. The 4.00 ns
target may saturate before this bound. If it does, a later matched-target pair
must test tighter timing; no extra run is implicitly authorized by this pair.

This generation cannot shorten the FP32 feedback arithmetic or hide epilogue,
launch, or memory-transfer cycles. Those are separate experiments.

### The two-run plan

| trial | CTRL_REG | purpose | PIPE | RD_REG | target ns | util | hold margin ns |
|---|---|---|---|---|---|---|---|
| X6-Y0 | 0 | current architecture, re-baselined on the same source and host settings | 1 | 1 | 4.00 | 40 | 0.05 |
| X6-Y1 | 1 | next-phase control registered per cell; arithmetic and interval unchanged | 1 | 1 | 4.00 | 40 | 0.05 |

Expected storage: 74,252 flip-flops for Y0; 75,020 for Y1 (+768). Check the
specific control-register population as well as total storage, since the usual
1% total-count tolerance is too broad to establish this change reliably.

Run at most these **two physical flows concurrently**, each with `NUM_CORES=32`.
Both use identical toolchain, constraints, arithmetic, and thread limits.
Use distinct `fp8_x6y0` and `fp8_x6y1` artifact directories and frozen source
snapshots. Preserve all X5 artifacts and append results, including failures.

### Gates and result interpretation

Before launch: leaf arithmetic regression; all PIPE/RD_REG/CTRL_REG states;
unchanged O1 ordering test; earliest-legal back-to-back operations; control-phase
equivalence checks; synthesized control-register preservation. Each physical run
also repeats its own simulation gate against its frozen RTL.

Every completed row must report measured II and latency, reg-to-reg MHz, GMAC/s,
limiter start/endpoints, setup and hold, DRC, GDS presence, area, and power.
An implied frequency from negative target slack is still an estimate from STA,
not a timing-closed operating point. No winner is signoff-clean merely because
its DRC count is zero. Missing correctness, interval, or artifact evidence is
not a throughput result. Report area/power tradeoffs without treating either
as the primary objective or pretending this is an unconstrained replication
contest.

### X6 preflight, before launch

Both routed configurations pass 30/30 array checks, including O1 and the new Q1
four-instruction resident stream (all four op encodings): **II=21, actual
start-to-done latency=20**. The old single-operation checker reports 21 because
it observes `done` before NBA updates; that convention must not be confused
with timestamped latency. All 38 `sim-matrix` configurations pass, including
both leaf arithmetic regressions and all eight FP8 parameter combinations.

A lightweight synthesis plus Nangate45 flop mapping retains **768 control
drivers and 75,020 total flops**. The existing X5-Y1 mapped baseline has 74,252.
This preflight is a structural check, **not a PPA measurement**. The first
checker incorrectly relied on ORFS-style register instance names; generic
synthesis used anonymous names. It now inspects actual mapped-flop Q
connections and verifies one driver for each of the 768 cell/bit coordinates.
Seven isolated harness tests pass, including missing/duplicate replica rejection
and refusal to report throughput without both measured II and timing evidence.
The full ORFS synthesis repeats the exact replica gate before placement.

### X6-Y0 / X6-Y1 result — the first pair completed

Both jobs exited zero (Y0: 2026-09-06 23:36 UTC; Y1: 2026-09-07 01:35 UTC).
`CTRL_REG=0/1` gives **171.113 / 193.428 GMAC/s**, respectively, at measured
II=21 and actual start-to-done latency=20: **+13.04% completed MAC throughput**.
Area falls 8.24%, reported power falls 11.15%, and storage rises by the predicted
768 flops. Both hold checks pass, both routed DRC reports are empty and both
final GDS files exist. The full rows and path attribution are appended to
`EXPERIMENTS.md` and summarized in `experiments/RESULTS.md`.

The startpoint prediction is confirmed: `ccnt[2]` is replaced by a local
`ep_ctrl[0]` launching through the adder into lane 2 of the same cell. The
estimated control/mux segment falls 0.85 → 0.14 ns, while the adder segment
grows 3.29 → 3.49 ns (two-decimal report precision). This is progress, not a
flat row, and **not proof that the feedback loop is now the limiter**.

Y1's setup slack is −0.0335012 ns (174 violations), TNS −1.29961. Therefore
193.428 GMAC/s is an STA-implied estimate, not a timing-closed 250 MHz result.
The near-target result leaves optimization headroom untested. The next useful
question is whether a tighter timing objective improves the same RTL further,
before spending another cycle or changing arithmetic. This paragraph records
the finding; it does not launch another experiment or alter the predeclared pair.

### X6-Y2 / X6-Y3 — timing-target sweep

Declared 2026-09-07, after user approval and before either trial starts. The
first pair has completed; this is the next **two** runs, not an additional
concurrent pair. X7 scheduling changes remain conditional on what these show.

Hypothesis: X6-Y1's 4.00 ns target, −0.0335012 ns setup slack and −1.29961 TNS
leave optimizer effort untested. A tighter target may improve the same RTL's
completed MAC throughput without adding latency or changing arithmetic.

| trial | CTRL_REG | PIPE | RD_REG | target ns | throughput if target closes |
|---|---|---|---|---|---|
| X6-Y2 | 1 | 1 | 1 | 3.80 | 205.313 GMAC/s at II=21 |
| X6-Y3 | 1 | 1 | 1 | 3.60 | 216.720 GMAC/s at II=21 |

These are targets, **not predicted or measured results**. Both retain the X6-Y1
RTL byte-for-byte (`sha256[0:16] = 7da8ee7a89063d22`), the same testbench,
flow templates and tool paths, 40% utilization, 0.05 ns hold margin, and
`NUM_CORES=32`. The target changes both the SDC and ABC objective together.
Expected storage remains 75,020 flops, including 768 preserved local control
drivers. The sim gate must again measure II=21 and actual latency=20.

This pair measures **timing-target/optimization effort**, not the causal effect
of `CTRL_REG`; the first matched-target pair already measured that change.
Compare Y1/Y2/Y3 on GMAC/s, reg-to-reg slack and path start/endpoints, area,
power, hold, DRC and GDS. Label negative-slack throughput as STA-implied; a
chosen operating period still needs setup/hold closure. A growing timing
violation budget and area/power cost with little throughput movement would
support ending target tightening, not justify claiming a faster chip.

Use isolated `fp8_x6y2` / `fp8_x6y3` artifacts and a new frozen snapshot at
`work/campaigns/x6_timing/source/`. The launcher must reject reuse, verify the
prior pair has exited, and refuse RTL/testbench/template/tool-path drift from
the first snapshot. Each full synthesis repeats the control-driver gate.
Only these two flows are launched; no X7 RTL or physical run is included.

### X6-Y2 / X6-Y3 result — timing effort has reached a practical plateau

Both trials exited zero. At targets 3.80 / 3.60 ns they produced **199.992 /
200.208 GMAC/s**, II=21, latency=20. The last 0.20 ns of target tightening bought
only **0.108%** throughput while power rose 14.0044 → 16.0663 W and area rose
4176090 → 4533970 µm². Setup TNS worsened −293.433 → −4335.23; both targets
remain unmet. Hold passes and DRC=0 for both. The startpoints are product `pr`
in Y2 and local `ep_ctrl` in Y3, not a demonstrated accumulator-feedback limit.

End this target sweep at Y2's practical operating point. This does not prove an
absolute arithmetic floor; it establishes diminishing returns from this fix
family. X7 changes the evidence and fix family to scheduling/operation overlap.

## X7 — remove the resident-operation launch bubble

Declared 2026-09-08 before RTL changes or trials. Objective remains completed
resident-tile GMAC/s, not peak active-cycle MAC rate. Keep the X6 arithmetic,
per-lane k order, balanced FP32 epilogue, DAZ/FTZ/RNE and canonical NaN policy.

### Evidence and hypothesis

X6-Y2 reaches 199.992 GMAC/s at 256.3 MHz with II=21. Only 16 of the 21 cycles
issue useful products. The controller finishes EP2, goes idle, and uses the next
edge solely to clear lanes and launch again. EP2 reads the OLD lane result to
update C, so nonblocking writes can clear those lanes for the next instruction
on that same edge. No FP32 operation needs to move or be reassociated.

Hypothesis: remove this one idle/launch cycle, reaching II=20 at `PIPE=1`, while
single-operation start-to-done latency remains 20. At unchanged clock this is
**+5%**, about 210 GMAC/s. A clock regression of 4.76% erases the entire gain;
rank routed GMAC/s, not the prettier II alone. Both runs use a 3.80 ns target,
the lower-cost X6 point, with 40% utilization, hold margin 0.05 ns, 32 threads.

### Interface contract — explicit completion-edge acceptance

Add `start_ready` to both parameter states. A request is accepted only on a
rising edge where `start && start_ready` and reset is inactive. The caller must
hold `start` and `op` stable until that edge; there is **no internal request
queue**. Pulsing start while not ready does not enqueue anything. Tile writes
remain forbidden while executing; this experiment is for resident operands.

- `CHAIN=0`: ready only in IDLE, preserving legacy start behavior; II=20+PIPE.
- `CHAIN=1`: ready also on the current instruction's EP2 cycle. On acceptance,
  commit OLD C, clear lane accumulators, latch the NEW op and reset ccnt on the
  completion edge; II=19+PIPE. `done` still reports the old completion and may
  coincide with `busy=1` for the new instruction. No request means return idle.
- Reset deasserts ready and aborts any in-flight operation; no unaccepted
  request is retained inside the block. The caller cancels or holds its own
  pending request explicitly. Legacy callers waiting for !busy still work but
  do not gain the completion-edge throughput.

The product-valid pipeline and local epilogue controls must be clear of the old
instruction at rollover. Tests must check every completion, not just the final
C after a long stream, and must not use internal phase counters to time requests.

### The first X7 pair

| trial | CHAIN | PIPE | RD_REG | CTRL_REG | target ns | expected II | latency |
|---|---|---|---|---|---|---|---|
| X7-Y0 | 0 | 1 | 1 | 1 | 3.80 | 21 | 20 |
| X7-Y1 | 1 | 1 | 1 | 1 | 3.80 | 20 | 20 |

Y0 re-baselines the shared new port and source bytes. No intentional storage is
added by CHAIN: expected total remains about 75,020 flops, with exactly 768
local control flops; verify synthesis rather than infer the change from count.
Parameter plumbing and measured II must establish that CHAIN actually reached
the build. Use separate `fp8_x7y0` / `fp8_x7y1` artifacts and a frozen source
snapshot. Launch at most these two physical flows, after both X6 jobs finish.

### Gates, limits and stop rule

Before launch: all 16 PIPE/RD_REG/CTRL_REG/CHAIN combinations, leaf arithmetic,
the unchanged single-operation regressions and O1, per-completion C checks on
a held-valid stream with all four formats, simultaneous done/new acceptance,
busy-start pulses, reset during a waiting request, stop/drain/restart and a
mutation that disables rollover. Recheck II from the trial's simulation record.

This generation cannot speed up FP32 addition, remove product flush/epilogue
cycles yet, or hide tile transfers. CHAIN's clear/acceptance fanout may cost
clock or area; a lower II without higher GMAC/s is a negative result. More
aggressive epilogue overlap is a later rung, not bundled into this pair. Report
setup/hold, DRC, GDS, limiter path and area/power with throughput; negative-slack
rates remain STA-implied, not timing-closed operating points.

### X7 preflight, before launch

All sixteen PIPE/RD_REG/CTRL_REG/CHAIN combinations pass 33 array checks. At
the routed settings, the common held-valid driver measures II=21 for CHAIN=0
and II=20 for CHAIN=1, with latency=20 for both. The chained stream observes
three simultaneous completion/new-acceptance edges and checks every C result.
Busy-pulse rejection, reset cancellation, fresh restart and O1 all pass.

A mutation disabling the actual completion-edge restart, while leaving ready
asserted, fails Q1 with 988 errors and reports RESULT: FAIL; the remaining 32
checks pass. This demonstrates why isolated operations alone cannot validate
the new handshake. Lightweight synthesis and Nangate45 flop mapping retain
75,020 flops, including all 768 local control drivers: no storage was added.
Seven isolated harness tests pass, including rejection of a CHAIN=1 record
whose measured initiation interval is still 21. Both full flows will repeat
their simulation and mapped-control checks against the frozen source.

### X7-Y0 / X7-Y1 result — the interval fell, and MHz could not see it

Both trials exited zero at the declared 3.80 ns target, same RTL bytes
(`sha256[0:16] = 2d786dd038143aa3`), one parameter apart. Both have GDS, DRC=0
and zero hold violations.

| | Y0 `CHAIN=0` | Y1 `CHAIN=1` | Δ |
|---|---|---|---|
| reg→reg MHz | 256.7 | 256.9 | **+0.08%** |
| initiation interval | 21 | **20** | −1 cycle |
| start-to-done latency | 20 | 20 | unchanged |
| **completed GMAC/s** | 200.265 | **210.467** | **+5.094%** |
| flip-flops | 75,020 | 75,020 | **0** |
| local control drivers | 768 | 768 | **0** |
| stdcells | 3,213,431 | 3,207,438 | −0.19% |
| power W | 13.8164 | 14.4541 | +4.62% |
| energy | 14.495 GMAC/J | 14.561 GMAC/J | +0.46% |

**Every prediction held, including the number.** The declaration said II=20,
latency unchanged at 20, and "+5%, about 210 GMAC/s". Measured 210.467. It named
its own falsifier — "a clock regression of 4.76% erases the entire gain" — and the
clock moved +0.08%, so the result survives the test it set itself. Storage is
exactly unchanged and verified against both routed netlists, not inferred from a
total: `CHAIN` is a handshake and a rollover, not a register.

**This row is the payoff for X6's metric change, and it is worth being explicit
about why.** On MHz the pair is flat — +0.2 MHz, 0.08%, indistinguishable from
noise — and a generation ranking frequency would have recorded a failed rung and
moved to a different fix family. On completed throughput it is +5.094%. That is
X4's lesson in a third dimension: X1–X3 could not see a 19.2× power win, X5 nearly
credited an area saving to the wrong mechanism, and MHz cannot see an initiation
interval at all. The difference here is that the harness was **already watching**
for it — X6 declared the throughput metric before either of its own trials ran, so
X7 measured the right quantity by construction rather than recovering it at close.

**Why X7's prediction landed when X5's missed by 1.012 ns.** X7 predicted a
*cycle count*, which is a property of the RTL that simulation settles before any
physical flow runs — the preflight measured II=21/20 on a held-valid stream and
the routed rows merely confirmed it. X5 predicted a *routed delay*, which depends
on where the tool decides the worst path is, and the tool chose a path X5 had not
considered. Predictions about structure are cheap to make correct; predictions
about placement are not. That is a harness-level lesson, not a design one.

Costs, stated plainly: energy per MAC is **flat** (+0.46%, inside this flow's
power noise), so the throughput comes from using hardware that was already idle
rather than from more hardware. Neither row closes setup, so both rates remain
STA-implied at a register-to-register clock and neither is a timing-closed
operating point.

X7's stop rule was "a lower II without higher GMAC/s is a negative result." That
is not what happened, so this fix family is **not** exhausted. What remains idle
is the epilogue's three cycles; overlapping those is a further rung and a
different generation, not an extension of this pair.

### Instrument change recorded: the reg→reg STA query was wrong before X6

`scripts/sta_limiter.sh` changed its `REGREG` query during this branch, and it is
recorded here because it silently affects how earlier rows compare to later ones:

```diff
-report_checks -path_delay max -to [all_registers -data_pins] ...
+report_checks -path_delay max -from [all_registers -clock_pins] -to [all_registers -data_pins] ...
```

The old query constrained only the **endpoint**. Any path *ending* at a register
data pin qualified — including paths starting at an **input port**, which are not
register-to-register and do not have the clock-insertion-delay cancellation that
is the entire justification for preferring `reg→reg fmax` over `implied_fmax`.
With 512-bit `tile_wdata` feeding tile registers directly, such paths are real
candidates, not hypothetical. The new query constrains both ends. **The fix is
correct and the old number was the defective one.**

**Immaterial to every X6 and X7 row.** All six have `limiter_class = reg->reg`
with identical overall and reg→reg startpoints and endpoints, so both queries
return the same path and the same slack. Verified in each `limiter.json`.

**Material, and now unverifiable, for four `amx_tdpbssd` rows.** X2-Y2, X2-Y4,
X3-Y0 and X4-Y0 were limited at an I/O boundary, so their headline figures were
*substituted* from the reg→reg number: 600.3, 643.3, 658.7 and **698.9 MHz — the
figure quoted as this campaign's operating point in `README.md`,
`experiments/RESULTS.md` and `EXPERIMENTS.md`**. Those were computed with the
loose query. Whether any of them included an input-port launch cannot now be
determined: X4's "Recovered, not re-measured" recovery was legitimate precisely
because every `6_final.odb/.sdc/.spef` was still on disk, and those
`amx_tdpbssd` artifacts have since been deleted. `work/results/nangate45/` holds
only `fp8*` and `my_chip_n4_c1`.

So those four figures are **labelled, not corrected**: measured with a query that
could admit an input-port launch, on a design whose input ports feed registers
directly, with the evidence to check now gone. Re-deriving them means re-running
four ~40-minute flows. Nothing in X5, X6 or X7 depends on them — the `amx_fp8`
campaign is self-contained and post-fix — but the INT8-vs-FP8 comparison in
`EXPERIMENTS.md` uses 698.9 MHz as its INT8 anchor, so that ratio inherits the
same caveat and should be read as approximate until the row is re-run.
