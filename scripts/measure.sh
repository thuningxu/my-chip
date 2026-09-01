#!/usr/bin/env bash
#=============================================================================
# measure.sh -- simulate, then synthesise+P&R, then emit one QoR row.
#
# THE RULE THIS SCRIPT ENFORCES: no PPA number is produced for RTL that has
# not passed its regression. A prior project of this kind published a headline
# frequency for a design that was never simulated and computed 2*sum-last
# instead of a dot product. The flow does not care what your logic computes --
# so the gate has to be here.
#
# Usage:
#   scripts/measure.sh [-d DESIGN] [-n N] [-c C_PORT] [-r OUT_PAR] [-s SAT]
#                      [-p PERIOD_NS] [-u UTIL] [-t TAG] [--hold-margin NS]
#                      [--no-sim]
#
# Env:
#   ORFS        path to OpenROAD-flow-scripts   (default: ~/sd/OpenROAD-flow-scripts)
#   YOSYS_EXE   yosys binary                   (default: whatever is on PATH)
#   KLAYOUT_CMD klayout binary                 (required by ORFS at parse time)
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORFS="${ORFS:-$HOME/sd/OpenROAD-flow-scripts}"

DESIGN=mac_array
N=4
CPORT=1
OUTPAR=0
SAT=1
PIPE=0
RDREG=0
PERIOD=1.00
UTIL=40
TAG=""
RUN_SIM=1
# Empty means "do not set it", which preserves every previously measured row
# exactly. Only set it deliberately, and record the value with the row.
HOLD_MARGIN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) DESIGN="$2"; shift 2 ;;
    -n) N="$2"; shift 2 ;;
    -c) CPORT="$2"; shift 2 ;;
    -r) OUTPAR="$2"; shift 2 ;;
    -s) SAT="$2"; shift 2 ;;
    -P) PIPE="$2"; shift 2 ;;
    -R) RDREG="$2"; shift 2 ;;
    -p) PERIOD="$2"; shift 2 ;;
    -u) UTIL="$2"; shift 2 ;;
    -t) TAG="$2"; shift 2 ;;
    --hold-margin) HOLD_MARGIN="$2"; shift 2 ;;
    --no-sim) RUN_SIM=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=scripts/nick.sh
source "$HERE/scripts/nick.sh"

# Everything that differs per design is decided ONCE, here: the artifact name,
# the RTL file list, the testbench, the top parameters and the sim -P flags. Adding
# a third design means adding one case, not editing five scattered places.
case "$DESIGN" in
  mac_array)
    NICK="$(nick "$N" "$CPORT" "$TAG" "$OUTPAR")"
    RTL_LIST="$HERE/rtl/mac_array.v"
    TB_FILE="$HERE/tb/tb_mac_array.v"
    TOP_PARAMS="N $N C_PORT $CPORT OUT_PAR $OUTPAR"
    SIM_PARAMS=(-Ptb_mac_array.N="$N" -Ptb_mac_array.C_PORT="$CPORT"
                -Ptb_mac_array.OUT_PAR="$OUTPAR")
    CFG_DESC="N=$N C_PORT=$CPORT OUT_PAR=$OUTPAR"
    ;;
  amx_tdpbssd)
    NICK="$(nick_amx "$SAT" "$TAG")"
    RTL_LIST="$HERE/rtl/amx_tdpbssd.v"
    TB_FILE="$HERE/tb/tb_amx_tdpbssd.v"
    TOP_PARAMS="SAT $SAT PIPE $PIPE RD_REG $RDREG"
    SIM_PARAMS=(-Ptb_amx_tdpbssd.SAT="$SAT" -Ptb_amx_tdpbssd.PIPE="$PIPE"
                -Ptb_amx_tdpbssd.RD_REG="$RDREG")
    CFG_DESC="SAT=$SAT PIPE=$PIPE RD_REG=$RDREG"
    ;;
  *)
    echo "FATAL: unknown design '$DESIGN'. Known: mac_array, amx_tdpbssd" >&2
    exit 2 ;;
esac

# GUARD: the simulated configuration and the SYNTHESISED configuration must be
# the same one. This exists because they silently diverged: PIPE was added to the
# RTL, the testbench and SIM_PARAMS, but not to TOP_PARAMS, so the gate ran
# PIPE=1 and the flow built PIPE=0 -- a trial that measured a duplicate of its own
# baseline while logging that it was something else. The comment two screens down
# already warned that a gate on a different configuration is decorative; a comment
# is not a check, so here is the check.
for sp in "${SIM_PARAMS[@]}"; do
  pname="${sp##*.}"; pname="${pname%%=*}"
  pval="${sp##*=}"
  if ! printf '%s' "$TOP_PARAMS" | grep -qE "(^| )$pname $pval( |\$)"; then
    echo "FATAL: parameter drift between the sim gate and synthesis." >&2
    echo "       sim is given   $pname = $pval" >&2
    echo "       synth is given TOP_PARAMS = '$TOP_PARAMS'" >&2
    echo "       Every -P passed to the testbench must appear in VERILOG_TOP_PARAMS," >&2
    echo "       or the gate proves nothing about what actually gets built." >&2
    exit 1
  fi
done

PERIOD_PS=$(python3 -c "print(int(round(float('$PERIOD')*1000)))")

# ---------------------------------------------------------------- 1. simulate
if [[ $RUN_SIM -eq 1 ]]; then
  echo "== simulating $DESIGN ($CFG_DESC) =="
  if ! command -v iverilog >/dev/null; then
    echo "FATAL: iverilog not found. brew install icarus-verilog" >&2
    exit 1
  fi
  SIMDIR=$(mktemp -d)
  # Every parameter that changes the hardware must be passed here too. Gating on
  # a simulation of a DIFFERENT configuration than the one being synthesised
  # would make the gate decorative. Note $RTL_LIST, not rtl/*.v: the simulated
  # file set has to be the synthesised one for the same reason.
  iverilog -g2005 -o "$SIMDIR/tb.vvp" \
    "${SIM_PARAMS[@]}" "$TB_FILE" $RTL_LIST
  if ! vvp "$SIMDIR/tb.vvp" | tee "$SIMDIR/sim.log" | grep -q "^RESULT: PASS"; then
    echo "FATAL: regression FAILED -- refusing to produce a PPA number." >&2
    grep -E "\[FAIL\]|RESULT:" "$SIMDIR/sim.log" >&2 || true
    exit 1
  fi
  echo "   regression PASS"
fi

# ---------------------------------------------------------------- 2. stage
# Everything generated lives under my-chip/work/. Nothing is written into the
# ORFS checkout: ORFS's WORK_HOME (Makefile:98) feeds LOG_DIR / OBJECTS_DIR /
# REPORTS_DIR / RESULTS_DIR (variables.mk:46-49), and DESIGN_HOME
# (variables.mk:13) relocates the design tree. Both are overridable, so the
# ORFS clone stays pristine and this repo owns its own artifacts.
WORK="$HERE/work"
DESIGNS="$WORK/designs"
CFG_DIR="$DESIGNS/nangate45/$NICK"
echo "== staging into $WORK =="
mkdir -p "$CFG_DIR"

# Fill the committed templates. They are the single definition of the config --
# there is no second, hand-maintained copy to drift out of sync.
TPL="$HERE/flow/nangate45"
for t in config.mk constraint.sdc; do
  [[ -f "$TPL/$t.in" ]] || { echo "FATAL: missing template $TPL/$t.in" >&2; exit 1; }
done

sed -e "s|@NICK@|$NICK|g" \
    -e "s|@DESIGN@|$DESIGN|g" \
    -e "s|@VERILOG_FILES@|$RTL_LIST|g" \
    -e "s|@TOP_PARAMS@|$TOP_PARAMS|g" \
    -e "s|@UTIL@|$UTIL|g" \
    -e "s|@PERIOD_PS@|$PERIOD_PS|g" \
    -e "s|@RTL_DIR@|$HERE/rtl|g" \
    -e "s|@CFG_DIR@|$CFG_DIR|g" \
    "$TPL/config.mk.in" > "$CFG_DIR/config.mk"

sed -e "s|@PERIOD@|$PERIOD|g" \
    "$TPL/constraint.sdc.in" > "$CFG_DIR/constraint.sdc"

# Any @TOKEN@ left unsubstituted means the template gained a placeholder that
# this script does not know about -- fail loudly rather than hand ORFS junk.
# Comments are stripped first: the templates mention placeholder syntax in their
# own header comments, which is not a substitution failure.
for f in "$CFG_DIR/config.mk" "$CFG_DIR/constraint.sdc"; do
  if sed 's/#.*//' "$f" | grep -q '@[A-Z_]*@'; then
    echo "FATAL: unsubstituted @TOKEN@ in $f" >&2
    sed 's/#.*//' "$f" | grep -n '@[A-Z_]*@' >&2
    exit 1
  fi
done

# ---------------------------------------------------------------- 3. run flow
echo "== running ORFS ($DESIGN, $CFG_DESC, period=${PERIOD}ns, util=$UTIL${HOLD_MARGIN:+, hold_margin=${HOLD_MARGIN}ns}) =="
# WORK_HOME/DESIGN_HOME redirect every output away from the ORFS tree.
# DESIGN_CONFIG must be absolute since it is no longer under $ORFS/flow.
MAKE_ARGS=(
  WORK_HOME="$WORK"
  DESIGN_HOME="$DESIGNS"
  DESIGN_CONFIG="$CFG_DIR/config.mk"
)
[[ -n "${YOSYS_EXE:-}"   ]] && MAKE_ARGS+=("YOSYS_EXE=$YOSYS_EXE")
[[ -n "${KLAYOUT_CMD:-}" ]] && MAKE_ARGS+=("KLAYOUT_CMD=$KLAYOUT_CMD")
# Passed on ORFS's make command line so it overrides config.mk without editing
# the committed template -- which keeps every row measured before this flag
# existed byte-for-byte reproducible.
[[ -n "$HOLD_MARGIN"    ]] && MAKE_ARGS+=("HOLD_SLACK_MARGIN=$HOLD_MARGIN")

mkdir -p "$WORK/logs"
LOG="$WORK/logs/${NICK}_flow.log"
R="$WORK/logs/nangate45/$NICK/base/6_report.json"
DRC="$WORK/reports/nangate45/$NICK/base/5_route_drc.rpt"

set +e
( cd "$ORFS/flow" && make "${MAKE_ARGS[@]}" finish ) > "$LOG" 2>&1
FLOW_RC=$?
set -e
if [[ $FLOW_RC -ne 0 ]]; then
  # ORFS's 6_report stage renders layout images via gui::save_image, which can
  # fail with GUI-0013/GUI-0070 ("Unable to find visible display control at
  # Timing Path/*") on some OpenROAD builds. That is the image renderer, not the
  # design -- metrics are dumped before it runs. Tolerate exactly that case.
  if grep -q "GUI-0070" "$LOG" && [[ -s "$R" ]]; then
    # GUI-0070 comes from final_outputs.tcl:58, `gui::show "source save_images.tcl"`,
    # which asks for a display control ("Timing Path/*") this OpenROAD build does
    # not have. Metrics are dumped before it, so they survive.
    #
    # BUT: ORFS's `finish` target lists 6_report.log BEFORE $(GDS_FINAL_FILE), so
    # make aborts on that failure and the GDS rule never runs. For a long time
    # this script called that "layout images unavailable" and moved on, while the
    # actual consequence was that NO GDS WAS EVER PRODUCED. Recover it explicitly.
    # Be precise about what was actually lost. This used to say "layout images
    # unavailable", which is FALSE and misleading: GUI-0013 fails on the
    # "Timing Path/*" display control specifically, so 9 of the 10 images are
    # already on disk by the time it fires -- only final_worst_path.webp is lost.
    # Verified by mtime: final_all.webp lands one second BEFORE the error is
    # logged, and the failure is in final_report.tcl, not save_images.tcl.
    echo "   WARNING: 6_report failed at GUI-0070 (no 'Timing Path' display control)."
    echo "            Metrics are intact and 9 of 10 layout images were written;"
    echo "            only final_worst_path.webp is lost. Recovering the GDS, which"
    echo "            the aborted 'finish' target would otherwise have skipped..."
    set +e
    ( cd "$ORFS/flow" && make "${MAKE_ARGS[@]}" do-gds ) >> "$LOG" 2>&1
    GDS_RC=$?
    set -e
    GDS="$WORK/results/nangate45/$NICK/base/6_final.gds"
    if [[ $GDS_RC -eq 0 && -s "$GDS" ]]; then
      echo "            GDS recovered: $(du -h "$GDS" | cut -f1)  $GDS"
    else
      echo "FATAL: GDS recovery failed (rc=$GDS_RC). A routed design with no GDS is" >&2
      echo "       not a built chip; refusing to report it as one. See $LOG" >&2
      exit 1
    fi
  else
    echo "FLOW FAILED (rc=$FLOW_RC). Tail of $LOG:" >&2
    tail -15 "$LOG" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- 4. extract
if [[ ! -s "$R" ]]; then
  echo "FATAL: no metrics at $R" >&2
  exit 1
fi
python3 - "$R" "$DRC" "$N" "$PERIOD" "$UTIL" "$NICK" <<'PY'
import json, os, sys
rpt, drc, n, period, util, nick = sys.argv[1:7]
d = json.load(open(rpt))
def g(k, default=0.0):
    return d.get(k, default)
ws  = float(g('finish__timing__setup__ws'))
tns = float(g('finish__timing__setup__tns'))
hold= float(g('finish__timing__hold__ws'))
per = float(period)
fmax = 1000.0/(per - ws) if (per - ws) > 0 else float('nan')
drc_n = 0
if os.path.exists(drc):
    drc_n = sum(1 for _ in open(drc))
print()
print("| design | N | period | setup WS | TNS | hold WS | implied fmax | DRC | stdcells | flip-flops | area um2 | power W |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|")
print(f"| {nick} | {n} | {per:.2f} ns | {ws:+.4f} | {tns:.3f} | {hold:+.4f} | "
      f"{fmax:.0f} MHz | {drc_n} | {int(g('finish__design__instance__count__stdcell'))} | "
      f"{int(g('finish__design__instance__count__class:sequential_cell'))} | "
      f"{int(g('finish__design__instance__area__stdcell'))} | {g('finish__power__total'):.4f} |")
print()
if ws < 0:
    print(f"NOTE: setup NOT met at {per} ns. Retry with -p {per - ws + 0.02:.2f}")
PY
