# X-Y hillclimb results — `amx_tdpbssd`

Generated from `experiments/trials.jsonl`. Regenerate the tables with
`python3 scripts/trials.py`. Nothing here is transcribed by hand: every figure is
read from `6_report.json`, counted in `6_final.v`, or produced by
`scripts/sta_limiter.sh` against the routed database.

**X** = harness generation (which reports get read, which bottleneck gets blamed,
which family of fix gets proposed). **Y** = an RTL attempt inside that generation.
A Y failing implicates the design; an X row going flat implicates the harness.

**Status: closed at X4.** The design is limited by a multiplier carry-propagate at
**~703 MHz** and is efficient at **~699 MHz / 2.436 W**. Ten trials, one RTL defect
count of zero, twelve tooling defects.

## Read this first: which frequency column is real

`implied_fmax = 1000/(target − setup_WS)` describes the **hardware** only when the
limiting path runs register-to-register. `constraint.sdc.in` budgets I/O as a
fraction of the period, so a path ending at an output port has required time
`0.8P − 0.1`, giving `implied period = 0.2P + 0.1 + arrival`. That `0.2P` term
shrinks as the target tightens, inflating the reported frequency.

Four of the ten rows were limited that way; their `reported` figure is struck
through. **`reg→reg fmax` is the objective**, because launch and capture clock
insertion delay cancel across a flop-to-flop path.

One caveat established by X4-Y0: the output-port `arrival` is **not**
period-independent either (1.191 ns at P=1.60 → 1.085 at P=1.40), so
`implied_fmax` mixes the artifact with real optimisation. The artifact is real; a
clean numeric projection of it is not available.

## Every trial, in order run

| trial | PIPE/RD | target | limiter | reported | **reg→reg fmax** | reg→reg WS | TNS | hold | flops | cells | area µm² | power W | DRC |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| X1Y0 | 0/0 | 2.80 | reg->reg | 350.1 | **350.1** | -0.0565 | -35.96 | +0.0399 | 24584 | 509176 | 1086640 | 19.001 | 0 |
| **X1Y1** | 1/0 | 2.80 | — | **FAIL** | — | — | — | — | — | — | — | — | — |
| X1Y1 | 1/0 | 2.80 | reg->reg | 350.4 | **350.4** | -0.0539 | -0.76 | +0.0402 | 29194 | 457390 | 920220 | 0.992 | 0 |
| X2Y0 | 1/0 | 2.00 | reg->reg | 404.8 | **404.8** | -0.4702 | -1067.83 | +0.0227 | 29194 | 492398 | 971277 | 1.483 | 0 |
| X2Y1 | 2/0 | 1.80 | reg->reg | 482.7 | **482.7** | -0.2717 | -906.03 | +0.0353 | 45579 | 577348 | 1074080 | 1.893 | 0 |
| X2Y2 | 3/0 | 1.80 | **IN->OUT** | ~~511.4~~ | **600.3** | +0.1341 | -31.58 | +0.0329 | 46604 | 514700 | 1021570 | 1.956 | 0 |
| X2Y3 | 2/0 | 1.50 | reg->reg | 505.4 | **505.4** | -0.4788 | -3549.78 | +0.0236 | 45579 | 583132 | 1081950 | 2.296 | 0 |
| X2Y4 | 3/0 | 1.60 | **OUT-PORT** | ~~514.9~~ | **643.3** | +0.0456 | -114.64 | +0.0285 | 46604 | 519051 | 1029960 | 2.217 | 0 |
| X3Y0 | 3/1 | 1.60 | **OUT-PORT** | ~~620.8~~ | **658.7** | +0.0818 | -0.01 | +0.0307 | 47116 | 522690 | 1029030 | 2.098 | 0 |
| X4Y0 | 3/1 | 1.40 | **OUT-PORT** | ~~682.8~~ | **698.9** | -0.0309 | -1.56 | +0.0386 | 47116 | 532445 | 1046050 | 2.436 | 0 |
| X4Y1 | 3/1 | 1.20 | reg->reg | 703.0 | **702.9** | -0.2226 | -558.27 | +0.0330 | 47116 | 567769 | 1088150 | 3.069 | 0 |

Positive `reg→reg WS` means the compute datapath **met** its target and the reported
figure was measuring the pad boundary instead.

## Per RTL variant — one change per rung

Ladder economics, best result per RTL variant
(ranked on reg->reg fmax -- see headline() for why not implied_fmax)

variant   best at  fmax MHz  d fmax    flops    d flops   MHz per 1k flops   limiter
P0/RD0    X1Y0     350.1     -         24584    -                            reg->reg
P1/RD0    X2Y0     404.8     +54.7     29194    +4610     +11.87             reg->reg
P2/RD0    X2Y3     505.4     +100.6    45579    +16385    +6.14              reg->reg
P3/RD0    X2Y4     643.3     +137.9    46604    +1025     +134.54            OUT-PORT
P3/RD1    X4Y1     702.9     +59.6     47116    +512      +116.41            reg->reg

Only the best target per variant is used: a trial measures an
(RTL, target) pair, and a saturated target measures the target.
CAVEAT: rungs come from different targets, so effort still differs.
Only equal-target pairs are like-for-like comparisons.


## The only like-for-like comparisons — equal target, one variable

| pair | target | change | Δ reg→reg fmax |
|---|---|---|---|
| X1-Y0 → X1-Y1 | 2.80 | `PIPE` 0→1 | +0.3 — **but −94.8% power**, see below |
| X2-Y1 → X2-Y2 | 1.80 | `PIPE` 2→3 | **+117.6** (482.7 → 600.3) |
| X2-Y4 → X3-Y0 | 1.60 | `RD_REG` 0→1 | **+15.4** (643.3 → 658.7) |

Every other pairing crosses targets, and the tool works to whatever target it is
given, so those deltas mix design improvement with optimiser effort.

## The two findings that matter for using this design

### 1. Pipelining is a power fix, not a frequency fix

At equal target and equal speed, registering `sum4` cut power **19.2×**:

| | PIPE=0 | PIPE=1 | |
|---|---|---|---|
| power | **19.0014 W** | **0.9921 W** | **−94.8%** |
| cells | 509,176 | 457,390 | −10.2% |
| area µm² | 1,086,640 | 920,220 | −15.3% |
| reg→reg fmax | 350.1 | 350.4 | +0.3 |

`PIPE=0` is one combinational path from `kcnt` through 1024 multipliers to `cacc`;
glitches propagate the full depth and every multiplier output toggles repeatedly
before settling. One register truncates that. **`PIPE=0` was never viable on any
axis** — 6.2× the power of the operating point at half its speed.

### 2. 1.40 ns is the knee

| step | Δ reg→reg fmax | Δ power |
|---|---|---|
| 1.60 → 1.40 | +40.2 | +16% |
| 1.40 → 1.20 | **+4.0** | **+26%** |

**Operating point: 1.40 ns, 698.9 MHz, 2.436 W**, where the compute path is not
even binding. Past it, power is the cost and frequency is not the return.

## The generations

| X | declared | what it produced |
|---|---|---|
| **X1** | Read `FLW-0009`; blame the single combinational path; fix by pipelining. Period **fixed at 2.80** | Closed hold with no RTL change. Reported `PIPE=1` as **+0.3 MHz** and called the row flat — while a **19.2× power win** sat in the `6_report.json` it had already parsed |
| **X2** | Same blame and fix family; changed the **procedure**: period per trial, TNS as the saturation signal | Revealed `PIPE=1`'s real gain and reached 643.3 MHz — but two of its rows were secretly I/O-limited, which it had no way to see |
| **X3** | Read the **path**, not just the slack. Blame the readback port; register `rd_data` | The fix worked (setup −0.342 → −0.011) and **exposed the metric defect**. Flop prediction exact; path-movement prediction wrong |
| **X4** | `sta_limiter.sh` first: limiter class before any frequency is quoted. Blame the multiplier carry chain; iterate each variant to its own fixed point | **Refuted its own premise** (Y0: the chain was effort-limited, +40.2 MHz with no RTL change), then **confirmed the wall** (Y1: TNS ×357 with the objective stalled at +4.0). Closed without spending a Y on carry-save |

## Why X4 closed instead of building carry-save

The binding path is `pr[14]` on all three X3/X4 rows:
`a_dw_r → 6× FA/HA → ~8 levels AOI21/OAI21 → pr[14]` — partial-product reduction
then the multiplier's final **carry-propagate adder**. So X4's declared fix
("carry-save **accumulation**") named the wrong stage: it is **multiply→`pr`**, not
the accumulate loop, which has more slack.

1. **`SAT=1` structurally blocks full carry-save.** The fold must clamp once per
   k-step against the true value, so the accumulator cannot stay redundant across
   k-steps. Carry-save can only move the resolve into the tree stage — rebalance,
   not eliminate.
2. **Cost ~+16k flops, +35%** — `pr` is 16,384 flops (16 bits × 1024) and redundant
   form roughly doubles it.
3. **The headroom is ~4 MHz past a knee already located.**

## What this campaign is entitled to claim

The end-to-end **350.1 → 698.9 MHz** spans 2.80 → 1.40 ns. X1-Y0's TNS was −35.96,
i.e. **not** saturated, so 350.1 is the tool's best effort at 2.80 and `PIPE=0`'s
capability at a tighter target is unmeasured — exactly the effect that turned
`PIPE=3`'s 658.7 into 698.9. **"+99.6%" is indicative, not a measurement**, and it
overstates the gain by an unknown amount.

What is measured: the three equal-target deltas above, the 19.2× power reduction,
and the knee.

## Claims retracted

| claimed | actual | why |
|---|---|---|
| `PIPE=1` is worth +0.3 MHz | **+54.7** at a proper target, and **−94.8% power** at the same one | X1's fixed period saturated the measurement, and the harness watched only frequency |
| `PIPE=3` is best value at +28.00 MHz/1k flops, 5.9× `PIPE=2` | **+6.14 for `PIPE=2`, `PIPE=1` best at +11.87** | compared `PIPE=3` against `PIPE=2`'s floor |
| `FLW-0009` shifts a consistent −0.032 ns | ranges 0 to −0.122 | fitted to two points; later rows broke it |
| `PIPE=2`'s gain will be smaller than `PIPE=1`'s | larger (+100.6 vs +54.7) | used gate count as a proxy for logic depth |
| X2-Y2 is 511.4 MHz | **600.3** | limiter was a combinational input→output path burning 46% of the period on I/O model |
| X2-Y4 (514.9) beat X2-Y2 (511.4) | **void** — 643.3 @1.60 vs 600.3 @1.80, same RTL | different targets; the gap is optimiser effort |
| `RD_REG` is worth +105.9 MHz | **+15.4** of compute | ~85% of the reported gain was artifact removal |
| the ladder is 350.1 → 620.8 = +47.1% | not like-for-like, and the endpoint is now 698.9 | spans targets; both endpoints are floors |
| `PIPE=3` is worth +153.3 MHz for +1,537 flops | **+137.9 for +1,025** | the ladder grouped by `PIPE`, crediting `RD_REG`'s gain to the third stage |
| the multiplier carry chain is the binding limit (X4 premise) | **effort-limited** until 1.20 ns | it had +0.0818 ns of slack and had never been observed to fail |
| `implied_fmax` would read 670.7 at P=1.00 with identical hardware | too crude — arrival improves too | treated the output-port arrival as period-independent; it fell 1.191 → 1.085 |

## Tooling defects found — twelve, against zero RTL defects

| defect | caught by |
|---|---|
| sim/synth parameter drift: `PIPE` never reached `TOP_PARAMS` | the flop-count prediction (+1 where +4,608 was due) |
| flat-row diagnostic required *every* step flat, keeping dead rows alive | synthetic test data |
| prediction check was exact-match, would false-fail correct trials | a legitimate 2-flop slip |
| edited `trial.sh` while it was running; bash resumed at a shifted offset | the crash on an otherwise-valid run |
| `FLW-0009` assumed to be the final slack | cross-check against routed values |
| `trials.jsonl` append not atomic (1,469-byte records, 512-byte `PIPE_BUF`) | checking the actual limit before parallelising |
| ladder economics compared per-trial, splitting one change across two rows | the tool's own output |
| ladder economics compared variants at unequal effort | the `PIPE=3` calibration |
| **testbench never checked fold ORDER**, only that the fold happened | RTL mutation that survived everything |
| **headline metric inflated by a period-scaled I/O budget; no row recorded where its limiting path ended** | reading the X3-Y0 path report instead of only its slack |
| **ladder grouped by `PIPE`, crediting `RD_REG`'s gain to the third stage** | an implausible +99.74 MHz/1k flops |
| **`mktemp /tmp/f.XXXXXX.tcl` — macOS substitutes only trailing X's, so concurrent calls collide** | one survivor per batch, first misdiagnosed as OOM |

Plus one defect of a different kind, found at close: **the hillclimb ranked on a
single scalar and therefore could not see a Pareto move.** X1 called its row flat on
+0.3 MHz while holding a 19.2× power reduction in data it had already read.

The RTL has been correct at all four `PIPE` levels and both `RD_REG` states since it
was written — 16/16 at every configuration, every flop prediction exact. Every
defect lived in how the design was measured or reasoned about.
