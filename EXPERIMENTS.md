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

For `amx_tdpbssd`: **24,584 flip-flops = 3,073 bytes** (three 16×64-byte tiles,
plus 8 control bits), and 1024 MACs/cycle × 355 MHz = **363 GMAC/s ≈ 727 INT8
GOPS**. Do not compare that GOPS figure to the INT4 one above as if they were the
same unit — an INT8 multiply costs 407 gates against 84 for INT4, measured.

## Results

There are now **two designs**, and their rows are tabulated separately because
their metrics are not comparable: `mac_array` is measured in cycles for a
runtime-variable K, `amx_tdpbssd` in cycles for one fixed-shape instruction.
Forcing them into one table would put a "Cycles @K=1024" number next to a design
that has no K.

- **`mac_array`** — INT4 outer-product array, `D = init + A@B`. Rows below.
- **`amx_tdpbssd`** — Intel AMX `TDPBSSD`, INT8, `C += A@B`. See
  [amx rows](#results--amx_tdpbssd).

Row ids in the `mac_array` table use two prefixes. **`v`** rows are the
performance experiments from the plan below — each trades cycles for clock.
**`f`** rows add a *capability* and report what it cost; they are not attempts to
go faster, and a small fmax loss in an `f` row is a price, not a regression.


| # | Design | N | Stage | Period | Setup WS | Implied fmax | DRC | Hold WS | Cycles @K=1024 | stdcells | flip-flops | area µm² | power W | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| v0 | `mac_array` baseline | 4 | routed | 1.00 ns | **−0.2776** | **783 MHz** | **0** | +0.0021 | 1043 (sim) | 7,979 | 455 | 12,817 | 0.082 | naive: mult + 24-bit add in one cycle. Setup NOT met, TNS −51.6. Die 156×156 µm, 55% util. |
| v0 | `mac_array` baseline | 16 | routed | 1.00 ns | **−0.3373** | **748 MHz** | **0** | −0.0071 | 1283 (sim) | 114,047 | 6,223 | 167,983 | 1.130 | same RTL, N=16. Setup NOT met, TNS −742. **Hold now slightly violating.** Die 581×581 µm, 50% util. |
| f1a | `mac_array` + INIT_KEEP (`C_PORT=0`) | 4 | routed | 1.00 ns | **−0.2854** | **778 MHz** | **0** | +0.0013 | 1043 (sim) | 7,988 | 455 | 12,619 | 0.078 | `D = A@B + D_prev`. Chaining k-tiles by NOT clearing the accumulator; external-C hardware pruned. Within noise of v0 (+9 stdcells, −5 MHz, −1.5% area). TNS −54.2. |
| f1b | `mac_array` + INIT_C (`C_PORT=1`) | 4 | routed | 1.00 ns | **−0.3223** | **756 MHz** | **0** | +0.0004 | 1043 (sim) | 9,158 | 455 | 13,663 | 0.070 | adds arbitrary external `C` on a 384-bit port. **+1,170 stdcells, +1,044 µm², −22 MHz vs f1a.** TNS −57.2. |
| f2a | `mac_array` + `OUT_PAR=1` (on f1a, `C_PORT=0`) | 4 | routed | 1.00 ns | −0.3001 | 769 MHz | **0** | +0.0050 | 1028 (sim) | 8,152 | 422 | 12,545 | 0.074 | parallel readout without the external-C port. **Cycles at K=4: 23 → 8.** +164 stdcells, −33 flops, −74 µm², TNS −54.8. fmax −9 MHz vs f1a — see f2 findings: **the fmax delta has the opposite sign at `C_PORT=1`, so do not attribute it to `OUT_PAR`.** |
| f2b | `mac_array` + `OUT_PAR=1` (on f1b, `C_PORT=1`) | 4 | routed | 1.00 ns | −0.2581 | 795 MHz | **0** | +0.0092 | 1028 (sim) | 9,257 | 422 | 13,482 | 0.075 | same change with external C. **Cycles at K=4: 23 → 8.** +99 stdcells, −33 flops, −182 µm², TNS −51.8. fmax +39 MHz vs f1b, but f2a moved −9 MHz: **not attributable.** Die back to 155.8 µm (f1b was 160.2). |

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
| ~~f2~~ | The drain, not the datapath, is what makes the small-tile case slow | `OUT_PAR=1`: read all `N*N` accumulators out at once instead of over `N*N` cycles | **DONE** — rows f2a/f2b. Cycles 23 → 8 at K=4, and it *removes* the v4 mux rather than pipelining it. v4 remains open only as the alternative for cases where a `N*N*ACC_W`-bit port is unaffordable |
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

`D[i][j] = init[i][j] + Σ_k Amem[k][i]·Bmem[k][j]`, which under the layout the
hardware requires (`Amem[k]` = column k of A, `Bmem[k]` = row k of B) is
`init + A@B`. `init` is selected by `init_mode`: `INIT_ZERO`, `INIT_C` (external
`c_in`), or `INIT_KEEP` (hold, so `D = A@B + D_prev`). Two rows because they are
two separate ideas: f1a is chaining, f1b is an arbitrary externally-supplied
addend. See the `mac_array` header for why only A is stored transposed.

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
*nested* conditional inside one `if (state == S_IDLE && start)` cost **+1,170**
generic cells (6,107 vs v0's 4,937); writing the identical logic as a *flat*
`if / else if` chain cost **+381** (5,318). Same function, 3.1× the cost of the
feature, because only the flat form lets yosys
recognise the leading constant-zero branch as a synchronous reset. The RTL now
carries a comment saying not to "tidy" it.

Cycle counts are unchanged (1043 at K=1024, identical to v0): the addend adds no
cycles. `INIT_C` needs all `N²·ACC_W` bits of `c_in` on the single `start` edge,
because all N² accumulators load simultaneously — it cannot be streamed in on a
narrow port without adding a preload state.

### f2 findings — the parallel readout

The serial drain moves one accumulator per cycle through an `N*N:1` mux, so it
costs `N*N` cycles *whatever K is*. `OUT_PAR=1` presents all `N*N` accumulators
at once on `out_all` and strobes `out_we` once. Measured cycle counts fit exactly
over 20 cases with K from 0 to 2048:

    OUT_PAR=0   cycles = K + N*N + 3
    OUT_PAR=1   cycles = K + 4

(K=0 costs one less in both: `S_IDLE` jumps straight to `S_DRAIN`, so the
`rd_valid` pipeline never fills. The testbench **asserts** this model rather than
printing it, so an optimisation that silently cost cycles would fail.)

**The win grows as N², because the drain does.** At K=4:

| N | `OUT_PAR=0` | `OUT_PAR=1` | speedup | multipliers busy (0 → 1) |
|---|---|---|---|---|
| 4 | 23 | 8 | 2.9× | 17% → 50% |
| 8 | 71 | 8 | 8.9× | 6% → 50% |
| 16 | 263 | 8 | **32.9×** | 1.5% → 50% |

`OUT_PAR=1` makes the cycle count **independent of N**. That is the real result:
the serial drain, not the datapath, is what made the small-tile case slow.

#### The change was measured at both `C_PORT` values, and that mattered

`OUT_PAR` was routed at `C_PORT=0` and `C_PORT=1` — four configs, one variable
apart in each direction. Doing so overturned a conclusion drawn from the first
corner alone:

| Δ from `OUT_PAR=0` → `1` | at `C_PORT=0` | at `C_PORT=1` | robust? |
|---|---|---|---|
| cycles at K=4 | 23 → 8 | 23 → 8 | ✅ exact, both |
| flip-flops | −33 | −33 | ✅ exact, both |
| `timing_repair_buffer` | +380 | +385 | ✅ tight, both |
| stdcells | **+164** | **+99** | ✅ sign, both |
| cell area µm² | −74 | −182 | ✅ sign, both |
| worst slack ns | **−0.0147** | **+0.0642** | ❌ **opposite signs** |
| implied fmax | **−9 MHz** | **+39 MHz** | ❌ **opposite signs** |

**The fmax effect is not attributable to this change.** The `C_PORT=1` corner
came in at +39 MHz and, on that evidence alone, a tidy causal story was written
here: deleting the drain frees placement area, the tool spends it buffering the
MAC path, fmax rises. It fitted the data — arrival time on the same logical path
did fall 1.356 → 1.295 ns, and the path did pick up buffer stages (3 → 5). Then
the `C_PORT=0` corner came in at **−9 MHz** and the story died. Same RTL change,
opposite sign.

What is genuinely established, from `report_path.sh` on all four routed configs:

| `C_PORT` | `OUT_PAR` | worst path | slack |
|---|---|---|---|
| 0 | 0 | `wgt_rdata[1]` → `acc[8][23]` | −0.285 |
| 0 | 1 | `act_rdata[9]` → `acc[8][22]` | −0.300 |
| 1 | 0 | `act_rdata[14]` → `acc[14][23]` | −0.322 |
| 1 | 1 | `act_rdata[1]` → `acc[0][22]` | −0.258 |

Every one is the same *class* of path — an input data port, through the
multiplier's FA/HA chain, through the 24-bit accumulate, into an accumulator flop.
Not one ends at `out_wdata` or `out_all`; no drain logic appears on any of them,
at either `OUT_PAR`. **So there is no mechanism by which `OUT_PAR` could change
fmax**, which is the strongest form of this argument: not "the effect was small"
but "the effect has nowhere to come from."

And the *identity* of the worst accumulator moves every run — `acc[8]`, `acc[8]`,
`acc[14]`, `acc[0]`. The accumulator bits are near-uniformly near-critical: all
four configs report **290–295 violating setup endpoints** with TNS between −51.8
and −57.2, so ~290 endpoints are competing for last place and which one wins is
decided by placement. That is what the 64 ps of slack scatter across these rows
is, and it is why a single-corner fmax delta of 39 MHz meant nothing.

Note this makes the **original prediction of "~unchanged, ±0.03 ns" the better
call**, and the post-hoc explanation the worse one: the prediction held at
`C_PORT=0` (−0.015) and only the single `C_PORT=1` outlier broke it. **A causal
mechanism inferred from n=1 and confirmed by nothing is exactly the failure this
repo exists to prevent, and it nearly shipped here.** Quote the cycle count and
the buffer cost from this row; do not quote its fmax.

One thing this does *not* establish is how much run-to-run noise the flow has,
because the two corners are different designs, not repeats. Measuring that needs
the same config routed twice — cheap, and worth doing before any future row
claims a sub-40 MHz gain.

**Why cells went up when generic synth said down — the same trap as f1b.**
Routed, `OUT_PAR=1` costs **+99 stdcells** where yosys `synth` predicted −911.
Both numbers are real; they measure different things:

At `C_PORT=1`:

| | `OUT_PAR=0` | `OUT_PAR=1` | Δ |
|---|---|---|---|
| generic cells (yosys `synth`) | 5,330 | 4,418 | **−911** |
| routed stdcells | 9,158 | 9,257 | **+99** |
| routed flip-flops (counted in `6_final.v`) | 455 | 422 | −33 |
| routed `BUF_*` + `INV_*` (counted in `6_final.v`) | 3,421 | 3,838 | +417 |
| ORFS `count__class:timing_repair_buffer` | 2,804 | 3,189 | **+385** |

Unlike the fmax number, this one **replicates**: at `C_PORT=0` the same change
costs +164 stdcells and +380 timing-repair buffers. Two designs 1,170 cells apart
both pay ~382 buffers for the same 384-bit port, which is what makes the
buffering explanation trustworthy where the fmax explanation was not.

The drain logic really does vanish — the flop delta is exactly the −33 predicted
(4 bits of `drow`/`dcol`, plus 28 bits of `out_addr`/`out_wdata` going constant).
But a 384-bit output port needs drivers, and the flow added **~400 buffers** to
provide them. Two independent measures agree on that: counting `BUF_*`/`INV_*`
instances in the netlist gives +417, and ORFS's own `timing_repair_buffer`
classification gives +385. Net: the logic saving is real, and the port eats it.

This is the second time in this project a coarse-cell delta has mispredicted a
physical one, and the mechanism is identical both times — **a wide top-level port
costs roughly a thousand stdcells of buffering that generic synth does not
model**, and the direction of the logic change is irrelevant to that:

| | wide port | generic Δ | routed Δ | buffering is |
|---|---|---|---|---|
| f1b | 384-bit `c_in` **in** | +381 | +1,170 | two-thirds of the cost |
| f2b | 384-bit `out_all` **out** | −911 | +99 | more than the whole saving |

Treat pre-techmap deltas as telling you about *logic*, never about *area*.

**Area and die shrank anyway** (13,663 → 13,482 µm², die 160.2 → 155.8 µm),
because the 33 flip-flops removed are far larger cells than the 417 buffers
added. Cell *count* and cell *area* moved in opposite directions here.

**Both modes are permanent.** `out_all` is `N*N*ACC_W` bits — 384 at N=4 but
**6,144 at N=16**. The parallel readout is viable *because* a tensor-core tile is
small; the serial drain remains the right choice for large-N streaming. Neither
is a legacy path.

**Power is again not credible** (0.070 → 0.075 W), for the reason given under
f1b: `out_all` terminates at top-level pins whose load is assumed, not derived.

## Results — amx_tdpbssd

Intel AMX `TDPBSSD`: tile dot-product, signed INT8 × signed INT8 accumulating
into INT32, `C += A @ B` on `(16,64) @ (64,16) → (16,16)`. **16,384 MACs per
instruction**, 1024 multipliers, 16 k-steps. Semantics taken from the x86 ISA
reference, not recalled.

| # | Design | Stage | Period | Setup WS | Implied fmax | DRC | Hold WS | Cycles/instr | stdcells | flip-flops | area µm² | power W | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| a1 | `amx_tdpbssd` `SAT=1` | routed | 1.00 ns | **−1.8171** | **355 MHz** | **0** | **−0.0349** | 17 (sim) | 519,820 | 24,584 | 1,109,920 | 35.99 | 1024 INT8 MACs/cycle. Setup badly missed, TNS **−14,566**. **HOLD IS VIOLATED** — see below. Die 1554.8 µm square (2.42 mm²), GDS 423 MB, verified. 127,028 timing-repair buffers = 24% of the design. |

### The headline: 29x the MACs/cycle pays for 2.2x the clock

| | MAC/cycle | fmax | GMAC/s | area mm² | GMAC/s per mm² |
|---|---|---|---|---|---|
| `amx_tdpbssd` (INT8) | 1024 | 355 | **363.5** | 1.110 | 328 |
| `mac_array` N=16 (INT4) | 256 | 748 | 191.5 | 0.168 | **1140** |
| `mac_array` f2b N=4 (INT4) | 16 | 795 | 12.7 | 0.013 | 943 |

Against the largest previous design: **1.90× the throughput for 6.6× the area.**
So in GMAC/s per mm² the INT8 tile engine is **3.5× WORSE** than the INT4 array —
which is the honest way to report it, with the caveat that these are different
datatypes and an INT8 MAC is not an INT4 MAC. The measured multiplier ratio is
407 gates vs 84, i.e. 4.8×, so on a per-multiplier basis 0.61× the MAC density is
better than the 0.21× that ratio alone would predict — `mac_array` pays for a
private accumulate adder in every cell, while this design shares one adder tree
per four products.

### Setup: 2.2x the period, and it is the logic depth

−1.8171 ns against a 1.00 ns target: the design needs **2.785 ns**. That is not a
surprise and not a placement accident — it is what putting all of this in one
cycle costs:

```
8x8 signed multiply  ->  4-input adder tree  ->  33-bit add  ->  2 mux levels
```

against `mac_array`'s `4x4 multiply -> 24-bit add`, which already needs 1.258 ns.
TNS is **−14,566** over **9,429 violating endpoints** — systemic, every DPBD, not
outliers. The fix is the same one v1 proposes for `mac_array`: register the
product between the multiply and the tree, buying clock with a cycle of latency.

Timing repair spent **127,028 buffers (24% of the final cell count)** and grew the
design from 407,034 post-synthesis stdcells to 519,820 (**+28%**) without closing.
Buffering cannot fix logic depth; the cells were spent for nothing.

### The critical path names the cost of the tile-register decision

`report_path.sh -d amx_tdpbssd --sat 1`, post-route with parasitics:

```
Startpoint: kcnt[1]$_DFFE_PN0P_      (the k counter)
Endpoint:   cacc[98][2]$_DFFE_PP_    (an accumulator)
slack -1.817 (VIOLATED)              -- matches the row's -1.8171
```

**It starts at the k counter, not at an input port**, and that is the finding.
`kcnt` drives the 16:1 selects that pull `a_flat[m].dword[k]` and `b_flat[k]` out
of the tile registers, so the whole chain

```
kcnt -> 16:1 operand select -> 8x8 multiply -> adder tree -> 33-bit add -> fold -> acc
```

is one flop-to-flop path. Contrast `mac_array`, whose worst path starts at an
*input port* (`act_rdata[...]`) because its operands come from external memory:
it pays the SDC's 0.2 ns input delay but has **no operand mux in front of the
multiplier**.

**And it is not only logic depth — a third of the path is wire.** Cell classes on
the worst path, counted:

| | `amx_tdpbssd` | `mac_array` f2b |
|---|---|---|
| adder cells (`FA`/`HA`) | **9** (8 FA + 1 HA) | 6 (4 FA + 2 HA) |
| buffers (`BUF`/`CLKBUF`) | **14** | 5 |
| muxes (`MUX2`) | 2 | 0 |
| total cells on path | ~45 | ~20 |
| arrival | **3.316 ns** | 1.295 ns |

1.5× the adder cells but **2.6× the arrival time**, and the gap is buffering: 14
buffer stages, 31% of the cells on the path, driving wires across a **1554.8 µm**
die — ten times the edge length of `mac_array`'s 155.8 µm.

That changes what the fix is. Pipelining the multiply (the obvious v1-style move)
attacks the 9 adder cells, but it does nothing about 14 buffers' worth of wire
delay on a 2.4 mm² die. A design this size needs *physical* partitioning as well
as logical pipelining, and this row is the evidence for that rather than an
assumption about it.

So holding the tiles internally — which was chosen to make the multiply do zero
memory traffic and give free random access to any dword — moved the operand fetch
*into* the critical path. That is a real, measured cost of the decision, and it was
not in the plan's reasoning. It is also the cheapest thing to fix: register the
selected operands, spending one cycle of latency (17 → 18) to remove the mux and
the multiply from the same path as the accumulate.

### HOLD IS VIOLATED, and that is the serious one

**−0.0349 ns, 34 violating endpoints.** Setup you can fix by slowing the clock.
**Hold you cannot** — it is a min-delay failure and it is still there at any
period. `mac_array` at N=16 was already marginal (−0.0071); this is 5× worse.

This row should therefore **not** be read as "works at 355 MHz". It is a design
that does not meet timing at any frequency as routed, and the hold violations are
the reason. Fixing them means hold buffers on the fast paths, which the flow's
`repair_timing -hold_margin 0` did not fully do.

### Power is not credible, but the magnitude is still a signal

35.99 W on a 2.42 mm² die is ~15 W/mm², which is thermally impossible for a real
part. Treat the number as uncalibrated for the reasons given under f1b (undriven
inputs, assumed activity), but the order of magnitude is a legitimate warning that
1024 INT8 multipliers switching every cycle is a power problem, not just an area
one.

### What went right

**DRC clean, first routing attempt.** The plan flagged "ORFS may take a very long
time or fail in global route" as the main risk at 3.6× the largest previously
routed design. Global routing placed 658,918 nets in 24 seconds with no congestion
abort, and detailed routing finished with **zero** DRC violations. The risk was
overstated.

**Flip-flops are exactly 24,584 post-route**, unchanged from synthesis — the three
tile registers plus 8 control bits, to the bit. Nothing was optimised away across
the entire flow.

**The die estimate was close.** Planned at ~1450 µm/side, came in at 1554.8 — 7%
high.

### A process failure worth recording

While this run was in flight I read the worst slack **three times and got it wrong
twice**: −1.782 from `repair_design`'s progress table (right by luck), then
"corrected" it to −0.006 from `repair_timing`'s per-iteration `WNS` column
(wrong — that column tracks the batch of endpoints being repaired, not the
design's global worst), then −1.785 from `[INFO FLW-0009]`, which the final routed
value (−1.8171) confirms.

**Read `FLW-0009`, not an optimizer's progress table.** It was cross-validated
here: for `mac_array` f2b, `FLW-0009` reported −0.259 and the final routed slack
was −0.2581. An in-progress optimizer's own numbers are about what it is currently
working on, not about the design.

### What is verified, independent of any PPA number

**Functional: 14/14 at both `SAT` settings**, checked against *four* models — the
DUT, the ISA pseudocode transcribed onto physical tiles, a textbook triple loop
on logical matrices, and `tb/amx_golden.py`. The three-model structure is
deliberate: a bug in the tile packing makes the DUT and the ISA model agree with
each other and both disagree with the textbook model, while a bug in the RTL's
reading of the layout makes the DUT disagree with the ISA model. Two failures,
two distinct signatures.

**Cycles: 17 per instruction, asserted not printed** (16 k-steps + the IDLE→RUN
transition). At 16,384 MACs that is **964 MACs/cycle** against 1024 multipliers —
94% utilisation, and the missing 6% is the single transition cycle.

**The VNNI interleave is the thing that can silently break**, and its coverage is
measured rather than assumed. Reversing B's byte pairing is caught by the
asymmetric and random cases *only* — the all-ones and all-`−128` cases pass a
wrong interleave, because uniform tiles cannot detect a reordering, and the
mixed-sign case happens to be period-2 in `b` so its four-byte sum is invariant
under reversal. Four mutations, three caught in both modes, one correctly dead at
`SAT=0`; the table is in [tb/README.md](tb/README.md).

### Synthesis: the tile registers are all there, exactly

Mapped to Nangate45 at `SAT=1`, counted from `1_2_yosys.v`:

| | count | |
|---|---|---|
| total stdcells | **407,034** | 3.6× the largest design this flow had routed (114,047) |
| flip-flops | **24,584** | = 24,576 + 8 — see below |
| `DFF_X1` alone | **24,576** | `3 tiles × 16 rows × 512 bits`, to the bit |
| full/half adders | 151,064 | 119,568 `FA_X1` + 31,496 `HA_X1` |
| `MUX2_X1` | 46,116 | the 16:1 row/dword selects, plus the fold muxes |
| buf/inv | 41,706 | |

**The flip-flop count is an exact structural check, not an approximation.**
24,576 is the three tile registers to the bit, and the remaining 8 are precisely
the control state: `state` (2) + `kcnt` (4) + `busy` (1) + `done` (1). Nothing was
optimised away and no tile silently collapsed — the same class of check as v0's
flip-flop count tracking `N²·ACC_W + control`.

Worth noting against the estimate: this was **planned at ~574k cells and came in
at 407k, 29% below**. The multiplier estimate (1024 × 407 gates ≈ 417k) was
essentially the whole design; the adder trees and accumulates that were budgeted
separately mostly disappeared into shared logic that abc found. An over-estimate
in the safe direction, but an estimate all the same.

### Saturation is a deviation, and it is parameterised for that reason

Intel's `DPBD` is plain modular INT32 — `c := c + p0+p1+p2+p3`, no clamp. `SAT=1`
was requested and **is** a departure from the ISA, so both are built:

| `SAT` | behaviour | |
|---|---|---|
| 0 | wraps | **bit-exact ISA conformance** — the conformance test stays meaningful |
| 1 | clamps to `[−2³¹, 2³¹−1]` | the deviation (default) |

**Where the clamp goes is part of the specification, not an implementation
detail**, because saturating addition is not associative. Folding per step versus
once after a tree over the same four values gives `−1` versus `+1073741824` —
verified, not asserted. It goes once per k-step, which is exactly Intel's `DPBD`
call boundary, so the two modes differ only in the clamp and never in the
summation order.

That is also the only reason this machine can claim conformance at all: it runs
**k outermost** (all `m` and `n` parallel) while the ISA runs **m outermost**. For
a fixed `(m,n)` the k sequence is 0…15 in both, because `m` and `n` index
independent accumulators. Move the fold anywhere else and the orders diverge.

**What saturation cannot reach:** one instruction from `C=0` tops out at
`64 × 16384 = 1,048,576` — 21 bits, a 2047× margin. **A single TDPBSSD cannot
overflow INT32.** Saturation only ever matters for the `C +=` chain across
instructions, which is why cases S1–S4 preload `tmm2` within 5 of each rail
instead of hoping a long run gets there.

Coarse-cell cost of the clamp, pre-techmap at N/A geometry (this design has fixed
geometry): 8,091 cells at `SAT=0` versus 8,859 at `SAT=1`, i.e. **+768 = 3 cells
per accumulator** — the overflow XOR, the rail select and the fold mux, times 256.
Treat that as a lower bound on area, not an estimate: this project has twice
measured a coarse-cell delta mispredict the routed one (`c_in` +381 → +1,170;
`out_all` −911 → +99).

### A synthesis lesson that cost a run

The first ORFS attempt **failed outright** in synthesis:

```
Error: Synthesized memory size 4096 exceeds SYNTH_MEMORY_MAX_BITS
```

The tiles were declared `reg [511:0] tmm_a [0:15]` — an unpacked array, which
yosys infers as a **memory**. Raising the threshold would have been the wrong fix.
The datapath reads a dword from **all 16 rows of A in the same cycle**, so it
needs 16 concurrent read ports; no SRAM has that, and these can only ever be
flip-flops. They are now flat packed vectors with part-select access, which says
so in the declaration instead of arguing with a threshold until it agrees.

Note which array was *not* the problem: `cacc`, the 256 accumulators, was already
being converted to registers (`Replacing memory \cacc with list of registers`)
because each element has its own driver from the generate loop. Same intent, two
different outcomes, decided by how the array is written.

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
| `my_chip_n4_c0_r1` | f2a | 5.7 MB | `mac_array` | 151.5 × 151.5 µm | 103 |
| `my_chip_n4_c1_r1` | f2b | 6.5 MB | `mac_array` | 155.8 × 155.8 µm | 102 |
| `amx_s1` | a1 | **423 MB** | `amx_tdpbssd` | **1554.8 × 1554.8 µm** | 103 |

Every one is verified rather than merely present: `scripts/gds.sh` reads the
stream back, asserts the top cell is `mac_array` with a non-empty bounding box,
and requires KLayout to have reported both "All LEF cells have matching GDS/OAS
cells" and "No orphan cells in the final layout". A wrong or truncated stream
still produces a plausibly-sized file, so existence is not correctness.

`make gds` builds one for an already-routed config straight from `6_final.def`,
without re-running synthesis, placement or routing — which is how the v0 row got
its layout without rebuilding the pre-addend RTL.
