#!/usr/bin/env bash
#=============================================================================
# mutate.sh -- break the RTL on purpose and check that the testbench notices.
#
# WHY THIS EXISTS. Every testbench in this repo reports a large number of passing
# checks. That number is worthless on its own: a testbench that compares a design
# against a restatement of itself passes 100k checks and catches nothing. The only
# evidence that a testbench works is that it FAILS when the design is wrong.
#
# Mutations were run ad-hoc for fp32_add, fp8_mul and amx_fp8 -- by hand, in a
# shell, and the results survive only as prose in EXPERIMENTS.md. That is how the
# fp32_add alignment cap ended up documented as "27 and 26 are equivalent,
# established by mutation rather than assumed": a real and useful fact that nobody
# can re-derive without redoing the work. So the mutations now live in a file next
# to the testbench and are re-runnable.
#
#------------------------------------------------------------------ EXPECTED SURVIVORS
# A mutation prefixed with `=` is expected to SURVIVE, because it is provably
# equivalent to the original. Those are the most valuable entries in the file: each
# one is a place where an obvious-looking "bug" is not one, recorded so that a
# future reader does not "fix" the RTL or go hunting for a hole in the tests.
#
# An unmarked mutation that survives is a hole, and the script exits non-zero.
# A `=` mutation that gets KILLED is also a failure -- the equivalence claim was
# wrong, which is a more interesting result than a missing test.
#
#------------------------------------------------------------------ USAGE
#   scripts/mutate.sh -r rtl/fx2fp32.v -t tb/tb_fx2fp32.v -m tb/mut/fx2fp32.mut
#   scripts/mutate.sh -r rtl/amx_fp8.v -t tb/tb_amx_fp8.v -m tb/mut/amx_fp8.mut \
#                     -x rtl/fp8_mul.v -x rtl/fp32_add.v -x rtl/fx2fp32.v
#   ... -P "-DACC=1"          extra iverilog flags (parameters, defines)
#   ... -o name               run only the mutation whose name contains `name`
#
# Mutation file format, `|||`-separated so no shell quoting is involved:
#   # comment
#   short name ||| perl -0pi expression
#   =short name ||| perl -0pi expression      (expected to survive; say why)
#=============================================================================
set -uo pipefail

RTL=""; TB=""; MUT=""; ONLY=""; PFLAGS=""
EXTRA=()

usage() { sed -n '2,45p' "$0" | sed 's/^# \?//'; exit 1; }

while getopts ":r:t:m:x:P:o:h" o; do
  case "$o" in
    r) RTL="$OPTARG" ;;
    t) TB="$OPTARG" ;;
    m) MUT="$OPTARG" ;;
    x) EXTRA+=("$OPTARG") ;;
    P) PFLAGS="$OPTARG" ;;
    o) ONLY="$OPTARG" ;;
    h) usage ;;
    *) echo "unknown option -$OPTARG" >&2; usage ;;
  esac
done

[[ -n "$RTL" && -n "$TB" && -n "$MUT" ]] || usage
for f in "$RTL" "$TB" "$MUT" "${EXTRA[@]+"${EXTRA[@]}"}"; do
  [[ -f "$f" ]] || { echo "missing: $f" >&2; exit 1; }
done

command -v iverilog >/dev/null || { echo "iverilog not on PATH" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BASENAME="$(basename "$RTL")"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
if [[ ! -t 1 ]]; then RED=""; GRN=""; YEL=""; DIM=""; OFF=""; fi

#---------------------------------------------------------------- baseline
# The unmutated design MUST pass first. Without this check a testbench that is
# broken outright would report every mutation as "killed" and look perfect.
echo "baseline (unmutated) ..."
if ! iverilog -g2005 -o "$WORK/base.vvp" $PFLAGS "$TB" "$RTL" \
        "${EXTRA[@]+"${EXTRA[@]}"}" 2>"$WORK/base.log"; then
  echo "${RED}baseline does not COMPILE -- nothing below would mean anything${OFF}" >&2
  cat "$WORK/base.log" >&2; exit 1
fi
if ! "$WORK/base.vvp" >"$WORK/base.out" 2>&1 || ! grep -q 'PASSED' "$WORK/base.out"; then
  echo "${RED}baseline does not PASS -- fix the design or the testbench first${OFF}" >&2
  tail -20 "$WORK/base.out" >&2; exit 1
fi
BASE_CHECKS=$(grep -o 'checks *: *[0-9]*' "$WORK/base.out" | grep -o '[0-9]*' | tail -1)
echo "  ${GRN}PASSED${OFF}  ${BASE_CHECKS:-?} checks"
echo

#---------------------------------------------------------------- mutations
NRUN=0; NKILL=0; NHOLE=0; NEQ=0; NEQBAD=0; NSKIP=0
HOLES=""; EQBAD=""

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "${line// }" ]] && continue
  [[ "$line" =~ ^[[:space:]]*# ]] && continue

  name="${line%%|||*}"
  expr="${line#*|||}"
  # trim
  name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  expr="$(printf '%s' "$expr" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -n "$expr" && "$expr" != "$line" ]] || { echo "${YEL}malformed line: $line${OFF}"; continue; }

  expect_survive=0
  if [[ "$name" == =* ]]; then expect_survive=1; name="${name#=}"; fi
  if [[ -n "$ONLY" && "$name" != *"$ONLY"* ]]; then continue; fi

  cp "$RTL" "$WORK/$BASENAME"
  perl -0pi -e "$expr" "$WORK/$BASENAME" 2>/dev/null

  if cmp -s "$RTL" "$WORK/$BASENAME"; then
    printf '%-40s %sPATTERN DID NOT MATCH -- the mutation is a no-op%s\n' "$name" "$YEL" "$OFF"
    NSKIP=$((NSKIP+1)); continue
  fi

  NRUN=$((NRUN+1))
  if ! iverilog -g2005 -o "$WORK/m.vvp" $PFLAGS "$TB" "$WORK/$BASENAME" \
          "${EXTRA[@]+"${EXTRA[@]}"}" 2>/dev/null; then
    # A mutation that will not compile is killed, but weakly: it proves nothing
    # about the testbench. Reported distinctly so it is not counted as a win.
    printf '%-40s %scompile error (counts for nothing)%s\n' "$name" "$YEL" "$OFF"
    NSKIP=$((NSKIP+1)); NRUN=$((NRUN-1)); continue
  fi

  "$WORK/m.vvp" >"$WORK/m.out" 2>&1
  nfail=$(grep -c '^FAIL' "$WORK/m.out")
  if grep -q 'PASSED' "$WORK/m.out"; then
    if [[ $expect_survive -eq 1 ]]; then
      printf '%-40s %ssurvived, as expected (proven equivalent)%s\n' "$name" "$DIM" "$OFF"
      NEQ=$((NEQ+1))
    else
      printf '%-40s %sSURVIVED  <-- hole in the tests%s\n' "$name" "$RED" "$OFF"
      NHOLE=$((NHOLE+1)); HOLES="$HOLES  $name"$'\n'
    fi
  else
    if [[ $expect_survive -eq 1 ]]; then
      printf '%-40s %sKILLED, but was declared equivalent%s\n' "$name" "$RED" "$OFF"
      NEQBAD=$((NEQBAD+1)); EQBAD="$EQBAD  $name"$'\n'
    else
      printf '%-40s killed (%s failing vectors)\n' "$name" "$nfail"
      NKILL=$((NKILL+1))
    fi
  fi
done < "$MUT"

#---------------------------------------------------------------- verdict
echo
echo "========================================================"
printf 'design : %s\n' "$RTL"
printf 'tests  : %s  (%s checks clean)\n' "$TB" "${BASE_CHECKS:-?}"
printf 'killed : %d of %d real mutations\n' "$NKILL" "$NRUN"
[[ $NEQ    -gt 0 ]] && printf 'equiv  : %d survived as declared\n' "$NEQ"
[[ $NSKIP  -gt 0 ]] && printf 'skipped: %d (no-op pattern or compile error)\n' "$NSKIP"
echo "========================================================"

rc=0
if [[ $NHOLE -gt 0 ]]; then
  echo "${RED}$NHOLE mutation(s) survived without being declared equivalent:${OFF}"
  printf '%s' "$HOLES"
  echo "Either add a test that catches it, or -- if it really is equivalent --"
  echo "prefix its name with '=' in $MUT and write down the proof."
  rc=1
fi
if [[ $NEQBAD -gt 0 ]]; then
  echo "${RED}$NEQBAD mutation(s) declared equivalent were KILLED -- the claim is wrong:${OFF}"
  printf '%s' "$EQBAD"
  rc=1
fi
[[ $rc -eq 0 ]] && echo "${GRN}all mutations accounted for${OFF}"
exit $rc
