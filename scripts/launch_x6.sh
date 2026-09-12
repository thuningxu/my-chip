#!/usr/bin/env bash
# Run a declared X6 pair: the initial control comparison, or --tighten for the
# unchanged winner at 3.80/3.60 ns. --dry-run checks/previews without writes.
# The foreground supervisor waits for both children in a persistent session.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$HERE/work"
RUN="$WORK/campaigns/x6"
TIGHTEN=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    --tighten) TIGHTEN=1 ;;
    --dry-run) DRY=1 ;;
    *) echo "Usage: bash scripts/launch_x6.sh [--tighten] [--dry-run]" >&2; exit 2 ;;
  esac
done

TRIAL_IDS=(0 1)
CTRL_REGS=(0 1)
PERIODS=(4.00 4.00)
FLOPS=(74252 75020)
GOALS=(
  "Resident-tile MAC throughput baseline at II=21, CTRL_REG=0; same source and host settings as Y1"
  "Improve resident-tile GMAC/s with 768 preserved local epilogue control flops, unchanged arithmetic and II=21"
)

[[ -f "$HERE/local.mk" ]] || { echo "FATAL: local.mk missing" >&2; exit 1; }
grep -q '^## X6 ' "$HERE/experiments/harness.md" || { echo "FATAL: X6 not declared" >&2; exit 1; }
if [[ "$TIGHTEN" == 1 ]]; then
  grep -q '^### X6-Y2 / X6-Y3 — timing-target sweep' "$HERE/experiments/harness.md" || {
    echo "FATAL: X6-Y2/Y3 not declared" >&2; exit 1;
  }
  for y in 0 1; do
    prior_status="$WORK/campaigns/x6/x6y$y.status"
    [[ -f "$prior_status" ]] && grep -qx 'EXIT 0' "$prior_status" || {
      echo "FATAL: prior X6-Y$y has not completed successfully; refusing another pair" >&2; exit 1;
    }
  done
  # A target-only experiment must not quietly include a later RTL or flow edit.
  # Comparing exact bytes also protects against changes in parameter defaults.
  for f in rtl/amx_fp8.v rtl/fp8_mul.v rtl/fp32_add.v tb/tb_amx_fp8.v \
           flow/nangate45/config.mk.in flow/nangate45/constraint.sdc.in local.mk; do
    cmp -s "$HERE/$f" "$WORK/campaigns/x6/source/$f" || {
      echo "FATAL: $f differs from the X6-Y1 snapshot; not a target-only experiment" >&2; exit 1;
    }
  done
  RUN="$WORK/campaigns/x6_timing"
  TRIAL_IDS=(2 3)
  CTRL_REGS=(1 1)
  PERIODS=(3.80 3.60)
  FLOPS=(75020 75020)
  GOALS=(
    "Probe resident-tile throughput headroom of unchanged X6-Y1 RTL at a 3.80 ns target, II=21"
    "Test the timing-effort limit of unchanged X6-Y1 RTL at a 3.60 ns target, II=21"
  )
fi
# Never reuse a nickname: ORFS could otherwise resume another configuration's
# files, or this launcher could overwrite a still-running trial's source.
for y in "${TRIAL_IDS[@]}"; do
  for area in designs results logs reports objects; do
    [[ ! -e "$WORK/$area/nangate45/fp8_x6y$y" ]] || {
      echo "FATAL: fp8_x6y$y already has $area artifacts; refusing reuse" >&2; exit 1;
    }
  done
done
[[ ! -e "$RUN" ]] || { echo "FATAL: campaign already exists at $RUN" >&2; exit 1; }
for i in 0 1; do
  printf 'Plan X6-Y%s: CTRL_REG=%s PIPE=1 RD_REG=1 target=%s ns, flops=%s, NUM_CORES=32\n' \
    "${TRIAL_IDS[$i]}" "${CTRL_REGS[$i]}" "${PERIODS[$i]}" "${FLOPS[$i]}"
done
if [[ "$DRY" == 1 ]]; then
  printf 'Dry run: no jobs or files created. Planned snapshot: %s/source\n' "$RUN"
  exit 0
fi
mkdir -p "$WORK/campaigns"
mkdir "$RUN"  # exclusive: an existing campaign is never overwritten
SNAP="$RUN/source"
mkdir "$SNAP"
cp -a "$HERE/rtl" "$HERE/tb" "$HERE/scripts" "$HERE/flow" \
      "$HERE/Makefile" "$HERE/local.mk" "$SNAP/"
# Existing scripts remain self-contained under their snapshot root. Only the
# generated outputs and append-only trial ledger are shared with the checkout.
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
  local y="$1" ctrl="$2" period="$3" flops="$4" goal="$5" rc=0
  printf 'RUNNING\n' > "$RUN/x6y$y.status"
  bash "$SNAP/scripts/trial.sh" -x 6 -y "$y" -d amx_fp8 \
    -P 1 -R 1 --ctrl-reg "$ctrl" -p "$period" -u 40 --hold-margin 0.05 \
    --expect-flops "$flops" -g "$goal" > "$RUN/x6y$y.log" 2>&1 || rc=$?
  printf 'EXIT %d\n' "$rc" > "$RUN/x6y$y.status"
  return "$rc"
}

PIDS=()
for i in 0 1; do
  run_trial "${TRIAL_IDS[$i]}" "${CTRL_REGS[$i]}" "${PERIODS[$i]}" \
    "${FLOPS[$i]}" "${GOALS[$i]}" &
  PIDS+=("$!")
  printf 'x6y%s %s\n' "${TRIAL_IDS[$i]}" "${PIDS[$i]}" >> "$RUN/pids"
done
printf 'Launched X6-Y%s and X6-Y%s, NUM_CORES=32 each.\nLogs: %s\n' \
  "${TRIAL_IDS[0]}" "${TRIAL_IDS[1]}" "$RUN"

RC0=0; RC1=0
wait "${PIDS[0]}" || RC0=$?
wait "${PIDS[1]}" || RC1=$?
printf 'X6 pair finished: Y%s exit %d; Y%s exit %d\n' \
  "${TRIAL_IDS[0]}" "$RC0" "${TRIAL_IDS[1]}" "$RC1"
python3 "$SNAP/scripts/trials.py" --throughput
[[ "$RC0" == 0 && "$RC1" == 0 ]]
