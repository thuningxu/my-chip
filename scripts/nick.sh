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

# amx_fp8: the tile geometry is fixed by the instruction (16x64 fp8, 16x16 fp32)
# and the four variants are a RUNTIME input, not a build parameter -- one netlist
# executes all of TDPBF8PS, TDPBHF8PS, TDPHBF8PS and TDPHF8PS, which is the whole
# point of a unified design. RD_REG is omitted for the same reason it is omitted
# from nick_tpu: it adds one register and no geometry, so forking every artifact
# directory over it would be noise.
#
# ACC and FX_W are DIFFERENT: ACC selects between two entirely different
# accumulators, and FX_W changes the width of 256 of them. Two builds that differ
# in either are different hardware with different cell counts, so they must not
# share an artifact directory -- that is exactly the collision this file was
# written to prevent (see the header on C_PORT).
#
# ACC=0 emits the BARE name `fp8`, with no suffix, so the p1 artifacts already on
# disk keep resolving. Same reasoning as OUT_PAR's explicit zero test above: p1
# backs a published EXPERIMENTS.md row and renaming its directory would orphan
# that provenance. FX_W appears only when ACC=1, because it has no meaning
# otherwise -- an `fp8_a0_w52` would imply a width that does not exist in that
# build.
#
# Distinct `fp8_` prefix keeps these clear of my_chip_*, amx_* and tpu_*.
#   nick_fp8 <ACC> <FX_W> [TAG]
nick_fp8() {
    local acc="${1:-0}" w="${2:-52}" tag="${3:-}"
    # The signature GAINED two leading arguments when ACC arrived, and every
    # existing caller passed TAG first. A stale caller would therefore hand a tag
    # string in as ACC and get a plausible-looking wrong directory -- the precise
    # failure this file exists to prevent. So reject anything that is not a number
    # rather than build a name out of it.
    if [[ ! "$acc" =~ ^[0-9]+$ || ! "$w" =~ ^[0-9]+$ ]]; then
        echo "FATAL: nick_fp8 takes <ACC> <FX_W> [TAG], got ACC='$acc' FX_W='$w'." >&2
        echo "       A caller is still using the old nick_fp8 <TAG> signature." >&2
        return 2
    fi
    if [[ "$acc" == "0" ]]; then
        printf 'fp8%s' "${tag:+_$tag}"
    else
        printf 'fp8_a%s_w%s%s' "$acc" "$w" "${tag:+_$tag}"
    fi
}

# List the nicknames that actually exist, for error messages. A "missing
# directory" error that shows what IS there turns a silent mismatch into an
# obvious one.
nick_available() {
    local d="$1/work/results/nangate45"
    [[ -d "$d" ]] || return 0
    find "$d" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sort
}
