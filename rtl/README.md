# rtl/ — the designs

| file | what | scale |
|---|---|---|
| `mac_array.v` | INT4 outer-product MAC array — the **v0 baseline**, deliberately the simplest *correct* design so there is somewhere to climb from | 16 multipliers at N=4 |
| `amx_tdpbssd.v` | **Intel AMX `TDPBSSD`** — INT8 tile dot-product, `C += A@B`, with optional INT32 saturation | 1024 multipliers, 16 cycles |

The two are independent top-level modules with no shared code. `measure.sh -d`
selects which one to build, and each is passed only its own file — the ORFS
config used to glob `rtl/*.v`, which meant a syntax error in one broke synthesis
of the other.

---

# mac_array

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

---

# amx_tdpbssd — Intel AMX `TDPBSSD`

Tile dot-product, signed INT8 × signed INT8, accumulating into INT32:
**`C += A @ B`** on a `(16,64) @ (64,16) → (16,16)` shape — 16,384 MACs per
instruction. Semantics taken from the x86 ISA reference, not recalled.

## The physical shape is not the logical shape

**This is the one thing to get right.** All three `tmm` registers are 16 rows ×
64 bytes. "B is 64×16" describes the *logical* matrix; the pseudocode indexes
`tsrc2.row[k]` with `k` in 0…15, so B is **VNNI-interleaved** into the same
16×64 register as A:

| reg | operand | physical → logical | shape |
|---|---|---|---|
| `tmm0` | A (`tsrc1`) | `A_phys[m].byte[4k+b] = A[m][4k+b]` | 16×64 INT8, plain row-major |
| `tmm1` | B (`tsrc2`) | `B_phys[k].byte[4n+b] = B[4k+b][n]` | 64×16 INT8, **interleaved** |
| `tmm2` | C (`tsrcdest`) | `C_phys[m].dword[n] = C[m][n]` | 16×16 INT32, row-major |

Four *consecutive* logical rows of B (`4k`…`4k+3`) share one physical row, so
byte `b` of B's dword `n` lines up with byte `b` of A's dword `k`. With `K = 4k+b`
that is `C[m][n] += Σ_K A[m][K]·B[K][n]`.

Get the interleave wrong and you still get plausible numbers. Verified by
mutation: reversing the byte pairing is caught **only** by the asymmetric and
random cases — the all-ones and all-`−128` cases pass a wrong interleave, because
uniform tiles cannot detect a reordering.

## Saturation is a deliberate deviation

Intel's `DPBD` is plain modular INT32 — no clamp. So both behaviours are built:

| `SAT` | behaviour | |
|---|---|---|
| 0 | wraps | **bit-exact ISA conformance** |
| 1 | clamps to `[−2³¹, 2³¹−1]` | the deviation (default) |

**Where the clamp goes is part of the specification**, because saturating
addition is not associative: folding per step versus once after a tree over the
same four values gives `−1` versus `+1073741824`. It goes **once per k-step**,
which is exactly Intel's `DPBD` call boundary.

That is also what makes a k-outermost machine conformant to an m-outermost
specification: for a fixed `(m,n)` the k sequence is 0…15 in both, because `m`
and `n` index independent accumulators.

Note what saturation *cannot* reach: one instruction from `C=0` tops out at
`64 × 16384 = 1,048,576` — 21 bits. **A single TDPBSSD cannot overflow INT32**
(2047× margin). Saturation only matters for the `C +=` chain, so the tests
preload `tmm2` near the rails rather than hoping a long run gets there.

## Architecture

1024 multipliers, 16 cycles — one `k` per cycle with every `m` and `n` parallel,
which is the Sapphire Rapids rate. Widths are derived, not guessed:

```
product     −128·127 … −128·−128 = [−16256, +16384]   → 16 bits signed
sum of four                        [−65024, +65536]   → 18 bits signed
accumulator                                              32 bits
```

`sum4` therefore *cannot* overflow — only the final add can, which is why the
clamp sits there and nowhere else.

## Hard constraints — do not "fix" these

- **The tiles are flat packed vectors, not unpacked arrays.** `reg [511:0] t [0:15]`
  is inferred as a *memory*, and ORFS rejects it outright
  (`SYNTH_MEMORY_MAX_BITS`). More fundamentally it is wrong: the datapath reads a
  dword from **all 16 rows of A in the same cycle**, so it would need 16
  concurrent read ports. No SRAM has that. These are registers by necessity.
- **`cacc` is per-dword, not packed rows.** Packing C into 512-bit rows would put
  16 always blocks on different bit ranges of one array element — not something to
  rely on a synthesis tool accepting. Each accumulator gets exactly one driver.
- **The accumulator's `if/else-if` is flat, not nested** — same flop-inference
  lesson as `mac_array`.
- **Tile geometry is `localparam`, not `parameter`.** Changing it does not give a
  smaller TDPBSSD, it gives a different instruction.
