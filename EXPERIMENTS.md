# my-chip experiment log

One row per measured run. **Append only** — do not edit or delete rows, including
failures. A negative result you keep is worth more than a positive result you
can't reproduce.

## Rules

1. **No row without a passing regression.** `scripts/measure.sh` enforces this.
   If you bypass it with `--no-sim`, write `UNVERIFIED` in the Notes column.
2. **Label what kind of number you are reporting.** A post-route slack and an
   ABC mapping objective are not comparable. Use the Stage column:
   `synth` (ABC estimate) / `routed` (post-route STA with parasitics).
3. **Report cycles, not just MHz.** Clock frequency alone hides the cost of
   pipelining. Every row needs cycles-for-a-fixed-K so throughput is visible.
4. **Measure your own baseline.** Speedups are against row v0 in *this* table,
   in *this* flow — never against a number from someone else's paper or blog.
5. **One idea per row.** If you change two things and it gets faster, you have
   learned nothing about either.
6. **Pin the toolchain** and record it. Record the ORFS commit, not a tag.
7. **A row is identified by (`#`, `N`, `Period`)**, not by `#` alone. The same
   design measured at two array sizes is two rows sharing one `#`.

## Environment

| item | value |
|---|---|
| ORFS | 26Q3-1510-g6cb3f2b704 |
| PDK | nangate45 (academic, no fab target) |
| Corner | `NangateOpenCellLibrary_typical.lib` — **typical only, not signoff** |
| yosys | 0.68 (Homebrew) |
| Simulator | Icarus Verilog 12.0 |
| SDC convention | single clock, 20% I/O delay, **0.1 ns uncertainty**, false path on `rst_n` |

## Units

**There is no floating point anywhere in this project.** Every datapath is
integer / fixed-point, so any "FLOPS" figure would be meaningless here.

| Term used here | Means | Unit | Do NOT read as |
|---|---|---|---|
| **flip-flop** | one 1-bit storage element (netlist cells `DFF_X1`, `DFFR_X1`, …) | a **count of bits** | FLOPS (floating-point ops/sec) |
| **stdcell** | one standard-cell instance — gate, buffer, or flip-flop | a **count** | — |
| **MAC** | one multiply-accumulate | a count, or count/second | — |
| throughput | `N² × fmax` | GMAC/s, or **INT4 GOPS** counting multiply and add separately | FLOPS |

Worked example at N=16: **6,223 flip-flops = 6,223 bits ≈ 778 bytes** of state
(256 accumulators × 24 bits, plus ~70 control bits). Throughput is
256 MACs/cycle × 748 MHz = **191 GMAC/s ≈ 383 INT4 GOPS** — the factor of two
between those last two figures is the multiply and the add counted separately,
which is a routine source of inflated headline numbers.

## Results

Row ids use two prefixes. **`v`** rows are the performance experiments from the
plan below — each trades cycles for clock. **`f`** rows add a *capability* and
report what it cost; they are not attempts to go faster, and a small fmax loss in
an `f` row is a price, not a regression.


| # | Design | N | Stage | Period | Setup WS | Implied fmax | DRC | Hold WS | Cycles @K=1024 | stdcells | flip-flops | area µm² | power W | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| v0 | `mac_array` baseline | 4 | routed | 1.00 ns | **−0.2776** | **783 MHz** | **0** | +0.0021 | 1043 (sim) | 7,979 | 455 | 12,817 | 0.082 | naive: mult + 24-bit add in one cycle. Setup NOT met, TNS −51.6. Die 156×156 µm, 55% util. |
| v0 | `mac_array` baseline | 16 | routed | 1.00 ns | **−0.3373** | **748 MHz** | **0** | −0.0071 | 1283 (sim) | 114,047 | 6,223 | 167,983 | 1.130 | same RTL, N=16. Setup NOT met, TNS −742. **Hold now slightly violating.** Die 581×581 µm, 50% util. |
| f1a | `mac_array` + INIT_KEEP (`C_PORT=0`) | 4 | routed | 1.00 ns | **−0.2854** | **778 MHz** | **0** | +0.0013 | 1043 (sim) | 7,988 | 455 | 12,619 | 0.078 | `D = A@B + D_prev`. Chaining k-tiles by NOT clearing the accumulator; external-C hardware pruned. Within noise of v0 (+9 stdcells, −5 MHz, −1.5% area). TNS −54.2. |
| f1b | `mac_array` + INIT_C (`C_PORT=1`) | 4 | routed | 1.00 ns | **−0.3223** | **756 MHz** | **0** | +0.0004 | 1043 (sim) | 9,158 | 455 | 13,663 | 0.070 | adds arbitrary external `C` on a 384-bit port. **+1,170 stdcells, +1,044 µm², −22 MHz vs f1a.** TNS −57.2. |

### v0 findings

**The `N` parameter genuinely scales the design** (this was the open question).
Flip-flop counts match prediction almost exactly, so nothing was optimised away
and `VERILOG_TOP_PARAMS` works through synthesis:

| N | expected flip-flops (`N²·24` + ~70 control) | measured | area ratio |
|---|---|---|---|
| 4 | 454 | **455** | — |
| 16 | 6,214 | **6,223** | 13.1× (16× the MACs; control doesn't scale) |

**fmax falls as N grows: 783 → 748 MHz (−4.5%) for 16× the array.** This is
experiment **v5 answered early** — the broadcast penalty is already measurable
at N=16. Each activation/weight nibble fans out to N multipliers, so the fanout
load quadruples from N=4 to N=16, and buffering it costs delay. Extrapolating,
this only gets worse; it is the reason v6 (systolic) exists on the plan.

**TNS explodes 14× faster than cell count** (−51.6 → −742, i.e. 14.4× for 14.3×
the cells) — so at N=16 essentially *every* accumulator path is failing, not a
few outliers. Consistent with a single systemic limiter (the carry chain), not
a placement accident.

**Hold turned marginal at N=16** (+2.1 ps → −7.1 ps). Worth watching: hold
violations do not go away by slowing the clock down.

**The limiter is measured, not inferred.** `scripts/report_path.sh -n 4` reports
the worst `core_clock` path post-route with parasitics:

```
Startpoint: wgt_rdata[14]   (input port)
Endpoint:   acc[7][23]      (accumulator bit 23 — the MSB)
  → AND2_X4 → FA_X1 ×3 → HA_X1/CO → FA_X1/CO → AOI21 → OAI21
  → XOR2 → HA_X1/S → … → acc[7][23]/D
arrival 1.289   required 1.011   slack −0.278 (VIOLATED)
six adder cells in series: 4× FA_X1 + 2× HA_X1
```

That is the multiply and the full 24-bit add in one cycle, ending at the far end
of the carry chain — exactly what v0 was written to be, and exactly what v1/v2
target. The −0.278 matches this table's −0.2776, so the row and the path agree.

Where the 1.00 ns goes: 0.200 input delay (the SDC's 20% I/O budget) + 0.100
clock uncertainty + 0.038 setup, less 0.149 recovered from clock network delay,
leaves **1.011 ns for logic — the logic needs 1.089.** About a third of the
nominal period is spent before any gate switches, so the 278 ps has to come out
of ~1.011 ns of usable budget, not out of 1.000.

Baseline reading: the naive design tops out near **783 MHz** at N=4 and loses
ground as it grows.

## Planned experiments

Ordered by expected value. Each is one row, one idea.

| id | Hypothesis | Change | Expect |
|---|---|---|---|
| v1 | The per-cycle 24-bit carry chain is the limit | register the product between multiply and add | fmax up, cycles +1 latency only |
| v2 | The wide add is still the limit | hierarchical fold: 12-bit chunk accumulator, fold to 24-bit every 16 | fmax up; **cycles up ~19%** — record both |
| v3 | The `issued < k_dim` comparator on the request port costs | replace with a registered down-counter | small fmax gain |
| v4 | The `N*N:1` drain mux will dominate as N grows | pipeline the readout (register the row, then mux the column) | no gain at N=4 or N=16 (measured: neither is limited by it); **needed before N=32** |
| ~~v5~~ | Broadcast fanout caps a broadcast array | scale N at fixed period | **PARTLY DONE** — N=4 and N=16 measured (783 → 748 MHz). N=8 and N=32 still open |
| v6 | Broadcast geometry is the wall, not arithmetic | output-stationary systolic PE, nearest-neighbour only | fmax becomes independent of N |

v4's original wording said "required before N=16". That is **falsified**: N=16
routed DRC-clean, and the measured N=4 critical path runs through the multiplier
and accumulator, not the drain mux. The reference project hit the readout mux as
its *only* remaining violation at a 32×32 array, which is where to expect it.

### Note on starting at N=4

N=4 is a **bring-up** size, not a research size. Two of the three bottleneck
classes cannot appear at N=4:

| bottleneck | visible at N=4? | why |
|---|---|---|
| arithmetic (carry chain) | **yes** | independent of N |
| control fanout | **no** | one enable drives 16 MACs — trivially buffered |
| wire geometry / broadcast span | **no** | the array is tens of microns across |

So expect v1–v3 to work at N=4 and then to plateau with nothing left to climb.
The point of v5 is to grow N until the other two effects appear. Do not conclude
"the design is optimal" from a plateau at N=4 — conclude that N=4 is too small
to be interesting, and scale up.

### f1 findings — the +C addend

`D[i][j] = init[i][j] + sum_k A[k][i]*B[k][j]`, with `init` selected by
`init_mode`: `INIT_ZERO`, `INIT_C` (external `c_in`), or `INIT_KEEP` (hold, so
`D = A@B + D_prev`). Two rows because they are two separate ideas: f1a is
chaining, f1b is an arbitrary externally-supplied addend.

**Chaining is free. Arbitrary C is not.**

| | stdcells | vs v0 | area µm² | fmax | flip-flops |
|---|---|---|---|---|---|
| v0 baseline | 7,979 | — | 12,817 | 783 MHz | 455 |
| f1a `INIT_KEEP` | 7,988 | **+9 (+0.1%)** | 12,619 | 778 MHz | 455 |
| f1b `+ INIT_C` | 9,158 | **+1,179 (+14.8%)** | 13,663 | 756 MHz | 455 |

`INIT_KEEP` reproduces v0 to within run-to-run placement noise, which is the
point: chaining assigns *nothing*, the flop simply holds, so no data mux appears
on `D` and the clear-to-zero keeps riding the flop's dedicated synchronous-reset
pin. Yosys confirms it structurally — all 384 accumulator bits stay
`$_SDFFE_PP0P_` in both configurations.

**flip-flops are identical (455) in all three rows.** The addend costs no state
at all; the entire cost is combinational. That is the check that the accumulator
count was not perturbed.

**GENERIC SYNTH UNDERSTATED THE REAL COST BY 3×.** Yosys `synth` at N=4 put
`C_PORT=1` at +381 cells over `C_PORT=0`; the routed flow measured **+1,170**.
The generic number counts the 384 ACC_W-wide 2:1 muxes and nothing else. The
real flow additionally buffers a 384-bit `c_in` net fanning out across the die,
and that buffering is the missing two-thirds. Treat pre-techmap cell deltas as a
*lower bound* on area cost, never an estimate — this is the second time in this
project a coarse-cell count has failed to predict a physical one.

**Do not trust the power column here.** f1b reports *less* power (0.070 W) than
f1a (0.078 W) despite 15% more cells. `c_in` is an undriven top-level input, so
its switching activity is assumed rather than derived, and 384 extra input pins
moved the whole placement. The delta is not credible as a power result and no
conclusion is drawn from it.

**RTL shape mattered more than RTL content.** Writing the three init modes as a
*nested* conditional inside one `if (state == S_IDLE && start)` cost **+1,168**
generic cells; writing the identical logic as a *flat* `if / else if` chain cost
**+381**. Same function, 3.1× the area, because only the flat form lets yosys
recognise the leading constant-zero branch as a synchronous reset. The RTL now
carries a comment saying not to "tidy" it.

Cycle counts are unchanged (1043 at K=1024, identical to v0): the addend adds no
cycles. `INIT_C` needs all `N²·ACC_W` bits of `c_in` on the single `start` edge,
because all N² accumulators load simultaneously — it cannot be streamed in on a
narrow port without adding a preload state.

### Note on GDS (applies to every row above)

Until this was found, **no row in this table had a GDS behind it.** ORFS's
`finish` target is

```make
finish: $(LOG_DIR)/6_report.log $(RESULTS_DIR)/6_final.v \
        $(RESULTS_DIR)/6_final.sdc $(GDS_FINAL_FILE)
```

and `6_report` fails on this OpenROAD build at `final_outputs.tcl:58`,
`gui::show "source save_images.tcl"`, which asks for a display control
(`Timing Path/*`) the build does not have. Metrics are dumped *before* that call,
so they were always valid — but make aborts on the first failed prerequisite, so
`$(GDS_FINAL_FILE)` was never built. `measure.sh` called this "layout images
unavailable" and moved on.

`measure.sh` now recovers the GDS with `do-gds` and **fails the run if it cannot**:
a routed design with no GDS is not a built chip. Verified output:

| config | row | GDS | top cell | die | cell defs |
|---|---|---|---|---|---|
| `my_chip_n4`    | v0  | 5.7 MB | `mac_array` | 155.8 × 155.8 µm | 103 |
| `my_chip_n4_c0` | f1a | 5.7 MB | `mac_array` | 155.5 × 155.5 µm | 100 |
| `my_chip_n4_c1` | f1b | 6.6 MB | `mac_array` | 160.2 × 160.2 µm |  99 |

Every one is verified rather than merely present: `scripts/gds.sh` reads the
stream back, asserts the top cell is `mac_array` with a non-empty bounding box,
and requires KLayout to have reported both "All LEF cells have matching GDS/OAS
cells" and "No orphan cells in the final layout". A wrong or truncated stream
still produces a plausibly-sized file, so existence is not correctness.

`make gds` builds one for an already-routed config straight from `6_final.def`,
without re-running synthesis, placement or routing — which is how the v0 row got
its layout without rebuilding the pre-addend RTL.
