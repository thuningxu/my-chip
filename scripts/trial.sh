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
# Artifact isolation comes from the TAG: tag x1y1 lands in work/*/amx_s1_x1y1/ and
# cannot collide with another trial. For amx_fp8 the TAG is the ONLY thing that
# isolates it -- nick_fp8() deliberately puts no knobs in the name, so two amx_fp8
# trials at different PIPE sharing a TAG would overwrite each other's routed
# database and the second would be read back as the first. One TAG per trial.
#
# Usage:
#   scripts/trial.sh -x 1 -y 0 -g "goal string" [-d DESIGN] [-p PERIOD] [-s SAT]
#                    [-P PIPE] [-R RD_REG] [-u UTIL] [--hold-margin NS]
#                    [--expect-flops N] [--dry-run] [--log-only]
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_JSONL="$HERE/experiments/trials.jsonl"

X=""; Y=""; GOAL=""
DESIGN=amx_tdpbssd
SAT=1; PIPE=0; RDREG=0; CTRLREG=0; CHAIN=0; PERIOD=2.80; UTIL=40; HOLD_MARGIN=""
# A written-down prediction the trial will CHECK, not merely sit next to. The
# first X1-Y1 attempt was a duplicate of its own baseline for 17 minutes because
# the flop count was logged and never compared to what the change had to add.
EXPECT_FF=""
DRY=0
LOG_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -x) X="$2"; shift 2 ;;
    -y) Y="$2"; shift 2 ;;
    -g) GOAL="$2"; shift 2 ;;
    -d) DESIGN="$2"; shift 2 ;;
    -s) SAT="$2"; shift 2 ;;
    -P) PIPE="$2"; shift 2 ;;
    -R) RDREG="$2"; shift 2 ;;
    --ctrl-reg) CTRLREG="$2"; shift 2 ;;
    --chain) CHAIN="$2"; shift 2 ;;
    -p) PERIOD="$2"; shift 2 ;;
    -u) UTIL="$2"; shift 2 ;;
    --hold-margin) HOLD_MARGIN="$2"; shift 2 ;;
    --expect-flops) EXPECT_FF="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    # Log from artifacts already on disk, skipping the flow. For when the flow
    # SUCCEEDED but the logging step did not -- which happened once, because this
    # script was edited while it was running and bash, which reads scripts
    # incrementally, resumed from a shifted offset. Re-running 30 minutes of
    # routing to recover a record that is already sitting in 6_report.json would
    # be silly. NEVER edit a running script.
    --log-only) LOG_ONLY=1; shift ;;
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
# Everything that differs per design is decided ONCE, here, the same way
# measure.sh does it: the artifact nick, the RTL files the fingerprint has to
# cover, and which knobs are real for this design.
#
# The file list is a SECOND copy of measure.sh's RTL_LIST and there is no way to
# share it without a fifth file, so the existence check below is what stops the
# two from drifting silently.
case "$DESIGN" in
  amx_tdpbssd)
    NICK="$(nick_amx "$SAT" "$TAG")"
    RTL_FILES=("$HERE/rtl/amx_tdpbssd.v")
    KNOBS="SAT=$SAT PIPE=$PIPE RD_REG=$RDREG"
    ;;
  amx_fp8)
    NICK="$(nick_fp8 "$TAG")"
    # THREE files, and the fingerprint below covers all three. amx_fp8.v
    # instantiates fp8_mul and fp32_add ~1000 times each, so a sha over
    # amx_fp8.v alone would report a trial that retimed fp32_add.v as having the
    # same RTL as the row before it -- and a row that is not attributable to
    # exact bytes cannot be compared with anything.
    RTL_FILES=("$HERE/rtl/amx_fp8.v" "$HERE/rtl/fp8_mul.v" "$HERE/rtl/fp32_add.v")
    # No SAT: this design has no saturation parameter. Printing SAT=1 beside it
    # would be a banner describing a knob the hardware does not have.
    KNOBS="PIPE=$PIPE RD_REG=$RDREG CTRL_REG=$CTRLREG CHAIN=$CHAIN"
    ;;
  *) echo "FATAL: trial.sh has no nick and no RTL file list for design '$DESIGN'." >&2
     echo "       Supported: amx_tdpbssd, amx_fp8. Add a case rather than" >&2
     echo "       letting a trial log a row it cannot fingerprint." >&2
     exit 2 ;;
esac

# Identify the RTL by content, not by branch state: a trial has to stay
# attributable to exact bytes after the tree moves on. A missing file would make
# the fingerprint cover less than it claims to, so it is fatal, not a warning.
for f in "${RTL_FILES[@]}"; do
  [[ -f "$f" ]] || { echo "FATAL: $DESIGN's RTL list names a file that does not exist:" >&2
                     echo "       $f" >&2
                     echo "       trial.sh's list has drifted from the tree (or from" >&2
                     echo "       measure.sh's RTL_LIST). Fix it before logging a row." >&2
                     exit 2; }
done
# shasum is the perl script macOS ships; sha256sum is coreutils and is what this
# Linux box has. Only one may exist, and falling back to `|| true` would log an
# EMPTY sha -- an unattributable row that looks perfectly fine in the log.
if command -v sha256sum >/dev/null; then SHA_CMD=(sha256sum)
elif command -v shasum >/dev/null; then SHA_CMD=(shasum -a 256)
else
  echo "FATAL: neither sha256sum nor shasum found -- cannot fingerprint the RTL," >&2
  echo "       and a trial with no fingerprint is not attributable to any bytes." >&2
  exit 1
fi
# Hashed as ONE CONCATENATED BYTE STREAM, not `sha256sum f1 f2 f3`: the per-file
# form embeds pathnames, which are absolute here, so the digest would change when
# the repo is cloned to another directory and every past row would stop matching.
# Streaming the bytes also leaves the single-file digest bit-identical to the old
# `shasum -a 256 <one file>` value, so the amx_tdpbssd shas already in
# trials.jsonl stay comparable across this change.
RTL_SHA=$(cat "${RTL_FILES[@]}" | "${SHA_CMD[@]}" | cut -c1-16)
# Frozen source snapshots need not be git worktrees. Record the originating
# checkout explicitly while hashing the actual snapshot bytes above.
GIT_ROOT="${TRIAL_GIT_ROOT:-$HERE}"
GIT_SHA=$(git -C "$GIT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
DIRTY=$(git -C "$GIT_ROOT" status --porcelain 2>/dev/null | head -1)

echo "=============================================================="
echo " TRIAL X${X}-Y${Y}   $DESIGN   $KNOBS"
echo " period ${PERIOD}ns  util ${UTIL}%${HOLD_MARGIN:+  hold_margin ${HOLD_MARGIN}ns}"
echo " rtl sha256[0:16] $RTL_SHA   git $GIT_SHA${DIRTY:+ (dirty)}"
echo " goal: $GOAL"
echo "=============================================================="

if [[ $DRY -eq 1 ]]; then echo "(dry run -- not executing)"; exit 0; fi

START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ $LOG_ONLY -eq 1 ]]; then
  echo "(log-only: reading artifacts already on disk, not running the flow)"
  RC=0
else
set +e
ORFS="$(sed -n 's/^ORFS *:= *//p' "$HERE/local.mk")" \
YOSYS_EXE="$(sed -n 's/^YOSYS_EXE *:= *//p' "$HERE/local.mk")" \
KLAYOUT_CMD="$(sed -n 's/^KLAYOUT_CMD *:= *//p' "$HERE/local.mk")" \
  "$HERE/scripts/measure.sh" -d "$DESIGN" -s "$SAT" -P "$PIPE" -R "$RDREG" --ctrl-reg "$CTRLREG" --chain "$CHAIN" \
    -p "$PERIOD" -u "$UTIL" \
    -t "$TAG" ${HOLD_MARGIN:+--hold-margin "$HOLD_MARGIN"}
RC=$?
set -e
fi
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ---- metrics, straight from the flow's own JSON -------------------------------
R="$HERE/work/logs/nangate45/$NICK/base/6_report.json"
DRC="$HERE/work/reports/nangate45/$NICK/base/5_route_drc.rpt"
GDS="$HERE/work/results/nangate45/$NICK/base/6_final.gds"
NETLIST="$HERE/work/results/nangate45/$NICK/base/6_final.v"
FLW=$(grep -rhoE 'FLW-0009\] Clock [a-z_]+ slack -?[0-9.]+' \
        "$HERE/work/logs/nangate45/$NICK/base/"*.log 2>/dev/null | tail -1 \
        | grep -oE '\-?[0-9.]+$' || true)

# WHAT IS ACTUALLY LIMITING THIS ROW. Eight trials were logged before anything
# recorded where the worst path ENDED, and three of them turned out to be limited
# by an I/O-boundary path rather than by the design -- so their headline fmax was
# measuring the SDC's pad-delay convention, not the hardware. X2-Y2 was reported
# at 511.4 MHz when its compute datapath was good for 600.3. See
# scripts/sta_limiter.sh for the arithmetic. Never optional: a frequency without
# a limiter class cannot be compared to another frequency.
LIMFILE="$HERE/work/logs/nangate45/$NICK/base/limiter.json"
if [[ -d "$(dirname "$LIMFILE")" ]]; then
  "$HERE/scripts/sta_limiter.sh" -d "$DESIGN" -s "$SAT" -t "$TAG" > "$LIMFILE" 2>/dev/null \
    || echo '{"error":"sta_limiter.sh failed"}' > "$LIMFILE"
  echo "  limiter: $(python3 -c "import json,sys;d=json.load(open('$LIMFILE'));print(d.get('limiter_class') or d.get('error'))" 2>/dev/null || echo unknown)"
fi

# PREDICTION CHECK. A trial whose hardware does not match what the change was
# supposed to build is not a measurement of that change, whatever the PPA says.
PRED_NOTE=""
if [[ -n "$EXPECT_FF" && -f "$NETLIST" ]]; then
  GOT_FF=$(grep -coE '^[[:space:]]*(DFF|SDFF)[A-Z_]*_X[0-9]+' "$NETLIST" || true)
  # TOLERANT, not exact. The failure this guards against is "the parameter had no
  # effect at all", which is by construction a large fraction of the total -- the
  # real bug was 24,585 where 29,192 was expected, 15.8% off. An exact match would
  # instead police the arithmetic of the prediction itself: X1-Y1's true count was
  # 29,194 because ccnt is one bit wider than kcnt and v_sr[0] exists, and a 2-flop
  # slip would have demoted a perfectly correct trial. A false failure in the log
  # is as corrosive as a false success, so the band is deliberately generous.
  TOL=$(python3 -c "print(max(32, int(0.01*$EXPECT_FF)))")
  DIFF=$(python3 -c "print(abs($GOT_FF - $EXPECT_FF))")
  if [[ "$DIFF" -gt "$TOL" ]]; then
    PRED_NOTE="PREDICTION MISSED: expected ~$EXPECT_FF flip-flops (tolerance $TOL), netlist has $GOT_FF"
    echo "  !! $PRED_NOTE" >&2
    echo "     The built hardware is not what this Y was supposed to build, so the" >&2
    echo "     PPA below does not measure this Y. Recorded as a bug on the trial." >&2
  else
    echo "  prediction OK: $GOT_FF flip-flops vs ~$EXPECT_FF expected (within $TOL)"
  fi
fi

python3 - "$LOG_JSONL" "$R" "${DRC:-}" "${GDS:-}" "$NETLIST" "${LIMFILE:-}" <<PY
import json, os, sys, subprocess, re
jsonl, rep, drc, gds, netlist, limfile = sys.argv[1:7]
rec = {
  "x": $X, "y": $Y, "tag": "$TAG", "design": "$DESIGN",
  "goal": """$GOAL""",
  "started": "$START", "ended": "$END",
  "knobs": {"SAT": $SAT, "PIPE": $PIPE, "RD_REG": $RDREG, "period_ns": $PERIOD, "util": $UTIL,
            "hold_margin_ns": ${HOLD_MARGIN:-None}},
  "rtl_sha256_16": "$RTL_SHA", "git": "$GIT_SHA", "dirty": bool("""$DIRTY"""),
  "measure_rc": $RC,
  "source_root": "$HERE",
}
if rec["design"] == "amx_fp8":
    rec["knobs"].pop("SAT", None)
    rec["knobs"]["CTRL_REG"] = $CTRLREG
    rec["knobs"]["CHAIN"] = $CHAIN
if os.environ.get("NUM_CORES"):
    rec["knobs"]["num_cores"] = int(os.environ["NUM_CORES"])
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
    # WHERE THE LIMIT ACTUALLY IS. implied_fmax_mhz is only a statement about the
    # hardware when limiter_class == "reg->reg". For an I/O-boundary limiter the
    # SDC charges 0.2*P (output port) or 0.4*P (input->output) plus 0.1 ns of
    # uncertainty against the path, and because that budget SCALES with the target
    # the reported frequency rises as the target tightens with identical cells.
    # regreg_fmax_mhz has no such term -- launch and capture clock insertion delay
    # cancel -- so it is the number that is comparable across targets.
    lim = {}
    if limfile and os.path.exists(limfile):
        try:
            lim = json.load(open(limfile))
        except Exception as e:
            lim = {"error": "unreadable limiter.json: %s" % e}
    rec["metrics"]["limiter_class"]    = lim.get("limiter_class")
    rec["metrics"]["overall_endpoint"] = lim.get("overall_endpoint")
    rec["metrics"]["overall_startpoint"] = lim.get("overall_startpoint")
    rec["metrics"]["regreg_ws_ns"]     = lim.get("regreg_ws_ns")
    rec["metrics"]["regreg_endpoint"]  = lim.get("regreg_endpoint")
    rec["metrics"]["regreg_startpoint"] = lim.get("regreg_startpoint")
    _rr = lim.get("regreg_ws_ns")
    rec["metrics"]["regreg_fmax_mhz"] = (
        round(1000.0/($PERIOD - _rr), 1) if _rr is not None and ($PERIOD - _rr) > 0 else None)
    if rec["design"] == "amx_fp8":
        sim_path = "$HERE/work/logs/${NICK}_sim.log"
        sim = open(sim_path).read() if os.path.exists(sim_path) else ""
        match = re.search(r"^THROUGHPUT: macs_per_op=(\d+) initiation_interval_cycles=(\d+) "
                          r"completion_latency_cycles=(\d+) resident_ops=(\d+)$", sim, re.M)
        if not match or "RESULT: PASS" not in sim:
            rec["result"] = "OK_BUT_NO_THROUGHPUT"
            rec.setdefault("bugs", []).append("missing passing back-to-back throughput evidence")
        else:
            macs, ii, latency, ops = map(int, match.groups())
            if macs != 16384 or ii <= 0 or latency <= 0 or ops < 2:
                raise ValueError("invalid throughput evidence in " + sim_path)
            if ii != 20 + $PIPE - $CHAIN or latency != 19 + $PIPE:
                rec["result"] = "OK_BUT_WRONG_SCHEDULE"
                rec.setdefault("bugs", []).append(
                    "measured II/latency %d/%d differs from requested %d/%d"
                    % (ii, latency, 20 + $PIPE - $CHAIN, 19 + $PIPE))
            mm = rec["metrics"]
            mm.update(macs_per_op=macs, initiation_interval_cycles=ii,
                      completion_latency_cycles=latency, resident_ops=ops)
            mm["mac_throughput_gmac_s"] = (
                macs / (ii * ($PERIOD - _rr)) if _rr is not None and $PERIOD > _rr else None)
            mm["throughput_scope"] = "resident tiles, transfers excluded; STA-implied clock"
            if mm["mac_throughput_gmac_s"] is None:
                rec["result"] = "OK_BUT_NO_THROUGHPUT"
                rec.setdefault("bugs", []).append("no reg-to-reg timing for throughput")
    _cls = lim.get("limiter_class")
    if _cls is None:
        rec.setdefault("bugs", []).append(
            "no limiter class recorded (%s) -- implied_fmax_mhz is uninterpretable"
            % lim.get("error", "sta_limiter.sh produced nothing"))
    elif _cls != "reg->reg":
        rec.setdefault("bugs", []).append(
            "limiter is %s, NOT the design: implied_fmax_mhz is inflated by the "
            "period-scaled I/O budget and is not comparable across targets -- "
            "use regreg_fmax_mhz (%s)" % (_cls, rec["metrics"]["regreg_fmax_mhz"]))
    # The two must agree. They did on every mac_array row; if they ever diverge
    # the run is not trustworthy and the divergence is itself the finding.
    if ${FLW:-None} is not None and abs(${FLW:-0} - ws) > 0.05:
        rec.setdefault("bugs", []).append(
            "FLW-0009 (%.4f) disagrees with routed setup WS (%.4f) by >0.05 ns"
            % (${FLW:-0}, ws))
    if """$PRED_NOTE""".strip():
        rec.setdefault("bugs", []).append("""$PRED_NOTE""".strip())
        # A missed prediction demotes the result: the numbers are real but they
        # do not describe the change this trial claims to be testing.
        rec["result"] = "OK_BUT_WRONG_HARDWARE"
# LOCKED APPEND. Records are ~1.5 kB and PIPE_BUF on this platform is 512, so a
# plain O_APPEND write is NOT atomic and two trials finishing together could
# interleave and corrupt the log. Trials are now run in parallel -- most of an
# ORFS run is single-threaded, so a machine with 18 cores sits nearly idle
# through synthesis and global route -- which makes this a live hazard, not a
# theoretical one.
import fcntl
with open(jsonl, "a") as f:
    fcntl.flock(f.fileno(), fcntl.LOCK_EX)
    try:
        f.write(json.dumps(rec) + "\n")
        f.flush()
        os.fsync(f.fileno())
    finally:
        fcntl.flock(f.fileno(), fcntl.LOCK_UN)
print()
print("  logged X$X-Y$Y -> %s" % jsonl)
if rec["metrics"]:
    mm = rec["metrics"]
    print("  setup %+.4f ns -> %.1f MHz | hold %+.4f (%d viol) | %d cells | %.0f um2 | DRC %d"
          % (mm["setup_ws_ns"], mm["implied_fmax_mhz"], mm["hold_ws_ns"],
             mm["hold_viol"], mm["stdcells"], mm["area_um2"], mm["drc_lines"]))
    if mm.get("mac_throughput_gmac_s") is not None:
        print("  %.3f GMAC/s | II %d | completion latency %d cycles (resident tiles)"
              % (mm["mac_throughput_gmac_s"], mm["initiation_interval_cycles"],
                 mm["completion_latency_cycles"]))
else:
    print("  FAILED -- no metrics. That is still a data point.")
sys.exit(0 if rec["result"] == "OK" else 1)
PY
[[ -z "$PRED_NOTE" ]] || exit 1
exit "$RC"
