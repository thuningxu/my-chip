# rtl/ — the design

One file: `mac_array.v`. It is the **v0 baseline** — deliberately the simplest
*correct* design, not a fast one, so there is somewhere to climb from.

## What it computes

```
D[i][j] = init[i][j] + Σ over k of  Amem[k][i] · Bmem[k][j]   for k in [0, k_dim)
```

`Amem[k]` and `Bmem[k]` are each `N` signed INT4 lanes packed into one memory
word — memory coordinates, indexed `[k][lane]`, which is what `act_rdata` and
`wgt_rdata` carry. The mathematical matrices `A`/`B` are indexed `[row][col]`,
and the required layout is **`Amem[k]` = column k of A, `Bmem[k]` = row k of B**.
So `Amem = Aᵀ`, `Bmem = B` — only A is stored transposed — and the sum above is
`Σ_k A[i][k]·B[k][j]`, i.e. `D = init + A@B`. That asymmetry is forced by matmul
itself: `k` is A's column index and B's row index. See the `mac_array.v` header.

This is an **outer-product accumulation**: every cycle it reads one activation
word and one weight word, forms the full N×N outer product, and adds it into
N² independent accumulators — so every cycle touches all N² outputs, rather than
finishing one output at a time.

The block **masters its own memory ports** — it drives `act_addr`/`wgt_addr` and
expects read data one cycle later (ordinary synchronous SRAM). Results leave
either as N² sequential writes on `out_we`/`out_addr`/`out_wdata` (`OUT_PAR=0`)
or all at once on `out_all` in a single cycle (`OUT_PAR=1`).

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `N` | 4 | array edge. **Must be a power of two.** Instantiates N² MACs |
| `KW` | 16 | width of `k_dim`, so max accumulation depth is 2^KW − 1 |
| `ACC_W` | 24 | accumulator width |
| `C_PORT` | 1 | build the external-C preload path so `INIT_C` works. `0` prunes `c_in` and its N² muxes, and returns the accumulator's free sync-reset pin |
| `OUT_PAR` | 0 | `0` = serial drain, N² cycles through an N²:1 mux. `1` = all N² accumulators at once on `out_all`, 1 cycle |
| `RAW`, `OAW`, `OUT_AW` | derived | `$clog2(N)`, `$clog2(N²)`, and `N²·ACC_W` or 1. **Do not override** — the module asserts `OUT_AW` was not |

`N` is a *compile-time* array size; `k_dim` is a *run-time* input. Changing `N`
builds different silicon. Changing `k_dim` does not. Same for `C_PORT` and
`OUT_PAR`: both change the hardware, so `make sim-matrix` builds all 12
combinations of `N` × `C_PORT` × `OUT_PAR` — a parameter only ever shipped in one
state is dead code with a name.

Cycle counts follow from `OUT_PAR`, and are asserted by the testbench:

```
OUT_PAR=0   cycles = K + N² + 3        K=4, N=4  →  23
OUT_PAR=1   cycles = K + 4             K=4, N=4  →   8
```

The drain is a *fixed* cost, so it is nearly free at long K (98% of multiplier
cycles do useful work at K=1024) and dominates at the small tile a tensor core is
defined by (17% at K=4). Because it scales as N², `OUT_PAR=1` makes the cycle
count independent of N — 32.9× fewer cycles at K=4, N=16.

### Accumulator width arithmetic — do this every time you touch a width

```
max |product|   = |−8 · −8|            = 64
worst-case sum  = (2^KW − 1) · 64
KW=16, ACC_W=24 → 65535·64 = 4,194,240 ≤ 2^23−1 = 8,388,607     ✓ 2× margin
```

`tb/golden.py --acc-w N --kw M` prints this check. The reference project shipped
a 12-bit accumulator documented as safe to K=64 that actually overflowed at
K=32 — the arithmetic is three lines, so do it.

## The measured critical path

At N=4, 1.00 ns, post-route with parasitics:

```
Startpoint: wgt_rdata[14]      (input port)
Endpoint:   acc[7][23]         (accumulator bit 23 — the MSB)

wgt_rdata[14] → BUF_X32 → BUF_X8 → AND2_X4        ← partial product
              → FA_X1 → FA_X1 → FA_X1 → HA_X1/CO  ← multiplier reduction
              → FA_X1/CO → AOI21 → OAI21 → XOR2   ← carry propagate
              → HA_X1/S → NAND4 → … → acc[7][23]/D

arrival 1.289   required 1.011   slack −0.278 (VIOLATED)
six adder cells in series: 4× FA_X1 + 2× HA_X1
```

That is the multiply and the full 24-bit add in the **same cycle**, terminating
at the far end of the carry chain. It is not a surprise — it is what v0 was
written to be. Reproduce it with:

```bash
scripts/report_path.sh -n 4          # or -n 16, -g <group>, -c <count>
```

Where the 1.00 ns goes: 0.200 input delay (the SDC's 20% I/O budget) + 0.100
clock uncertainty + 0.038 setup, less 0.149 recovered from clock network delay,
leaves **1.011 ns for logic — and the logic needs 1.089.**

## Three deliberate inefficiencies (these are the climbing targets)

1. **Multiply and the full `ACC_W` add share one cycle.** Measured above as the
   limiter. → v1 registers the product; v2 narrows the per-cycle add to 12 bits
   with a periodic fold.
2. **`acc[drow][dcol]` is read with variable indices** during drain, which
   synthesises to an N²:1 mux. Harmless at N=4 (16:1); it becomes the critical
   path near N=32 (1024:1). The reference project's best design ended with
   exactly this as its one remaining violation. → v4 pipelines the readout.
3. **`issued < k_dim` is a KW-bit comparator sitting combinationally on an
   output port** (`act_req`). → v3 replaces it with a registered down-counter.

## Broadcast structure — and why fmax falls as N grows

`a_lane` depends only on the row index, `w_lane` only on the column index. No
data passes between neighbours: activation lane *i* is broadcast to all N
columns of row *i*, weight lane *j* to all N rows of column *j*.

So **each of the 2N input lanes drives N multipliers**, and that fanout grows
linearly with N. Measured consequence:

| N | fmax |
|---|---|
| 4 | 783 MHz |
| 16 | **748 MHz** (−4.5% for 16× the MACs) |

This is why v6 (output-stationary systolic, nearest-neighbour only) is on the
plan: it makes the worst path *local to one PE*, so it stops depending on N.

## Hard constraints — do not "fix" these

- **Never declare an output port `signed`.** Yosys preserves the attribute into
  the netlist and OpenSTA rejects it with a syntax error on the port line.
  `out_wdata` is deliberately unsigned; the bits are two's complement either way.
- **Derived parameters must be declared in the parameter list**, not as
  localparams after the ports. Verilog forbids declaration-after-use in a port
  declaration, and `OAW` is used to size `out_addr`.
- **`N` must be a power of two.** `RAW = $clog2(N)` sizes the drain counters, and
  the `{drow, dcol}` concatenation forming `out_addr` only equals `drow*N + dcol`
  when N is a power of two. There is an `initial` block that checks this.
- **No floating point anywhere.** Everything is integer/fixed-point.
