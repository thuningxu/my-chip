#!/usr/bin/env python3
"""Reject an X6 netlist if per-cell epilogue registers were merged away."""
import argparse
import re


def inspect(lines):
    total = 0
    controls = []
    # Count mapped CELL INSTANCES, not declarations or aliases of kept wires.
    cell = re.compile(r"^\s*(?:S?DFF)[A-Z0-9_]*_X\d+\s+(\S+)\s*\(")
    control_q = re.compile(r"\.Q\(\s*\\?(g_m\[\d+\]\.g_n\[\d+\]\.g_ctrl_reg\.ep_ctrl)"
                           r"\s*\[(\d+)\]\s*\)")
    in_flop = False
    for line in lines:
        match = cell.match(line)
        if match:
            total += 1
            in_flop = True
        if in_flop:
            # Generic synthesis uses anonymous cell names; ORFS renames them.
            # The actual Q connection identifies the driver in BOTH forms.
            output = control_q.search(line)
            if output:
                controls.append("%s[%s]" % output.groups())
            if ");" in line:
                in_flop = False
    return total, controls


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("netlist")
    parser.add_argument("--ctrl-reg", type=int, choices=(0, 1), required=True)
    args = parser.parse_args()
    with open(args.netlist) as netlist:
        total, controls = inspect(netlist)
    if total == 0:
        parser.exit(1, "FATAL: no mapped flip-flops found; not a usable netlist\n")
    expected = 16 * 16 * 3 * args.ctrl_reg
    if len(controls) != expected or len(set(controls)) != expected:
        parser.exit(1, "FATAL: expected %d distinct control flop instances, found %d; "
                    "refusing placement/routing\n" % (expected, len(controls)))
    if args.ctrl_reg:
        for row in range(16):
            for col in range(16):
                prefix = "g_m[%d].g_n[%d].g_ctrl_reg.ep_ctrl[" % (row, col)
                for bit in range(3):
                    if sum(prefix + str(bit) + "]" in name for name in controls) != 1:
                        parser.exit(1, "FATAL: missing/duplicate control flop %s%d]\n"
                                    % (prefix, bit))
    print("CONTROL_REGS: PASS ctrl_reg=%d replicas=%d total_flipflops=%d"
          % (args.ctrl_reg, len(controls), total))


if __name__ == "__main__":
    main()
