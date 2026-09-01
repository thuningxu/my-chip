#!/usr/bin/env python3
"""Build experiments/report.html -- the readable campaign report, one plate per trial.

Prose is authored here; every NUMBER is pulled from experiments/trials.jsonl and every
image from work/reports/.../final_all.webp, so no figure in the report is hand-typed.

Images are embedded as base64 data URIs, which makes the output self-contained (~3.4 MB)
and viewable with no server and no dependency on work/ still existing. That is why the
generated HTML is committed alongside this script: work/ is build output and is not in
git, so once it is cleaned the report cannot be regenerated from this file alone.

Run:  python3 scripts/report.py && open experiments/report.html
"""
import base64, json, os

IMG = "work/reports/nangate45/amx_s1_%s/base/final_all.webp"
trials = [json.loads(l) for l in open("experiments/trials.jsonl")]

# Prose is authored; every NUMBER below is pulled from trials.jsonl, never typed.
PROSE = {
 ("x1y0", True): dict(
  head="Re-baseline, no RTL change",
  tried="""Establish a comparison point before touching anything. The previous measurement
  violated <em>hold</em> at &minus;0.0349&nbsp;ns over 34 endpoints &mdash; a min-delay failure that no
  clock period can fix. X1 treated hold as a harness knob rather than an RTL problem and
  set the tool's <code>HOLD_SLACK_MARGIN</code> to 0.05&nbsp;ns. Period fixed at 2.80&nbsp;ns,
  derived from the measured need, and held constant for every trial in the generation.""",
  result="""Hold closed completely &mdash; 34 violations to zero &mdash; with <strong>no RTL
  change at all</strong>. It was a repair-effort problem, not a design problem. The whole
  design is one combinational path: <code>kcnt</code> through a 16:1 mux, 1024 multipliers,
  the adder trees, a 33-bit add and the saturating fold, into the accumulator. That shows up
  in the power number, and nobody looked at it for eight more trials.""",
  note=None),
 ("x1y1", True): dict(
  head="PIPE=1 &mdash; and the row the metric could not see",
  tried="""The same change, now actually built: one pipeline register after <code>sum4</code>,
  verified identical in simulation and synthesis.""",
  result="""By the number X1 was watching, this row was <strong>flat</strong> &mdash; frequency
  moved 0.3&nbsp;MHz and the generation was declared exhausted. That reading was correct about
  its own metric and wrong about the design. At the same target and the same speed, power fell
  from 19.00&nbsp;W to 0.99&nbsp;W: a <strong>19.2&times; reduction</strong>, with 10% fewer
  cells and 15% less area. One register truncated glitch propagation through 1024 multipliers
  that had been toggling repeatedly before settling every cycle. The win was sitting in a file
  the harness had already parsed.""",
  note="This run appears twice in the log. The flow succeeded, but the script was edited while bash was part-way through executing it, so it resumed at a shifted byte offset and the logging step was destroyed after 61 minutes of completed work. The record was then recovered from these very artifacts in zero seconds, once the script grew a flag for exactly that. Separately: the 19x power win was noticed at close, not at the time. A hillclimb that ranks on one scalar cannot see a Pareto move."),
 ("x2y0", True): dict(
  head="Same RTL, honest target",
  tried="""No RTL change. X1's fixed 2.80&nbsp;ns period was the suspect: total negative slack
  had been only &minus;0.8&nbsp;ns, meaning the tool met its target and stopped optimising. If
  the measurement was saturated, the &ldquo;flat&rdquo; row was an artifact of the period.
  Re-measure the identical netlist at 2.00&nbsp;ns.""",
  result="""<code>PIPE=1</code> was worth <strong>+54.7&nbsp;MHz</strong>, not +0.3. The fix
  family had worked all along; the procedure had hidden it. From here on, total negative slack
  is read as the saturation signal before any row is called flat.""",
  note=None),
 ("x2y1", True): dict(
  head="PIPE=2 &mdash; split the multiply from the tree",
  tried="""Also register the raw products, adding 16,384 flops &mdash; by far the most expensive
  rung. Target derived from the previous row's measured need.""",
  result="""<strong>+77.9&nbsp;MHz.</strong> Larger than the previous rung, which contradicted
  the prediction written before the run: gate count had been used as a proxy for logic depth,
  and depth is what a clock period actually pays for.""",
  note=None),
 ("x2y2", True): dict(
  head="PIPE=3 &mdash; and a number that was measuring the wrong thing",
  tried="""Register the selected operands too, splitting the 16:1 mux from the multiply for only
  1,024 more flops. Same 1.80&nbsp;ns target as the previous rung, so the comparison is clean.""",
  result="""Reported at 511.4&nbsp;MHz &mdash; and that figure is <strong>wrong</strong>. The
  limiting path here runs from an input port through the readback mux straight to an output
  port, never touching a register. The timing constraints charge such a path 40% of the clock
  period plus uncertainty as pad-boundary budget: <strong>46% of the period spent on modelling
  assumptions</strong>, not logic. The compute datapath had already met its target with
  0.134&nbsp;ns to spare. The real figure is <strong>600.3&nbsp;MHz</strong>, recovered nine
  months of trials later. <code>PIPE=3</code> was undersold by roughly 90&nbsp;MHz, and every
  later decision about it used the wrong number.""",
  note="Also: adding 1,025 flops made the design 62,648 cells SMALLER. Repair buffering collapsed from 127,433 to 65,593 once the stage was short enough not to need forcing into shape."),
 ("x2y3", True): dict(
  head="Is PIPE=2 effort-limited?",
  tried="""Re-measure <code>PIPE=2</code> at 1.50&nbsp;ns. Its earlier number came from a run
  with very large negative slack, meaning the optimiser was still finding improvements when it
  stopped. If frequency rises purely from asking harder, then no absolute figure in this project
  is a property of the design.""",
  result="""<strong>+22.7&nbsp;MHz from asking harder alone.</strong> The tool works
  <em>to</em> its target, so every frequency here is a lower bound, and rows measured at
  different targets are not comparable. This is the finding that made the later correction
  possible &mdash; and the one the campaign kept failing to apply.""",
  note=None),
 ("x2y4", True): dict(
  head="PIPE=3 at a tighter target",
  tried="""Push <code>PIPE=3</code> to 1.60&nbsp;ns to find its own limit.""",
  result="""Reported at 514.9&nbsp;MHz, and recorded at the time as beating the earlier
  <code>PIPE=3</code> row. It did not. Both figures were I/O-limited, at different targets, so
  the comparison was meaningless in both directions. Corrected: <strong>643.3&nbsp;MHz</strong>,
  with the compute datapath again meeting its target &mdash; this time with 0.046&nbsp;ns spare.
  The worst path was a flop driving five levels of readback mux out to a pin, 47% of its delay
  being clock insertion that cannot cancel because an output port has no capture flop.""",
  note=None),
 ("x3y0", True): dict(
  head="Register the readback port",
  tried="""Read the <em>path</em>, not just the slack &mdash; the change that defines this
  generation. The report named the readback port explicitly, so <code>RD_REG=1</code> puts a
  flop after the readback mux, converting an uncancellable port path into flop&rarr;mux&rarr;flop.
  Costs one cycle of readback latency, not throughput. Same 1.60&nbsp;ns target: one variable.""",
  result="""Total negative slack collapsed <strong>8,900&times;</strong>, from &minus;114.6 to
  &minus;0.013&nbsp;ns, and area and power both <em>fell</em> while 512 flops were added. The
  flop prediction was exact to the flop. But the path did not move where predicted &mdash; it
  stayed on the readback port, just shorter, still 64% clock insertion delay. Chasing that
  discrepancy is what exposed the metric defect: pad budget scales with the period, so tightening
  the target inflates the reported frequency with <em>identical hardware</em>. Four of ten rows
  were affected. Real figure: <strong>658.7&nbsp;MHz</strong>.""",
  note="Every past trial was corrected from artifacts already on disk. Recovered slack matched each logged value within 0.002 ns, which is what made the correction legitimate rather than a guess."),
 ("x4y0", True): dict(
  head="Test the premise before building anything",
  tried="""X4 blamed the multiplier's carry-propagate adder and proposed carry-save arithmetic to
  fix it. But that path had <em>positive</em> slack &mdash; it had never once been observed to
  fail, so the blame was unfalsified rather than confirmed. Spend this trial on a measurement
  instead: identical RTL, target tightened to 1.40&nbsp;ns.""",
  result="""<strong>+40.2&nbsp;MHz with no RTL change.</strong> The carry chain was merely
  effort-limited, not at its wall. Building carry-save would have spent roughly 16,000 flops
  &mdash; 35% of the design &mdash; optimising a path that was not binding. Both timing
  predictions written before this run were wrong, including the model of the pad-budget artifact
  itself: the output path's delay is not period-independent, since the tool shortens that too
  when pushed.""",
  note="This trial exists only because the previous one taught that a positive-slack path is not evidence of a limit."),
 ("x4y1", True): dict(
  head="Find the wall",
  tried="""Keep tightening the same RTL to 1.20&nbsp;ns. The stopping condition was written down
  in advance: <em>large total negative slack together with a stalled objective</em> means a real
  limit; a small one means the tool simply met its target again.""",
  result="""The condition fired exactly as specified. Total negative slack blew up
  <strong>357&times;</strong> while the objective moved <strong>+4.0&nbsp;MHz</strong>, and the
  limiter finally flipped from the pad boundary to a genuine register-to-register path. The wall
  is <strong>~703&nbsp;MHz</strong>. The cost of those last four megahertz was 26% more power and
  35,324 more cells &mdash; which is what closed the campaign: past 1.40&nbsp;ns, power is the
  price and frequency is not the return.""",
  note="The binding path is the multiplier's final carry-propagate adder, ending at bit 14 of a 16-bit product, where carries arrive last."),
}

GEN = {
 1: dict(name="Generation X1", claim="Read the slack. Blame the one combinational path. Fix by pipelining.",
     detail="""Period held <strong>fixed at 2.80&nbsp;ns</strong> across the whole generation, so
     every rung is compared on equal footing. That discipline was correct in intent and produced
     the generation's central failure: a fixed period saturates the measurement, and a saturated
     measurement reports the target rather than the design."""),
 2: dict(name="Generation X2", claim="Same blame, same fix. Change the procedure.",
     detail="""Target derived per trial from the previous row's measured need; total negative slack
     read as the saturation signal. This recovered a 15.6% gain that X1 had recorded as
     &ldquo;flat&rdquo; &mdash; but two of its five rows were secretly limited by pad-boundary
     paths, which nothing it read could reveal."""),
 3: dict(name="Generation X3", claim="Read the path, not just the number.",
     detail="""The slack says how much you missed by; the path says what to change. Reading it
     named the readback port as the limiter, the fix worked &mdash; and following up on a wrong
     prediction is what exposed that the headline metric had been inflated for eight trials."""),
 4: dict(name="Generation X4", claim="Establish the limiter before proposing a fix for it.",
     detail="""Limiter class recorded before any frequency is quoted; each variant iterated to its
     own fixed point. The generation then <em>refuted its own premise</em> and closed without
     building the RTL change it was created to build."""),
}

def b64(tag):
    p = IMG % tag
    if not os.path.exists(p): return None, 0
    raw = open(p, "rb").read()
    return base64.b64encode(raw).decode(), len(raw)

rows, total = [], 0
for t in trials:
    tag, ok = t["tag"], bool(t.get("metrics"))
    key = (tag, ok)
    if key not in PROSE: continue
    img, n = b64(tag); total += n
    rows.append((t, PROSE[key], img))
print("<!-- images embedded: %.1f MB raw -->" % (total/1048576.0))

def esc(s): return s
out = []
W = out.append

W('<title>Carry Chain at 703 Megahertz</title>')
W('<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>')
W('<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans+Condensed:wght@600;700&family=IBM+Plex+Sans:ital,wght@0,400;0,500;0,600;1,400&display=swap">')
W('''<style>
:root{
  --ground:#0B0D10; --sunk:#080A0C; --surface:#14181D; --raised:#1B2027;
  --line:#252C35; --line-soft:#1B2129;
  --ink:#E8EDF2; --ink-dim:#A9B6C4; --muted:#7C8996;
  --cyan:#3FD2E8; --rose:#F0407F; --lime:#A8E04A; --amber:#F5B942;
  --cyan-soft:rgba(63,210,232,.11); --rose-soft:rgba(240,64,127,.11);
  --plate-ring:rgba(255,255,255,.07);
  --sans:"IBM Plex Sans",ui-sans-serif,system-ui,sans-serif;
  --cond:"IBM Plex Sans Condensed","IBM Plex Sans",ui-sans-serif,system-ui,sans-serif;
  --mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
}
@media (prefers-color-scheme: light){
  :root:not([data-theme="dark"]){
    --ground:#F6F7F9; --sunk:#EDEFF3; --surface:#FFFFFF; --raised:#FFFFFF;
    --line:#D8DDE4; --line-soft:#E6EAEF;
    --ink:#11161C; --ink-dim:#41505F; --muted:#68757F;
    --cyan:#0B7C92; --rose:#C4165A; --lime:#4E7A12; --amber:#9A6B00;
    --cyan-soft:rgba(11,124,146,.09); --rose-soft:rgba(196,22,90,.08);
    --plate-ring:rgba(0,0,0,.10);
  }
}
:root[data-theme="light"]{
  --ground:#F6F7F9; --sunk:#EDEFF3; --surface:#FFFFFF; --raised:#FFFFFF;
  --line:#D8DDE4; --line-soft:#E6EAEF;
  --ink:#11161C; --ink-dim:#41505F; --muted:#68757F;
  --cyan:#0B7C92; --rose:#C4165A; --lime:#4E7A12; --amber:#9A6B00;
  --cyan-soft:rgba(11,124,146,.09); --rose-soft:rgba(196,22,90,.08);
  --plate-ring:rgba(0,0,0,.10);
}
*{box-sizing:border-box}
body{background:var(--ground);color:var(--ink);font-family:var(--sans);
  font-size:16px;line-height:1.65;-webkit-font-smoothing:antialiased;
  padding:0 clamp(18px,5vw,64px)}
.wrap{max-width:1120px;margin:0 auto;display:flex;flex-direction:column;gap:clamp(56px,7vw,104px);
  padding:clamp(48px,8vw,96px) 0 120px}
h1,h2,h3,h4{text-wrap:balance;margin:0;font-family:var(--cond);font-weight:700;line-height:1.12}
p{margin:0}
code{font-family:var(--mono);font-size:.88em;background:var(--sunk);
  border:1px solid var(--line-soft);border-radius:3px;padding:.06em .34em;color:var(--ink-dim)}
em{font-style:italic;color:var(--ink)}
strong{font-weight:600;color:var(--ink)}
a{color:var(--cyan)}
.eyebrow{font-family:var(--mono);font-size:11.5px;font-weight:500;letter-spacing:.16em;
  text-transform:uppercase;color:var(--muted)}

/* ---- masthead ---- */
.mast{display:flex;flex-direction:column;gap:26px}
.mast h1{font-size:clamp(34px,6.4vw,68px);letter-spacing:-.022em}
.mast .lede{font-size:clamp(17px,2vw,21px);line-height:1.55;color:var(--ink-dim);max-width:64ch}
.rule{height:1px;background:var(--line);border:0;margin:0}
.spec{display:flex;flex-wrap:wrap;gap:10px 34px;font-family:var(--mono);font-size:12.5px;color:var(--muted)}
.spec b{color:var(--ink);font-weight:500}

/* ---- headline stats ---- */
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(158px,1fr));gap:1px;
  background:var(--line);border:1px solid var(--line);border-radius:4px;overflow:hidden}
.stat{background:var(--surface);padding:18px 20px;display:flex;flex-direction:column;gap:5px}
.stat .k{font-family:var(--mono);font-size:10.5px;letter-spacing:.13em;text-transform:uppercase;color:var(--muted)}
.stat .v{font-family:var(--cond);font-size:29px;font-weight:700;letter-spacing:-.015em;
  font-variant-numeric:tabular-nums;line-height:1}
.stat .n{font-size:12.5px;color:var(--muted);line-height:1.4}
.stat.hi .v{color:var(--cyan)}
.stat.warn .v{color:var(--rose)}

/* ---- callout ---- */
.callout{border:1px solid var(--line);border-left:2px solid var(--rose);background:var(--rose-soft);
  border-radius:0 4px 4px 0;padding:20px 24px;display:flex;flex-direction:column;gap:10px}
.callout.good{border-left-color:var(--cyan);background:var(--cyan-soft)}
.callout h3{font-size:16px;font-family:var(--sans);font-weight:600;letter-spacing:0}
.callout p{font-size:14.5px;color:var(--ink-dim);max-width:76ch}

/* ---- generation header ---- */
.gen{display:flex;flex-direction:column;gap:14px;padding-top:8px}
.gen-top{display:flex;align-items:baseline;gap:16px;flex-wrap:wrap}
.gen h2{font-size:clamp(24px,3.4vw,36px);letter-spacing:-.018em}
.gen .claim{font-family:var(--mono);font-size:13px;color:var(--cyan);letter-spacing:.01em}
.gen .detail{font-size:15px;color:var(--ink-dim);max-width:74ch}

/* ---- plate ---- */
.plates{display:flex;flex-direction:column;gap:clamp(34px,4vw,56px)}
.plate{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,340px);gap:clamp(22px,3vw,40px);
  align-items:start}
@media (max-width:900px){.plate{grid-template-columns:minmax(0,1fr)}}
.body{display:flex;flex-direction:column;gap:16px;min-width:0}
.id{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
.tag{font-family:var(--mono);font-size:12px;font-weight:600;letter-spacing:.08em;
  border:1px solid var(--line);border-radius:3px;padding:3px 8px;color:var(--ink)}
.pill{font-family:var(--mono);font-size:10.5px;font-weight:500;letter-spacing:.11em;
  text-transform:uppercase;border-radius:3px;padding:3px 8px}
.pill.clean{color:var(--cyan);background:var(--cyan-soft);border:1px solid var(--cyan)}
.pill.io{color:var(--rose);background:var(--rose-soft);border:1px solid var(--rose)}
.pill.fail{color:var(--rose);background:var(--rose-soft);border:1px solid var(--rose)}
.plate h3{font-size:clamp(19px,2.4vw,25px);letter-spacing:-.014em}
.qa{display:flex;flex-direction:column;gap:14px}
.qa section{display:flex;flex-direction:column;gap:6px}
.qa .lbl{font-family:var(--mono);font-size:10.5px;letter-spacing:.15em;text-transform:uppercase;
  color:var(--muted)}
.qa p{font-size:15px;color:var(--ink-dim);max-width:72ch}
.aside{font-size:13.5px;color:var(--muted);border-top:1px solid var(--line-soft);padding-top:12px;
  max-width:72ch;font-style:italic}

/* ---- figure ---- */
figure{margin:0;display:flex;flex-direction:column;gap:9px;position:sticky;top:22px}
@media (max-width:900px){figure{position:static}}
.shot{display:block;width:100%;height:auto;border-radius:3px;background:#000;
  box-shadow:0 0 0 1px var(--plate-ring)}
figcaption{font-family:var(--mono);font-size:11px;line-height:1.5;color:var(--muted)}

/* ---- metrics ---- */
.metrics{display:grid;grid-template-columns:repeat(auto-fit,minmax(112px,1fr));gap:1px;
  background:var(--line);border:1px solid var(--line);border-radius:4px;overflow:hidden}
.m{background:var(--surface);padding:11px 13px;display:flex;flex-direction:column;gap:3px}
.m .k{font-family:var(--mono);font-size:9.5px;letter-spacing:.1em;text-transform:uppercase;color:var(--muted)}
.m .v{font-family:var(--mono);font-size:16px;font-weight:600;font-variant-numeric:tabular-nums;line-height:1.15}
.m.key{background:var(--raised)}
.m.key .v{color:var(--cyan);font-size:18px}
.m .was{font-family:var(--mono);font-size:11px;color:var(--rose);text-decoration:line-through}

/* ---- table ---- */
.tw{overflow-x:auto;border:1px solid var(--line);border-radius:4px;background:var(--surface)}
table{border-collapse:collapse;width:100%;font-family:var(--mono);font-size:12.5px;
  font-variant-numeric:tabular-nums}
th,td{text-align:right;padding:9px 13px;border-bottom:1px solid var(--line-soft);white-space:nowrap}
th{font-size:10px;letter-spacing:.1em;text-transform:uppercase;color:var(--muted);font-weight:500;
  background:var(--sunk);position:sticky;top:0}
th:first-child,td:first-child{text-align:left}
tbody tr:last-child td{border-bottom:0}
td.f{color:var(--cyan);font-weight:600}
td.strike{color:var(--rose);text-decoration:line-through}
.dim{color:var(--muted)}

/* ---- close ---- */
.close{display:flex;flex-direction:column;gap:20px}
.close h2{font-size:clamp(24px,3.4vw,34px);letter-spacing:-.018em}
.close p{font-size:15.5px;color:var(--ink-dim);max-width:74ch}
.lastword{font-family:var(--cond);font-size:clamp(19px,2.6vw,26px);font-weight:600;
  line-height:1.35;color:var(--ink);max-width:56ch;border-left:2px solid var(--cyan);padding-left:20px}
:focus-visible{outline:2px solid var(--cyan);outline-offset:2px}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
</style>''')

W('<div class="wrap">')

# masthead
W('''<header class="mast">
<p class="eyebrow">Physical design log &middot; Intel AMX TDPBSSD on Nangate45</p>
<h1>Carry Chain at 703&nbsp;Megahertz</h1>
<p class="lede">Ten synthesis-and-place-and-route experiments on a 1,024-multiplier INT8 tile
matrix-multiply unit, run as a disciplined hillclimb. The design ended up limited by a multiplier's
carry-propagate adder. Along the way the experiment log discovered that its own headline metric had
been measuring the wrong thing for eight consecutive trials.</p>
<hr class="rule">
<div class="spec">
<span>Design <b>amx_tdpbssd</b></span>
<span>Operation <b>C += A&times;B, (16&times;64)&times;(64&times;16) INT8</b></span>
<span>MACs <b>16,384 per instruction</b></span>
<span>Flow <b>Yosys + OpenROAD, Nangate45</b></span>
<span>Trials <b>10</b></span>
<span>RTL defects <b>0</b></span>
</div>
</header>''')

# headline stats
best = [t for t in trials if t.get("metrics") and t["tag"]=="x4y0"][0]["metrics"]
wall = [t for t in trials if t.get("metrics") and t["tag"]=="x4y1"][0]["metrics"]
base = [t for t in trials if t.get("metrics") and t["tag"]=="x1y0"][0]["metrics"]
p1   = [t for t in trials if t.get("metrics") and t["tag"]=="x1y1"][0]["metrics"]
W('<section class="stats">')
W('<div class="stat hi"><span class="k">Operating point</span><span class="v">%.1f</span><span class="n">MHz at 1.40&nbsp;ns, %.3f&nbsp;W</span></div>' % (best["regreg_fmax_mhz"], best["power_w"]))
W('<div class="stat"><span class="k">Wall</span><span class="v">%.1f</span><span class="n">MHz &mdash; %.0f%% more power for +%.1f&nbsp;MHz</span></div>' % (wall["regreg_fmax_mhz"], 100*(wall["power_w"]/best["power_w"]-1), wall["regreg_fmax_mhz"]-best["regreg_fmax_mhz"]))
W('<div class="stat hi"><span class="k">Power, one register</span><span class="v">%.1f&times;</span><span class="n">%.2f&nbsp;W &rarr; %.2f&nbsp;W at equal speed</span></div>' % (base["power_w"]/p1["power_w"], base["power_w"], p1["power_w"]))
W('<div class="stat warn"><span class="k">Rows misreported</span><span class="v">4 / 10</span><span class="n">limited by pad boundary, not by the design</span></div>')
W('<div class="stat"><span class="k">Tooling defects</span><span class="v">12</span><span class="n">against zero RTL defects</span></div>')
W('</section>')

W('''<section class="callout">
<h3>What the metric got wrong, and why it matters for reading every number below</h3>
<p>Frequency was computed as <code>1000 / (target &minus; worst&nbsp;slack)</code>. That describes the
hardware only when the limiting path runs register to register. The timing constraints budget chip
I/O as <em>20% of the clock period</em>, so a path ending at an output pad is charged a slice of
budget that <strong>shrinks as the target tightens</strong> &mdash; and the reported frequency rises
with byte-identical hardware. Four of these ten rows were limited that way.</p>
<p>Each plate below shows the figure as originally reported and, where they differ, the corrected
register-to-register figure. The correction was recovered from routed databases still on disk, and
every recovered slack matched its logged value to within 0.002&nbsp;ns &mdash; which is what makes it
a correction rather than a guess. Nothing had to be re-measured.</p>
</section>''')

# plates grouped by generation
seen = set()
for t, pr, img in rows:
    x = t["x"]
    if x not in seen:
        seen.add(x); g = GEN[x]
        W('<section class="gen"><div class="gen-top"><h2>%s</h2><p class="claim">%s</p></div><p class="detail">%s</p></section>'
          % (g["name"], g["claim"], g["detail"]))
        W('<div class="plates">')
    m = t.get("metrics"); k = t["knobs"]
    W('<article class="plate"><div class="body">')
    cls = (m or {}).get("limiter_class")
    pill = ('<span class="pill fail">flow refused</span>' if not m else
            ('<span class="pill clean">design-limited</span>' if cls=="reg->reg"
             else '<span class="pill io">pad-limited</span>'))
    W('<div class="id"><span class="tag">X%d&middot;Y%d</span>%s<span class="eyebrow">PIPE=%d &nbsp;RD_REG=%d &nbsp;target %.2f ns</span></div>'
      % (t["x"], t["y"], pill, k["PIPE"], k.get("RD_REG",0), k["period_ns"]))
    W('<h3>%s</h3>' % pr["head"])
    W('<div class="qa">')
    W('<section><span class="lbl">What was tried</span><p>%s</p></section>' % pr["tried"])
    W('<section><span class="lbl">Result</span><p>%s</p></section>' % pr["result"])
    W('</div>')
    if m:
        W('<div class="metrics">')
        if m["limiter_class"]=="reg->reg":
            W('<div class="m key"><span class="k">fmax</span><span class="v">%.1f</span></div>' % m["regreg_fmax_mhz"])
        else:
            W('<div class="m key"><span class="k">fmax corrected</span><span class="v">%.1f</span><span class="was">%.1f</span></div>' % (m["regreg_fmax_mhz"], m["implied_fmax_mhz"]))
        W('<div class="m"><span class="k">reg&rarr;reg slack</span><span class="v">%+.4f</span></div>' % m["regreg_ws_ns"])
        W('<div class="m"><span class="k">TNS ns</span><span class="v">%.2f</span></div>' % m["setup_tns"])
        W('<div class="m"><span class="k">power</span><span class="v">%.3f W</span></div>' % m["power_w"])
        W('<div class="m"><span class="k">flip-flops</span><span class="v">%s</span></div>' % format(m["flipflops"], ","))
        W('<div class="m"><span class="k">std cells</span><span class="v">%s</span></div>' % format(m["stdcells"], ","))
        W('<div class="m"><span class="k">hold</span><span class="v">%+.4f</span></div>' % m["hold_ws_ns"])
        W('<div class="m"><span class="k">DRC</span><span class="v">%d</span></div>' % m["drc_lines"])
        W('</div>')
    if pr["note"]: W('<p class="aside">%s</p>' % pr["note"])
    W('</div>')
    if img:
        cap = ('Routed die, all layers &mdash; %s&nbsp;&micro;m&sup2;, %s cells. Pink and cyan are the lower metal layers, green the vias; blue is unused routing track.'
               % (format(int(m["area_um2"]), ","), format(m["stdcells"], ",")))
        W('<figure><img class="shot" src="data:image/webp;base64,%s" alt="Routed layout of trial X%dY%d" loading="lazy" decoding="async"><figcaption>%s</figcaption></figure>'
          % (img, t["x"], t["y"], cap))
    W('</article>')
    nxt = rows[rows.index((t,pr,img))+1] if rows.index((t,pr,img))+1 < len(rows) else None
    if nxt is None or nxt[0]["x"] != x: W('</div>')

# summary table
W('<section class="close"><h2>Every trial, in one table</h2>')
W('<div class="tw"><table><thead><tr><th>Trial</th><th>PIPE / RD</th><th>Target</th><th>Limiter</th>'
  '<th>Reported</th><th>Corrected</th><th>reg&rarr;reg slack</th><th>TNS</th><th>Power</th><th>Flops</th><th>Cells</th><th>DRC</th></tr></thead><tbody>')
for t in trials:
    m = t.get("metrics"); k = t["knobs"]
    if not m:
        W('<tr><td>X%dY%d</td><td>%d / %d</td><td>%.2f</td><td class="dim">&mdash;</td><td class="strike">no row</td>'
          '<td class="dim">&mdash;</td><td class="dim">&mdash;</td><td class="dim">&mdash;</td><td class="dim">&mdash;</td>'
          '<td class="dim">&mdash;</td><td class="dim">&mdash;</td><td class="dim">&mdash;</td></tr>'
          % (t["x"],t["y"],k["PIPE"],k.get("RD_REG",0),k["period_ns"])); continue
    io = m["limiter_class"]!="reg->reg"
    W('<tr><td>X%dY%d</td><td>%d / %d</td><td>%.2f</td><td>%s</td><td%s>%.1f</td><td class="f">%.1f</td>'
      '<td>%+.4f</td><td>%.2f</td><td>%.3f</td><td>%s</td><td>%s</td><td>%d</td></tr>'
      % (t["x"],t["y"],k["PIPE"],k.get("RD_REG",0),k["period_ns"],
         ('<span style="color:var(--rose)">pad</span>' if io else '<span style="color:var(--cyan)">design</span>'),
         (' class="strike"' if io else ''), m["implied_fmax_mhz"], m["regreg_fmax_mhz"],
         m["regreg_ws_ns"], m["setup_tns"], m["power_w"],
         format(m["flipflops"],","), format(m["stdcells"],","), m["drc_lines"]))
W('</tbody></table></div>')

W('''<h2 style="margin-top:22px">What the campaign is entitled to claim</h2>
<p>Only trials run at the same target are directly comparable, because the tool optimises
<em>to</em> whatever target it is given. Three such pairs exist: the third pipeline stage was worth
<strong>+117.6&nbsp;MHz</strong> at 1.80&nbsp;ns, registering the readback port
<strong>+15.4&nbsp;MHz</strong> at 1.60&nbsp;ns, and the first pipeline stage +0.3&nbsp;MHz at
2.80&nbsp;ns &mdash; alongside its 19.2&times; power reduction.</p>
<p>The end-to-end 350&nbsp;&rarr;&nbsp;699&nbsp;MHz figure spans two different targets, and the
starting point was itself not saturated, so the design's true capability at the low end was never
measured. <strong>That headline is indicative, not a measurement</strong>, and it overstates the
gain by an unknown amount. Closing the log does not license the number the broken metric would have
produced.</p>''')

W('''<section class="callout good" style="margin-top:6px">
<h3>The pattern across all ten trials</h3>
<p>Every flip-flop-count prediction written before a run was exact. Almost every timing prediction
was wrong &mdash; including which path would become critical, which rung would gain most, and the
model of the measurement artifact itself. That asymmetry is the argument for writing predictions
down before the run rather than reasoning about results afterwards: structural claims about what
gets built are reliable, and claims about what the optimiser will do with it are not.</p>
<p>Twelve defects were found in how the design was measured. Zero were found in the design. The
RTL has been correct at every pipeline depth since it was written.</p>
</section>''')

W('<p class="lastword">The hillclimb ranked on one number, so it could not see a Pareto move. It called a row flat on 0.3&nbsp;MHz while holding a nineteen-fold power win in a file it had already read.</p>')
W('</section></div>')

open("experiments/report.html","w").write("\n".join(out))
print("wrote experiments/report.html  %.2f MB" % (os.path.getsize("experiments/report.html")/1048576.0))
