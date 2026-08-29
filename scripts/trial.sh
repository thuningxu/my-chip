#!/usr/bin/env bash
#=============================================================================
# trial.sh -- run ONE X-Y trial and append it to experiments/trials.jsonl.
#
# The outer loop of the hillclimb. X is a harness generation (declared in
# experiments/harness.md BEFORE its trials run); Y is an RTL attempt inside that
# generation. See harness.md for the rule that makes the two axes mean anything:
# a Y failing implicates the design, a whole X row going flat implicates the
# harness.
#
# WHAT THIS SCRIPT DELIBERATELY DOES NOT DO: decide anything. It runs the trial,
# reads the metrics out of the flow's own JSON, and records the result whether it
# improved or not. Choosing the next Y -- or deciding the row has gone flat and X
# must advance -- is the reasoning step, and reasoning does not belong in a shell
# script that cannot be held to account for it.
#
# It is a THIN wrapper. measure.sh already does the work, including the thing
# that matters most: refusing to emit a PPA number for RTL that has not passed
# its regression. So a trial cannot log a row for broken hardware.
#
# Artifact isolation is free: nick_amx() already takes a TAG, so tag x1y1 lands
# in work/*/amx_s1_x1y1/ and cannot collide with another trial.
#
# Usage:
#   scripts/trial.sh -x 1 -y 0 -g "goal string" [-p PERIOD] [-s SAT]
#                    [-P PIPE] [--hold-margin NS] [--dry-run]
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_JSONL="$HERE/experiments/trials.jsonl"

X=""; Y=""; GOAL=""
DESIGN=amx_tdpbssd
SAT=1; PIPE=0; PERIOD=2.80; UTIL=40; HOLD_MARGIN=""
DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -x) X="$2"; shift 2 ;;
    -y) Y="$2"; shift 2 ;;
    -g) GOAL="$2"; shift 2 ;;
    -d) DESIGN="$2"; shift 2 ;;
    -s) SAT="$2"; shift 2 ;;
    -P) PIPE="$2"; shift 2 ;;
    -p) PERIOD="$2"; shift 2 ;;
    -u) UTIL="$2"; shift 2 ;;
    --hold-margin) HOLD_MARGIN="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$X" && -n "$Y" ]] || { echo "FATAL: -x and -y are required" >&2; exit 2; }
# A trial without a goal is unattributable after the fact, and the protocol is
# that a failed attempt's goal gets quoted into the next one. So it is mandatory.
[[ -n "$GOAL" ]] || { echo "FATAL: -g GOAL is required -- an untagged trial teaches nothing" >&2; exit 2; }

# The harness generation must be DECLARED before its trials run. Without this
# check it would be possible to run a row and write the reasoning afterwards to
# fit the result, which is exactly the failure the two-axis rule exists to expose.
if ! grep -qE "^## X$X( |\$|—|-)" "$HERE/experiments/harness.md" 2>/dev/null; then
  echo "FATAL: harness generation X$X is not declared in experiments/harness.md." >&2
  echo "       Declare what it reads, blames, proposes and CANNOT reach first." >&2
  exit 1
fi

TAG="x${X}y${Y}"
mkdir -p "$HERE/experiments"

# shellcheck source=scripts/nick.sh
source "$HERE/scripts/nick.sh"
case "$DESIGN" in
  amx_tdpbssd) NICK="$(nick_amx "$SAT" "$TAG")" ;;
  *) echo "FATAL: trial.sh currently targets amx_tdpbssd only" >&2; exit 2 ;;
esac

# Identify the RTL by content, not by branch state: a trial has to stay
# attributable to exact bytes after the tree moves on.
RTL_SHA=$(shasum -a 256 "$HERE/rtl/$DESIGN.v" | cut -c1-16)
GIT_SHA=$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo "unknown")
DIRTY=$(git -C "$HERE" status --porcelain 2>/dev/null | head -1)

echo "=============================================================="
echo " TRIAL X${X}-Y${Y}   $DESIGN   SAT=$SAT PIPE=$PIPE"
echo " period ${PERIOD}ns  util ${UTIL}%${HOLD_MARGIN:+  hold_margin ${HOLD_MARGIN}ns}"
echo " rtl sha256[0:16] $RTL_SHA   git $GIT_SHA${DIRTY:+ (dirty)}"
echo " goal: $GOAL"
echo "=============================================================="

if [[ $DRY -eq 1 ]]; then echo "(dry run -- not executing)"; exit 0; fi

START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
set +e
ORFS="$(sed -n 's/^ORFS *:= *//p' "$HERE/local.mk")" \
YOSYS_EXE="$(sed -n 's/^YOSYS_EXE *:= *//p' "$HERE/local.mk")" \
KLAYOUT_CMD="$(sed -n 's/^KLAYOUT_CMD *:= *//p' "$HERE/local.mk")" \
  "$HERE/scripts/measure.sh" -d "$DESIGN" -s "$SAT" -P "$PIPE" \
    -p "$PERIOD" -u "$UTIL" \
    -t "$TAG" ${HOLD_MARGIN:+--hold-margin "$HOLD_MARGIN"}
RC=$?
set -e
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ---- metrics, straight from the flow's own JSON -------------------------------
R="$HERE/work/logs/nangate45/$NICK/base/6_report.json"
DRC="$HERE/work/reports/nangate45/$NICK/base/5_route_drc.rpt"
GDS="$HERE/work/results/nangate45/$NICK/base/6_final.gds"
NETLIST="$HERE/work/results/nangate45/$NICK/base/6_final.v"
FLW=$(grep -rhoE 'FLW-0009\] Clock [a-z_]+ slack -?[0-9.]+' \
        "$HERE/work/logs/nangate45/$NICK/base/"*.log 2>/dev/null | tail -1 \
        | grep -oE '\-?[0-9.]+$' || true)

python3 - "$LOG_JSONL" "$R" "${DRC:-}" "${GDS:-}" "$NETLIST" <<PY
import json, os, sys, subprocess
jsonl, rep, drc, gds, netlist = sys.argv[1:6]
rec = {
  "x": $X, "y": $Y, "tag": "$TAG", "design": "$DESIGN",
  "goal": """$GOAL""",
  "started": "$START", "ended": "$END",
  "knobs": {"SAT": $SAT, "PIPE": $PIPE, "period_ns": $PERIOD, "util": $UTIL,
            "hold_margin_ns": ${HOLD_MARGIN:-None}},
  "rtl_sha256_16": "$RTL_SHA", "git": "$GIT_SHA", "dirty": bool("""$DIRTY"""),
  "measure_rc": $RC,
}
if $RC != 0 or not os.path.exists(rep):
    rec["result"] = "FAIL"
    rec["metrics"] = None
    rec["note"] = "measure.sh returned %d; no PPA row produced" % $RC
else:
    m = json.load(open(rep))
    g = lambda k: m.get(k)
    ws = float(g("finish__timing__setup__ws"))
    ff = 0
    if os.path.exists(netlist):
        ff = int(subprocess.run(["grep","-coE",r"^\\s*(DFF|SDFF)[A-Z_]*_X[0-9]+",netlist],
                 capture_output=True,text=True).stdout.strip() or 0)
    drc_n = 0
    if drc and os.path.exists(drc):
        drc_n = sum(1 for _ in open(drc))
    rec["result"] = "OK"
    rec["metrics"] = {
      "setup_ws_ns": ws,
      "setup_tns": float(g("finish__timing__setup__tns")),
      "hold_ws_ns": float(g("finish__timing__hold__ws")),
      "setup_viol": int(g("finish__timing__drv__setup_violation_count") or 0),
      "hold_viol": int(g("finish__timing__drv__hold_violation_count") or 0),
      "implied_fmax_mhz": round(1000.0/($PERIOD - ws), 1),
      "stdcells": int(g("finish__design__instance__count__stdcell")),
      "flipflops": ff,
      "area_um2": float(g("finish__design__instance__area")),
      "power_w": float(g("finish__power__total")),
      "drc_lines": drc_n,
      "gds_bytes": os.path.getsize(gds) if gds and os.path.exists(gds) else 0,
      "flw0009_slack_ns": ${FLW:-None},
    }
    # The two must agree. They did on every mac_array row; if they ever diverge
    # the run is not trustworthy and the divergence is itself the finding.
    if ${FLW:-None} is not None and abs(${FLW:-0} - ws) > 0.05:
        rec["bugs"] = ["FLW-0009 (%.4f) disagrees with routed setup WS (%.4f) by >0.05 ns"
                       % (${FLW:-0}, ws)]
with open(jsonl, "a") as f:
    f.write(json.dumps(rec) + "\n")
print()
print("  logged X$X-Y$Y -> %s" % jsonl)
if rec["metrics"]:
    mm = rec["metrics"]
    print("  setup %+.4f ns -> %.1f MHz | hold %+.4f (%d viol) | %d cells | %.0f um2 | DRC %d"
          % (mm["setup_ws_ns"], mm["implied_fmax_mhz"], mm["hold_ws_ns"],
             mm["hold_viol"], mm["stdcells"], mm["area_um2"], mm["drc_lines"]))
else:
    print("  FAILED -- no metrics. That is still a data point.")
PY
