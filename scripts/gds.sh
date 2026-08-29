#!/usr/bin/env bash
#=============================================================================
# gds.sh -- build (or rebuild) the GDS for an already-routed config, and prove
#           the result is a real layout rather than a file that exists.
#
# WHY THIS IS A SEPARATE TARGET. ORFS's `finish` lists its prerequisites as
#
#     finish: $(LOG_DIR)/6_report.log $(RESULTS_DIR)/6_final.v \
#             $(RESULTS_DIR)/6_final.sdc $(GDS_FINAL_FILE)
#
# and 6_report fails on this OpenROAD build at final_outputs.tcl:58 --
# `gui::show "source save_images.tcl"` wants a display control ("Timing Path/*")
# the build does not provide. Metrics are written before that call so they are
# always valid, but make aborts on the first failed prerequisite and
# $(GDS_FINAL_FILE) is LAST. Result: for a long time this project reported
# routed PPA for designs it had never actually built to a layout, behind a
# warning that only mentioned images.
#
# measure.sh now recovers the GDS inline and fails if it cannot. This script is
# for the other case: a config that was routed BEFORE that fix, or one whose GDS
# you want to regenerate. It works from 6_final.def, so it does not re-run
# synthesis, placement or routing.
#
# Usage:  scripts/gds.sh [-d DESIGN] [-n N] [-c C_PORT] [-r OUT_PAR] [-s SAT] [-t TAG]
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/nick.sh
source "$HERE/scripts/nick.sh"

[[ -f "$HERE/local.mk" ]] || { echo "run 'make setup' first" >&2; exit 1; }
ORFS="$(sed -n 's/^ORFS *:= *//p'        "$HERE/local.mk")"
YOSYS_EXE="$(sed -n 's/^YOSYS_EXE *:= *//p'   "$HERE/local.mk")"
KLAYOUT_CMD="$(sed -n 's/^KLAYOUT_CMD *:= *//p' "$HERE/local.mk")"
[[ -n "$ORFS" ]] || { echo "ORFS unset in local.mk" >&2; exit 1; }

DESIGN=mac_array; N=4; CPORT=1; OUTPAR=0; SAT=1; TAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) DESIGN="$2"; shift 2 ;;
    -n) N="$2"; shift 2 ;;
    -c) CPORT="$2"; shift 2 ;;
    -r) OUTPAR="$2"; shift 2 ;;
    -s) SAT="$2"; shift 2 ;;
    -t) TAG="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# An empty CPORT is legal: it addresses configs routed before C_PORT existed.
case "$DESIGN" in
  mac_array)   NICK="$(nick "$N" "$CPORT" "$TAG" "$OUTPAR")" ;;
  amx_tdpbssd) NICK="$(nick_amx "$SAT" "$TAG")" ;;
  *) echo "FATAL: unknown design '$DESIGN'" >&2; exit 2 ;;
esac
WORK="$HERE/work"
R="$WORK/results/nangate45/$NICK/base"
CFG="$WORK/designs/nangate45/$NICK/config.mk"

for f in "$R/6_final.def" "$CFG"; do
  if [[ ! -f "$f" ]]; then
    echo "FATAL: $f missing." >&2
    echo "       Looked for config '$NICK' (N=$N C_PORT=${CPORT:-none} OUT_PAR=$OUTPAR${TAG:+ TAG=$TAG})." >&2
    echo "       Available in work/:" >&2
    nick_available "$HERE" | sed 's/^/         /' >&2
    exit 1
  fi
done

echo "== building GDS for $NICK =="
LOG="$WORK/logs/${NICK}_gds.log"
mkdir -p "$(dirname "$LOG")"

MAKE_ARGS=(
  WORK_HOME="$WORK"
  DESIGN_HOME="$WORK/designs"
  DESIGN_CONFIG="$CFG"
)
[[ -n "$YOSYS_EXE"   ]] && MAKE_ARGS+=("YOSYS_EXE=$YOSYS_EXE")
[[ -n "$KLAYOUT_CMD" ]] && MAKE_ARGS+=("KLAYOUT_CMD=$KLAYOUT_CMD")

set +e
( cd "$ORFS/flow" && make "${MAKE_ARGS[@]}" do-gds ) > "$LOG" 2>&1
RC=$?
set -e

GDS="$R/6_final.gds"
if [[ $RC -ne 0 || ! -s "$GDS" ]]; then
  echo "FATAL: GDS build failed (rc=$RC). Tail of $LOG:" >&2
  tail -15 "$LOG" >&2
  exit 1
fi

# EXISTENCE IS NOT CORRECTNESS. Open it and check it is the design we asked for:
# a wrong or truncated stream still produces a plausibly-sized file.
python3 - "$GDS" "$LOG" <<'PY'
import re, sys
gds, log = sys.argv[1:3]
txt = open(log, errors="replace").read()
for want, msg in [("All LEF cells have matching GDS/OAS cells", "cell coverage"),
                  ("No orphan cells in the final layout",       "no orphans")]:
    if want not in txt:
        sys.exit("FATAL: klayout did not report '%s' -- %s unconfirmed" % (want, msg))
print("   klayout: all LEF cells matched, no orphan cells")
PY

# klayout picks its interpreter from the file EXTENSION, so `-r /dev/stdin` fails
# with "Can't run macro (no interpreter)". It needs a real .py file. And stderr is
# deliberately NOT suppressed here: this is the step that decides whether the
# stream is trustworthy, so a broken check must be loud, not invisible.
INSPECT=$(mktemp /tmp/gds_inspect.XXXXXX.py)
trap 'rm -f "$INSPECT"' EXIT
cat > "$INSPECT" <<PY
import pya, sys
ly = pya.Layout(); ly.read("$GDS")
top = ly.top_cell(); bb = top.bbox(); d = ly.dbu
w, h = bb.width()*d, bb.height()*d
if top.name != "$DESIGN":
    sys.exit("FATAL: top cell is '%s', expected '$DESIGN'" % top.name)
if w <= 0 or h <= 0:
    sys.exit("FATAL: empty bounding box -- the stream has no geometry")
print("   top=%s  die=%.1f x %.1f um  area=%.0f um2  cell defs=%d  layers=%d"
      % (top.name, w, h, w*h, ly.cells(), len(ly.layer_indexes())))
PY
"$KLAYOUT_CMD" -b -r "$INSPECT" \
  || { echo "FATAL: could not read back $GDS -- stream is not trustworthy" >&2; exit 1; }

printf '   %s  %s\n' "$(du -h "$GDS" | cut -f1)" "$GDS"
