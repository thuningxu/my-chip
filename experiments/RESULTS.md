# X-Y hillclimb results

Generated from `experiments/trials.jsonl`. Regenerate the tables with
`python3 scripts/trials.py`. Nothing here is transcribed by hand: every figure is
read from `6_report.json`, counted in `6_final.v`, or produced by
`scripts/sta_limiter.sh` against the routed database.

**X** = harness generation (which reports get read, which bottleneck gets blamed,
which family of fix gets proposed). **Y** = an RTL attempt inside that generation.
A Y failing implicates the design; an X row going flat implicates the harness.

**Two designs, kept apart.** X1–X4 climbed **`amx_tdpbssd`**; **X5–X7** climb
**`amx_fp8`**. `trials.py` groups by design, because a delta between two designs is
a number with no referent. Everything below the `amx_tdpbssd` heading is that
campaign; X5, X6 and X7 have their own sections at the end.

**`amx_tdpbssd` status: closed at X4.** The design is limited by a multiplier
carry-propagate at **~703 MHz** and is efficient at **~699 MHz / 2.436 W**. Ten
trials, one RTL defect count of zero, twelve tooling defects. Four of its rows
carry an instrument caveat — see the note at the end of this file.

**`amx_fp8` status: X7 open, seven logged trials.** Best completed resident-tile
throughput is **210.467 GMAC/s** at 256.9 MHz, `PIPE=1 RD_REG=1 CTRL_REG=1
CHAIN=1`, initiation interval 20 and latency 20 — **+45.6%** over X5-Y0's
144.6 GMAC/s. The objective changed at X6 from MHz to completed throughput, and
X7 is the row that proved the change was necessary: **+5.094% throughput at
+0.08% clock**. See [X5](#x5--amx_fp8-registering-the-product),
[X6](#x6--amx_fp8-local-epilogue-control) and
[X7](#x7--amx_fp8-the-initiation-interval).

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

Ladder economics, best result per RTL variant -- amx_tdpbssd
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

Ladder economics -- amx_fp8: 1 measured trial(s). A rung is a comparison
  between two variants, so there is nothing to rank yet.


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

---

## X5 — `amx_fp8`, registering the product

| trial | PIPE/RD | target | limiter | **reg→reg fmax** | reg→reg WS | TNS | hold | cycles | flops | cells | area µm² | power W | DRC |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| — (Y0) | 0/1 | 4.00 | reg->reg | **176.5** | -1.6654 | -59371.7 | +0.0423 | 20 | 57867 | 3974058 | 4745090 | 40.225 | 0 |
| X5Y1 | 1/1 | 4.00 | reg->reg | **212.6** | -0.7041 | -12285.5 | +0.0454 | 21 | 74252 | 3454124 | 4361340 | 14.089 | 0 |

**Y0 is not in `trials.jsonl`, and the dash in its trial column says so.** It was
measured with `measure.sh` directly, under nickname `fp8`, *before* `trial.sh`
supported this design — so it has no trial tag, no goal string and no harness
record. Its numbers are real and its artifacts are on disk; it simply was not run
through the harness. It is **not** re-run as a tagged trial because that would be
~14 hours of place-and-route to buy provenance and no physics: `PIPE=0` on the
current RTL is proven identical to the pre-parameter RTL it measured — same flop
count (57,867) and same cell histogram (26 types, 116,911 cells). Aliasing its
artifact directory to `fp8_x5y0` to manufacture a second record was rejected: a
reader would see two runs where one happened.

That is why the ladder above reports nothing to rank. One logged trial is one
variant, and a rung is a comparison. The comparison itself lives in
[`EXPERIMENTS.md`](../EXPERIMENTS.md#x5-findings--registering-the-product-and-a-floor-that-was-not-the-ceiling)
as rows **p2** and **p3**, which are same-platform, equal-target and one parameter
apart.

### The like-for-like comparison

| pair | target | change | Δ reg→reg fmax | Δ throughput | Δ power |
|---|---|---|---|---|---|
| Y0 → Y1 | 4.00 | `PIPE` 0→1 | **+36.1** (176.5 → 212.6) | **+14.7%** | **−65.0%** |

The frequency and throughput deltas differ because `PIPE=1` costs a cycle, 20 → 21.
**+14.7% is the number**; +20.5% is the clock and would overstate the row.

### X5's own prediction, and how it failed

Declared floor **3.692 ns / 270.9 MHz**, predicted Y1 would reach it. Measured
**4.7041 ns / 212.6 MHz**. The adder segment was predicted correctly (3.299 →
3.315 ns routed), the multiplier was removed as intended (1.006 → 0 ns), and the
floor was still wrong — because it assumed the worst path would launch from the new
product register. It launches from **`ccnt`**, spends 1.087 ns in a control buffer
tree and through mux select pins, and only then enters the adder.

**The accumulate loop X5 named as its floor has never been the limiter** — p1, Y0
and Y1 all launch from `ccnt`, at both `PIPE` settings and on both platforms. X6 is
therefore a *control*-pipelining generation, not another datapath one.

## X6 — `amx_fp8`, local epilogue control

Both runs completed, with identical `PIPE=1 RD_REG=1`, 4.00 ns target, 40%
utilization, 0.05 ns hold margin and 32 threads. Only `CTRL_REG` differs.

| trial | CTRL_REG | reg→reg MHz | measured II | latency cycles | GMAC/s | setup WS ns | TNS | hold WS ns | flops | cells | area µm² | power W | DRC |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| X6Y0 | 0 | 219.3 | 21 | 20 | 171.113 | −0.559528 | −8779.11 | +0.0443583 | 74252 | 3423820 | 4336630 | 14.1854 | 0 |
| X6Y1 | 1 | **247.9** | 21 | 20 | **193.428** | −0.0335012 | −1.29961 | +0.0434359 | 75020 | 2984378 | 3979430 | 12.6034 | 0 |

**+13.04% resident-tile MAC throughput**, −8.24% area and −11.15% reported
power, with 768 more flops. Both hold checks pass, both GDS files exist, and
both jobs exited zero. These throughput figures use STA-implied clocks and
exclude tile transfers. Y1 still has 174 setup violations and is **not**
timing-closed at 250 MHz.

The limiter moves from global `ccnt[2]` to local cell (4,5) `ep_ctrl[0]`, through
the FP32 adder into lane 2. The register-distribution hypothesis worked; the
pure accumulator feedback loop is still not the measured limiter. See
[`EXPERIMENTS.md`](../EXPERIMENTS.md#x6-findings--local-epilogue-control-improves-completed-mac-throughput)
for path-region attribution, buffer-area accounting and artifact provenance.
No further physical runs have been started.

### X6 timing sweep completed

| trial | target ns | reg→reg MHz | II | GMAC/s | setup WS ns | TNS | hold WS ns | area µm² | power W | DRC |
|---|---|---|---|---|---|---|---|---|---|---|
| X6Y2 | 3.80 | 256.3 | 21 | 199.992 | −0.101071 | −293.433 | +0.0438729 | 4176090 | 14.0044 | 0 |
| X6Y3 | 3.60 | 256.6 | 21 | 200.208 | −0.296873 | −4335.23 | +0.0201836 | 4533970 | 16.0663 | 0 |

Both runs succeeded with GDS and hold met, but setup targets unmet. Y3's
**0.108%** throughput increase costs 14.72% more power and 8.57% more area.
X7 uses Y2's 3.80 ns target as its matched baseline setting and changes the
fix family to completion-edge launch. These remain resident-tile STA estimates.

---

## X7 — `amx_fp8`, the initiation interval

Resident-tile completed throughput, ranked. `trials.py --throughput` generates
this; historical rows without a measured initiation interval are omitted rather
than backfilled.

```
  trial      CTRL CHAIN GMAC/s    MHz     II  latency  hold ns   DRC  result
  x7y1       1    1      210.467   256.9  20       20  +0.0453    0  OK
  x7y0       1    0      200.265   256.7  21       20  +0.0412    0  OK
  x6y3       1    0      200.208   256.6  21       20  +0.0202    0  OK
  x6y2       1    0      199.992   256.3  21       20  +0.0439    0  OK
  x6y1       1    0      193.428   247.9  21       20  +0.0434    0  OK
  x6y0       0    0      171.113   219.3  21       20  +0.0444    0  OK
```

### The like-for-like comparisons

| pair | target | change | Δ MHz | Δ GMAC/s |
|---|---|---|---|---|
| X6-Y0 → X6-Y1 | 4.00 | `CTRL_REG` 0→1 | +28.6 (219.3 → 247.9) | **+13.04%** |
| X6-Y2 → X6-Y3 | 3.80 → 3.60 | target only | +0.3 | +0.108% — plateau |
| **X7-Y0 → X7-Y1** | 3.80 | `CHAIN` 0→1 | **+0.2 (flat)** | **+5.094%** |

**Read the last row twice.** `CHAIN` moved the clock 0.08% and completed
throughput 5.094%, because the initiation interval fell 21 → 20 at unchanged
latency. Ranked on MHz it is a flat rung and would have been discarded. This is
why X6 changed the objective from MHz to completed GMAC/s *before* running its own
trials, and X7 is the row that collected on it.

`amx_fp8` end to end, X5-Y0 → X7-Y1: **144.6 → 210.5 GMAC/s, +45.6%**, at
21 → 20 cycles of interval and 40.2 → 14.5 W. Every step is a matched-target pair
except the deliberate 3.80 ns target move, which is labelled.

### One caveat that reaches backwards

`scripts/sta_limiter.sh`'s reg→reg query was corrected during X6 — it previously
constrained only the endpoint, admitting input-port launches that are not
register-to-register. Immaterial to all six X6/X7 rows (verified: overall and
reg→reg share start and endpoints on every one). **Material to the four
`amx_tdpbssd` rows whose headline was substituted from the reg→reg figure**, one
of which is the 698.9 MHz operating point used as the INT8 anchor in
`EXPERIMENTS.md`. Those artifacts are deleted, so the figures are labelled rather
than corrected. See the instrument-change note in
[`harness.md`](harness.md#instrument-change-recorded-the-regreg-sta-query-was-wrong-before-x6).
