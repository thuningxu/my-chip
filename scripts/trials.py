#!/usr/bin/env python3
"""
Read experiments/trials.jsonl and print the X-Y grid.

The grid is the whole point of the two-axis scheme, because the decision it
supports cannot be made from a single row:

    a Y regressing or failing  -> the DESIGN is wrong, try another Y
    an entire X row going FLAT -> the HARNESS is wrong; it kept proposing fixes
                                  from the wrong family, so more Y cannot help

So this prints per-X rows with the delta between consecutive Y, and flags a row
as flat when successive Y stop moving the metric the generation was trying to
move. It does NOT decide anything -- "flat" is a threshold on a number, and
whether that means the harness is exhausted is a judgement that belongs to
whoever reads it, next to what the generation said it could and could not reach.

    python3 scripts/trials.py                # the grid
    python3 scripts/trials.py --metric area_um2
    python3 scripts/trials.py --full         # every field of every trial
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSONL = os.path.join(HERE, "experiments", "trials.jsonl")

# How much movement in the headline metric still counts as movement. Below this
# a step is noise, not progress. 10 MHz is deliberately generous: this project
# has already measured a 48 MHz spread in the fmax EFFECT of one RTL change
# across two configurations (rows f2a/f2b), so anything smaller cannot be
# attributed to a Y at all.
FLAT_MHZ = 10.0


def load():
    if not os.path.exists(JSONL):
        sys.exit("no trials yet: %s" % JSONL)
    out = []
    for n, line in enumerate(open(JSONL), 1):
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError as e:
            sys.exit("trials.jsonl line %d is not valid JSON: %s" % (n, e))
    return out


def fmt(v, spec="%s"):
    return "-" if v is None else spec % v


def grid(trials, metric):
    xs = sorted({t["x"] for t in trials})
    print("X-Y grid  (metric: %s, headline: implied_fmax_mhz)\n" % metric)
    for x in xs:
        row = sorted((t for t in trials if t["x"] == x), key=lambda t: t["y"])
        print("  X%d" % x)
        print("    %-4s %-6s %-9s %-9s %-8s %-9s %-8s %-7s %s" %
              ("Y", "res", "fmax MHz", "d fmax", "setup ws", "hold ws",
               "cells", "DRC", "metric"))
        prev = None
        moved = []
        for t in row:
            m = t.get("metrics")
            if not m:
                print("    %-4d %-6s %s" % (t["y"], t["result"],
                                            t.get("note", "")))
                continue
            f = m["implied_fmax_mhz"]
            d = None if prev is None else f - prev
            if d is not None:
                moved.append(abs(d))
            hold = m["hold_ws_ns"]
            print("    %-4d %-6s %-9.1f %-9s %-+9.4f %-+9.4f %-8d %-7d %s"
                  % (t["y"], t["result"], f,
                     fmt(d, "%+.1f"), m["setup_ws_ns"], hold,
                     m["stdcells"], m["drc_lines"],
                     fmt(m.get(metric), "%.4g")),
                  end="")
            print("   HOLD VIOLATED" if hold < 0 else "")
            prev = f
        # The diagnostic. What matters is whether the LAST few Y moved it, not
        # whether any Y ever did: a row that jumps once and then plateaus is
        # exhausted, and "X advances when Y stops moving" is about the recent
        # steps. Requiring every step to be flat would keep a dead row alive
        # forever on the strength of its first success.
        TAIL = 2
        tail = moved[-TAIL:]
        if len(tail) >= TAIL and all(d < FLAT_MHZ for d in tail):
            print("    => ROW LOOKS FLAT: the last %d Y each moved < %.0f MHz "
                  "(%s)." % (TAIL, FLAT_MHZ,
                             ", ".join("%+.1f" % d for d in tail)))
            print("       By the X-Y rule that implicates the HARNESS, not the")
            print("       RTL. Re-read what X%d declared it could NOT reach" % x)
            print("       before spending another Y on the same fix family.")
            if max(moved) >= FLAT_MHZ:
                print("       Note this row DID move earlier (best step %+.1f MHz),"
                      % max(moved))
                print("       so the family worked and is now exhausted -- which is")
                print("       a different finding from a family that never worked.")
        elif moved:
            print("    => still moving (last step %+.1f MHz)" % moved[-1])
        print()


def full(trials):
    for t in trials:
        print(json.dumps(t, indent=2, sort_keys=True))
        print()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--metric", default="area_um2")
    ap.add_argument("--full", action="store_true")
    a = ap.parse_args()
    trials = load()
    if a.full:
        full(trials)
    else:
        grid(trials, a.metric)
    print("  %d trial(s) in %s" % (len(trials), os.path.relpath(JSONL, HERE)))


if __name__ == "__main__":
    main()
