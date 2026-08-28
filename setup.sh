#!/usr/bin/env bash
#=============================================================================
# setup.sh -- verify (and optionally install) everything my-chip needs, then
# write local.mk so `make` works without you exporting anything by hand.
#
#   ./setup.sh            check, and install anything missing via Homebrew
#   ./setup.sh --check    check only, install nothing
#
# Every check here exists because it bit someone. In particular the KLayout
# quarantine check: ORFS evaluates `klayout -v` at makefile-PARSE time, so a
# quarantined KLayout hangs *every* make invocation, including trivial ones.
#=============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL=1
[[ "${1:-}" == "--check" ]] && INSTALL=0

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
FAIL=0
NOTES=()

ok()   { printf "  ${GRN}ok${RST}    %s\n" "$1"; }
warn() { printf "  ${YEL}warn${RST}  %s\n" "$1"; NOTES+=("$1"); }
bad()  { printf "  ${RED}FAIL${RST}  %s\n" "$1"; FAIL=1; }
hdr()  { printf "\n== %s ==\n" "$1"; }

# run a command with a hard time limit (macOS has no coreutils `timeout`)
tmo() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@" 2>/dev/null; }

#-----------------------------------------------------------------------------
hdr "platform"
OS="$(uname -s)"
ok "os: $OS $(uname -m)"
if [[ "$OS" == "Darwin" ]]; then
  if ! xcode-select -p >/dev/null 2>&1; then
    bad "Xcode command line tools missing. Run: xcode-select --install"
  else
    ok "xcode command line tools"
  fi
  if ! command -v brew >/dev/null; then
    bad "Homebrew missing. See https://brew.sh"
  else
    ok "homebrew $(brew --version | head -1 | awk '{print $2}')"
  fi
fi

#-----------------------------------------------------------------------------
hdr "host tools"

need_brew() {         # need_brew <formula> <binary> [--cask]
  local formula="$1" bin="$2" cask="${3:-}"
  if command -v "$bin" >/dev/null; then
    ok "$bin ($(command -v "$bin"))"
    return 0
  fi
  if [[ $INSTALL -eq 1 && "$OS" == "Darwin" ]] && command -v brew >/dev/null; then
    printf "  ....  installing %s\n" "$formula"
    if [[ "$cask" == "--cask" ]]; then brew install --cask "$formula" >/dev/null 2>&1
    else                               brew install "$formula"        >/dev/null 2>&1; fi
    if command -v "$bin" >/dev/null; then ok "$bin (installed)"; return 0; fi
  fi
  bad "$bin not found (install: brew install $formula)"
  return 1
}

need_brew icarus-verilog iverilog
need_brew icarus-verilog vvp

if command -v python3 >/dev/null; then
  PYV="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
  if python3 -c 'import sys;sys.exit(0 if sys.version_info>=(3,8) else 1)'; then
    ok "python3 $PYV"
  else
    bad "python3 $PYV too old (need >= 3.8)"
  fi
else
  bad "python3 not found"
fi

# yosys: ORFS requires >= 0.58
if need_brew yosys yosys; then
  YV="$(yosys -V 2>/dev/null | head -1 | sed -E 's/^Yosys ([0-9]+\.[0-9]+).*/\1/')"
  if [[ -n "$YV" ]] && python3 -c "import sys;sys.exit(0 if float('$YV')>=0.58 else 1)" 2>/dev/null; then
    ok "yosys version $YV (>= 0.58)"
  else
    warn "yosys version '$YV' could not be confirmed >= 0.58 (ORFS minimum)"
  fi
  YOSYS_EXE_RESOLVED="$(command -v yosys)"
fi

#-----------------------------------------------------------------------------
hdr "ORFS (OpenROAD-flow-scripts)"
ORFS_TRY=("${ORFS:-}" "$HERE/../OpenROAD-flow-scripts" "$HOME/sd/OpenROAD-flow-scripts" "$HOME/OpenROAD-flow-scripts")
ORFS_FOUND=""
for cand in "${ORFS_TRY[@]}"; do
  [[ -n "$cand" && -d "$cand/flow" ]] && { ORFS_FOUND="$(cd "$cand" && pwd)"; break; }
done

OPENROAD_EXE_RESOLVED=""
if [[ -z "$ORFS_FOUND" ]]; then
  bad "ORFS not found -- see SETUP.md section 2, then re-run with ORFS=/path/to/OpenROAD-flow-scripts ./setup.sh"
else
  ok "ORFS at $ORFS_FOUND"

  ORB="$ORFS_FOUND/tools/install/OpenROAD/bin/openroad"
  if [[ -x "$ORB" ]] && VER="$("$ORB" -version 2>/dev/null | head -1)"; then
    ok "openroad $VER"
    OPENROAD_EXE_RESOLVED="$ORB"
  elif command -v openroad >/dev/null; then
    ok "openroad (on PATH: $(command -v openroad))"
    OPENROAD_EXE_RESOLVED="$(command -v openroad)"
  else
    # Deliberately platform-aware: build_openroad.sh --local does NOT work on
    # macOS (four separate defects -- see SETUP.md), so pointing a mac user at
    # it would send them down a dead end.
    if [[ "$OS" == "Darwin" ]]; then
      bad "openroad binary not found at $ORB -- follow SETUP.md section 2 (macOS). Note: ORFS's own build_openroad.sh --local does NOT work on macOS."
    else
      bad "openroad binary not found at $ORB -- build it: cd $ORFS_FOUND && sudo ./setup.sh && ./build_openroad.sh --local"
    fi
  fi

  if [[ -d "$ORFS_FOUND/flow/platforms/nangate45/lib" ]]; then
    ok "nangate45 PDK ($(ls "$ORFS_FOUND/flow/platforms/nangate45/lib" | wc -l | tr -d ' ') lib files)"
  else
    bad "nangate45 platform missing under $ORFS_FOUND/flow/platforms"
  fi
fi

#-----------------------------------------------------------------------------
hdr "KLayout (needed at makefile-PARSE time)"
# ORFS computes KLAYOUT_VERSION via `$(KLAYOUT_CMD) -v` in a $(shell ...) at
# parse time. If KLayout is quarantined it never returns and EVERY make target
# hangs -- including `make help`. So resolve a binary that provably answers.
KL_LOCAL="$HOME/klayout-local/klayout.app/Contents/MacOS/klayout"
KL_APP="/Applications/KLayout/klayout.app/Contents/MacOS/klayout"
KLAYOUT_CMD_RESOLVED=""

kl_answers() { [[ -x "$1" ]] && [[ -n "$(tmo 20 "$1" -v)" ]]; }

if kl_answers "$KL_LOCAL"; then
  ok "klayout $(tmo 20 "$KL_LOCAL" -v | head -1) (de-quarantined copy)"
  KLAYOUT_CMD_RESOLVED="$KL_LOCAL"
elif kl_answers "$KL_APP"; then
  ok "klayout $(tmo 20 "$KL_APP" -v | head -1) (/Applications)"
  KLAYOUT_CMD_RESOLVED="$KL_APP"
elif command -v klayout >/dev/null && kl_answers "$(command -v klayout)"; then
  ok "klayout on PATH"
  KLAYOUT_CMD_RESOLVED="$(command -v klayout)"
else
  # not installed, or installed but hanging (quarantine)
  if [[ ! -e "/Applications/KLayout/klayout.app" ]] && [[ $INSTALL -eq 1 ]] && command -v brew >/dev/null; then
    printf "  ....  installing klayout (cask)\n"
    brew install --cask klayout >/dev/null 2>&1
  fi
  if [[ -e "/Applications/KLayout/klayout.app" ]]; then
    if [[ $INSTALL -eq 1 ]]; then
      printf "  ....  /Applications KLayout does not answer -v (Gatekeeper quarantine);\n"
      printf "  ....  building a de-quarantined copy at %s\n" "$HOME/klayout-local"
      rm -rf "$HOME/klayout-local"
      mkdir -p "$HOME/klayout-local"
      ditto --noextattr --norsrc /Applications/KLayout/klayout.app \
            "$HOME/klayout-local/klayout.app" 2>/dev/null
      if kl_answers "$KL_LOCAL"; then
        ok "klayout $(tmo 20 "$KL_LOCAL" -v | head -1) (de-quarantined copy created)"
        KLAYOUT_CMD_RESOLVED="$KL_LOCAL"
      else
        bad "de-quarantined copy still does not answer. Grant your terminal App Management, then: xattr -dr com.apple.quarantine /Applications/KLayout/klayout.app"
      fi
    else
      bad "KLayout present but hangs on -v (quarantine). Re-run ./setup.sh without --check to auto-fix."
    fi
  else
    bad "klayout not installed (brew install --cask klayout)"
  fi
fi

#-----------------------------------------------------------------------------
hdr "writing local.mk"
if [[ $FAIL -eq 0 ]]; then
  cat > "$HERE/local.mk" <<EOF
# generated by setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ) -- do not edit, do not commit
ORFS        := $ORFS_FOUND
YOSYS_EXE   := ${YOSYS_EXE_RESOLVED:-}
OPENROAD_EXE:= ${OPENROAD_EXE_RESOLVED:-}
KLAYOUT_CMD := ${KLAYOUT_CMD_RESOLVED:-}
IVERILOG    := $(command -v iverilog 2>/dev/null)
PYTHON      := $(command -v python3 2>/dev/null)
EOF
  ok "local.mk written"
else
  warn "local.mk NOT written -- fix the failures above first"
fi

#-----------------------------------------------------------------------------
printf "\n"
if [[ ${#NOTES[@]} -gt 0 ]]; then
  printf "%s\n" "${YEL}warnings:${RST}"
  for n in "${NOTES[@]}"; do printf "  - %s\n" "$n"; done
  printf "\n"
fi
if [[ $FAIL -eq 0 ]]; then
  printf "%s  Run: make sim   then: make measure\n" "${GRN}setup OK${RST}"
  exit 0
else
  printf "%s  see failures above\n" "${RED}setup INCOMPLETE${RST}"
  exit 1
fi
