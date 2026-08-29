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

# nick <N> <C_PORT> <TAG>   -- C_PORT and TAG may be empty
nick() {
    printf 'my_chip_n%s%s%s' "$1" "${2:+_c$2}" "${3:+_$3}"
}

# List the nicknames that actually exist, for error messages. A "missing
# directory" error that shows what IS there turns a silent mismatch into an
# obvious one.
nick_available() {
    local d="$1/work/results/nangate45"
    [[ -d "$d" ]] || return 0
    find "$d" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sort
}
