# scripts/ — the measurement harness

| Script | Job |
|---|---|
| `measure.sh` | RTL → **one row of `EXPERIMENTS.md`** |
| `report_path.sh` | routed design → **the worst timing path**, i.e. *why* the clock is what it is |
| `gds.sh` | routed design → a **verified GDS**, and it fails rather than accept an unverified one |
| `schematic.sh` | RTL → eight **readable schematics** at the coarse-cell level |
| `nick.sh` | the **single definition** of an artifact nickname — sourced, never run |

`measure.sh` tells you the number; `report_path.sh` tells you what to change to
improve it. Use both — a row without a known limiter is a row you cannot act on.

## Design parameters every script must agree on

`N`, `C_PORT` and `OUT_PAR` all change the hardware, so every script that names,
simulates, synthesises or draws a config takes all three. They are spelled
differently in different places for reasons that are not cosmetic:

| | Makefile | `measure.sh` / `gds.sh` | `report_path.sh` | design |
|---|---|---|---|---|
| which design | `DESIGN` | `-d` | `-d` | both |
| array size | `N` | `-n` | `-n` | `mac_array` |
| external C | `CPORT` | `-c` | `--cport` | `mac_array` |
| parallel readout | `OUTPAR` | `-r` | `--outpar` | `mac_array` |
| INT32 saturation | `SAT` | `-s` | `--sat` | `amx_tdpbssd` |

`measure.sh` decides everything design-specific in ONE `case` — the artifact
name, the RTL file list, the testbench, the top parameters and the sim `-P`
flags. Adding a third design means adding one case, not editing five places.

The ORFS config template no longer globs `rtl/*.v`. It did, which meant every
build elaborated every module and a syntax error in one design broke synthesis of
the other; `VERILOG_FILES` is now an explicit per-design list.

`report_path.sh` uses long names because its `-c` was already **count** before
`C_PORT` existed. Renaming it would silently change what `-c 5` means.

**`nick.sh` exists because these used to drift.** `measure.sh` writes
`work/` directories under a nickname and `report_path.sh` reads them; when they
derived the name independently, adding `C_PORT` made `make path N=4 CPORT=1` read
a *different design* than `make measure` had just written and report a plausible
wrong critical path. There is now one function. Do not re-derive the name.

A nickname omits a field when it is at its default, so `OUT_PAR=0` produces
`my_chip_n4_c1`, not `my_chip_n4_c1_r0` — every artifact that predates a
parameter keeps resolving. Note that `${4:+_r$4}` would have broken this: `:+`
tests for *non-empty*, and `"0"` is non-empty.

`amx_tdpbssd` gets its own builder, `nick_amx`, rather than more fields on
`nick()`. The two designs have **disjoint** parameter sets (`N`/`C_PORT`/`OUT_PAR`
vs `SAT`), so one shared builder would grow every `mac_array` name an empty `SAT`
slot. The distinct `amx_` prefix also guarantees no collision with the
`my_chip_*` artifacts already on disk. `SAT` is always emitted there — that
design has no legacy names to preserve, and *which saturation mode* is exactly
what you want visible on the directory.

## report_path.sh

```bash
scripts/report_path.sh -n 4                     # worst core_clock path, N=4
scripts/report_path.sh -n 16 -c 5               # top 5 paths (-c is COUNT here)
scripts/report_path.sh -n 4 --cport 1 --outpar 1
scripts/report_path.sh -n 4 -g asynchronous
```

Requires a completed `make measure N=<N>` (it reads `6_final.{odb,sdc,spef}`
from `work/`). Two non-obvious things it handles for you:

- **`read_db` does not restore liberty.** Without a preceding `read_liberty` all
  you get is `STA-2141 No liberty libraries found`.
- **It always passes `-path_group core_clock`.** OpenSTA's default reports the
  worst path overall, which for this design is an asynchronous recovery check on
  `rst_n` — genuinely the worst number, but a false path in the SDC and useless
  for finding the datapath limiter.

## measure.sh

It turns "some RTL" into one row of `EXPERIMENTS.md`, and it is the component
that makes the hill-climb trustworthy rather than just fast.

```
scripts/measure.sh [-n N] [-c C_PORT] [-r OUT_PAR] [-p PERIOD_NS] [-u UTIL]
                   [-t TAG] [--no-sim]
```

Normally invoked through the Makefile, which supplies tool paths from `local.mk`:

```bash
make measure                       # N=4, C_PORT=1, OUT_PAR=0, 1.00 ns, util 40
make measure N=8 PERIOD=1.4        # override anything
make measure OUTPAR=1              # parallel readout: 8 cycles at K=4, not 23
make sweep-period                  # 1.6 / 1.4 / 1.2 / 1.0 ns
```

The sim gate is passed **every** hardware parameter (`-Ptb_mac_array.N`,
`.C_PORT`, `.OUT_PAR`). Gating on a simulation of a different configuration than
the one being synthesised would make the gate decorative.

## The four stages

### 1. Simulate — the gate

Compiles `tb/` + `rtl/` with `-Ptb_mac_array.N=$N` and runs it. **If the
regression does not print `RESULT: PASS`, the script exits non-zero and no PPA
number is produced.**

This is the entire point of the script. The physical flow will cheerfully route
and report excellent timing for logic that computes the wrong answer — the
comparable project published a headline frequency for a design that returned
`2·Σ − last`, because it was never simulated. Timing closure is not correctness.

`--no-sim` bypasses the gate. If you use it, write `UNVERIFIED` in the row's
Notes column. It exists for debugging the flow itself, not for producing results.

### 2. Stage — fill the templates

Reads `flow/nangate45/{config.mk,constraint.sdc}.in`, substitutes placeholders,
writes to `work/designs/nangate45/<nick>/`.

The templates are the **single definition** of the config. There is no
hand-maintained second copy to drift. A guard fails the run if any `@TOKEN@`
survives substitution — so adding a placeholder without a matching `sed` rule is
caught here instead of confusing ORFS later. The guard strips comments first,
because the templates describe their own placeholder syntax in their headers.

No RTL is copied: `VERILOG_FILES` points straight at `rtl/`.

### 3. Run ORFS — with output redirected into this repo

```bash
make -C $ORFS/flow \
     WORK_HOME=my-chip/work \
     DESIGN_HOME=my-chip/work/designs \
     DESIGN_CONFIG=<abs path to generated config.mk> \
     YOSYS_EXE=... KLAYOUT_CMD=... finish
```

| Variable | Why |
|---|---|
| `WORK_HOME` | ORFS defaults it to `.` (`Makefile:98`), which is `$ORFS/flow` when make runs there. It feeds `LOG_DIR`, `OBJECTS_DIR`, `REPORTS_DIR`, `RESULTS_DIR` (`variables.mk:46-49`), so leaving it unset scatters *your* results through a third-party checkout where `git clean` will eat them |
| `DESIGN_HOME` | relocates the design tree (`variables.mk:13`) |
| `DESIGN_CONFIG` | must be **absolute**, since it no longer lives under `$ORFS/flow` |
| `KLAYOUT_CMD` | ORFS evaluates `klayout -v` in a `$(shell …)` at **makefile-parse time**. A quarantined KLayout hangs *every* target, including `make help`. `setup.sh` resolves one that provably answers |

Verified: relocating produced a byte-identical QoR row, and no `my_chip_*`
entries exist anywhere under `$ORFS/flow`.

### 4. Extract — one markdown row

Parses `6_report.json` and the routed DRC report into:

```
| design | N | period | setup WS | TNS | hold WS | implied fmax | DRC | stdcells | flip-flops | area um2 | power W |
```

`implied fmax = 1000 / (period − setup_WS)`. If setup is violated it prints the
period to retry at. **"flip-flops" means flip-flops** — 1-bit storage elements,
not FLOPS; there is no floating point in this project.

## Failure modes it handles deliberately

**Tolerated:** ORFS's `6_report` stage renders layout images via
`gui::save_image`, which fails on some OpenROAD builds with
`GUI-0013`/`GUI-0070` ("Unable to find visible display control at Timing
Path/*"). That is the *image renderer*, not the design — metrics are written
before it runs, and 9 of the 10 images are produced anyway (only
`final_worst_path.webp` is lost). The script detects that exact signature,
warns, and continues.

**Not tolerated:** any other non-zero exit, or a missing/empty `6_report.json`.
Those hard-fail with the log tail.

Both behaviours are narrow on purpose. Tolerating a broad class of flow failures
would let a genuinely broken run produce a row.

## A caution about the wrapper

If you invoke `measure.sh` from a wrapper that appends anything after it — e.g.
`measure.sh …; echo done` — the wrapper's exit status masks the script's. That
bit twice during development: a background task reported success while `make`
had returned 2. **Check for the artifact, not the exit code.**

## Environment

| Variable | Default | Source |
|---|---|---|
| `ORFS` | `~/sd/OpenROAD-flow-scripts` | `local.mk`, written by `setup.sh` |
| `YOSYS_EXE` | whatever is on `PATH` | `local.mk` |
| `KLAYOUT_CMD` | — | `local.mk` (required in practice) |
