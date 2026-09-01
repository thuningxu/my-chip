#!/usr/bin/env bash
#=============================================================================
# sta_limiter.sh -- classify what is ACTUALLY limiting a routed config, and
# report the period-comparable register-to-register slack.
#
# WHY THIS EXISTS. The campaign's headline metric was
#
#     implied_fmax = 1000 / (period - setup_ws)
#
# and for eight trials nothing recorded WHERE the limiting path ended. That
# turned out to matter, because constraint.sdc.in budgets I/O as a FRACTION of
# the period:
#
#     set_input_delay  [expr $clk_period * 0.2] ...
#     set_output_delay [expr $clk_period * 0.2] ...
#
# For a path that ends at an output port there is no capture flop, so clock
# insertion delay does not cancel, and the required time is 0.8*P - 0.1. Then
#
#     slack          = 0.8P - 0.1 - arrival
#     implied period = P - slack = 0.2P + 0.1 + arrival
#
# The 0.2P term SHRINKS as the target tightens, so the reported frequency rises
# with identical hardware -- 620.7 MHz at P=1.60 becomes 670.7 at P=1.00 with
# not one cell changed. A combinational input-port -> output-port path is
# charged 0.4P + 0.1: twice as bad. X2-Y2 lost 46% of its period to I/O
# modelling and was reported as 511.4 MHz when its compute datapath was good
# for 600.3.
#
# A register-to-register path has no such term: launch and capture insertion
# delay largely cancel, so its slack is a statement about the hardware and is
# comparable across targets. That is the number this script exists to produce.
#
# It reads artifacts already on disk. It does NOT run the flow, so every past
# trial can be re-derived in minutes rather than re-measured in hours.
#
# Usage:
#   scripts/sta_limiter.sh -N <nick>            # e.g. amx_s1_x3y0
#   scripts/sta_limiter.sh -d amx_tdpbssd -s 1 -t x3y0
#
# Prints one line of JSON:
#   {"limiter_class":"OUT-PORT","overall_ws_ns":-0.0108,"regreg_ws_ns":0.0818,
#    "overall_endpoint":"rd_data[447]","regreg_endpoint":"...pr[14]$_DFF_P_"}
#
# limiter_class is one of:
#   reg->reg   the design itself is the limit. The reported fmax is honest.
#   OUT-PORT   a flop -> output pad path is the limit. Reported fmax is inflated
#              by 0.2P + 0.1 of I/O model and is NOT comparable across targets.
#   IN->OUT    a combinational input pad -> output pad path. Charged 0.4P + 0.1.
#
# On any failure it prints a record with "error" set and NO class. It never
# guesses a class -- the first version of this analysis defaulted to "reg->reg"
# when its regex missed, and confidently mislabelled seven empty files.
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORFS="${ORFS:-$(sed -n 's/^ORFS *:= *//p' "$HERE/local.mk" 2>/dev/null)}"
ORFS="${ORFS:-$HOME/sd/OpenROAD-flow-scripts}"

NICK=""; DESIGN=amx_tdpbssd; SAT=1; TAG=""; N=4; CPORT=1; OUTPAR=0
TN=32; RDREG=0   # tpu_mmu: array dimension, readback register
while [[ $# -gt 0 ]]; do
  case "$1" in
    -N) NICK="$2"; shift 2 ;;
    -d) DESIGN="$2"; shift 2 ;;
    -s) SAT="$2"; shift 2 ;;
    -t) TAG="$2"; shift 2 ;;
    -T) TN="$2"; shift 2 ;;
    -n) N="$2"; shift 2 ;;
    -c) CPORT="$2"; shift 2 ;;
    -r) OUTPAR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$NICK" ]]; then
  # shellcheck source=scripts/nick.sh
  source "$HERE/scripts/nick.sh"
  case "$DESIGN" in
    mac_array)   NICK="$(nick "$N" "$CPORT" "$TAG" "$OUTPAR")" ;;
    amx_tdpbssd) NICK="$(nick_amx "$SAT" "$TAG")" ;;
    tpu_mmu)     NICK="$(nick_tpu "$TN" "$TAG")" ;;
    *) echo "FATAL: unknown design '$DESIGN'" >&2; exit 2 ;;
  esac
fi

R="$HERE/work/results/nangate45/$NICK/base"
P="$ORFS/flow/platforms/nangate45"

emit_err () { printf '{"nick":"%s","error":"%s"}\n' "$NICK" "$1"; exit 0; }

for f in 6_final.odb 6_final.sdc 6_final.spef; do
  [[ -f "$R/$f" ]] || emit_err "missing $f for $NICK"
done

# A unique DIRECTORY, not a templated filename: macOS mktemp only substitutes
# X's at the END of a template, so `mktemp /tmp/f.XXXXXX.tcl` yields a file named
# literally "f.XXXXXX.tcl" and a second CONCURRENT call dies with "File exists".
# That failure mode leaves exactly one survivor per batch and mimics an OOM kill.
TDIR=$(mktemp -d)
trap 'rm -rf "$TDIR"' EXIT
cat > "$TDIR/q.tcl" <<EOF
# read_db does not restore liberty -- load it first or STA-2141 is all you get.
read_liberty $P/lib/NangateOpenCellLibrary_typical.lib
read_db $R/6_final.odb
read_sdc $R/6_final.sdc
source $P/setRC.tcl
read_spef $R/6_final.spef
puts "===OVERALL"
report_checks -path_delay max -group_path_count 1 -digits 4 -fields {}
puts "===REGREG"
report_checks -path_delay max -to [all_registers -data_pins] -group_path_count 1 -digits 4 -fields {}
puts "===END"
EOF

# 2.66 GB resident per process -- the caller is responsible for not running so
# many of these at once that the box starts swapping.
if ! "$ORFS/tools/install/OpenROAD/bin/openroad" -exit -no_init -threads 4 \
     "$TDIR/q.tcl" > "$TDIR/out.txt" 2> "$TDIR/err.txt"; then
  emit_err "openroad rc!=0: $(tr -d '\n' < "$TDIR/err.txt" | tail -c 200)"
fi
grep -q '===END' "$TDIR/out.txt" || emit_err "STA output truncated -- no ===END marker"

python3 - "$NICK" "$TDIR/out.txt" <<'PY'
import json, re, sys
nick, path = sys.argv[1], sys.argv[2]
txt = open(path).read()

def section(a, b):
    return txt.split(a)[1].split(b)[0]

def info(block):
    ep = re.search(r'Endpoint: (\S+)(.*)', block)
    sl = re.search(r'(-?[\d.]+)\s+slack \((MET|VIOLATED)\)', block)
    # No fallback. A missing match means the report is not what we think it is,
    # and a guessed class is worse than no class at all.
    if not ep or not sl:
        return None, None, None
    head = block.split('Endpoint')[0]
    outp = 'output port' in ep.group(2)
    inp  = 'input port' in head
    cls = 'IN->OUT' if (inp and outp) else ('OUT-PORT' if outp else 'reg->reg')
    return cls, float(sl.group(1)), ep.group(1)

try:
    ocls, ows, oep = info(section('===OVERALL', '===REGREG'))
    rcls, rws, rep = info(section('===REGREG', '===END'))
except (IndexError, AttributeError) as e:
    print(json.dumps({"nick": nick, "error": "unparseable STA output: %s" % e}))
    sys.exit(0)

if ocls is None:
    print(json.dumps({"nick": nick, "error": "no slack line in overall report"}))
    sys.exit(0)

rec = {"nick": nick, "limiter_class": ocls, "overall_ws_ns": ows,
       "overall_endpoint": oep, "regreg_ws_ns": rws, "regreg_endpoint": rep}
# Sanity: the reg-to-reg path can never be better-constrained than the overall
# worst path, since it is a subset of the same path set.
if rws is not None and rws < ows - 1e-6:
    rec["bug"] = "reg->reg slack %.4f is WORSE than overall %.4f -- impossible" % (rws, ows)
print(json.dumps(rec))
PY
