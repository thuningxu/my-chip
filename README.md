# my-chip

A hill-climbing project on an INT4 MAC array, using open-source EDA
(Yosys + OpenROAD via ORFS) on the Nangate45 academic PDK.

The deliverable is **not** the chip. It is `EXPERIMENTS.md` — a table of
measured, reproducible rows where every row is one idea, and every number says
what kind of number it is.

## Prerequisites

| Dependency | Why | Minimum |
|---|---|---|
| Homebrew + Xcode CLT | installing everything else (macOS) | — |
| **Icarus Verilog** | simulation. `measure.sh` refuses to emit PPA without a passing sim | 12.0 |
| **Python 3** | golden model, QoR extraction | 3.8 |
| **Yosys** | synthesis | **0.58** (ORFS minimum) |
| **ORFS** with a built `openroad` | synthesis + place & route + STA | any recent — **see [SETUP.md](SETUP.md)** |
| **KLayout** | GDS merge — and ORFS calls `klayout -v` at makefile **parse** time | 0.28.8 |
| Nangate45 PDK | the standard cells; ships inside ORFS | — |

## Quick start

**On a brand-new machine, start with [SETUP.md](SETUP.md)** — it covers cloning
and building ORFS, which `setup.sh` requires but does not do. On macOS that is
the bulk of the work: ORFS's own `build_openroad.sh --local` does not work there,
and SETUP.md has the manual recipe.

Once ORFS exists and `openroad` runs:

```bash
./setup.sh          # check + install what's missing, write local.mk
make sim            # run the regression        (9/9 must pass)
make measure        # sim-gated synth + P&R, prints one QoR row
make path           # why the clock is what it is
```

`setup.sh` discovers ORFS automatically (`$ORFS`, `../OpenROAD-flow-scripts`,
`~/sd/...`), verifies the `openroad` binary actually runs, checks the Yosys
version against ORFS's 0.58 floor, and resolves a KLayout that **provably
answers `-v`** — auto-creating a de-quarantined copy on macOS if the
`/Applications` one hangs. It writes `local.mk` so no target needs exported
variables. Use `./setup.sh --check` to verify without installing anything.

```bash
make help                       # all targets + resolved tool paths
make sim N=8                    # regression at another array size
make sim-all                    # N = 4, 8, 16
make golden                     # Python reference model
make measure N=8 PERIOD=1.4     # override anything
make sweep-period               # 1.6 / 1.4 / 1.2 / 1.0 ns
make sweep-n                    # N = 4, 8, 16
make clean                      # local artifacts (ORFS results untouched)
```

**`measure.sh` will not produce a PPA number unless the regression passes.**
That gate is the point of the script.

## Layout

```
my-chip/
├── setup.sh             # dependency check/install -> writes local.mk
├── Makefile             # sim / measure / sweep / clean targets
├── local.mk             # generated, gitignored, machine-specific tool paths
├── rtl/mac_array.v      # v0 baseline: parameterised N x N INT4 outer-product MAC
├── tb/tb_mac_array.v    # self-checking regression, 9 cases, PASS at N=4/8/16
├── tb/golden.py         # independent Python reference + accumulator-width checker
├── flow/nangate45/
│   ├── config.mk.in     # ORFS config TEMPLATE -- the single definition
│   └── constraint.sdc.in# SDC TEMPLATE. Edit these; never the generated copies.
├── scripts/measure.sh   # sim gate -> stage -> ORFS -> QoR row
├── EXPERIMENTS.md       # the log. This is the actual output of the project.
└── work/                # ALL generated output, gitignored
    ├── designs/         #   generated per-N config.mk + constraint.sdc
    ├── results/         #   .odb / .def / .gds / netlists
    ├── reports/         #   layout images (*.webp), DRC report
    ├── logs/            #   per-stage logs + 6_report.json metrics
    └── objects/
```

### Nothing is written into the ORFS checkout

`measure.sh` passes ORFS two variables so the third-party clone stays pristine
and this repo owns its own artifacts:

| Variable | Set to | Effect |
|---|---|---|
| `WORK_HOME` | `my-chip/work` | redirects `LOG_DIR`, `OBJECTS_DIR`, `REPORTS_DIR`, `RESULTS_DIR` (`variables.mk:46-49`) |
| `DESIGN_HOME` | `my-chip/work/designs` | relocates the design tree (`variables.mk:13`) |

ORFS defaults `WORK_HOME ?= .` (`Makefile:98`), which is `$ORFS/flow` when you
run make from there — that is why an unconfigured flow scatters your results
across someone else's repo, where `git clean` or an ORFS update will eat them.
`VERILOG_FILES` points straight at this repo's `rtl/`, so the RTL is never
copied either.

Verified: relocating produced a byte-identical QoR row, and
`$ORFS/flow/{results,logs,reports,objects,designs}` contain no `my_chip_*`
entries.

## What the design computes

```
C[i][j] = sum over k of  A[k][i] * B[k][j]     for k in [0, k_dim)
```

`A[k]` and `B[k]` are each `N` signed INT4 lanes packed into one memory word.
The block masters two read ports and one write port; results drain as `N*N`
sequential writes. `N` is a parameter (power of two) — sweep it with
`measure.sh -n`.

v0 is deliberately the **simplest correct** design, not a fast one: multiply and
a full 24-bit add sit in the same cycle. That is the first thing to fix, and the
baseline you measure against.

## Discipline this repo enforces

Each of these exists because its absence caused a real, documented failure in a
prior project of this kind:

| Rule | Failure it prevents |
|---|---|
| `measure.sh` gates PPA on a passing sim | a published headline frequency for a design that computed `2*sum - last` instead of a dot product, because *it was never simulated* |
| T1 (all-ones, K=4) is permanent | that same double-accumulate bug — it shows up as `5` (or `7`) instead of `4` |
| T6 (restart with no reset) is permanent | `DONE` as a terminal state: first operation works, every later `start` silently ignored |
| T5 (adversarial K) + `golden.py --acc-w` | a 12-bit accumulator claimed safe to K=64 that actually overflows at K=32 |
| The config exists once, as a template `measure.sh` fills in | nearly every config in a comparable project hardcoded its author's home directory, unrunnable anywhere else — and a committed config nothing reads will silently drift from the one that runs |
| SDC always sets `set_clock_uncertainty` | omitting it flatters every reported frequency by ~10% |
| `EXPERIMENTS.md` has a `Stage` column | an ABC mapping objective (900 MHz) tabulated next to routed slack as if comparable |
| Baseline measured in *this* flow | speedups quoted against an external number that was never reproduced |
| `N` is a parameter | dozens of near-duplicate hand-copied RTL files, one per array size |

## Known gotchas already hit

- **Do not declare an output port `signed`.** Yosys preserves the attribute into
  the netlist and OpenSTA rejects it (`syntax error` on the port line). Bits are
  two's complement regardless.
- **`klayout -v` runs at makefile-parse time.** Every `make` invocation hangs if
  KLayout is quarantined. On macOS: `ditto --noextattr --norsrc` a copy, or clear
  `com.apple.quarantine`.
- **A variable-indexed 2D array read is an `N*N:1` mux.** Fine at N=4 and N=16
  (both measured; neither is limited by it), becomes the critical path around
  N=32. Pipeline the readout before scaling that far.
- **ORFS's `6_report` can fail at `GUI-0070`** (`gui::save_image` cannot find a
  display control) *after* metrics are already written. That is the image
  renderer, not the design — 9 of the 10 layout images are still produced, only
  `final_worst_path.webp` is lost. `measure.sh` tolerates that exact signature
  and hard-fails on anything else.
- **`read_db` does not restore liberty.** Load `read_liberty` first or STA gives
  you nothing but `STA-2141 No liberty libraries found`.
- **`report_checks` defaults to the worst path group**, which here is an
  asynchronous recovery check on `rst_n` — true, but a false path in the SDC and
  useless for finding the datapath limiter. Always pass `-path_group core_clock`
  (`scripts/report_path.sh` does).

## Honest scope

Nangate45 is a teaching PDK with no fab target, and `measure.sh` reports the
**typical** corner only, with no signoff derating. These numbers are useful for
comparing rows in `EXPERIMENTS.md` against each other. They are not silicon
predictions, and they are not comparable to a production accelerator on a modern
node.

Current state: **v0 baseline measured at N=4 and N=16, both DRC-clean, neither
meeting 1.00 ns.** See `EXPERIMENTS.md` for the rows and `rtl/README.md` for the
measured critical path.
