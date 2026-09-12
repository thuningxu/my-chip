#!/usr/bin/env bash
# Exactly the declared X7 baseline/chaining pair. Keep this foreground
# supervisor in a persistent terminal; it waits for both physical flows.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$HERE/work"
RUN="$WORK/campaigns/x7"
DRY=0
if [[ $# -gt 0 ]]; then
  [[ $# == 1 && "$1" == --dry-run ]] || {
    echo "Usage: bash scripts/launch_x7.sh [--dry-run]" >&2; exit 2;
  }
  DRY=1
fi
[[ -f "$HERE/local.mk" ]] || { echo "FATAL: local.mk missing" >&2; exit 1; }
grep -q '^## X7 ' "$HERE/experiments/harness.md" || { echo "FATAL: X7 not declared" >&2; exit 1; }
for prior in x6/x6y0 x6/x6y1 x6_timing/x6y2 x6_timing/x6y3; do
  status="$WORK/campaigns/$prior.status"
  [[ -f "$status" ]] && grep -qx 'EXIT 0' "$status" || {
    echo "FATAL: prior $prior has not completed; refusing another pair" >&2; exit 1;
  }
done
# CHAIN changes only the top-level schedule and its verification. No arithmetic
# leaf or physical-flow change is part of this generation's first pair.
for f in rtl/fp8_mul.v rtl/fp32_add.v flow/nangate45/config.mk.in \
         flow/nangate45/constraint.sdc.in local.mk; do
  cmp -s "$HERE/$f" "$WORK/campaigns/x6_timing/source/$f" || {
    echo "FATAL: $f differs from X6; not a schedule-only experiment" >&2; exit 1;
  }
done
for y in 0 1; do
  for area in designs results logs reports objects; do
    [[ ! -e "$WORK/$area/nangate45/fp8_x7y$y" ]] || {
      echo "FATAL: fp8_x7y$y already has $area artifacts; refusing reuse" >&2; exit 1;
    }
  done
done
[[ ! -e "$RUN" ]] || { echo "FATAL: campaign already exists at $RUN" >&2; exit 1; }
printf 'Plan X7-Y0/Y1: CHAIN=0/1, expected II=21/20, PIPE=1 RD_REG=1 CTRL_REG=1\n'
printf 'Both: 3.80 ns, utilization 40%%, hold margin 0.05 ns, NUM_CORES=32\n'
if [[ "$DRY" == 1 ]]; then echo 'Dry run: no files or jobs created.'; exit 0; fi

mkdir -p "$WORK/campaigns"
mkdir "$RUN"
SNAP="$RUN/source"
mkdir "$SNAP"
cp -a "$HERE/rtl" "$HERE/tb" "$HERE/scripts" "$HERE/flow" \
      "$HERE/Makefile" "$HERE/local.mk" "$SNAP/"
ln -s "$WORK" "$SNAP/work"
ln -s "$HERE/experiments" "$SNAP/experiments"
cp "$HERE/experiments/harness.md" "$RUN/harness.md"
git -C "$HERE" diff --binary > "$RUN/checkout.patch"
git -C "$HERE" status --short > "$RUN/checkout.status"
find "$SNAP/rtl" "$SNAP/tb" "$SNAP/scripts" "$SNAP/flow" -type f \
  ! -path '*/__pycache__/*' -print0 | sort -z | xargs -0 sha256sum > "$RUN/source.sha256"

IVERILOG_EXE="$(sed -n 's/^IVERILOG *:= *//p' "$SNAP/local.mk")"
export PATH="$(dirname "$IVERILOG_EXE"):$PATH"
export NUM_CORES=32
export TRIAL_GIT_ROOT="$HERE"
unset MAKEFLAGS MFLAGS

run_trial() {
  local y="$1" chain="$2" goal="$3" rc=0
  printf 'RUNNING\n' > "$RUN/x7y$y.status"
  bash "$SNAP/scripts/trial.sh" -x 7 -y "$y" -d amx_fp8 \
    -P 1 -R 1 --ctrl-reg 1 --chain "$chain" -p 3.80 -u 40 --hold-margin 0.05 \
    --expect-flops 75020 -g "$goal" > "$RUN/x7y$y.log" 2>&1 || rc=$?
  printf 'EXIT %d\n' "$rc" > "$RUN/x7y$y.status"
  return "$rc"
}
run_trial 0 0 'Resident-tile throughput baseline with start_ready interface, legacy idle launch, II=21' &
BASE_PID=$!
run_trial 1 1 'Improve completed MAC throughput by completion-edge restart, II=20, unchanged FP32 order and latency' &
CHAIN_PID=$!
printf 'x7y0 %s\nx7y1 %s\n' "$BASE_PID" "$CHAIN_PID" > "$RUN/pids"
printf 'Launched X7-Y0 and X7-Y1, NUM_CORES=32 each.\nLogs: %s\n' "$RUN"
RC0=0; RC1=0
wait "$BASE_PID" || RC0=$?
wait "$CHAIN_PID" || RC1=$?
printf 'X7 pair finished: Y0 exit %d; Y1 exit %d\n' "$RC0" "$RC1"
python3 "$SNAP/scripts/trials.py" --throughput
[[ "$RC0" == 0 && "$RC1" == 0 ]]
