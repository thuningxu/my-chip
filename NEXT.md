# Where X2 stands, and the exact next command

Written at commit time for a machine change. `work/` is **gitignored**, so no flow
artifacts travel with the repo — only the RTL, the tests, the harness log and
`experiments/trials.jsonl`. Everything below is reproducible from a clean checkout.

## State

| | |
|---|---|
| branch | `design/fp8-x2` (**not** merged to `main`) |
| upstream | none set — `git push -u origin design/fp8-x2` |
| generation | X2, "the accumulate does not need to renormalise every add" |
| declared in | `experiments/harness_fp8.md` |

| Y | config | outcome |
|---|---|---|
| **Y0** | `ACC=0 RD_REG=1` @ 5.75 ns | **DONE.** 170.0 MHz reg→reg, DRC 0, hold +0.0440, 3,602,795 cells, 57,867 flops, 4,589,500 µm², 28.95 W. Provisional: WS −0.1315, not at `ws ≈ 0` |
| **Y1** | `ACC=1 FX_W=52` @ 3.00 ns | **FAILED** at global route, `GRT-0116` congestion. No PPA row, none claimed |
| **Y2** | `ACC=1 FX_W=52` @ 4.00 ns | **NEXT.** Declared, not yet run |

Y1's failure is a **target choice**, not a refutation. At equal stages it beat Y0 by
38.8% on cells and 32.6% on wirelength, and its CTS checkpoint implied 3.804 ns
pre-route against Y0's 5.934. It was asked for 3.00 ns, could not get it, and the
placer spent the difference on density until the router ran out of local capacity.
Full analysis in `experiments/harness_fp8.md`.

## The next command

```bash
./setup.sh                      # writes local.mk with this machine's tool paths
make sim-matrix                 # 40 configs; the gate before any PPA number
make mutate                     # 96 mutations must die, 6 survive as declared

scripts/trial.sh -x 2 -y 2 -d amx_fp8 -A 1 -W 52 -R 1 -p 4.00 -u 40 \
  --hold-margin 0.05 --expect-flops 39371 \
  -g "X2-Y2: ACC=1 at 4.00ns. Y1 failed GRT-0116 at 3.00ns having asked for 0.80ns
      its own CTS checkpoint said it could not have; the placer paid for that in
      density (48.2% vs Y0's 45.8%) and the router ran out of local capacity. This
      changes the target only, nothing in the design. PREDICTION: routes, lands
      3.9-4.3ns = 230-256 MHz against Y0's 170.0."
```

**Budget for it.** Y0's flow took **15.11 hours**; global route alone is ~4.7 h and
detailed route ~2.9 h. Y1 spent 34 min in global route before failing. Peak memory
7.6 GB. Run it detached and come back.

If Y2 also congests, the ladder continues Y3 (`-u 30`) then Y4 (`-W 44`) — both
declared with reasons in `experiments/harness_fp8.md`. Do not skip to Y4: a width
change and a congestion failure at the same time is unattributable.

## Two things that are easy to get wrong

**Artifact directory names.** `ACC=0` emits the bare nickname `fp8`, so p1's published
row keeps resolving; `ACC=1` emits `fp8_a1_w<FX_W>`. `nick_fp8` takes
`<ACC> <FX_W> [TAG]` and **rejects a non-numeric first argument**, because four
callers used to pass `TAG` first and a silent wrong directory is the failure that
file exists to prevent.

**Do not edit a script while it is executing.** bash reads scripts incrementally and
resumes from a shifted byte offset. During this session the arm-purity gate in
`measure.sh` was found to be broken *while* `measure.sh` was running it, and the fix
was deliberately deferred; `trial.sh` documents the same hazard about itself. Verify
by hand instead, then fix after the process exits.

## Verification state, all reproducible

| | |
|---|---|
| `tb_fx2fp32` | 140,962 checks, 0 errors |
| `tb_maxmag64` | 40,347 checks, 0 errors |
| `tb_amx_fp8` `ACC=0` | 30/30, four golden constants byte-identical to p1 |
| `tb_amx_fp8` `ACC=1` | 30/30 at `FX_W` 40/44/48/52/56 |
| mutations | 96 killed, 6 declared equivalent with proofs, 0 undeclared survivors |
| flop counts | `ACC=0` 57,867 (= p1 exactly), `ACC=1` 39,371 (= prediction exactly) |

`ACC=0` staying bit-identical to p1 is X2's one inviolable condition. If any `ACC=0`
golden constant moves, the Y is void whatever its PPA says.
