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

Trials from different DESIGNS are kept apart. Every diagnostic in this file is a
delta between consecutive rows, and a delta between two designs is a number with
no referent: an amx_fp8 PIPE=1 row ranked against an amx_tdpbssd PIPE=1 row shares
a knob name and nothing else. So each design gets its own grid and its own ladder.

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


def by_design(trials):
    """Split the log by design, in FIRST-APPEARANCE order.

    Two designs in one trials.jsonl is not hypothetical: amx_fp8 arrives at X5
    while amx_tdpbssd already holds X1..X4. Merged, they would share one ladder
    and one flatness verdict -- so an amx_fp8 row would be credited or blamed for
    a step away from a completely different netlist, and "d fmax" between the two
    would be a subtraction with no referent. The X axis does not save us either:
    nothing enforces that two designs never reuse an X number.

    First-appearance order rather than sorted() so the design that is already
    published stays at the top of the output, which is what experiments/RESULTS.md
    is generated from.
    """
    groups = {}
    for t in trials:
        # Rows predating the "design" field can only be amx_tdpbssd, but do not
        # guess: an unlabelled row grouped under a name it may not belong to is
        # the same defect one level down.
        groups.setdefault(t.get("design", "UNLABELLED"), []).append(t)
    return list(groups.items())


def headline(m):
    """The frequency that describes the HARDWARE, plus how trustworthy it is.

    implied_fmax_mhz = 1000/(period - setup_ws) is only a statement about the
    design when the limiting path runs register-to-register. When it ends at an
    I/O port the SDC charges 0.2*period (output) or 0.4*period (input->output)
    plus 0.1 ns uncertainty against it, and because that budget SCALES with the
    target, the reported frequency rises as the target tightens with identical
    cells: X3-Y0 reads 620.7 MHz at P=1.60 and would read 670.7 at P=1.00 with
    nothing changed. Three of the first eight trials were limited that way and
    X2-Y2 was reported at 511.4 when its datapath was good for 600.3.

    regreg_fmax_mhz has no such term -- launch and capture clock insertion delay
    cancel across a flop-to-flop path -- so it is comparable across targets and
    is the objective this project ranks on. Returns (value, limiter, trusted).
    """
    rr = m.get("regreg_fmax_mhz")
    cls = m.get("limiter_class")
    if rr is not None:
        return rr, cls, (cls == "reg->reg")
    # No limiter data: pre-backfill row, or sta_limiter.sh failed. Fall back to
    # the old metric but never silently -- an untrusted number must look untrusted.
    return m["implied_fmax_mhz"], cls, False


def ladder(trials, design=None, multi=False):
    """Cost per unit gain, grouped by RTL VARIANT (PIPE), not by trial.

    Called once per design. `multi` names the design in the heading only when the
    log holds more than one -- with a single design the name is redundant, and
    printing it would change the text experiments/RESULTS.md is generated from.

    Per-trial was wrong and the output said so: it split PIPE=1's gain across two
    rows -- "+0.3 MHz for +4,610 flops" at the saturated 2.80 ns target, then
    "+54.4 MHz for +0 flops" when the same RTL was re-measured at 2.00 -- making
    one change look worthless and then free. Neither is true.

    A trial measures an (RTL, target) pair. Only the BEST target per RTL reveals
    what that RTL can do, so the ladder takes the max fmax per PIPE level and
    compares consecutive levels. That is the number which answers the question the
    ladder exists for: is the next pipeline stage worth its flops.
    """
    suffix = " -- %s" % design if multi else ""
    ok = [t for t in trials if t.get("metrics")]
    if len(ok) < 2:
        # Say so rather than vanishing. Once the log holds two designs, a silently
        # absent ladder looks like the per-design split lost the rows, which is
        # the opposite of what happened.
        print("Ladder economics%s: %d measured trial(s). A rung is a comparison"
              % (suffix, len(ok)))
        print("  between two variants, so there is nothing to rank yet.\n")
        return
    # Group by the FULL RTL variant, not by PIPE alone. Keying on PIPE made
    # "PIPE=3" resolve to X3-Y0, which is PIPE=3 AND RD_REG=1, so RD_REG's gain
    # was credited to the third pipeline stage: +153.3 MHz for +1,537 flops,
    # +99.74 MHz per 1k flops, which is 8x the next-best rung and obvious
    # nonsense. This is the same defect as the earlier per-trial grouping, one
    # level up: a rung has to be ONE change from the rung below it.
    best = {}
    for t in ok:
        k = (t["knobs"]["PIPE"], t["knobs"].get("RD_REG", 0))
        if k not in best or headline(t["metrics"])[0] > headline(best[k]["metrics"])[0]:
            best[k] = t
    print("Ladder economics, best result per RTL variant%s" % suffix)
    print("  (ranked on reg->reg fmax -- see headline() for why not implied_fmax)\n")
    print("  %-9s %-8s %-9s %-9s %-8s %-9s %-18s %s"
          % ("variant", "best at", "fmax MHz", "d fmax", "flops", "d flops",
             "MHz per 1k flops", "limiter"))
    prev = None
    for p in sorted(best):
        t = best[p]; m = t["metrics"]
        f, cls, trusted = headline(m)
        ff = m["flipflops"]
        label = "P%d/RD%d" % p
        df = dff = None
        if prev:
            df, dff = f - prev[0], ff - prev[1]
        eff = "%+.2f" % (df / (dff / 1000.0)) if (df is not None and dff) else ""
        print("  %-9s %-8s %-9.1f %-9s %-8d %-9s %-18s %s"
              % (label, "X%dY%d" % (t["x"], t["y"]), f, fmt(df, "%+.1f"), ff,
                 fmt(dff, "%+d"), eff, cls or "UNKNOWN"))
        prev = (f, ff)
    print()
    print("  Only the best target per variant is used: a trial measures an")
    print("  (RTL, target) pair, and a saturated target measures the target.")
    # The rungs are still measured at DIFFERENT targets, and the tool works to
    # whatever target it is given, so effort differs between rungs even now that
    # the I/O artifact is gone. Removing the pad-boundary term does not make
    # cross-target rungs equal-effort; it only stops them being wrong for a
    # second, avoidable reason.
    print("  CAVEAT: rungs come from different targets, so effort still differs.")
    print("  Only equal-target pairs are like-for-like comparisons.")
    print()


def grid(trials, metric, design=None, multi=False):
    # Called once per design, for the reason by_design() gives: the d-fmax column
    # and the flat/saturated verdict below are deltas down a single X row, and a
    # row holding two designs would compute both across a change of netlist.
    xs = sorted({t["x"] for t in trials})
    print("X-Y grid%s  (metric: %s, headline: reg->reg fmax)\n"
          % (" -- %s" % design if multi else "", metric))
    for x in xs:
        row = sorted((t for t in trials if t["x"] == x), key=lambda t: t["y"])
        print("  X%d" % x)
        print("    %-4s %-6s %-9s %-9s %-8s %-9s %-8s %-7s %-10s %s" %
              ("Y", "res", "fmax MHz", "d fmax", "setup ws", "hold ws",
               "cells", "DRC", "limiter", "metric"))
        prev = None
        moved = []
        saturated = []
        for t in row:
            m = t.get("metrics")
            if not m:
                print("    %-4d %-6s %s" % (t["y"], t["result"],
                                            t.get("note", "")))
                continue
            # The flatness and saturation diagnostics run on the HEADLINE number,
            # so they inherit whatever that metric's defects are. Before the
            # limiter class was recorded they ran on implied_fmax_mhz, which
            # means a row could look like it was moving when the only thing
            # moving was the period-scaled pad budget.
            f, cls, trusted = headline(m)
            d = None if prev is None else f - prev
            if d is not None:
                moved.append(abs(d))
                saturated.append(abs(m["setup_tns"]) < SATURATED_TNS)
            hold = m["hold_ws_ns"]
            print("    %-4d %-6s %-9.1f %-9s %-+9.4f %-+9.4f %-8d %-7d %-10s %s"
                  % (t["y"], t["result"], f,
                     fmt(d, "%+.1f"), m["setup_ws_ns"], hold,
                     m["stdcells"], m["drc_lines"], cls or "UNKNOWN",
                     fmt(m.get(metric), "%.4g")),
                  end="")
            print("   HOLD VIOLATED" if hold < 0 else "")
            if not trusted:
                print("         ^ implied_fmax %.1f is I/O-limited (%s); "
                      "reg->reg %.1f used instead"
                      % (m["implied_fmax_mhz"], cls or "no limiter data", f))
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
        # Grids first, then ladders, keeping the two-section shape RESULTS.md
        # mirrors with its headings rather than interleaving per design.
        groups = by_design(trials)
        multi = len(groups) > 1
        for name, ts in groups:
            grid(ts, a.metric, name, multi)
        for name, ts in groups:
            ladder(ts, name, multi)
    print("  %d trial(s) in %s" % (len(trials), os.path.relpath(JSONL, HERE)))


if __name__ == "__main__":
    main()
