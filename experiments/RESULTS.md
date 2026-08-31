# X-Y hillclimb results — `amx_tdpbssd`

Generated from `experiments/trials.jsonl`. Regenerate the tables with
`python3 scripts/trials.py`. Nothing here is transcribed by hand: every figure is
read from `6_report.json` or counted in `6_final.v`.

**X** = harness generation (how the design is reasoned about: which reports get
read, which bottleneck gets blamed, which family of fix gets proposed).
**Y** = an RTL attempt inside that generation. A Y failing implicates the design;
an X row going flat implicates the harness.

## Every trial, in order run

| trial | PIPE | target | result | setup WS | need | fmax | TNS | hold | flops | stdcells | repair buf | area µm² | DRC |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| X1Y0 | 0 | 2.80 | ok | -0.0565 | 2.857 | **350.1** | -36.0 | +0.0399 | 24584 | 509176 | 116591 | 1086640 | 0 |
| **X1Y1** | 1 | 2.80 | **FAIL** | — | — | — | — | — | — | — | — | — | — |
| X1Y1 | 1 | 2.80 | ok | -0.0539 | 2.854 | **350.4** | -0.8 | +0.0402 | 29194 | 457390 | 74257 | 920220 | 0 |
| X2Y0 | 1 | 2.00 | ok | -0.4702 | 2.470 | **404.8** | -1067.8 | +0.0227 | 29194 | 492398 | 109346 | 971277 | 0 |
| X2Y1 | 2 | 1.80 | ok | -0.2717 | 2.072 | **482.7** | -906.0 | +0.0353 | 45579 | 577348 | 127433 | 1074080 | 0 |
| X2Y2 | 3 | 1.80 | ok | -0.1552 | 1.955 | **511.4** | -31.6 | +0.0329 | 46604 | 514700 | 65593 | 1021570 | 0 |
| X2Y3 | 2 | 1.50 | ok | -0.4788 | 1.979 | **505.4** | -3549.8 | +0.0236 | 45579 | 583132 | 133178 | 1081950 | 0 |
| X2Y4 | 3 | 1.60 | ok | -0.3422 | 1.942 | **514.9** | -114.6 | +0.0285 | 46604 | 519051 | 69945 | 1029960 | 0 |

## Per RTL variant — best measured, after calibrating for effort

| PIPE | registers added | best at | fmax | Δ fmax | flops | Δ flops | MHz/1k flops | stdcells |
|---|---|---|---|---|---|---|---|---|
| 0 | none — one combinational path | X1Y0 | **350.1** | — | 24584 | — | — | 509176 |
| 1 | `sum4` (+4,608) | X2Y0 | **404.8** | +54.7 | 29194 | +4610 | +11.87 | 492398 |
| 2 | + `prod[]` (+16,384) | X2Y3 | **505.4** | +100.6 | 45579 | +16385 | +6.14 | 583132 |
| 3 | + operands (+1,024) | X2Y4 | **514.9** | +9.5 | 46604 | +1025 | +9.27 | 519051 |

`need` = target − setup WS, i.e. the period the design actually achieved.
`fmax` = 1/need. Hold met and DRC clean on **every** trial that produced metrics.

## The generations

| X | declared | what it produced |
|---|---|---|
| **X1** | Read `FLW-0009`; blame the single combinational path `ccnt → mux → 8×8 multiply → tree → 33-bit add → fold`; fix by pipelining. Period **fixed at 2.80** for the whole generation, hold margin 0.05 | Hold closed (−0.0349/34 viol → +0.0399/0) with **no RTL change**, and −47% power for the same speed. But it reported `PIPE=1` as **+0.3 MHz** — its fixed period hid a 15.6% gain |
| **X2** | Same reports, bottleneck and fix family — the path report proved they were right. Changed the **procedure**: period derived per trial, **TNS read as the saturation signal**, clock skew tracked | Revealed `PIPE=1`'s real gain (+54.7), took the ladder to 514.9 MHz, and found that fmax in this flow is a function of how hard the tool is *asked* |

## Effort-limitation status per variant — how much each number can be trusted

| PIPE | measured at | spread | status |
|---|---|---|---|
| 0 | 1.00 ns (a1: 355) and 2.80 (X1Y0: 350.1) | **5 MHz** | solid; two targets 2.8× apart agree |
| 1 | 2.80 (saturated) and 2.00 (404.8) | — | **untested.** Only one non-saturated point |
| 2 | 1.80 (482.7) and 1.50 (505.4) | **+22.7** | was heavily effort-limited; 505.4 may still be a floor |
| 3 | 1.80 (511.4) and 1.60 (514.9) | **+3.5** | near its limit |

Effort-limitation **shrinks as the design improves** — short stages leave the
optimiser less to find — so it is not a constant offset and cannot be corrected
for. It has to be measured per variant.

## Findings that survive

1. **`PIPE=3`: 350.1 → 514.9 MHz = +47.1%**, for +1.9% cells (509,176 → 519,051)
   and +22,020 flops. Hold met, DRC clean.
2. **`PIPE=3` dominates `PIPE=2`** — faster by 9.5 MHz *and* smaller by 64,081
   cells. `PIPE` is cumulative, so **do not stop at `PIPE=2`**.
3. **Adding 1,025 flops made the design smaller.** `timing_repair_buffer` fell
   127,433 → 65,593; the shortened stage stopped needing to be buffered into shape.
4. **Saturation (`SAT=1`) costs 17,588 routed cells — 23× the coarse-synth
   prediction of 768** — because the fold mux sits inside the accumulate feedback
   loop. Zero flops, no measurable frequency cost. A 3.6% area tax for a semantic
   guarantee.
5. **Every fmax in this repo is a lower bound**, including `EXPERIMENTS.md`'s
   existing rows. Rows sharing a target stay comparable, so orderings stand while
   absolutes are floors.

## Claims retracted along the way

| claimed | actual | why |
|---|---|---|
| `PIPE=1` is worth +0.3 MHz | **+54.7** | X1's fixed period saturated the measurement |
| `PIPE=3` is the best value at +28.00 MHz/1k flops, 5.9× `PIPE=2` | **+9.27, 1.5×**; `PIPE=1` is best at +11.87 | compared `PIPE=3` against `PIPE=2`'s floor |
| `FLW-0009` shifts a consistent −0.032 ns | ranges 0 to −0.033 | fitted to two points; the third broke it |
| `PIPE=2`'s gain will be smaller than `PIPE=1`'s | larger (+77.9 vs +54.7) | used gate count as a proxy for logic depth |

## The remaining gap, and it is one run

**`PIPE=1`'s 404.8 MHz is the only number never tested for effort-limitation.**
Its other measurement (2.80 ns) was saturated, so 404.8 rests on a single
non-saturated point. Testing it at ~1.70 would either strengthen the "`PIPE=1` is
the best-value rung" claim or shift the Δ attribution between `PIPE=1` and
`PIPE=2`. Until then, treat the per-rung efficiency split as provisional; the
*ordering* and the cumulative +47.1% do not depend on it.

## Tooling defects found — eight, against zero RTL defects

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

The RTL has been correct at all four `PIPE` levels since it was written — 16/16 at
every `SAT`×`PIPE`, three consecutive exact flop predictions. Every defect lived in
how the design was measured or reasoned about, which is the Meta-Harness thesis
holding up under its own test.
