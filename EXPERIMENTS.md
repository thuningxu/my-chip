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

| # | Design | N | Stage | Period | Setup WS | Implied fmax | DRC | Hold WS | Cycles @K=1024 | stdcells | flip-flops | area µm² | power W | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| v0 | `mac_array` baseline | 4 | routed | 1.00 ns | **−0.2776** | **783 MHz** | **0** | +0.0021 | 1043 (sim) | 7,979 | 455 | 12,817 | 0.082 | naive: mult + 24-bit add in one cycle. Setup NOT met, TNS −51.6. Die 156×156 µm, 55% util. |
| v0 | `mac_array` baseline | 16 | routed | 1.00 ns | **−0.3373** | **748 MHz** | **0** | −0.0071 | 1283 (sim) | 114,047 | 6,223 | 167,983 | 1.130 | same RTL, N=16. Setup NOT met, TNS −742. **Hold now slightly violating.** Die 581×581 µm, 50% util. |

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
