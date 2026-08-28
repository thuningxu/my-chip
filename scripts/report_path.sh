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

N=4; TAG=""; GROUP="core_clock"; COUNT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) N="$2"; shift 2 ;;
    -t) TAG="$2"; shift 2 ;;
    -g) GROUP="$2"; shift 2 ;;
    -c) COUNT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

NICK="my_chip_n${N}${TAG:+_$TAG}"
R="$HERE/work/results/nangate45/$NICK/base"
P="$ORFS/flow/platforms/nangate45"

for f in 6_final.odb 6_final.sdc 6_final.spef; do
  [[ -f "$R/$f" ]] || { echo "FATAL: $R/$f missing -- run 'make measure N=$N' first" >&2; exit 1; }
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
