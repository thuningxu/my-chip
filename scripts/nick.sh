#!/usr/bin/env bash
#=============================================================================
# nick.sh -- the SINGLE definition of an artifact nickname. Source it.
#
# WHY THIS FILE EXISTS. measure.sh WRITES work/ directories under this name and
# report_path.sh READS them. They used to derive it independently, and when
# measure.sh gained the C_PORT field the two drifted: `make path N=4 CPORT=1`
# went looking for `my_chip_n4`, found the leftover pre-C_PORT baseline, and
# cheerfully reported the critical path of a DIFFERENT DESIGN than the one just
# measured -- no error, plausible number, wrong answer. The whole point of this
# repo is not shipping numbers like that.
#
# So there is now one function. Do not re-derive the name anywhere else.
#=============================================================================

# nick <N> <C_PORT> <TAG> <OUT_PAR>   -- C_PORT, TAG and OUT_PAR may be empty
#
# OUT_PAR is appended ONLY when non-zero, so every name that existed before the
# parameter was added still resolves to the same directory. That is not cosmetic:
# my_chip_n4, my_chip_n4_c0 and my_chip_n4_c1 each hold a verified GDS and back a
# published EXPERIMENTS.md row. Renaming them would orphan that provenance.
#
# `${4:+_r$4}` would be WRONG here -- :+ tests for non-empty, and the string "0"
# is non-empty, so the default config would have been renamed to _r0. Hence the
# explicit test.
nick() {
    local r=""
    if [[ -n "${4:-}" && "${4:-}" != "0" ]]; then r="_r$4"; fi
    # TAG stays last so sweep tags read as a suffix: my_chip_n4_c1_r1_p120
    printf 'my_chip_n%s%s%s%s' "$1" "${2:+_c$2}" "$r" "${3:+_$3}"
}

# nick_amx <SAT> <TAG>   -- artifact name for the amx_tdpbssd design.
#
# A separate function rather than more fields on nick(): the two designs have
# disjoint parameter sets (N/C_PORT/OUT_PAR vs SAT), and cramming both into one
# name builder would mean every mac_array name grew an empty SAT slot. The
# distinct `amx_` prefix also guarantees no collision with the `my_chip_*`
# artifacts already on disk. SAT is always emitted -- this design has no legacy
# names to preserve, and 'which saturation mode' is exactly what you want on the
# directory.
nick_amx() {
    printf 'amx_s%s%s' "${1:-1}" "${2:+_$2}"
}

# tpu_mmu: the array dimension is the only thing that changes the hardware size,
# so it is the only field in the name. RD_REG deliberately does NOT appear -- it
# adds one register and no geometry, and putting it in the name would fork every
# artifact directory for a knob that is measured, not swept. Distinct `tpu_`
# prefix keeps these clear of my_chip_* and amx_*.
#   nick_tpu <N> [TAG]
nick_tpu() {
    printf 'tpu_n%s%s' "${1:-32}" "${2:+_$2}"
}

# List the nicknames that actually exist, for error messages. A "missing
# directory" error that shows what IS there turns a silent mismatch into an
# obvious one.
nick_available() {
    local d="$1/work/results/nangate45"
    [[ -d "$d" ]] || return 0
    find "$d" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sort
}
