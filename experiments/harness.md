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

Target design: `amx_tdpbssd` (Intel AMX `TDPBSSD`, INT8, 1024 multipliers).
Harness: Claude Code only. One agent runs both loops.

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
