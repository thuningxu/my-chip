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
