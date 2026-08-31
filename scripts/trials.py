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

# |TNS| below this means the tool met its target and stopped working, so the
# measurement describes the TARGET rather than the design. Calibrated from real
# rows: X1-Y1 was saturated at -0.8, while X1-Y0 (-36.0, straining) and X2-Y0
# (-1067.8, working hard) were not. A small fmax step with saturated TNS is NOT
# evidence the fix family is exhausted -- it is evidence the period is wrong,
# which is a different fault with a different remedy.
SATURATED_TNS = 5.0


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


def ladder(trials):
    """Cost per unit gain, grouped by RTL VARIANT (PIPE), not by trial.

    Per-trial was wrong and the output said so: it split PIPE=1's gain across two
    rows -- "+0.3 MHz for +4,610 flops" at the saturated 2.80 ns target, then
    "+54.4 MHz for +0 flops" when the same RTL was re-measured at 2.00 -- making
    one change look worthless and then free. Neither is true.

    A trial measures an (RTL, target) pair. Only the BEST target per RTL reveals
    what that RTL can do, so the ladder takes the max fmax per PIPE level and
    compares consecutive levels. That is the number which answers the question the
    ladder exists for: is the next pipeline stage worth its flops.
    """
    ok = [t for t in trials if t.get("metrics")]
    if len(ok) < 2:
        return
    best = {}
    for t in ok:
        p = t["knobs"]["PIPE"]
        if p not in best or t["metrics"]["implied_fmax_mhz"] > best[p]["metrics"]["implied_fmax_mhz"]:
            best[p] = t
    print("Ladder economics, best result per RTL variant\n")
    print("  %-5s %-8s %-9s %-9s %-8s %-9s %s"
          % ("PIPE", "best at", "fmax MHz", "d fmax", "flops", "d flops",
             "MHz per 1k flops"))
    prev = None
    for p in sorted(best):
        t = best[p]; m = t["metrics"]
        f, ff = m["implied_fmax_mhz"], m["flipflops"]
        df = dff = None
        if prev:
            df, dff = f - prev[0], ff - prev[1]
        eff = "%+.2f" % (df / (dff / 1000.0)) if (df is not None and dff) else ""
        print("  %-5d %-8s %-9.1f %-9s %-8d %-9s %s"
              % (p, "X%dY%d" % (t["x"], t["y"]), f, fmt(df, "%+.1f"), ff,
                 fmt(dff, "%+d"), eff))
        prev = (f, ff)
    print()
    print("  Only the best target per variant is used: a trial measures an")
    print("  (RTL, target) pair, and a saturated target measures the target.")
    print()


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
        saturated = []
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
                saturated.append(abs(m["setup_tns"]) < SATURATED_TNS)
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
        # Saturation is checked BEFORE flatness, because a saturated step is not a
        # flat step -- it is an unmeasured one, and calling it flat would blame the
        # fix family for the period's fault. This is the exact mistake the X1 row
        # invited: +0.3 MHz looked like exhaustion and was actually a hidden 15%.
        if moved and saturated and saturated[-1] and moved[-1] < FLAT_MHZ:
            print("    => LAST STEP IS SATURATED, NOT FLAT: |TNS| < %.0f means the"
                  % SATURATED_TNS)
            print("       tool met its target and stopped, so this measures the")
            print("       TARGET, not the design. Do NOT read it as the fix family")
            print("       being exhausted. Re-measure the same RTL at a tighter")
            print("       period before spending another Y or advancing X on it.")
            print()
            continue
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
        ladder(trials)
    print("  %d trial(s) in %s" % (len(trials), os.path.relpath(JSONL, HERE)))


if __name__ == "__main__":
    main()
