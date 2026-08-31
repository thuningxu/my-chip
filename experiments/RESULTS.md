# X-Y hillclimb results — `amx_tdpbssd`

Generated from `experiments/trials.jsonl`. Regenerate the tables with
`python3 scripts/trials.py`. Nothing here is transcribed by hand: every figure is
read from `6_report.json`, counted in `6_final.v`, or produced by
`scripts/sta_limiter.sh` against the routed database.

**X** = harness generation (how the design is reasoned about: which reports get
read, which bottleneck gets blamed, which family of fix gets proposed).
**Y** = an RTL attempt inside that generation. A Y failing implicates the design;
an X row going flat implicates the harness.

## Read this first: which frequency column is real

`implied_fmax = 1000/(target − setup_WS)` is a statement about the **hardware**
only when the limiting path runs register-to-register. `constraint.sdc.in` budgets
I/O as a fraction of the period —

```tcl
set_input_delay  [expr $clk_period * 0.2] ...
set_output_delay [expr $clk_period * 0.2] ...
```

— so for a path ending at an output port the required time is `0.8P − 0.1`, giving
`implied period = 0.2P + 0.1 + arrival`. The `0.2P` term **shrinks as the target
tightens**, so the reported frequency rises with byte-identical hardware: X3-Y0
reads 620.7 MHz at P=1.60 and would read 670.7 at P=1.00 with nothing changed. A
combinational input→output path is charged `0.4P + 0.1` — twice as bad.

Three of the nine rows below were limited that way. Their `reported` figure is
struck through. **`reg→reg fmax` is the objective this project ranks on**, because
launch and capture clock insertion delay cancel across a flop-to-flop path, so it
carries no period-scaled term.

## Every trial, in order run

| trial | PIPE/RD | target | limiter | reported | **reg→reg fmax** | reg→reg WS | TNS | hold | flops | cells | repair buf | area µm² | DRC |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| X1Y0 | 0/0 | 2.80 | reg->reg | 350.1 | **350.1** | -0.0565 | -36.0 | +0.0399 | 24584 | 509176 | 116591 | 1086640 | 0 |
| **X1Y1** | 1/0 | 2.80 | — | **FAIL** | — | — | — | — | — | — | — | — | — |
| X1Y1 | 1/0 | 2.80 | reg->reg | 350.4 | **350.4** | -0.0539 | -0.8 | +0.0402 | 29194 | 457390 | 74257 | 920220 | 0 |
| X2Y0 | 1/0 | 2.00 | reg->reg | 404.8 | **404.8** | -0.4702 | -1067.8 | +0.0227 | 29194 | 492398 | 109346 | 971277 | 0 |
| X2Y1 | 2/0 | 1.80 | reg->reg | 482.7 | **482.7** | -0.2717 | -906.0 | +0.0353 | 45579 | 577348 | 127433 | 1074080 | 0 |
| X2Y2 | 3/0 | 1.80 | **IN->OUT** | ~~511.4~~ | **600.3** | +0.1341 | -31.6 | +0.0329 | 46604 | 514700 | 65593 | 1021570 | 0 |
| X2Y3 | 2/0 | 1.50 | reg->reg | 505.4 | **505.4** | -0.4788 | -3549.8 | +0.0236 | 45579 | 583132 | 133178 | 1081950 | 0 |
| X2Y4 | 3/0 | 1.60 | **OUT-PORT** | ~~514.9~~ | **643.3** | +0.0456 | -114.6 | +0.0285 | 46604 | 519051 | 69945 | 1029960 | 0 |
| X3Y0 | 3/1 | 1.60 | **OUT-PORT** | ~~620.8~~ | **658.7** | +0.0818 | -0.0 | +0.0307 | 47116 | 522690 | 69794 | 1029030 | 0 |

`reg→reg WS` is positive where the compute datapath **met** its target and the
reported number was measuring the pad boundary instead.

## Per RTL variant — one change per rung

Ladder economics, best result per RTL variant
(ranked on reg->reg fmax -- see headline() for why not implied_fmax)

variant   best at  fmax MHz  d fmax    flops    d flops   MHz per 1k flops   limiter
P0/RD0    X1Y0     350.1     -         24584    -                            reg->reg
P1/RD0    X2Y0     404.8     +54.7     29194    +4610     +11.87             reg->reg
P2/RD0    X2Y3     505.4     +100.6    45579    +16385    +6.14              reg->reg
P3/RD0    X2Y4     643.3     +137.9    46604    +1025     +134.54            OUT-PORT
P3/RD1    X3Y0     658.7     +15.4     47116    +512      +30.08             OUT-PORT

Only the best target per variant is used: a trial measures an
(RTL, target) pair, and a saturated target measures the target.
CAVEAT: rungs come from different targets, so effort still differs.
Only equal-target pairs are like-for-like comparisons.


## The only like-for-like comparisons — equal target, one variable

| pair | target | change | Δ reg→reg fmax |
|---|---|---|---|
| X1-Y0 → X1-Y1 | 2.80 | `PIPE` 0→1 | **+0.3** (saturated: TNS −0.8, the tool met its target and stopped) |
| X2-Y1 → X2-Y2 | 1.80 | `PIPE` 2→3 | **+117.6** (482.7 → 600.3) |
| X2-Y4 → X3-Y0 | 1.60 | `RD_REG` 0→1 | **+15.4** (643.3 → 658.7) |

Every other pairing in this file crosses targets, and the tool works to whatever
target it is given, so those deltas mix design improvement with optimiser effort.

## The generations

| X | declared | what it produced |
|---|---|---|
| **X1** | Read `FLW-0009`; blame the single combinational path `ccnt → mux → 8×8 multiply → tree → 33-bit add → fold`; fix by pipelining. Period **fixed at 2.80**, hold margin 0.05 | Hold closed (−0.0349/34 viol → +0.0399/0) with **no RTL change**, and −47% power for the same speed. But it reported `PIPE=1` as **+0.3 MHz** — its fixed period hid a 15.6% gain |
| **X2** | Same reports, bottleneck and fix family. Changed the **procedure**: period derived per trial, **TNS read as the saturation signal**, clock skew tracked | Revealed `PIPE=1`'s real gain (+54.7) and took the ladder to 643.3 MHz — but two of its five rows were secretly limited by I/O paths, which it had no way to see |
| **X3** | Read the **path**, not just the slack. Blamed the readback port: `a_flat → 5 mux levels → rd_data`, 47% of its arrival being uncancellable clock insertion delay. Fix by registering `rd_data` | The fix worked (setup −0.342 → −0.011, TNS −114.6 → −0.013) and **exposed the metric defect** above. Prediction on flop count exact; prediction on where the path would move wrong — it stayed on `rd_data`, just shorter |
| **X4** | `sta_limiter.sh` **first**: limiter class + reg→reg slack, before any frequency is quoted. Blame the multiplier carry chain. Fix by carry-save accumulation. Each variant iterated to its **own fixed point** | in progress |

## Findings that survive

1. **`PIPE=3` at equal target is worth +117.6 MHz** (482.7 → 600.3 at 1.80 ns),
   not the +28.7 the old metric showed. `PIPE` is cumulative — **do not stop at
   `PIPE=2`**.
2. **Adding flops made the design smaller, twice.** `PIPE=3` over `PIPE=2`:
   `timing_repair_buffer` 127,433 → 65,593 and 64,081 fewer cells. `RD_REG=1` over
   `RD_REG=0`: −930 µm² and −0.118 W for +512 flops. A shortened stage stops
   needing to be buffered into shape.
3. **The compute datapath is no longer the bottleneck.** At 1.60 ns the only
   violated path in X3-Y0 is the output port; the worst reg→reg path has +0.0818 ns
   of slack.
4. **The tightest real path is the multiplier carry chain**
   (`a_dw_r → 6× FA/HA → ~8 levels AOI/OAI → pr`), in both X2-Y4 and X3-Y0 — the
   same limiter survived the `RD_REG` change. **Not** the accumulate feedback loop,
   which X1 predicted would become the floor and which has more slack.
5. **Saturation (`SAT=1`) costs 17,588 routed cells — 23× the coarse-synth
   prediction of 768** — because the fold mux sits inside the accumulate feedback
   loop. Zero flops, no measurable frequency cost.
6. **Hold met and DRC clean on every row that produced metrics**, at every rung.
7. **Every fmax here is a lower bound.** `repair_timing` works *to* the target, so
   a met target measures the target. Rows sharing a target stay comparable.

## Claims retracted

| claimed | actual | why |
|---|---|---|
| `PIPE=1` is worth +0.3 MHz | **+54.7** | X1's fixed period saturated the measurement |
| `PIPE=3` is best value at +28.00 MHz/1k flops, 5.9× `PIPE=2` | **+6.14 for `PIPE=2`, `PIPE=1` best at +11.87** | compared `PIPE=3` against `PIPE=2`'s floor |
| `FLW-0009` shifts a consistent −0.032 ns | ranges 0 to −0.033 | fitted to two points; the third broke it |
| `PIPE=2`'s gain will be smaller than `PIPE=1`'s | larger (+100.6 vs +54.7) | used gate count as a proxy for logic depth |
| **X2-Y2 is 511.4 MHz** | **600.3** | limiter was a combinational input→output path burning 46% of the period on I/O model. `PIPE=3` was undersold ~90 MHz for the rest of the campaign |
| **X2-Y4 (514.9) beat X2-Y2 (511.4)** | **void** — 643.3 @1.60 vs 600.3 @1.80, same RTL | different targets; the gap is optimiser effort, not design |
| **`RD_REG` is worth +105.9 MHz** | **+15.4** of compute | ~85% of the reported gain was removing a measurement artifact. `RD_REG` is still what lets the design close at 1.60 at all |
| **the ladder is 350.1 → 620.8 = +47.1%** | not like-for-like | spans 2.80 → 1.60 ns; effort differs by target even among clean rows |
| **`PIPE=3` is worth +153.3 MHz for +1,537 flops** | **+137.9 for +1,025** | the ladder grouped by `PIPE` alone, so `RD_REG=1`'s gain was credited to the third pipeline stage |

## Tooling defects found — twelve, against zero RTL defects

| defect | caught by |
|---|---|
| sim/synth parameter drift: `PIPE` never reached `TOP_PARAMS`, so a trial built a duplicate of its baseline | the flop-count prediction (+1 where +4,608 was due) |
| flat-row diagnostic required *every* step flat, keeping dead rows alive | synthetic test data |
| prediction check was exact-match, would false-fail correct trials | a legitimate 2-flop slip |
| edited `trial.sh` while it was running; bash resumed at a shifted offset | the crash on an otherwise-valid run |
| `FLW-0009` assumed to be the final slack | cross-check against routed values |
| `trials.jsonl` append not atomic (1,469-byte records, 512-byte `PIPE_BUF`) | checking the actual limit before parallelising |
| ladder economics compared per-trial, splitting one change across two rows | the tool's own output |
| ladder economics compared variants at unequal effort | the `PIPE=3` calibration |
| **testbench never checked fold ORDER**, only that the fold happened | RTL mutation that survived everything |
| **the headline metric was inflated by a period-scaled I/O budget, and no row recorded where its limiting path ended** | reading the X3-Y0 path report instead of only its slack |
| **ladder grouped by `PIPE`, crediting `RD_REG`'s gain to the third pipeline stage** | an implausible +99.74 MHz/1k flops |
| **`mktemp /tmp/f.XXXXXX.tcl` — macOS only substitutes trailing X's, so concurrent calls collide** | one survivor per batch, which I first misdiagnosed as OOM |

The RTL has been correct at all four `PIPE` levels and both `RD_REG` states since it
was written — 16/16 at every configuration, and every flop prediction exact. Every
defect lived in how the design was measured or reasoned about, which is the
Meta-Harness thesis holding up under its own test.
