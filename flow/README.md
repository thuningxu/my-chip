# flow/ — ORFS config templates

Two files, both **templates**. Neither is a usable config on its own:

```
flow/nangate45/
├── config.mk.in        # ORFS design config
└── constraint.sdc.in   # timing constraints
```

`scripts/measure.sh` substitutes placeholders and writes the results to
`work/designs/nangate45/<nick>/`. **Edit the templates here; never the generated
copies**, which are overwritten on every run and gitignored.

## Why templates and not committed configs

There used to be a committed `flow/nangate45/my_chip_n4/config.mk` alongside a
generated copy. Nothing read the committed one — `measure.sh` wrote its own from
a heredoc. Two definitions of the same config, one of them inert, guaranteed to
drift, and an obvious trap: you edit the committed file and nothing changes.

Templating collapses that to one definition. It also fixes the failure mode in
a comparable project, where **nearly every config hardcoded the author's home
directory** and was unrunnable on any other machine. Here paths arrive as placeholders that
`measure.sh` fills in from the repo's own location, so absolute paths appear only
in generated, gitignored output.

## Placeholders

| Token | Filled with | File |
|---|---|---|
| `@NICK@` | `my_chip_n<N>[_tag]` | config |
| `@N@` | array size, via `VERILOG_TOP_PARAMS` | config |
| `@UTIL@` | `CORE_UTILIZATION` | config |
| `@PERIOD_PS@` | period in ps, for `ABC_CLOCK_PERIOD_IN_PS` | config |
| `@RTL_DIR@` | absolute path to `rtl/` | config |
| `@CFG_DIR@` | absolute path to the generated config dir | config |
| `@PERIOD@` | period in ns | SDC |

A guard in `measure.sh` fails the run if any `@TOKEN@` survives, so adding a
placeholder without a matching substitution rule is caught immediately.

## What each ORFS variable does

| Variable | Value | Why |
|---|---|---|
| `DESIGN_NAME` | `mac_array` | the top module |
| `VERILOG_FILES` | `$(wildcard @RTL_DIR@/*.v)` | reads `rtl/` in place — RTL is never copied |
| `VERILOG_TOP_PARAMS` | `N @N@` | overrides the top-level parameter. **Verified to work**: flip-flop counts match `N²·24 + control` at both N=4 (455) and N=16 (6,223) |
| `CORE_UTILIZATION` | `@UTIL@` | target density. 40 gives ~55% actual at N=4 |
| `PLACE_DENSITY_LB_ADDON` | 0.2 | placement headroom |
| `SYNTH_REPEATABLE_BUILD` | 1 | strips source-line attributes, so the netlist hash is stable when comments move |
| `ABC_CLOCK_PERIOD_IN_PS` | `@PERIOD_PS@` | **must track the SDC period.** `measure.sh` derives both from one `-p` argument so they cannot disagree |

## The SDC convention

Single clock, 20%-of-period I/O delays, **0.1 ns clock uncertainty**, false path
on the async `rst_n`.

**The clock uncertainty is not optional.** It budgets for jitter and skew that a
real clock has and an ideal SDC does not. A comparable project's headline SDC
omitted it entirely, which flattered every frequency it reported by roughly 10%
— and those numbers were then compared against a third party's. Omitting it is
how you accidentally publish an inflated result.

For context on where a 1.00 ns budget actually goes, measured at N=4:

```
0.200  input external delay (the 20% I/O budget)
0.100  clock uncertainty
0.038  library setup time
-0.149 recovered from clock network delay
─────
1.011 ns available for logic   (the logic needs 1.089 → slack −0.278)
```

So roughly a third of the nominal period is consumed before any gate switches.

## Gotchas

- **The clock port is excluded from `set_input_delay`.** Applying input delay to
  a clock port is meaningless and OpenSTA warns. `lsearch -inline -all -not
  -exact` removes it.
- **Yosys's SDC parser is a subset.** It reads this file too (for ABC), and it
  lacks commands OpenSTA has — the reference project hit exactly this and had to
  revert a `remove_from_collection` usage. Keep the SDC to plain
  `create_clock` / `set_input_delay` / `set_output_delay` /
  `set_clock_uncertainty` / `set_false_path`.
- **ABC period and SDC period must agree.** They are separate variables; setting
  one without the other makes synthesis optimise for a target that timing
  analysis never checks.
- **Nangate45 is a teaching PDK** with no fab target, and `measure.sh` reports
  the **typical** corner with no signoff derating. These numbers compare rows in
  `EXPERIMENTS.md` to each other. They are not silicon predictions.
