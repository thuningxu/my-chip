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
| OpenROAD | 26Q3-1510-g6cb3f2b704 |
| ORFS | `6ada18baba` — the commit whose OpenROAD submodule *is* that hash |
| PDK | nangate45 (academic, no fab target) |
| Corner | `NangateOpenCellLibrary_typical.lib` — **typical only, not signoff** |
| yosys | 0.68 |
| Simulator | Icarus Verilog 12.0 |
| SDC convention | single clock, 20% I/O delay, **0.1 ns uncertainty**, false path on `rst_n` |

The first row used to be labelled "ORFS". It is **OpenROAD's** `git describe`, not ORFS's —
ORFS's own `26Q3` tag is only a few hundred commits back, so anyone reading
`26Q3-1510` as an ORFS revision cannot check it out. Both are now given.

### Two platforms, and what differs between them

Rows **v0 … p1** were measured on macOS 26.5 / arm64 / AppleClang, yosys from
Homebrew. Rows **X5-Y0 onward** were measured on AlmaLinux 9.6 / x86_64 / gcc 11.5,
yosys from conda-forge, at the **identical OpenROAD commit**. The toolchain was
pinned deliberately rather than taken from HEAD, so the platform is the only
variable between the two sets.

It was calibrated on two designs before any new row was claimed, and the answer
differs by design:

| | `mac_array` f1b | `amx_fp8` p1 |
|---|---|---|
| flip-flops | **exact** (455) | **exact** (57,867) |
| stdcells | −0.17% | −0.28% |
| area | −1.0% | −0.28% |
| implied fmax | +1.3% | +0.84% |
| power | **+11%** | −0.32% |
| hold | `+0.0004, 0 viol` → `−0.0002, **1 viol**` | `+0.0448` → `+0.0423`, both met |

**Structure is reproduced essentially exactly; hold and power are not.** On the
small design the platform alone moved power 11% and pushed one endpoint into hold
violation. On the large one everything agreed inside 0.32%. So cross-platform rows
are comparable in structure and frequency, and should **not** be compared in hold
or power. Within a platform there is no such caveat, and the X5 pair below is
same-platform by construction.

## Units

**Three of the four designs have no floating point anywhere.** `mac_array`,
`amx_tdpbssd` and `tpu_mmu` are integer / fixed-point throughout, so a "FLOPS"
figure would be meaningless for them and none is given.

**`amx_fp8` is the exception**, and this section used to say the project had no
floating point at all — written before that design existed. It multiplies fp8 and
accumulates in **IEEE FP32**, so a FLOPS figure *is* meaningful for it, with one
caveat that matters more than the number: the operations are **mixed precision**.
One MAC is one fp8 multiply plus one FP32 add, so quoting "331.7 GFLOP/s" for row
p3 without saying that half of those ops are 8-bit is precisely the inflated
headline this section exists to prevent. Where a single figure is wanted for that
design, **GMAC/s is the honest one** and is what the rows use.

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

There are now **four designs**, and their rows are tabulated separately because
their metrics are not comparable: `mac_array` is measured in cycles for a
runtime-variable K, the other three in cycles for one fixed-shape instruction.
Forcing them into one table would put a "Cycles @K=1024" number next to a design
that has no K.

- **`mac_array`** — INT4 outer-product array, `D = init + A@B`. Rows below.
- **`amx_tdpbssd`** — Intel AMX `TDPBSSD`, INT8, `C += A@B`. See
  [amx rows](#results--amx_tdpbssd).
- **`tpu_mmu`** — TPU v1-style weight-stationary systolic array, INT8, built at
  `TN=32` so its multiplier count matches `amx_tdpbssd` exactly. See
  [tpu rows](#results--tpu_mmu).
- **`amx_fp8`** — Intel AMX-FP8, fp8 in and **IEEE FP32 accumulate**, same operand
  delivery as `amx_tdpbssd` so the delta is purely arithmetic. See
  [fp8 rows](#results--amx_fp8).

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

### The routed cost of saturation: 23x what coarse synth predicted

Measured at last, one variable apart (`PIPE=1`, 2.00 ns target, identical
everything else). This was open from the moment `SAT` was introduced.

| | `SAT=0` | `SAT=1` | Δ |
|---|---|---|---|
| setup WS ns | −0.5367 | −0.4702 | +0.0664 |
| setup TNS | −1242.9 | −1067.8 | +175.1 |
| implied fmax | 394.2 | 404.8 | +10.6 |
| **stdcells** | 474,810 | 492,398 | **+17,588** |
| **flip-flops** | 29,194 | 29,194 | **0** |
| area µm² | 958,398 | 971,277 | +12,879 |

**Saturation costs area, not state, and not speed.** Zero flops, exactly as
expected: the clamp is pure combinational logic (an XOR on the top two bits of a
33-bit sum, a rail select, a fold mux).

**+17,588 stdcells against a coarse-synth prediction of +768. 23×.** That is the
largest coarse-to-routed misprediction in this project, and the third of its kind:

| change | coarse synth | routed | ratio |
|---|---|---|---|
| `c_in` (384-bit input port) | +381 | +1,170 | 3.1× |
| `out_all` (384-bit output port) | −911 | +99 | **sign flip** |
| `SAT=1` (the clamp) | +768 | +17,588 | **22.9×** |

The mechanism differs from the first two. Those were wide *ports* whose buffering
coarse synth cannot see. This one is small logic in the **worst possible place**:
the fold mux sits inside the accumulate feedback loop, `cacc → add → fold → cacc`,
so it is on a path the tool must fight for. 17,588 ÷ 256 accumulators ≈ **69 extra
cells per accumulator** spent sizing and buffering around three coarse cells.
Coarse counts say what logic exists; they say nothing about where it sits.

**The +10.6 MHz is NOT attributable.** It sits exactly at this project's 10 MHz
threshold, and its direction is backwards — removing logic should not slow a design
down. The explanation is that both variants are limited by the *same* feed-forward
path (`ccnt → mux → multiply → tree → s4r`), which `SAT` does not touch, so `SAT`
should make no frequency difference at all. Supporting that: `SAT=0` got **worse**
TNS with **fewer** cells, i.e. the tool simply spent less effort because the
accumulate loop had slack to spare while the binding path elsewhere was unchanged.

So the honest summary: **`SAT=1` is a 3.6% area tax for a semantic guarantee, and
free in frequency.** Which makes it a reasonable default — but only because it was
measured, since coarse synth would have sold it as a 0.15% tax.

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

---

## Results — tpu_mmu

TPU v1-style **weight-stationary systolic array**: `C += A @ W`, all N×N, signed
INT8 × signed INT8 accumulating into INT32, wrapping. Weights resident in the PEs,
activations marching in from the left, partial sums marching down, accumulators
**outside** the array. Built at `N=32` because 32×32 = **1024 multipliers is
exactly `amx_tdpbssd`'s count** — matched arithmetic is what makes this a controlled
comparison instead of one across two scales, which is the error the amx campaign
spent a day retracting.

Reference for the architecture: Jouppi et al., ISCA 2017 — 256×256 = 65,536 INT8
MACs, 700 MHz, 92 TOPS, 75 W TDP, 28 nm, <331 mm². Verified against the paper, not
recalled.

| # | Design | Stage | Period | Setup WS | reg→reg fmax | Limiter | DRC | Hold WS | Cycles/op | stdcells | flip-flops | area µm² | power W |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| t1 | `tpu_mmu` `N=32 RD_REG=1` | routed | 1.40 ns | **−0.1502** | **645.1 MHz** | `reg→reg` | **0** | **−0.0278** | 96 (sim) | 915,078 | 83,307 | 1,653,910 | 2.2322 |

Flop count predicted **83,851** before the run, actual **83,307** — off by 544
(0.65%). The breakdown: `acc` 32,768 + `p_reg` 21,504 + `a_reg` 8,192 + weights
8,192 + A tile 8,192 + input skew 3,968 + `rd_data` 1,024 + control.

### Head-to-head at matched arithmetic

Both rows at **1.40 ns**, both **1024 INT8 MACs**. Equal target and equal MAC count
is the only comparison this project treats as valid.

| | amx broadcast | tpu systolic | ratio |
|---|---|---|---|
| reg→reg fmax | 698.9 MHz | 645.1 MHz | **0.92×** |
| flip-flops | 47,116 | 83,307 | 1.77× |
| std cells | 532,445 | 915,078 | 1.72× |
| area µm² | 1,046,050 | 1,653,910 | 1.58× |
| power W | 2.436 | **2.232** | **0.92×** |
| hold | +0.0386 met | −0.0278, **180 viol** | — |

**Power is 8% LOWER with 1.77× the flip-flops and 1.72× the cells.** Neighbour-only
communication pays for itself in switching energy even at this size — the one
prediction about this architecture that held.

### The hypothesis is NOT yet tested, and the path report says why

I predicted the systolic array would clock materially faster because no PE sees
more than one multiply and one add. It came in **slower**, and the reason is not the
architecture:

```
ccnt[0] -> 4 buffers -> MUX2 x5 -> AND2 -> AND2 -> FA chain -> p_reg[0][15]
```

The critical path starts at the **cycle counter**, runs through a **32:1
row-select mux**, and lands in the multiplier's carry chain. That is
`a_flat[ccnt*N*8 +: N*8]` — the operand mux at the array's input edge, left
**combinational**. The PE-to-PE path (`a_reg → mul → add → p_reg`) never became
critical, so the systolic structure has not been measured at all.

This is the **same defect as amx's**, and I walked into it after writing a comment
in this very file about avoiding a mux on the array's input edge. The fix is the
amx `S3` lesson verbatim: register `a_row`, cutting 5 mux levels off the front of
the multiply for ~256 flops.

### Throughput is the bigger problem, and it is architectural

| | amx | tpu N=32 |
|---|---|---|
| MACs / operation | 16,384 | 32,768 |
| cycles / operation | 20 | **96** |
| **array utilisation** | **80.0%** | **33.3%** |
| fill/drain cycles | 4 | **64** |
| as built, back-to-back | **572.5 GMAC/s** | **220.2 GMAC/s** |
| peak datapath | 715.7 GMAC/s | 660.6 GMAC/s |
| efficiency, as built | 235.0 GMAC/s/W | 98.6 GMAC/s/W |
| **efficiency, at peak** | **293.8 GMAC/s/W** | **295.9 GMAC/s/W** |

A systolic array costs `2N−2` cycles of ramp. At N=32 that is **64 cycles of a
96-cycle operation**, against amx's 4 of 20. The two designs are within **1%** of
each other at peak (295.9 vs 293.8 GMAC/s/W), which says the arithmetic is
comparably efficient and the entire 2.6× throughput gap is utilisation.

What the architecture is actually for is weight reuse — `M` activation rows against
one resident `W`, giving `M·N²` MACs in `M + 2N − 2` cycles:

| M | GMAC/s | utilisation |
|---|---|---|
| 32 (as built) | 224.9 | 34.0% |
| 128 | 445.0 | 67.4% |
| 256 | 531.8 | 80.5% |
| 1024 | 622.9 | 94.3% |
| 4096 | 650.7 | 98.5% |

**The FSM only does M=N.** It reloads A and re-ramps on every operation, so it sits
permanently at the left end of that table. The capability is structural in the array
— the weights are already stationary — but the control does not expose it. This is
precisely why TPU v1 pairs a 256×256 array with a 24 MiB activation buffer: at
N=256 the ramp is 510 cycles, so streaming thousands of rows per weight load is not
an optimisation, it is the only way the array is worth building.

### HOLD IS VIOLATED — this row is not signoff-clean

−0.0278 ns over **180 endpoints**. No clock period fixes a min-delay failure. The
amx campaign closed the identical problem with `HOLD_SLACK_MARGIN=0.05` and **no RTL
change**, and that was not tried here. Treat t1 as a measurement of the datapath,
not as a buildable configuration.

### What is verified, independent of any PPA number

- **28/28** `sim-matrix` configurations, `tpu_mmu` at N=4/8/16/32 × `RD_REG`=0/1
- `tpu_golden.py`: the schedule proof (provenance tags through the array), model
  agreement, the exact `16 + clog2(N)` psum bound driven to `N × 16384`, `C +=`
  chains, and **negative tests** — wrong placement by ±1 row and a transposed
  weight load must both be *detected*, or the value checks prove nothing
- **8 RTL mutations, each caught**: skew reversed, accumulate one cycle early and
  one late, weights transposed, psum one bit narrow, accumulator indices swapped,
  multiply using its own register instead of the arriving operand, sign-extension
  dropped

### Three things found by testing rather than reasoning

1. **The output-placement algebra was off by one.** Hand derivation gives
   `m = t − j − N`; the register-level model gives `m = t − j − (N−1)`; the RTL
   needs a third form again (`ccnt == m + j + N`) because it samples `p_reg` a cycle
   after the model emits. Writing the Python model first found this in seconds.
2. **A comment of mine asserted something false.** I claimed the `ccnt < N` bound on
   the A row select prevents corrupting the tail sums. It does not — removing it
   passes every test at every N, because the activation `PE(i,j)` consumes at cycle
   `t` is `A[t−i−j][i]` and `t−i−j` *is* the output row, so out-of-range activations
   only feed partial sums no accumulator is ever enabled for. The bound is an **area**
   guard: a mux over N rows instead of 3N−1.
3. **The `SYNTH_MEMORY_MAX_BITS` risk was real but does not bite.** `a_reg`, `p_reg`
   and `acc` are all reported as "Replacing memory with list of registers" and
   **zero `$mem` cells survive at N=32**, because every write is constant-index.
   Checked before starting a flow rather than after one failed.

### Reporting defect found while writing this up

`measure.sh`'s QoR row prints the `N` column from mac_array's `N` variable, so the
t1 row came out labelled `N=4` when the design was built at `TN=32`. The artifact
name (`tpu_n32`) and `VERILOG_TOP_PARAMS` were both correct, so only the printed
row was wrong — but a metrics table that mislabels its own configuration is exactly
the class of defect this log exists to catch. Fixed.

---

## Results — amx_fp8

**Intel AMX-FP8** (Diamond Rapids): all four mix-and-match variants in ONE netlist,
selected at runtime by `op[1:0]` — `op[1]` = A is HF8, `op[0]` = B is HF8, so the
encoding reads as the mnemonic.

| op | mnemonic | src1 (A) | src2 (B) |
|---|---|---|---|
| 00 | `TDPBF8PS` | BF8 = E5M2 | BF8 = E5M2 |
| 01 | `TDPBHF8PS` | BF8 = E5M2 | HF8 = E4M3 |
| 10 | `TDPHBF8PS` | HF8 = E4M3 | BF8 = E5M2 |
| 11 | `TDPHF8PS` | HF8 = E4M3 | HF8 = E4M3 |

`C[16][16]` fp32 `+= A[16][64]` fp8 `@ B[64][16]` fp8 — 16,384 MACs in 20 cycles,
1024 fp8 multipliers and **1024 IEEE FP32 adders**, four independent FP32
accumulators per output element, RNE rounding, DAZ in / FTZ out.

**Why it exists.** The `tpu_mmu` row above cannot attribute its result, because it
moved TWO variables at once — operand delivery *and* accumulator placement. This
design moves ONE. It reuses `amx_tdpbssd`'s operand delivery **exactly**: same 16×64
register tiles, same 16:1 mux on B's row, same per-row 16:1 mux on A's dword, same
k-outermost schedule. And it happens to land on the **same cycle count**, because
`amx_tdpbssd` at `PIPE=3` is also 20 cycles. So MACs, latency and operand delivery
are all identical, and the only thing that differs is the arithmetic.

| # | Design | Stage | Period | Setup WS | reg→reg fmax | Limiter | DRC | Hold WS | Cycles/op | stdcells | flip-flops | area µm² | power W |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| p1 | `amx_fp8` `RD_REG=1` | routed | 4.00 ns | **−1.7128** | **175.0 MHz** | `reg→reg` | **0** | **+0.0448** | 20 (sim) | 3,985,240 | 57,867 | 4,758,450 | 40.3523 |
| p2 | `amx_fp8` `PIPE=0 RD_REG=1` — X5-Y0 | routed | 4.00 ns | **−1.6654** | **176.5 MHz** | `reg→reg` | **0** | **+0.0423** | 20 (sim) | 3,974,058 | 57,867 | 4,745,090 | 40.2251 |
| p3 | `amx_fp8` `PIPE=1 RD_REG=1` — X5-Y1 | routed | 4.00 ns | **−0.7041** | **212.6 MHz** | `reg→reg` | **0** | **+0.0454** | 21 (sim) | 3,454,124 | 74,252 | 4,361,340 | 14.0894 |

**p2 is p1's configuration re-measured on the second platform**, and it is what p3
is compared against — not p1. **p3 is the one experiment**, `PIPE` 0→1, at p2's
target and knobs. See [X5](experiments/harness.md#x5--the-adder-is-the-floor-and-everything-ahead-of-it-is-one-register-away) for the generation that
declared it and [the X5 findings](#x5-findings--registering-the-product-and-a-floor-that-was-not-the-ceiling)
below for what it measured.

Setup is NOT met at 4.00 ns, and that is the informative outcome rather than a
failure: `TNS = −60,409 ns` with four separate optimisation stages each failing to
move it is this log's own signature for a **real wall**. The 7.00 ns run that was
started first was aborted precisely because it would have closed with `|TNS| ≈ 0`
and measured the constraint instead of the hardware.

Flop count predicted **57,867** before the run, actual **57,867** — exact. Breakdown:
`lacc` 32,768 (256 cells × 4 lanes × 32 b) + A tile 8,192 + B tile 8,192 + `cacc`
8,192 + `rd_data` 512 + control 11. Confirmed four ways: netlist `DFF` count, the
pre-CTS `clk` net fanout, CTS's sink count, and the final cell report.

### Head-to-head: same MACs, same cycles, same operand delivery

| | amx broadcast INT8 | amx broadcast **FP8** | ratio |
|---|---|---|---|
| arithmetic | INT8×INT8 → INT32, exact | fp8×fp8 (exact) → **64 rounded IEEE FP32 adds** | — |
| MACs / instruction | 16,384 | 16,384 | **1.00×** |
| cycles / instruction | 20 | 20 | **1.00×** |
| reg→reg fmax | 698.9 MHz | **175.0 MHz** | **0.25×** |
| throughput | 572.5 GMAC/s | **143.4 GMAC/s** | **0.25×** |
| flip-flops | 47,116 | 57,867 | 1.23× |
| std cells | 532,445 | **3,985,240** | **7.48×** |
| area µm² | 1,046,050 | 4,758,450 | 4.55× |
| DRC | 0 | 0 | — |
| hold | +0.0386 met | +0.0448 met | both clean |

**Bit-exact IEEE FP32 accumulation costs 4.0× the clock, 4.0× the throughput and
7.5× the cells against INT32 accumulation, at identical MAC count, identical
latency and identical operand delivery.** Because MACs and cycles match exactly,
the throughput ratio *is* the frequency ratio — no accounting required.

The multiplier is not the cost. One 4×4 significand multiply serves all four
instructions (both formats decode to a common 4-bit left-aligned significand), and
`fp8_mul` maps to **181 cells against `fp32_add`'s 2,270**. FP8 arithmetic is
cheaper than INT8 to multiply and vastly more expensive to accumulate.

### The critical path, and the claim it refutes

Routed, with parasitics. Startpoint `ccnt[1]`, endpoint
`g_m[1].g_n[13].lacc[49]`, **113 gate levels**:

| segment | delay | gates |
|---|---|---|
| clock network to launch flop | 1.276 ns | — |
| `ccnt` CLK→Q | 0.151 ns | — |
| operand mux + buffers | **0.864 ns** | 13 |
| `fp8_mul` | **1.157 ns** | 19 |
| `fp32_add` | **3.306 ns** | 77 |
| final gates → `lacc/D` | 0.046 ns | — |
| **data path from Q** | **5.373 ns** | **113** |

I predicted before measuring that the limiter would be the
`lacc → fp32_add → lacc` feedback loop and that **no feed-forward pipelining could
move it**. The endpoint is indeed a lane accumulator, and the limiter class is
`reg→reg` (so the 175.0 MHz is honest, with no I/O-delay inflation — `overall` and
`regreg` are the same path). But the second half of that prediction is **WRONG**:
the path *launches from `ccnt`*, so **2.021 ns — 38% of the data path — is
feed-forward logic ahead of the adder.** A single pipeline register at the adder
input would remove it, putting the design near ~3.5 ns / ~285 MHz.

The true accumulator loop is only the 3.306 ns adder segment, and that is the floor
a `PIPE` ladder would converge to. It also validates the leaf measurement in
hindsight: `fp32_add` alone measured 2.491 ns pre-layout and 3.306 ns routed, a
sane 1.33× for real parasitics and in-array fanout. The error was comparing a
standalone-leaf number to a whole path.

### What the ISA does not settle, quantified

Three sources disagree on how AMX-FP8 accumulates. Intel's patent EP4398097A2 says
the four byte-lane products are accumulated **separately** — four running sums,
combined with C at the end — and that is what is built. Bochs (`cpu/avx/amx.cc`)
keeps two running halves with a pairwise tree, which looks like its BF16 code shape
carried over to FP8's four lanes. LLVM's `amxfp8intrin.h` shows one wide
accumulator but wraps its fp8 operands in `INT64(...)` copy-pasted from the INT8
header, so it was discarded.

**Genuinely unresolved: the order the four lane sums are combined.** A balanced tree
is used, on hardware grounds — two adder levels instead of three, three epilogue
cycles instead of four. It is not cosmetic: `tb/fp8_golden.py` computes both
orderings and prints how far apart they are on every run.

```
[INFO] epilogue order UNRESOLVED in the sources: balanced tree vs
       sequential differ in 118/512 elements (23.05%)
```

23% of the output. So this design is bit-exact for every finite and infinite input
**given** the balanced tree, and the model can switch with one flag if better
documentation appears. Also deviating: NaN results are canonicalised to
`0x7FC00000` rather than propagating a source payload.

### Verified independent of any PPA number

Leaves first, because a rounding bug 1024 instances deep inside a 16-cycle
accumulation is indistinguishable from a schedule bug.

| gate | what it establishes |
|---|---|
| `tb_fp8_mul.v` | **EXHAUSTIVE** — all 4 format pairs × 256 × 256 = 262,144 cases against an independently written 24×24 model, four checksums tied to Python, and every product proven **exact** |
| `tb_fp32_add.v` | 121,376 checks — RNE ties at both parities, the alignment cap, deep cancellation, DAZ, the FTZ boundary at `e_fin` = 0/1/2, the full Inf/NaN matrix, commutativity on **every** vector |
| `tb_amx_fp8.v` | **29** cases × `RD_REG` 0/1 × `PIPE` 0/1; all four instructions **bit-exact** against `tb/fp8_golden.py`. The 29th is **O1**, added with `PIPE` — see X5 |
| mutation | 42 mutations; every real one caught |

Four mutation survivors were investigated and proved to be **genuine no-ops**,
recorded in the RTL so they are not mistaken for gaps: the alignment cap 27-vs-26
(a normal's leading 1 already lands in the sticky position at 26 — capping at 25 or
24 IS caught), and epilogue writes to lanes 1 and 3 (dead registers; EP0 consumes
them on the same edge that overwrites lanes 0 and 2). Two genuine gaps were found
and closed: the FTZ boundary at `e_fin == 0`, and `op` being latched at `start`.

`fp8_golden.py`'s second FP32 adder converts to Python floats, adds in FP64 and
rounds to FP32. That is sound for a **single** add because 53 ≥ 2p+2 = 50
(innocuous double rounding); overflow and underflow break the theorem and are
refused loudly rather than returned wrong.

### Routing closed, and the congestion warning was pessimistic

The global placer reported it **could not reach its routability target** and settled
at weighted congestion 0.9969 — essentially exactly at capacity, on the full
metal2–metal10 stack. That looked like the run's real risk. It was not:

```
global route     converged using 2 of 30 congestion iterations, 2m45s
detailed route   820,738 -> 318,273 -> 289,183 -> 8,127 -> 95 -> 10 -> 3 -> 3 -> 0
                 closed at iteration 8 of a 64 budget
```

Final: **0 DRC**, 0 antenna diodes, 60,586,359 µm of routed wire, 25,050,772
single-cut vias, and a GDS verified by read-back (top cell `amx_fp8`, die
3065.3 × 3065.3 µm) rather than by existence.

Hold is **fully clean** (`+0.0448` met, 0 violations) because `--hold-margin 0.05`
was passed from the start — the omission that left the `tpu_mmu` row dirty at
−0.0278 over 180 endpoints. CTS inserted **49,454 hold buffers** to get there, on a
clock tree of 11,094 buffers with a uniform 16-buffer depth and 0.196 ns setup skew.

**Power reads 40.35 W and is not credible**, per the same caveat as every row above:
this log's own rows span 19.0 W to 0.99 W for one design at one target.

### Three process failures worth recording

1. **A leaf benchmark is not a flow benchmark.** `fp32_add` was measured standalone
   with `abc -liberty` (1,260 cells, 6.180 ns) and used to project the design. ORFS
   maps with `abc_speed.script` plus `upsize`/`dnsize`, which gives **2,270 cells at
   2.491 ns** — 1.80× the area for 2.48× the speed. So the projection was **1.86×
   low on cells and 2.5× slow on timing**, and the bad timing number is what caused
   a 7.00 ns target to be chosen and a run to be thrown away. Benchmark a leaf with
   the flow's own recipe or not at all.

2. **Intermediate log tables are not results.** The design's area was misreported
   three times (+23%, then +67%, then a synthesis figure compared against another
   row's routed figure) by quoting running repair tables. A post-CTS "540× setup
   improvement" was also reported that never happened — it was a *hold* repair
   table, identifiable by its narrow column set and sub-nanosecond TNS. Only
   stage-final metrics JSON is quotable.

3. **`share` cannot help a design where nothing is shareable, and will not say so.**
   yosys's SAT-based resource sharing had not finished after 27 MINUTES on this
   design, where all 1024 adders are active every cycle. With `-noshare` the coarse
   phase takes **40 seconds**. Separately, keeping `fp32_add`/`fp8_mul` hierarchical
   cut whole-synthesis from ">34 min and still in ABC" to **90 s**, at +1.7% area —
   because flattening makes ABC optimise 1024 independent copies of identical logic.
   yosys is single-threaded with no `-j`; OpenROAD already uses all 18 cores. The
   fix had to be doing less work, not spreading it.

Keeping the modules hierarchical also exposed a latent bug: yosys emits
`input signed [5:0] a_exp;` into the netlist and **OpenSTA's Verilog reader rejects
`signed`** (`STA-0171`), killing the run at `1_synth`. Invisible while flattened,
because then there are no submodule ports at all. Fixed at the root — those ports
are unsigned now, since every use site already sign-extends explicitly.

### What this row sets up

The measured breakdown says the next experiment is not a guess:

1. **A `PIPE` register at the adder input.** 2.021 ns of the 5.373 ns data path is
   feed-forward. This is the single highest-value change and the row above is what
   justifies it.
2. **Pipelining `fp32_add` itself**, which needs interleaved accumulators so the
   adder is not in a one-cycle loop — the only thing that shortens a 77-gate,
   3.306 ns combinational block.
3. **A narrow-operand accumulate adder.** The accumulate step's second operand is a
   product with only 8 significant bits; the epilogue reuse is what forces a general
   FP32 adder. Not taken here deliberately.

---

## X5 findings — registering the product, and a floor that was not the ceiling

Generation declared in [`experiments/harness.md`](experiments/harness.md#x5--the-adder-is-the-floor-and-everything-ahead-of-it-is-one-register-away) before
either trial ran. Rows **p2** (PIPE=0) and **p3** (PIPE=1) above; same platform,
same 4.00 ns target, same hold margin, one parameter apart.

### What it bought

| | p2 `PIPE=0` | p3 `PIPE=1` | Δ |
|---|---|---|---|
| implied period | 5.6654 ns | 4.7041 ns | −0.961 ns |
| reg→reg fmax | 176.5 MHz | **212.6 MHz** | +20.5% |
| **cycles / instruction** | **20** | **21** | **+5%** |
| **throughput** | 144.6 GMAC/s | **165.9 GMAC/s** | **+14.7%** |
| power | 40.2251 W | **14.0894 W** | **−65.0%** |
| **energy efficiency** | 3.59 GMAC/J | **11.77 GMAC/J** | **3.28×** |
| stdcells | 3,974,058 | 3,454,124 | −13.1% |
| area µm² | 4,745,090 | 4,361,340 | −8.1% |
| flip-flops | 57,867 | 74,252 | +28.3% |
| setup TNS | −59,371.7 | −12,285.5 | 4.8× better |
| hold WS | +0.0423 | +0.0454 | both met |
| DRC | 0 | 0 | both clean |

**The number is +14.7%, not +20.5%.** `PIPE` buys clock with a cycle — 20 → 21 —
and Rule 3 exists so that a clock gain is never quoted as a throughput gain.

**The area saving is optimiser effort, and it was nearly credited to the wrong
mechanism.** The first write-up of this row attributed the 13.1% cell drop to X4's
glitch-truncation — one register stopping 1024 multiplier outputs from toggling
through 1024 adders. The cell-class breakdown refutes it:

| cell class | `PIPE=0` | `PIPE=1` | Δ µm² |
|---|---|---|---|
| `timing_repair_buffer` | 1,141,280 | 631,196 | **−510,084** |
| `sequential_cell` | 261,687 | 335,781 | +74,094 (the 16,384 new flops) |
| everything else | — | — | +52,254 |
| **total stdcell** | 4,745,090 | 4,361,340 | **−383,750** |

The repair-buffer saving **exceeds the total**, and the balance is exact. `PIPE=0`
misses its target by 1.6654 ns and `PIPE=1` by 0.7041, so the tool spends half a
million µm² of buffers on the harder one and gives them back on the easier one.
This is X1-Y0's signature — "−10,644 stdcells against −10,437 timing-repair
buffers: the same cells" — reappearing in an RTL change rather than a target change.

**Power is a separate question and is not settled by this pair.** −65.0% power
against −10.8% area is not proportionate to the buffers removed, and glitch
truncation remains the plausible mechanism for the remainder — X1 measured −94.8%
power from exactly this change shape at equal target. But the two effects are not
separated here, and a row that cannot separate them should say so rather than pick
the more flattering one. Ranking power in the declaration is still what made the
effect visible at all.

Flop prediction **74,252 against 74,252 measured** — asserted by
`trial.sh --expect-flops`, not logged beside the result.

### The prediction was WRONG, and the way it was wrong is the finding

X5 declared a floor of **3.692 ns / 270.9 MHz** and predicted Y1 would reach it.
Measured **4.7041 ns / 212.6 MHz** — 1.012 ns short, capturing about half the
2.021 ns the register was supposed to remove.

The path report says why. Routed, with parasitics, delay attributed by region:

| region | p2 `PIPE=0` | p3 `PIPE=1` |
|---|---|---|
| `ccnt` fanout + operand/epilogue muxes | 0.952 ns | 1.087 ns |
| `fp8_mul` | 1.006 ns | **0 — registered out** |
| `fp32_add` | 3.299 ns | 3.315 ns |
| **data path from Q** | **5.257 ns** | **4.402 ns** |

`fp32_add` is 3.299 → 3.315 ns, so extrapolating the adder segment was correct.
`fp8_mul` is gone, so the register did exactly its job. **The error was the
startpoint.** The floor assumed the post-register path would be
`pr → fp32_add → lacc`. It is not: the worst path launches from **`ccnt[2]`** — a
control counter — spends 1.087 ns in a buffer tree and through mux *select* pins,
and only then enters the adder. A data-side register cannot shorten a path that
arrives at a mux on its control input.

**And the accumulate loop has never been the limiter.** All three routed runs —
p1, p2, p3 — launch from `ccnt`, at both `PIPE` settings, on both platforms; only
the lane the path lands on moves with placement (p1 lane 1, p2 lane 2, p3 lane 0).
X5's "What X5 CANNOT reach" named `lacc → fp32_add → lacc` as the floor. That loop
is genuinely irreducible, and it is genuinely **not** what is binding. The
generation was right about the arithmetic and wrong about the topology, and no
amount of further datapath pipelining would have revealed it — only reading the
startpoint did.

The next move follows directly and is cheap: **register the control `ccnt` drives**,
so the mux select is settled at cycle start and the path begins adjacent to the
adder. That is ~1.09 ns of the remaining 4.402 ns for a few hundred replicated
flops, against the 16,384 this rung cost. It is a *control*-pipelining generation,
not another datapath one.

### Correction to the head-to-head above: cycles no longer match

The [head-to-head](#head-to-head-same-macs-same-cycles-same-operand-delivery) table
concluded "because MACs and cycles match exactly, the throughput ratio *is* the
frequency ratio — no accounting required." **`PIPE=1` breaks that**: 21 cycles
against `amx_tdpbssd`'s 20, so the two ratios diverge and latency has to be stated.
The comparison is still controlled on MAC count and operand delivery.

Restated at each design's own operating point — `amx_tdpbssd` `PIPE=3 RD_REG=1` at
1.40 ns, `amx_fp8` at 4.00 ns:

| cost of bit-exact FP32 accumulation | was (p1) | now (p3) |
|---|---|---|
| frequency | 3.99× | 3.29× |
| **throughput** | **3.99×** | **3.45×** |
| stdcells | 7.48× | **6.49×** |
| area | 4.55× | **4.17×** |
| flip-flops | 1.23× | **1.58×** ← worse |
| energy per MAC | ~65× | **~20×** |

So the claim "4.0× the throughput and 7.5× the cells" becomes **3.45× and 6.49×**:
one register recovered roughly an eighth of the penalty. Flops moved the wrong way,
as they must — 16,384 registers is pure storage.

**Two caveats, in order of how much they should bother a reader.** The power column
compares runs at *different targets* (1.40 vs 4.00 ns) so optimiser effort differs,
and this log's own rows span 19.0 W to 0.99 W for one design at one target — read
"~20×" as an order of magnitude, not a measurement. The frequency comparison
crosses targets too, so by this project's own rule it is not like-for-like; it is
fair as "each design at its own operating point" and nothing stronger. The p2 → p3
pair carries no such caveat.

The broader read: FP32 accumulation's cost was never mainly speed. At 3.45× the
throughput but ~20× the energy and 6.49× the cells, what IEEE-exact accumulation
buys you is paid for in silicon and power — and this rung moved the cheap axis
further than the expensive one.

### Verified before the row was claimed

| gate | result |
|---|---|
| `PIPE=0` flop count | **57,867** — identical to the pre-parameter RTL, the figure p1 predicted and hit |
| `PIPE=0` cell histogram | **identical** to pre-parameter RTL: 26 cell types, 116,911 cells |
| `PIPE=1` flop count | 74,252 = 16,384 product bits + `v_sr` |
| `tb_fp8_mul.v` | `y[15:0] == 0` on all **262,144** inputs → the 16-bit register is lossless by exhaustion |
| `tb_amx_fp8.v` | 29/29 at every `PIPE` × `RD_REG`, bit-exact against `fp8_golden.py` |
| mutation | a pure `kcnt` rotation is survived by **18 of 29** checks; new case **O1** fails 256/256 |
| `make sim-matrix` | all **34** configurations |
| both rows | `reg→reg` limited, DRC 0, GDS present (3.5 GB / 3.3 GB) |

O1 exists because `amx_tdpbssd`'s S6 lesson transfers: FP32 addition is not
associative, a one-off enable *permutes* k rather than dropping it, and uniform
operands cannot see a permutation even in principle. O1 accumulates `2^24` at k=0
then `1.0` for k=1..15; in order every one vanishes to an RNE tie, permuted they sum
to 15 first and survive — `0x4B800000` against `0x4B800008`.

### Process notes

**A mutation that proves nothing.** The first mutant tried was a doubly-delayed
accumulate enable. In `amx_fp8` that *drops* k rather than permuting it, because the
late pulse lands on EP0 where `ep0` has already taken lanes 0 and 2's operand B —
22 of 29 checks catch it, and it says nothing about ordering. Only a pure `kcnt`
rotation isolates order from count.

**A path-report script that double-counted.** The first attribution of p2's path
spanned first-`MUX2`-to-last-`MUX2` and so swallowed `fp8_mul`, reporting a 1.323 ns
"operand mux". Walking the path in order and binding each row to a region gives the
table above. Both numbers were mine and only the second is in this log; the first is
recorded here so the discarded figure is not mistaken for a measurement.

**`make measure` never passed `-P`.** Found while plumbing `PIPE` through: the target
dropped the flag, so `make measure PIPE=n` had always built `PIPE=0`. The drift guard
at `measure.sh:127` structurally cannot catch it — with no `-P` both sim and synth
agree on the default, so the guard is satisfied while the requested configuration was
never built. Every `PIPE` row on record came through `trial.sh`, which does pass it,
so no published row is affected; but the `make` route to a `PIPE` row was dead for the
whole amx campaign.

## X6 findings — local epilogue control improves completed MAC throughput

Completed 2026-09-07. The declared pair differs only in `CTRL_REG`, on the same
frozen RTL (`sha256[0:16] = 7da8ee7a89063d22`), host and flow settings:
`PIPE=1 RD_REG=1`, 4.00 ns, utilization 40%, hold margin 0.05 ns, 32 threads
per run. Both jobs exited zero. These are **routed STA estimates**, Nangate45
typical corner, not measured silicon performance or signoff.

| row | trial | CTRL_REG | stage | target ns | reg→reg MHz | measured II | actual latency | GMAC/s | setup WS ns | setup TNS | hold WS ns | hold violations | DRC | flops | stdcells | stdcell area µm² | power W |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| p4 | X6-Y0 | 0 | routed | 4.00 | 219.3 | 21 | 20 | 171.113 | −0.559528 | −8779.11 | +0.0443583 | 0 | 0 | 74252 | 3423820 | 4336630 | 14.1854 |
| p5 | X6-Y1 | 1 | routed | 4.00 | 247.9 | 21 | 20 | **193.428** | −0.0335012 | −1.29961 | +0.0434359 | 0 | 0 | 75020 | 2984378 | 3979430 | 12.6034 |

Throughput is `16384 / (II * implied_period_ns)` GMAC/s, using the four-decimal
reg-to-reg slack recorded by the timing helper, not the rounded MHz column.
Q1 measures both launch and completion intervals over four consecutive resident
instructions, all four format encodings, with no reload/readback between them.
The original single-operation checker counts 21 edges because it samples `done`
before NBA updates; timestamped start-to-done latency is 20. Neither number is
inferred from the other. Tile transfers are excluded from this throughput.

### The attributable gain

Y0 → Y1 is **+13.04% throughput**, −12.83% stdcells, −8.24% stdcell area and
−11.15% reported power, at the cost of exactly 768 additional flip-flops. II
does not change, so this pair's frequency gain and throughput gain coincide.
Compare against **X6-Y0**, not X5-Y1's 165.9 GMAC/s: the new baseline itself is
171.1 GMAC/s. That movement is not a benefit of `CTRL_REG`, and this pair does
not isolate which flow/run differences caused it.

The cell-class budget again identifies the area mechanism: timing-repair buffer
area falls **605326 → 232342 µm²** (−372984), sequential area grows by 4660,
and other classes grow by 11124, summing to the −357200 total. The repair-buffer
saving exceeds the whole area saving. Do not label this a glitch-power result:
the power mechanisms were not separately measured.

### The startpoint prediction is confirmed, but the feedback limit is not reached

The final reports identify:

- Y0: `ccnt[2] → control decode/distribution → fp32_add → cacc[154][5]`.
- Y1: cell (4,5) `ep_ctrl[0] → local buffer/mux → fp32_add → lacc[69]` (lane 2).

Approximate region delays from the reports' two-decimal arrival columns:

| region, launch Q to capture D | Y0 ns | Y1 ns |
|---|---|---|
| control distribution and operand mux, before the adder | 0.85 | 0.14 |
| FP32 adder, including in-module routing | 3.29 | 3.49 |
| tail after the adder | 0.11 | 0.11 |
| total data-path delay | 4.25 | 3.74 |

The long global control path is removed as intended. Some of the saving is
offset by a slower adder segment in the new implementation. The worst path
**still starts on control**, now local control, not on the lane accumulator;
claiming the pure feedback loop is now the limiter would repeat X5's mistake.

Y1 remains **33.5 ps short of the 4.00 ns target**, with 174 setup violations,
despite DRC=0 and hold passing. It is not timing-closed at 250 MHz. TNS near
zero also means this pair cannot establish that 247.9 MHz is the architecture's
ceiling. A tighter-target experiment is a sensible next test of optimization
headroom; none is launched as part of these two trials.

### Artifacts and verification

Both frozen-source sim gates pass 30/30, II=21 and latency=20. The full parameter
regression passed 38 configurations before launch. ORFS synthesis verified all
768 distinct mapped control drivers for Y1 before placement; routed total-flop
counts match 74252/75020. Both GDS files are present: **3519393480 bytes** (Y0)
and **3294862860 bytes** (Y1), with empty final routed DRC reports.

Trial rows are in `experiments/trials.jsonl`; frozen inputs and wrapper logs
are in `work/campaigns/x6/`. Final path reports are
`work/reports/nangate45/fp8_x6y{0,1}/base/6_finish.rpt` and timing classifications
are in `work/logs/nangate45/fp8_x6y{0,1}/base/limiter.json`. Reprint the ranking
with `python3 scripts/trials.py --throughput`. Final supervisor statuses are
`EXIT 0` at 2026-09-06 23:36 UTC (Y0) and 2026-09-07 01:35 UTC (Y1).

### X6 target sweep — p6/p7 close the timing-effort question

The unchanged `PIPE=1 RD_REG=1 CTRL_REG=1` RTL was run at two tighter targets,
with the same hold margin, utilization and 32-thread limit. Both jobs exited
zero, both have GDS, DRC=0 and zero hold violations. Rates exclude transfers
and use STA-implied register-to-register clocks; neither target closes setup.

| row | trial | target ns | reg→reg MHz | II | GMAC/s | setup WS ns | TNS | hold WS ns | flops | stdcells | area µm² | power W |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| p6 | X6-Y2 | 3.80 | 256.3 | 21 | 199.992 | −0.101071 | −293.433 | +0.0438729 | 75020 | 3212415 | 4176090 | 14.0044 |
| p7 | X6-Y3 | 3.60 | 256.6 | 21 | 200.208 | −0.296873 | −4335.23 | +0.0201836 | 75020 | 3638456 | 4533970 | 16.0663 |

Y2 → Y3 buys just **0.108%** throughput for **14.72%** more reported power
and **8.57%** more area. The worst paths start at the product register (Y2) and
local epilogue control (Y3), so this does not prove the feedback loop is the
absolute floor. It does make Y2 the practical X6 throughput point for the next
matched pair. X7 will test initiation interval rather than continue increasing
timing effort. GDS sizes are 3400056578 / 3631494594 bytes; full records and
start/endpoints are in `experiments/trials.jsonl`.

## X7 findings — one cycle of initiation interval, worth 5.1% that MHz cannot see

Generation declared in [`experiments/harness.md`](experiments/harness.md) on
2026-09-08, before any RTL change or trial. `CHAIN=1` accepts the next operation
on the current one's EP2 edge instead of waiting for IDLE, committing old `C` and
clearing the lane accumulators on that same edge. No FP32 operation moves and
nothing is reassociated.

Matched pair: same 3.80 ns target, same `PIPE=1 RD_REG=1 CTRL_REG=1`, same hold
margin, utilization and 32-thread limit, same RTL bytes
(`sha256[0:16] = 2d786dd038143aa3`), one parameter apart. Both exited zero, both
have GDS, DRC=0 and zero hold violations.

| row | trial | CHAIN | target ns | reg→reg MHz | II | latency | GMAC/s | setup WS ns | hold WS ns | flops | stdcells | power W |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| p8 | X7-Y0 | 0 | 3.80 | 256.7 | 21 | 20 | 200.265 | −0.0958469 | +0.0454 | 75020 | 3213431 | 13.8164 |
| p9 | X7-Y1 | 1 | 3.80 | 256.9 | **20** | 20 | **210.467** | −0.0923084 | +0.0459 | 75020 | 3207438 | 14.4541 |

**+5.094% completed MAC throughput for +0.08% clock.** The clock did not move —
256.7 → 256.9 MHz is inside any reasonable noise band — and the entire gain is the
initiation interval falling 21 → 20 while start-to-done latency stays 20.

**This is the row that justifies X6's metric change.** Ranked on MHz this pair is
flat to three decimal places and would have been discarded as a failed rung.
Ranked on completed throughput it is the second-largest single-parameter win in
the `amx_fp8` campaign. It is the same lesson as X4's power finding — a hillclimb
that ranks one scalar cannot see a Pareto move — arriving in a third dimension,
and this time the harness was already watching for it rather than discovering it
at close.

**Storage is exactly unchanged: 75,020 flops both sides, 768 local control
drivers both sides**, verified against the routed netlists rather than inferred
from a total. `CHAIN` is a handshake and a rollover, not a register.

The declaration's prediction held, including the number: it predicted II=20,
latency unchanged at 20, and "+5%, about 210 GMAC/s". Measured 210.467. It also
named its own falsifier — "a clock regression of 4.76% erases the entire gain" —
and the measured clock moved +0.08%, so the gain survives its own stated test.
That is a sharp contrast with X5, whose central prediction missed by 1.012 ns, and
the difference is instructive: X7 predicted a *cycle count*, which is a property of
the RTL that simulation can settle before any flow runs, while X5 predicted a
*routed delay*, which depends on where the tool decides the worst path is.

Costs, stated plainly: reported power rises 4.62% (13.8164 → 14.4541 W) and
stdcells fall 0.19%, so **energy per MAC is flat** — 14.495 → 14.561 GMAC/J,
+0.46%, which is inside this flow's noise for power. The throughput is bought with
utilization of hardware already present, not with more hardware.

**Neither row closes setup**, so both rates are STA-implied at a
register-to-register clock, not timing-closed operating points. The X7 stop rule
was "a lower II without higher GMAC/s is a negative result"; that is not what
happened, so the fix family is not exhausted — but the remaining idle cycles are
the epilogue's three, and overlapping those is a different generation.
