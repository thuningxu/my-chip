#!/usr/bin/env bash
#=============================================================================
# report_path.sh -- print the worst register-to-register path of a routed run,
# with real parasitics. This is how you find out WHAT is limiting the clock
# rather than guessing from the RTL.
#
#   scripts/report_path.sh [-n N] [-t TAG] [-g GROUP] [-c COUNT]
#
# Defaults to the core_clock path group. The default group in OpenSTA is
# whichever is worst overall, which for this design is an asynchronous
# recovery check on rst_n -- true but useless, since it is a false path in the
# SDC and tells you nothing about the datapath. Always ask for core_clock.
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/local.mk" ]] || { echo "run 'make setup' first" >&2; exit 1; }
ORFS="$(sed -n 's/^ORFS *:= *//p' "$HERE/local.mk")"
[[ -n "$ORFS" ]] || { echo "ORFS unset in local.mk" >&2; exit 1; }

# NOTE -c is COUNT here, not C_PORT -- it predates the parameter. C_PORT and
# OUT_PAR therefore use long names, which is also why the Makefile passes
# --cport/--outpar rather than the short flags measure.sh uses.
N=4; CPORT=1; OUTPAR=0; TAG=""; GROUP="core_clock"; COUNT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) N="$2"; shift 2 ;;
    -t) TAG="$2"; shift 2 ;;
    -g) GROUP="$2"; shift 2 ;;
    -c) COUNT="$2"; shift 2 ;;
    --cport) CPORT="$2"; shift 2 ;;
    --outpar) OUTPAR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=scripts/nick.sh
source "$HERE/scripts/nick.sh"
NICK="$(nick "$N" "$CPORT" "$TAG" "$OUTPAR")"
R="$HERE/work/results/nangate45/$NICK/base"
P="$ORFS/flow/platforms/nangate45"

for f in 6_final.odb 6_final.sdc 6_final.spef; do
  if [[ ! -f "$R/$f" ]]; then
    echo "FATAL: $R/$f missing." >&2
    echo "       Looked for config '$NICK' (N=$N C_PORT=$CPORT OUT_PAR=$OUTPAR${TAG:+ TAG=$TAG})." >&2
    echo "       Available in work/:" >&2
    nick_available "$HERE" | sed 's/^/         /' >&2
    echo "       Run: make measure N=$N CPORT=$CPORT OUTPAR=$OUTPAR" >&2
    exit 1
  fi
done

TCL=$(mktemp /tmp/report_path.XXXXXX.tcl)
trap 'rm -f "$TCL"' EXIT
cat > "$TCL" <<EOF
# read_db does NOT restore liberty -- load it first or STA-2141 "No liberty
# libraries found" is all you get.
read_liberty $P/lib/NangateOpenCellLibrary_typical.lib
read_db $R/6_final.odb
read_sdc $R/6_final.sdc
source $P/setRC.tcl
read_spef $R/6_final.spef
puts ""
puts "=== $NICK : worst '$GROUP' path (routed, with parasitics) ==="
report_checks -path_delay max -path_group $GROUP -group_path_count $COUNT -digits 3
EOF

"$ORFS/tools/install/OpenROAD/bin/openroad" -exit -no_init -threads 8 "$TCL" \
  | awk '/=== '"$NICK"'/,0'
