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
