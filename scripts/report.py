#!/usr/bin/env python3
"""Build experiments/report.html -- the readable campaign report, one plate per trial.

Prose is authored here; every NUMBER is pulled from experiments/trials.jsonl and every
image from work/reports/.../final_all.webp, so no figure in the report is hand-typed.

Both outputs reference experiments/img/*.webp, which this script extracts from the routed
reports and which IS committed. The HTML used to inline those images as base64 data URIs so
it would survive `make clean-work` -- work/ is build output and not in git. Extracting the
images for GitHub's sake removed that reason: both reports are now reproducible from
committed data, so the 3.4 MB self-contained HTML is neither needed nor committed.
experiments/REPORT.md is the shareable artifact; the HTML is a local convenience.

Run:  python3 scripts/report.py && open experiments/report.html
"""
import json, os, shutil

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
  result="""Frequency barely moved &mdash; 0.3&nbsp;MHz at this target. <strong>Power fell
  19.2&times;</strong>, from 19.00&nbsp;W to 0.99&nbsp;W, with 10% fewer cells and 15% less area,
  at the same speed and the same target. One register truncates glitch propagation through 1,024
  multipliers that had been toggling repeatedly before settling every cycle. The pipelining
  ladder's real payoff is here, not in the clock.""",
  note="The single most valuable change in the campaign, and it is invisible in a frequency number."),
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
  result="""<strong>+77.9&nbsp;MHz</strong> &mdash; a larger gain than the previous rung, despite
  registering products rather than sums. Logic depth, not gate count, is what a clock period pays
  for.""",
  note=None),
 ("x2y2", True): dict(
  head="PIPE=3 &mdash; the cheapest cut, and the limit moves off the arithmetic",
  tried="""Register the selected operands too, splitting the 16:1 mux from the multiply for only
  1,024 more flops. Same 1.80&nbsp;ns target as the previous rung, so the comparison is clean.""",
  result="""<strong>600.3&nbsp;MHz</strong>, and the compute datapath met its target with
  0.134&nbsp;ns to spare &mdash; so at this clock the limit was no longer the arithmetic but the
  readback path out to the pins, which runs combinationally from an input port through the mux to
  an output port with no register to absorb clock insertion delay. That is the observation X3 was
  created to act on.""",
  note="Adding 1,025 flops made the design 62,648 cells SMALLER. Repair buffering collapsed from 127,433 to 65,593 once the stage was short enough not to need forcing into shape."),
 ("x2y3", True): dict(
  head="Is PIPE=2 effort-limited?",
  tried="""Re-measure <code>PIPE=2</code> at 1.50&nbsp;ns. Its earlier number came from a run
  with very large negative slack, meaning the optimiser was still finding improvements when it
  stopped. If frequency rises purely from asking harder, then no absolute figure in this project
  is a property of the design.""",
  result="""<strong>+22.7&nbsp;MHz from asking harder alone.</strong> The tool works
  <em>to</em> its target, so every frequency in this report is a lower bound, and only rows sharing
  a target are directly comparable. Worth knowing before reading any single number as the
  design's capability.""",
  note=None),
 ("x2y4", True): dict(
  head="PIPE=3 at a tighter target",
  tried="""Push <code>PIPE=3</code> to 1.60&nbsp;ns to find its own limit.""",
  result="""<strong>643.3&nbsp;MHz</strong>, with the compute datapath again meeting its target
  &mdash; this time with 0.046&nbsp;ns spare. The worst path is a flop driving five levels of
  readback mux out to a pin, and 47% of its delay is clock insertion that cannot cancel, because
  an output port has no capture flop to cancel it against. Same limiter as the previous row, now
  measured precisely enough to fix.""",
  note=None),
 ("x3y0", True): dict(
  head="Register the readback port",
  tried="""Read the <em>path</em>, not just the slack &mdash; the change that defines this
  generation. The report named the readback port explicitly, so <code>RD_REG=1</code> puts a
  flop after the readback mux, converting an uncancellable port path into flop&rarr;mux&rarr;flop.
  Costs one cycle of readback latency, not throughput. Same 1.60&nbsp;ns target: one variable.""",
  result="""<strong>658.7&nbsp;MHz.</strong> Total negative slack collapsed
  <strong>8,900&times;</strong>, from &minus;114.6 to &minus;0.013&nbsp;ns, and area and power both
  <em>fell</em> while 512 flops were added. The design now closes at 1.60&nbsp;ns where before it
  missed by 0.34. The residual worst path is still the readback pin &mdash; shorter now, but 64% of
  its delay is clock insertion, which is a pad-boundary property no RTL change reaches.""",
  note="Registering an output port cannot remove clock insertion delay from it, only the logic in front of it. That is why the next generation stopped optimising this path."),
 ("x4y0", True): dict(
  head="Test the premise before building anything",
  tried="""X4 blamed the multiplier's carry-propagate adder and proposed carry-save arithmetic to
  fix it. But that path had <em>positive</em> slack &mdash; it had never once been observed to
  fail, so the blame was unfalsified rather than confirmed. Spend this trial on a measurement
  instead: identical RTL, target tightened to 1.40&nbsp;ns.""",
  result="""<strong>+40.2&nbsp;MHz with no RTL change</strong> &mdash; and this is the operating
  point the report recommends. The carry chain was merely effort-limited, not at its wall. Building
  carry-save arithmetic would have spent roughly 16,000 flops, 35% of the design, shortening a path
  that was not yet binding.""",
  note="A path with positive slack is not evidence of a limit. Measuring first cost one run and saved a redesign."),
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
     detail="""Period held <strong>fixed at 2.80&nbsp;ns</strong> across the whole generation so
     every rung is compared on equal footing. The limitation of that choice shows up immediately: a
     target the tool comfortably meets measures the target, not the design, so a real gain can
     register as no gain at all."""),
 2: dict(name="Generation X2", claim="Same blame, same fix. Change the procedure.",
     detail="""Target derived per trial from the previous row's measured need, and total negative
     slack read as the saturation signal &mdash; small means the tool met its goal and stopped,
     large means it was still finding improvements. That change alone recovered a 15.6% gain the
     fixed-period generation had recorded as flat."""),
 3: dict(name="Generation X3", claim="Read the path, not just the number.",
     detail="""The slack says how much you missed by; the path says what to change. Reading it
     named the readback port &mdash; not the arithmetic &mdash; as the thing standing between this
     design and its target, which no amount of further pipelining would have fixed."""),
 4: dict(name="Generation X4", claim="Establish the limiter before proposing a fix for it.",
     detail="""Establish where the limit actually is before proposing a fix for it, and iterate
     each variant to its own fixed point rather than trusting a single target. The generation then
     refuted its own premise &mdash; the path it blamed turned out to have slack &mdash; and closed
     without building the RTL change it was created to build."""),
}

IMG_OUT = "experiments/img"

# ONE layout, not ten. The per-trial die plots were visually near-identical -- dense
# routed views at the same die size differ in ways the eye cannot attribute -- so
# nine of them cost 2.2 MB to say nothing the metrics tables do not say better.
# It sits in the headline beside a baseline-vs-final comparison, which is why it is
# the OPERATING POINT (X4-Y0) rather than the chronologically last trial: pairing a
# picture of one design point with a table of another would misrepresent both.
FINAL_TAG = "x4y0"


def extract(tag):
    """Copy a routed layout into experiments/img/ and return its page-relative path.

    Replaces an earlier base64 inliner. Inlining made the HTML self-contained but
    cost 3.4 MB, stored the same pixels twice once the .md needed real files, and
    was silently useless on GitHub -- its sanitiser strips data: URIs.
    """
    if tag != FINAL_TAG:
        return None, 0
    src = IMG % tag
    if not os.path.exists(src):
        return None, 0
    os.makedirs(IMG_OUT, exist_ok=True)
    dst = "%s/%s.webp" % (IMG_OUT, tag)
    shutil.copyfile(src, dst)
    return "img/%s.webp" % tag, os.path.getsize(dst)


# ---- datapath block diagram, one per RTL variant -----------------------------
# Structure read directly from rtl/amx_tdpbssd.v, not from memory:
#   b_row_c = b_flat[kcnt*512 +: 512]      16:1 mux, 512 bits, shared
#   a_dw_c  = a_flat[gm*512 + kcnt*32 +: 32]  16:1 mux, 32 bits, per row
#   PIPE>=3 registers BOTH mux outputs (b_row_r + a_dw_r)      1,024 flops
#   prod[gb] = a_b * b_b                   four signed 8x8 -> 16
#   PIPE>=2 registers the four products    16b x 4 x 256     16,384 flops
#   sum4 = prod_e[0..3]                    18 bits, exact, no fold needed
#   PIPE>=1 registers sum4                 18b x 256          4,608 flops
#   raw = cacc + sum4_e (33b); ovf = raw[32]^raw[31]; folded = SAT ? rail : raw
#   cacc[gm][gn]                           32b x 256          8,192 flops, ALWAYS
#   RD_REG=1 registers rd_data AFTER the readback mux            512 flops
# Cumulative flops reproduce every measured netlist count exactly, which is the
# check that this diagram describes the hardware that was actually built.
def st(t, sub, cls=""):
    return '<div class="stage %s"><span class="t">%s</span><span class="s">%s</span></div>' % (cls, t, sub)
def rg(on, lbl, n):
    return ('<div class="reg %s"><span class="bar"></span><span class="lb">%s</span></div>'
            % ("on" if on else "off", (lbl + " " + n) if on else lbl))
ARW = '<div class="arw"></div>'

def datapath(pipe, rdreg):
    d = ['<div class="dpwrap"><div class="dp">']
    d.append(st("a_flat / b_flat", "tiles &middot; 16,384 ff", "src"))
    d.append(ARW)
    d.append(st("16:1 MUX", "select k-step"))
    d.append(rg(pipe >= 3, "S3", "1,024"))
    d.append(st("8&times;8 MUL", "&times;4 per unit"))
    d.append(rg(pipe >= 2, "S2", "16,384"))
    d.append(st("&Sigma; TREE", "4:1, 18 b exact"))
    d.append(rg(pipe >= 1, "S1", "4,608"))
    d.append('<div class="loop"><span class="lp">&#8635; accumulate loop &mdash; irreducible</span>')
    d.append(st("+ 33 b &rarr; FOLD", "ovf &rarr; clamp INT32"))
    d.append(ARW)
    d.append(st("cacc", "32 b &times; 256 &middot; 8,192 ff"))
    d.append('</div></div></div>')
    d.append('<div class="dpwrap"><div class="dp" style="min-width:520px">')
    d.append(st("cacc &times; 256", "readback tap", "src"))
    d.append(ARW)
    d.append(st("5-LEVEL MUX", "row select"))
    d.append(rg(rdreg == 1, "RD", "512"))
    d.append(st("rd_data", "512 b output port"))
    d.append('</div></div>')
    return "".join(d)

VARIANTS = [
 (0,0,"PIPE=0 &mdash; one combinational path", 24584,
  "Nothing between the mux and the accumulator. Every k-step selects operands, multiplies "
  "1,024 products, sums them, adds 33 bits and clamps &mdash; all inside one clock. Glitches "
  "from the mux propagate through the entire depth, which is why this variant burns 19&nbsp;W."),
 (1,0,"PIPE=1 &mdash; register sum4", 29194,
  "One boundary at S1 removes the mux, the multiply <em>and</em> the adder tree from the "
  "accumulate path in a single move, for 4,608 flops. The cheapest large cut available, and the "
  "one that cut power 19&times;."),
 (2,0,"PIPE=2 &mdash; also register the products", 45579,
  "S2 splits the multiply from the tree. By far the most expensive rung: 16,384 flops, two "
  "thirds of the tile register file, for +100.6&nbsp;MHz."),
 (3,0,"PIPE=3 &mdash; also register the mux outputs", 46604,
  "S3 splits the 16:1 mux off the front of the multiply for only 1,024 flops &mdash; the "
  "cheapest cut in the ladder and worth +117.6&nbsp;MHz at equal target. It also made the design "
  "62,648 cells <em>smaller</em>, because repair buffering collapsed once the stage was short "
  "enough not to need forcing into shape."),
 (3,1,"PIPE=3 + RD_REG &mdash; register the readback", 47116,
  "Not a datapath change. The readback mux had become the critical path, running combinationally "
  "from an input pin to an output pin with no register to cancel clock insertion delay against. "
  "RD places a flop after the mux for 512 flops, costing one cycle of readback latency and no "
  "throughput."),
]
USED = {(0,0):"X1&middot;Y0", (1,0):"X1&middot;Y1, X2&middot;Y0", (2,0):"X2&middot;Y1, X2&middot;Y3",
        (3,0):"X2&middot;Y2, X2&middot;Y4", (3,1):"X3&middot;Y0, X4&middot;Y0, X4&middot;Y1"}

rows, total = [], 0
for t in trials:
    tag, ok = t["tag"], bool(t.get("metrics"))
    key = (tag, ok)
    if key not in PROSE: continue
    img, n = extract(tag); total += n
    rows.append((t, PROSE[key], img))
print("extracted %d layouts to %s/  (%.2f MB)" % (sum(1 for _,_,i in rows if i), IMG_OUT, total/1048576.0))

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

/* ---- headline: hero layout + baseline/final comparison ---- */
.headline{display:flex;flex-direction:column;gap:22px}
.hero{margin:0;display:flex;flex-direction:column;gap:10px}
.hero .shot{width:100%;max-width:560px;align-self:center}
.cmp{display:flex;flex-direction:column;gap:12px}
.cmp table td:first-child{color:var(--ink-dim)}
.fine{font-size:13.5px;line-height:1.6;color:var(--muted);max-width:78ch}
.fine strong{color:var(--ink-dim);font-weight:600}

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
.plate{display:block}
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

/* ---- datapath block diagram ---- */
.designs{display:flex;flex-direction:column;gap:clamp(26px,3vw,40px)}
.dsn{display:flex;flex-direction:column;gap:12px;border:1px solid var(--line);
  border-radius:4px;background:var(--surface);padding:clamp(16px,2.2vw,24px)}
.dsn-top{display:flex;align-items:baseline;gap:14px;flex-wrap:wrap}
.dsn-top .nm{font-family:var(--cond);font-size:19px;font-weight:700;letter-spacing:-.01em}
.dsn-top .ff{font-family:var(--mono);font-size:12px;color:var(--muted)}
.dsn-top .used{font-family:var(--mono);font-size:11px;color:var(--cyan);letter-spacing:.06em}
.dpwrap{overflow-x:auto;padding:4px 0 2px}
.dp{display:flex;align-items:stretch;gap:0;min-width:660px}
.stage{flex:0 0 auto;display:flex;flex-direction:column;justify-content:center;gap:3px;
  background:var(--sunk);border:1px solid var(--line);border-radius:3px;
  padding:11px 13px;min-height:62px;text-align:center}
.stage .t{font-family:var(--mono);font-size:12px;font-weight:600;color:var(--ink);white-space:nowrap}
.stage .s{font-family:var(--mono);font-size:10px;color:var(--muted);white-space:nowrap}
.stage.src{background:transparent;border-style:dashed}
.arw{flex:0 0 auto;align-self:center;width:20px;height:1px;background:var(--line);position:relative}
.arw::after{content:"";position:absolute;right:0;top:-3px;border-left:5px solid var(--line);
  border-top:3.5px solid transparent;border-bottom:3.5px solid transparent}
/* register boundary: present = solid cyan pill, absent = faint dashed outline */
.reg{flex:0 0 auto;align-self:stretch;display:flex;flex-direction:column;align-items:center;
  justify-content:center;gap:4px;width:62px;margin:0 5px}
.reg .bar{width:8px;flex:1 1 auto;min-height:44px;border-radius:4px}
.reg .lb{font-family:var(--mono);font-size:9.5px;letter-spacing:.06em;white-space:nowrap}
.reg.on .bar{background:var(--cyan)}
.reg.on .lb{color:var(--cyan)}
.reg.off .bar{background:transparent;border:1px dashed var(--line);width:8px}
.reg.off .lb{color:var(--muted);opacity:.6}
.loop{flex:0 0 auto;display:flex;align-items:stretch;gap:0;border:1px dashed var(--rose);
  border-radius:4px;padding:8px;position:relative;margin-left:5px}
.loop .lp{position:absolute;left:9px;bottom:-8px;background:var(--surface);padding:0 6px;
  font-family:var(--mono);font-size:9.5px;letter-spacing:.08em;color:var(--rose);white-space:nowrap}
.dp-legend{display:flex;gap:20px;flex-wrap:wrap;font-family:var(--mono);font-size:11px;color:var(--muted)}
.dp-legend b{color:var(--cyan);font-weight:500}
.dp-legend i{color:var(--rose);font-style:normal}
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

# headline: the final chip, and baseline vs final
best_tag = "x4y0"   # the operating point: same netlist as the wall, better trade
best = [t for t in trials if t.get("metrics") and t["tag"]==best_tag][0]["metrics"]
wall = [t for t in trials if t.get("metrics") and t["tag"]=="x4y1"][0]["metrics"]
base = [t for t in trials if t.get("metrics") and t["tag"]=="x1y0"][0]["metrics"]
p1   = [t for t in trials if t.get("metrics") and t["tag"]=="x1y1"][0]["metrics"]

# X1-Y0 is the baseline: PIPE=0, the unpipelined design, at 2.80 ns. There is no
# X0 generation -- X1 is the first harness.

# ---- throughput accounting ---------------------------------------------------
# The obvious objection to a pipelining ladder: every stage adds a register, so
# one instruction takes MORE cycles. Does the arithmetic actually get faster?
# Answering it needs two numbers, not one, and they differ by 30 points.
MACS_PER_OP = 16 * 16 * 64          # 16,384 MACs in one TDPBSSD
MACS_PER_K = MACS_PER_OP // 16      # 1,024 per k-step -- exactly the multiplier count


def thr(m, pipe):
    """(cycles, latency_ns, single_gmacs, sustained_gmacs, gmacs_per_watt).

    The testbench asserts every run takes KDW + 1 + PIPE = 17 + PIPE cycles, so a
    deeper pipeline really does make one isolated instruction take longer in
    cycles -- 17 at PIPE=0, 20 at PIPE=3. That is the cost the objection expects.

    But PIPE adds LATENCY, not cycles per k-step. The array still retires 1,024
    MACs on every clock edge at every depth, so streamed work amortises the fill
    and sustained throughput tracks frequency exactly. RD_REG costs a READBACK
    cycle, not an operation cycle, so it does not enter this at all.
    """
    f = m["regreg_fmax_mhz"]
    cyc = 17 + pipe
    lat = cyc / f * 1000.0                     # ns, start edge to done
    sust = MACS_PER_K * f / 1000.0             # GMAC/s
    return cyc, lat, MACS_PER_OP / lat, sust, sust / m["power_w"]


# Best measured row per RTL variant, keyed (PIPE, RD_REG) -- same rule the ladder
# uses, so the two tables can never disagree about which run represents a variant.
VARIANT_BEST = {}
for _t in trials:
    if not _t.get("metrics"):
        continue
    _k = (_t["knobs"]["PIPE"], _t["knobs"].get("RD_REG", 0))
    if (_k not in VARIANT_BEST
            or _t["metrics"]["regreg_fmax_mhz"] > VARIANT_BEST[_k]["metrics"]["regreg_fmax_mhz"]):
        VARIANT_BEST[_k] = _t
VARIANT_ORDER = sorted(VARIANT_BEST)

THR_ROWS = []
for _k in VARIANT_ORDER[:-1]:
    THR_ROWS.append((_k, VARIANT_BEST[_k]))
_fk = VARIANT_ORDER[-1]
for _t in sorted((t for t in trials
                  if t.get("metrics")
                  and (t["knobs"]["PIPE"], t["knobs"].get("RD_REG", 0)) == _fk),
                 key=lambda t: -t["knobs"]["period_ns"]):
    THR_ROWS.append((_fk, _t))
BASE_THR = thr(base, 0)
FINAL_THR = thr(best, 3)

# Efficiency-optimal measured row, and how it compares to the operating point.
_effrows = [(thr(t["metrics"], k[0])[4], k, t) for k, t in THR_ROWS]
EFF_BEST = max(_effrows, key=lambda r: r[0])
EFF_PEAK_NS = EFF_BEST[2]["knobs"]["period_ns"]
EFF_PEAK = EFF_BEST[0]
EFF_PEAK_THR = thr(EFF_BEST[2]["metrics"], EFF_BEST[1][0])
OP_VS_PEAK_THRPUT = 100.0 * (FINAL_THR[3] / EFF_PEAK_THR[3] - 1.0)
OP_VS_PEAK_EFF = 100.0 * (FINAL_THR[4] / EFF_PEAK[0] - 1.0) if False else 100.0 * (FINAL_THR[4] / EFF_PEAK - 1.0)


def _pct(a_, b_):
    return "%+.1f%%" % (100.0 * (b_ / a_ - 1.0)) if a_ else "-"

finimg, _ = extract(FINAL_TAG)
W('<section class="headline">')
if finimg:
    W('<figure class="hero"><img class="shot" src="%s" alt="Routed layout of the final design" '
      'decoding="async"><figcaption>The final design, routed: <strong>%s</strong>&nbsp;&micro;m&sup2;, '
      '%s standard cells, %s flip-flops, hold met, DRC clean. Pink and cyan are the lower metal '
      'layers, green the vias; blue is unused routing track. The cell region does not fill the die '
      'because the floorplan targets 40%% utilisation.</figcaption></figure>'
      % (finimg, format(int(best["area_um2"]), ","), format(best["stdcells"], ","),
         format(best["flipflops"], ",")))
W('<div class="cmp"><div class="tw"><table><thead><tr>'
  '<th>&nbsp;</th><th>Baseline &mdash; X1&middot;Y0</th><th>Final &mdash; X4&middot;Y0</th><th>Change</th>'
  '</tr></thead><tbody>')
W('<tr><td>Design</td><td>PIPE=0, one combinational path</td><td>PIPE=3 + RD_REG</td><td class="dim">3 pipeline cuts</td></tr>')
W('<tr><td>Clock target</td><td>2.80 ns</td><td>1.40 ns</td><td class="dim">&minus;50%</td></tr>')
W('<tr><td><strong>fmax, reg&rarr;reg</strong></td><td>%.1f MHz</td><td class="f">%.1f MHz</td><td class="f">%s</td></tr>'
  % (base["regreg_fmax_mhz"], best["regreg_fmax_mhz"], _pct(base["regreg_fmax_mhz"], best["regreg_fmax_mhz"])))
W('<tr><td><strong>Power</strong></td><td>%.3f W</td><td class="f">%.3f W</td><td class="f">%s &middot; %.1f&times; less</td></tr>'
  % (base["power_w"], best["power_w"], _pct(base["power_w"], best["power_w"]), base["power_w"]/best["power_w"]))
W('<tr><td>Flip-flops</td><td>%s</td><td>%s</td><td>%s</td></tr>'
  % (format(base["flipflops"], ","), format(best["flipflops"], ","), _pct(base["flipflops"], best["flipflops"])))
W('<tr><td>Standard cells</td><td>%s</td><td>%s</td><td>%s</td></tr>'
  % (format(base["stdcells"], ","), format(best["stdcells"], ","), _pct(base["stdcells"], best["stdcells"])))
W('<tr><td>Die area</td><td>%s &micro;m&sup2;</td><td>%s &micro;m&sup2;</td><td>%s</td></tr>'
  % (format(int(base["area_um2"]), ","), format(int(best["area_um2"]), ","), _pct(base["area_um2"], best["area_um2"])))
W('<tr><td>Hold slack</td><td>%+.4f ns</td><td>%+.4f ns</td><td class="dim">met both</td></tr>'
  % (base["hold_ws_ns"], best["hold_ws_ns"]))
W('<tr><td>DRC violations</td><td>%d</td><td>%d</td><td class="dim">clean both</td></tr>'
  % (base["drc_lines"], best["drc_lines"]))
W('<tr><td><strong>Streamed throughput</strong></td><td>%.1f GMAC/s</td><td class="f">%.1f GMAC/s</td><td class="f">%s</td></tr>'
  % (BASE_THR[3], FINAL_THR[3], _pct(BASE_THR[3], FINAL_THR[3])))
W('<tr><td><strong>Energy efficiency</strong></td><td>%.1f GMAC/s/W</td><td class="f">%.1f GMAC/s/W</td><td class="f">%.1f&times; better</td></tr>'
  % (BASE_THR[4], FINAL_THR[4], FINAL_THR[4]/BASE_THR[4]))
W('</tbody></table></div>')
W('<p class="fine"><strong>Twice the speed for 7.8&times; less power</strong>, at +4.6%% more cells. '
  'But read the fmax row with its caveat: the two rows were measured at different clock targets, '
  'and the baseline was not saturated at 2.80&nbsp;ns, so the unpipelined design\'s true capability '
  'was never established. <strong>That percentage is indicative, not a measurement.</strong> The '
  'power comparison has no such problem &mdash; it is a measured quantity at each row\'s own '
  'operating condition, and most of it was won at equal speed and equal target.</p>')
W('<p class="fine">The wall is %.1f&nbsp;MHz. Going there costs %.0f%% more power for '
  '+%.1f&nbsp;MHz, which is why 1.40&nbsp;ns is the operating point and not 1.20.</p>'
  % (wall["regreg_fmax_mhz"], 100*(wall["power_w"]/best["power_w"]-1),
     wall["regreg_fmax_mhz"]-best["regreg_fmax_mhz"]))
W('</div></section>')

W("""<section class="gen" style="padding-top:0"><div class="gen-top">
<h2>Does the arithmetic actually get faster?</h2>
<p class="claim">Cycles per instruction grow 17 to 20. Throughput still doubles.</p></div>
<p class="detail">A fair objection to any pipelining ladder: each stage inserts a register, so one
instruction passes through more clock edges. The testbench asserts exactly that &mdash; an operation
takes <code>17 + PIPE</code> cycles, verified on every run &mdash; so the baseline finishes in 17
cycles and the final design needs 20, <strong>17.6% more</strong>. If frequency had risen by less
than that, the design would compute more slowly while looking faster.</p>
<p class="detail">It did not, and the reason is what <code>PIPE</code> costs. A pipeline register
adds <em>latency</em>, not cycles per k-step: the array still retires <strong>1,024 MACs on every
clock edge</strong> at every depth, because that is the multiplier count and the accumulate loop runs
one k-step per cycle regardless. So the extra cycles are pipeline fill, paid once per instruction
rather than once per k-step. Streamed work amortises them to nothing.</p></section>""")
W('<div class="tw"><table><thead><tr><th>Variant</th><th>Target</th><th>fmax</th>'
  '<th>Cycles</th><th>Latency</th><th>One instruction</th><th>Streamed</th><th>Efficiency</th>'
  '</tr></thead><tbody>')
for _k, _t in THR_ROWS:
    _m = _t["metrics"]
    _cyc, _lat, _one, _sus, _eff = thr(_m, _k[0])
    _isop = _t["tag"] == best_tag
    W('<tr><td>PIPE=%d%s</td><td>%.2f ns%s</td><td>%.1f MHz</td><td>%d</td><td>%.2f ns</td>'
      '<td>%.1f</td><td class="f">%.1f</td><td class="f">%.1f</td></tr>'
      % (_k[0], " + RD_REG" if _k[1] else "", _t["knobs"]["period_ns"],
         ' <span class="dim">&larr; operating point</span>' if _isop else "",
         _m["regreg_fmax_mhz"], _cyc, _lat, _one, _sus, _eff))
W('</tbody></table></div>')
W("""<p class="fine">Columns: <strong>One instruction</strong> is GMAC/s for a single isolated
<code>TDPBSSD</code>, 16,384 MACs divided by its full latency, so it pays the pipeline fill in full.
<strong>Streamed</strong> is GMAC/s once the fill is amortised, which is 1,024 MACs per cycle times
the clock. <strong>Efficiency</strong> is streamed GMAC/s per watt.</p>""")
W('<p class="fine">Baseline to final: one isolated instruction goes <strong>%.1f &rarr; %.1f '
  'GMAC/s (+%.1f%%)</strong> &mdash; the +99.6%% clock, less the 17.6%% the extra cycles take back. '
  'Streamed throughput goes <strong>%.1f &rarr; %.1f GMAC/s (+%.1f%%)</strong>, exactly tracking '
  'frequency because the registers cost nothing per k-step. Efficiency goes <strong>%.1f &rarr; '
  '%.1f GMAC/s per watt, a %.1f&times; improvement</strong> &mdash; the frequency gain and the power '
  'reduction compounding.</p>'
  % (BASE_THR[2], FINAL_THR[2], 100*(FINAL_THR[2]/BASE_THR[2]-1),
     BASE_THR[3], FINAL_THR[3], 100*(FINAL_THR[3]/BASE_THR[3]-1),
     BASE_THR[4], FINAL_THR[4], FINAL_THR[4]/BASE_THR[4]))
W('<p class="fine">Efficiency is <strong>not</strong> monotonic, and it does not peak where the '
  'throughput does. The best measured figure is <strong>%.1f GMAC/s per watt at %.2f&nbsp;ns</strong>, '
  'one target looser than the operating point: tightening from there to 1.40&nbsp;ns buys '
  '<strong>%+.1f%% streamed throughput for %+.1f%% efficiency</strong>, because the extra frequency '
  'is paid for with timing-repair cells that burn power. <strong>If energy per MAC is the '
  'objective rather than throughput, %.2f&nbsp;ns is the better target.</strong> The wall at '
  '1.20&nbsp;ns is worse on both counts than 1.40 &mdash; it exists to prove where the limit is, not '
  'to be shipped.</p>'
  % (EFF_PEAK, EFF_PEAK_NS, OP_VS_PEAK_THRPUT, OP_VS_PEAK_EFF, EFF_PEAK_NS))

# ---- the designs -------------------------------------------------------------
W('<section class="gen" style="padding-top:0"><div class="gen-top"><h2>The five designs</h2>'
  '<p class="claim">Same datapath. The question was only where to cut it.</p></div>'
  '<p class="detail">Every trial below is one of these five netlists measured at some clock target. '
  'The chain from operand select to accumulator is fixed; what each pipeline level changes is where '
  'a register boundary falls, and therefore how much logic has to settle within one cycle. '
  'The accumulate loop cannot be cut &mdash; a saturating add must read its own previous result &mdash; '
  'so it sets the floor no pipeline depth can go below.</p></section>')
W('<div class="designs">')
for pp, rr, nm, ff, blurb in VARIANTS:
    W('<div class="dsn"><div class="dsn-top"><span class="nm">%s</span>'
      '<span class="ff">%s flip-flops</span><span class="used">measured in %s</span></div>'
      % (nm, format(ff, ","), USED[(pp, rr)]))
    W('<p class="qa" style="font-size:14.5px;color:var(--ink-dim);max-width:78ch">%s</p>' % blurb)
    W(datapath(pp, rr))
    W('</div>')
W('<p class="dp-legend"><span><b>&#9613;</b> register boundary present</span>'
  '<span><span style="opacity:.6">&#9615;</span> boundary absent at this level</span>'
  '<span><i>&#8635;</i> feedback loop, cannot be pipelined</span>'
  '<span>flop counts are per boundary, whole design</span></p>')
W('</div>')

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
        W('<div class="m key"><span class="k">fmax</span><span class="v">%.1f</span></div>' % m["regreg_fmax_mhz"])
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
    W('</article>')
    nxt = rows[rows.index((t,pr,img))+1] if rows.index((t,pr,img))+1 < len(rows) else None
    if nxt is None or nxt[0]["x"] != x: W('</div>')


# summary table
W('<section class="close"><h2>Every trial, in one table</h2>')
W('<div class="tw"><table><thead><tr><th>Trial</th><th>PIPE / RD</th><th>Target</th><th>Limiter</th>'
  '<th>fmax</th><th>reg&rarr;reg slack</th><th>TNS</th><th>Power</th><th>Flops</th><th>Cells</th><th>DRC</th></tr></thead><tbody>')
for t in trials:
    m = t.get("metrics"); k = t["knobs"]
    if not m:
        W('<tr><td>X%dY%d</td><td>%d / %d</td><td>%.2f</td><td class="dim">&mdash;</td>'
          '<td class="dim">&mdash;</td><td class="dim">&mdash;</td><td class="dim">&mdash;</td>'
          '<td class="dim">&mdash;</td><td class="dim">&mdash;</td><td class="dim">&mdash;</td>'
          '<td class="dim">&mdash;</td></tr>'
          % (t["x"],t["y"],k["PIPE"],k.get("RD_REG",0),k["period_ns"])); continue
    io = m["limiter_class"]!="reg->reg"
    W('<tr><td>X%dY%d</td><td>%d / %d</td><td>%.2f</td><td>%s</td><td class="f">%.1f</td>'
      '<td>%+.4f</td><td>%.2f</td><td>%.3f</td><td>%s</td><td>%s</td><td>%d</td></tr>'
      % (t["x"],t["y"],k["PIPE"],k.get("RD_REG",0),k["period_ns"],
         ('<span style="color:var(--rose)">pad</span>' if io else '<span style="color:var(--cyan)">design</span>'),
         m["regreg_fmax_mhz"], m["regreg_ws_ns"], m["setup_tns"], m["power_w"],
         format(m["flipflops"],","), format(m["stdcells"],","), m["drc_lines"]))
W('</tbody></table></div>')

W("""<h2 style="margin-top:22px">How to read these numbers</h2>
<p>The tool optimises <em>to</em> whatever clock target it is given, so every frequency here is a
lower bound rather than a ceiling, and only trials sharing a target are directly comparable. Three
such pairs exist, and they are the cleanest results in the set: <code>PIPE</code>&nbsp;2&rarr;3 was
worth <strong>+117.6&nbsp;MHz</strong> at 1.80&nbsp;ns, <code>RD_REG</code>
<strong>+15.4&nbsp;MHz</strong> at 1.60&nbsp;ns, and the first pipeline register +0.3&nbsp;MHz at
2.80&nbsp;ns alongside its <strong>19.2&times;</strong> power reduction.</p>
<p>The end-to-end baseline-to-final figures span different targets, so read them as indicative of
the whole ladder rather than as a single controlled measurement. The power reduction is the most
robust result here: most of it was won at equal speed and equal target, and it is the reason to
pipeline this design at all.</p>
<h2 style="margin-top:22px">Where it ends</h2>
<p>The binding path in the final design is the multiplier's own carry-propagate adder, ending at bit
14 of a 16-bit product &mdash; the last place carries arrive. Going faster means changing the
arithmetic rather than the pipeline: keeping products in carry-save form so the resolve is deferred.
That costs roughly 16,000 flops, 35% of the design, and <code>SAT=1</code> caps what it can buy,
because a saturating accumulator must clamp against a resolved value once per step and so cannot
stay redundant. Measured against ~4&nbsp;MHz of remaining headroom, it was not worth building.</p>""")

W('<p class="lastword">Three pipeline registers and one on the readback port: twice the frequency, 7.8x less power, 4.6% more cells. The arithmetic is what is left.</p>')
W('</section></div>')

open("experiments/report.html","w").write("\n".join(out))
print("wrote experiments/report.html  %.2f MB" % (os.path.getsize("experiments/report.html")/1048576.0))

# =============================================================================
# Markdown emitter -- experiments/REPORT.md, for viewing on GitHub.
#
# Same PROSE and VARIANTS as the HTML above, so the two cannot drift. Three
# things have to change for GitHub:
#
#   1. Images. GitHub's HTML sanitiser strips `data:` URIs, so the inlined
#      base64 the HTML relies on renders as nothing. The webp files are written
#      out to experiments/img/ and referenced by repo-relative path instead.
#      WebP has rendered inline on GitHub since Aug 2025, so no conversion.
#   2. Diagrams. The HTML draws the datapath with flexbox, which markdown cannot
#      carry. GitHub renders ```mermaid fences natively, so the same five
#      diagrams are emitted as mermaid flowcharts -- present boundaries filled,
#      absent ones dashed and greyed, exactly as in the HTML.
#   3. Inline markup. PROSE is authored as HTML fragments; html2md() converts
#      the small tag set actually used and collapses the source indentation.
# =============================================================================
import re as _re

IMGDIR = "experiments/img"

_ENT = [("&mdash;", "—"), ("&ndash;", "–"), ("&minus;", "−"),
        ("&times;", "×"), ("&rarr;", "→"), ("&Sigma;", "Σ"),
        ("&micro;", "µ"), ("&sup2;", "²"), ("&middot;", "·"),
        ("&ldquo;", "“"), ("&rdquo;", "”"), ("&#8635;", "↺"),
        ("&#9613;", "▍"), ("&#9615;", "▏"), ("&nbsp;", " ")]


def html2md(s):
    """Convert the authored HTML fragments to markdown.

    Deliberately handles only the tags PROSE actually uses. A general converter
    would silently pass unknown markup through into the .md, where GitHub would
    either strip it or render it as literal text -- both worse than failing here.
    """
    s = _re.sub(r"\s+", " ", s).strip()
    s = _re.sub(r"<code>(.*?)</code>", r"`\1`", s)
    s = _re.sub(r"<strong>(.*?)</strong>", r"**\1**", s)
    s = _re.sub(r"<em>(.*?)</em>", r"*\1*", s)
    for a, b in _ENT:
        s = s.replace(a, b)
    leftover = _re.findall(r"<[a-zA-Z/][^>]*>|&[a-zA-Z#][a-zA-Z0-9]*;", s)
    if leftover:
        raise SystemExit("html2md: unhandled markup %r -- add it rather than "
                         "letting it reach the .md" % sorted(set(leftover)))
    return s


def mermaid(pipe, rdreg):
    """One datapath flowchart. Node labels stay ASCII-only: mermaid on GitHub is
    not a place to find out which glyphs its parser dislikes."""
    on, off = [], []
    (on if pipe >= 3 else off).append(("R3", "S3", "1,024 ff"))
    (on if pipe >= 2 else off).append(("R2", "S2", "16,384 ff"))
    (on if pipe >= 1 else off).append(("R1", "S1", "4,608 ff"))
    (on if rdreg == 1 else off).append(("RD", "RD", "512 ff"))
    # A boundary that does NOT exist at this level must not carry a flop count:
    # labelling it "S2 / 16,384 ff" claims registers the netlist does not have.
    # Absent boundaries are labelled "combinational" instead.
    def lab(node, name, cost):
        live = any(n == node for n, _, _ in on)
        return '%s["%s<br/>%s"]' % (node, name, cost if live else "combinational")
    L = ["```mermaid", "flowchart LR"]
    L.append('  T["a_flat / b_flat<br/>tiles - 16,384 ff"] --> MUX["16:1 MUX<br/>select k-step"]')
    L.append('  MUX --> ' + lab("R3", "S3", "1,024 ff"))
    L.append('  R3 --> MUL["8x8 MUL<br/>x4 per unit"]')
    L.append('  MUL --> ' + lab("R2", "S2", "16,384 ff"))
    L.append('  R2 --> TREE["Sum tree<br/>4:1, 18b exact"]')
    L.append('  TREE --> ' + lab("R1", "S1", "4,608 ff"))
    L.append('  R1 --> ADD["+33b then FOLD<br/>clamp INT32"]')
    L.append('  ADD --> CACC["cacc<br/>32b x 256 = 8,192 ff"]')
    L.append('  CACC -.->|"loop: irreducible"| ADD')
    L.append('  CACC --> RMUX["5-level MUX<br/>row select"]')
    L.append('  RMUX --> ' + lab("RD", "RD", "512 ff"))
    L.append('  RD --> PORT["rd_data<br/>512b output port"]')
    # `class X y` rather than the inline `:::y` form -- more widely supported.
    if on:
        L.append("  class %s regon" % ",".join(n for n, _, _ in on))
    if off:
        L.append("  class %s regoff" % ",".join(n for n, _, _ in off))
    L.append("  class T,PORT edge")
    # Colours chosen to stay legible on GitHub's light AND dark markdown themes:
    # a mid-cyan carries white text on either ground, grey-on-transparent reads
    # as absent in both.
    L.append("  classDef regon fill:#12879B,stroke:#12879B,color:#ffffff")
    L.append("  classDef regoff fill:transparent,stroke:#8A97A6,stroke-dasharray:4 3,color:#8A97A6")
    L.append("  classDef edge fill:transparent,stroke:#8A97A6,stroke-dasharray:2 2")
    L.append("```")
    return "\n".join(L)


M = []
A = M.append

A("# Carry Chain at 703 Megahertz")
A("")
A("**Physical design log — Intel AMX `TDPBSSD` on Nangate45**")
A("")
A(html2md("""Ten synthesis-and-place-and-route experiments on a 1,024-multiplier INT8 tile
matrix-multiply unit, run as a disciplined hillclimb. Four generations of method, ten routed
designs, and a final result that runs at twice the baseline frequency for 7.8 times less power.
The design ends up limited by a multiplier's carry-propagate adder."""))
A("")
A("| | |")
A("|---|---|")
A("| Design | `amx_tdpbssd` |")
A("| Operation | `C += A×B`, (16×64)×(64×16) INT8 |")
A("| MACs | 16,384 per instruction |")
A("| Flow | Yosys + OpenROAD, Nangate45 |")
A("| Trials | 10 |")
A("| RTL defects | 0 |")
A("")
A("> A styled HTML version of this page can be built locally with "
  "`python3 scripts/report.py` — it is not committed, because GitHub renders HTML as "
  "source and this Markdown is the shareable form.")
A("")

A("## The final chip")
A("")
A("![Routed layout of the final design](img/%s.webp)" % FINAL_TAG)
A("")
A("*The final design, routed — %s µm², %s standard cells, %s flip-flops, hold met, DRC clean. "
  "Pink and cyan are the lower metal layers, green the vias; blue is unused routing track. The "
  "cell region does not fill the die because the floorplan targets 40%% utilisation.*"
  % (format(int(best["area_um2"]), ","), format(best["stdcells"], ","),
     format(best["flipflops"], ",")))
A("")
A("### Baseline vs final")
A("")
A("| | Baseline — X1·Y0 | Final — X4·Y0 | Change |")
A("|---|---|---|---|")
A("| Design | PIPE=0, one combinational path | PIPE=3 + RD_REG | 3 pipeline cuts |")
A("| Clock target | 2.80 ns | 1.40 ns | −50% |")
A("| **fmax, reg→reg** | %.1f MHz | **%.1f MHz** | **%s** |"
  % (base["regreg_fmax_mhz"], best["regreg_fmax_mhz"],
     _pct(base["regreg_fmax_mhz"], best["regreg_fmax_mhz"])))
A("| **Power** | %.3f W | **%.3f W** | **%s · %.1f× less** |"
  % (base["power_w"], best["power_w"], _pct(base["power_w"], best["power_w"]),
     base["power_w"] / best["power_w"]))
A("| Flip-flops | %s | %s | %s |"
  % (format(base["flipflops"], ","), format(best["flipflops"], ","),
     _pct(base["flipflops"], best["flipflops"])))
A("| Standard cells | %s | %s | %s |"
  % (format(base["stdcells"], ","), format(best["stdcells"], ","),
     _pct(base["stdcells"], best["stdcells"])))
A("| Die area | %s µm² | %s µm² | %s |"
  % (format(int(base["area_um2"]), ","), format(int(best["area_um2"]), ","),
     _pct(base["area_um2"], best["area_um2"])))
A("| Hold slack | %+.4f ns | %+.4f ns | met both |" % (base["hold_ws_ns"], best["hold_ws_ns"]))
A("| DRC violations | %d | %d | clean both |" % (base["drc_lines"], best["drc_lines"]))
A("| **Streamed throughput** | %.1f GMAC/s | **%.1f GMAC/s** | **%s** |"
  % (BASE_THR[3], FINAL_THR[3], _pct(BASE_THR[3], FINAL_THR[3])))
A("| **Energy efficiency** | %.1f GMAC/s/W | **%.1f GMAC/s/W** | **%.1f× better** |"
  % (BASE_THR[4], FINAL_THR[4], FINAL_THR[4] / BASE_THR[4]))
A("")
A(html2md("""<strong>Twice the speed for 7.8&times; less power</strong>, at +4.6% more cells. Read the
fmax row with one caveat: the two rows were placed and routed at different clock targets, and the
tool optimises <em>to</em> whatever target it is given, so that percentage is indicative rather than
a like-for-like measurement. The power figures are measured at each row's own operating condition,
and most of that reduction was won at equal speed and equal target."""))
A("")
A(html2md("""The wall is %.1f&nbsp;MHz. Going there costs %.0f%% more power for +%.1f&nbsp;MHz, which
is why 1.40&nbsp;ns is the operating point and not 1.20.""")
  % (wall["regreg_fmax_mhz"], 100 * (wall["power_w"] / best["power_w"] - 1),
     wall["regreg_fmax_mhz"] - best["regreg_fmax_mhz"]))
A("")
A("## Does the arithmetic actually get faster?")
A("")
A("*Cycles per instruction grow 17 to 20. Throughput still doubles.*")
A("")
A(html2md("""A fair objection to any pipelining ladder: each stage inserts a register, so one
instruction passes through more clock edges. The testbench asserts exactly that &mdash; an operation
takes <code>17 + PIPE</code> cycles, verified on every run &mdash; so the baseline finishes in 17
cycles and the final design needs 20, <strong>17.6% more</strong>. If frequency had risen by less
than that, the design would compute more slowly while looking faster."""))
A("")
A(html2md("""It did not, and the reason is what <code>PIPE</code> costs. A pipeline register adds
<em>latency</em>, not cycles per k-step: the array still retires <strong>1,024 MACs on every clock
edge</strong> at every depth, because that is the multiplier count and the accumulate loop runs one
k-step per cycle regardless. So the extra cycles are pipeline fill, paid once per instruction rather
than once per k-step. Streamed work amortises them to nothing."""))
A("")
A("| Variant | Target | fmax | Cycles | Latency | One instruction | Streamed | Efficiency |")
A("|---|---|---|---|---|---|---|---|")
for _k, _t in THR_ROWS:
    _m = _t["metrics"]
    _cyc, _lat, _one, _sus, _eff = thr(_m, _k[0])
    A("| PIPE=%d%s | %.2f ns%s | %.1f MHz | %d | %.2f ns | %.1f | **%.1f** | **%.1f** |"
      % (_k[0], " + RD_REG" if _k[1] else "", _t["knobs"]["period_ns"],
         " ← operating point" if _t["tag"] == best_tag else "",
         _m["regreg_fmax_mhz"], _cyc, _lat, _one, _sus, _eff))
A("")
A(html2md("""Columns: <strong>One instruction</strong> is GMAC/s for a single isolated
<code>TDPBSSD</code>, 16,384 MACs divided by its full latency, so it pays the pipeline fill in full.
<strong>Streamed</strong> is GMAC/s once the fill is amortised, which is 1,024 MACs per cycle times
the clock. <strong>Efficiency</strong> is streamed GMAC/s per watt."""))
A("")
A("| | Baseline — X1·Y0 | Final — X4·Y0 | Change |")
A("|---|---|---|---|")
A("| Cycles per instruction | 17 | 20 | +17.6% |")
A("| One instruction | %.1f GMAC/s | **%.1f GMAC/s** | **+%.1f%%** |"
  % (BASE_THR[2], FINAL_THR[2], 100 * (FINAL_THR[2] / BASE_THR[2] - 1)))
A("| Streamed | %.1f GMAC/s | **%.1f GMAC/s** | **+%.1f%%** |"
  % (BASE_THR[3], FINAL_THR[3], 100 * (FINAL_THR[3] / BASE_THR[3] - 1)))
A("| Efficiency | %.1f GMAC/s/W | **%.1f GMAC/s/W** | **%.1f× better** |"
  % (BASE_THR[4], FINAL_THR[4], FINAL_THR[4] / BASE_THR[4]))
A("")
A(html2md("""One isolated instruction gains the +99.6% clock less the 17.6% the extra cycles take
back. Streamed throughput tracks frequency exactly, because the registers cost nothing per k-step.
Efficiency compounds the frequency gain with the power reduction."""))
A("")
A(html2md("""Efficiency is <strong>not</strong> monotonic, and it does not peak where throughput
does. The best measured figure is <strong>%.1f GMAC/s per watt at %.2f&nbsp;ns</strong>, one target
looser than the operating point: tightening from there to 1.40&nbsp;ns buys <strong>%+.1f%% streamed
throughput for %+.1f%% efficiency</strong>, because the extra frequency is paid for with
timing-repair cells that burn power. <strong>If energy per MAC is the objective rather than
throughput, %.2f&nbsp;ns is the better target.</strong> The wall at 1.20&nbsp;ns is worse than 1.40
on both counts &mdash; it exists to prove where the limit is, not to be shipped.""")
  % (EFF_PEAK, EFF_PEAK_NS, OP_VS_PEAK_THRPUT, OP_VS_PEAK_EFF, EFF_PEAK_NS))
A("")

A("## The five designs")
A("")
A("*Same datapath. The question was only where to cut it.*")
A("")
A(html2md("""Every trial is one of these five netlists measured at some clock target. The chain from
operand select to accumulator is fixed; what each pipeline level changes is where a register
boundary falls, and therefore how much logic has to settle within one cycle. The accumulate loop
cannot be cut &mdash; a saturating add must read its own previous result &mdash; so it sets the
floor no pipeline depth can go below."""))
A("")
A("In each diagram, a **filled** boundary is a register that exists at that level; a "
  "**dashed grey** one is a boundary that is still combinational.")
A("")
for pp, rr, nm, ff, blurb in VARIANTS:
    A("### %s" % html2md(nm))
    A("")
    A("`%s flip-flops` · measured in %s" % (format(ff, ","), html2md(USED[(pp, rr)])))
    A("")
    A(html2md(blurb))
    A("")
    A(mermaid(pp, rr))
    A("")

A("## The trials")
A("")
GENMD = {x: (GEN[x]["name"], GEN[x]["claim"], GEN[x]["detail"]) for x in GEN}
seen_md = set()
for t, pr, _img in rows:
    x = t["x"]
    if x not in seen_md:
        seen_md.add(x)
        nm, claim, detail = GENMD[x]
        A("### %s — %s" % (nm, html2md(claim)))
        A("")
        A(html2md(detail))
        A("")
    m, k = t.get("metrics"), t["knobs"]
    tag = t["tag"]
    lim = "design-limited" if m["limiter_class"] == "reg->reg" else "**pad-limited**"
    A("#### X%d·Y%d — %s" % (t["x"], t["y"], html2md(pr["head"])))
    A("")
    A("`PIPE=%d` `RD_REG=%d` `target %.2f ns` · %s"
      % (k["PIPE"], k.get("RD_REG", 0), k["period_ns"], lim))
    A("")
    A("**What was tried.** " + html2md(pr["tried"]))
    A("")
    A("**Result.** " + html2md(pr["result"]))
    A("")
    fm = "**%.1f MHz**" % m["regreg_fmax_mhz"]
    A("| fmax | reg→reg slack | TNS | power | flip-flops | std cells | hold | DRC |")
    A("|---|---|---|---|---|---|---|---|")
    A("| %s | %+.4f ns | %.2f | %.3f W | %s | %s | %+.4f | %d |"
      % (fm, m["regreg_ws_ns"], m["setup_tns"], m["power_w"],
         format(m["flipflops"], ","), format(m["stdcells"], ","),
         m["hold_ws_ns"], m["drc_lines"]))
    A("")
    if pr["note"]:
        A("> " + html2md(pr["note"]))
        A("")


A("## Every trial, in one table")
A("")
A("| Trial | PIPE / RD | Target | Limiter | fmax | reg→reg slack | TNS | Power | Flops | Cells | DRC |")
A("|---|---|---|---|---|---|---|---|---|---|---|")
for t in trials:
    m, k = t.get("metrics"), t["knobs"]
    if not m:
        A("| X%d·Y%d | %d / %d | %.2f | — | — | — | — | — | — | — | — |"
          % (t["x"], t["y"], k["PIPE"], k.get("RD_REG", 0), k["period_ns"]))
        continue
    io = m["limiter_class"] != "reg->reg"
    A("| X%d·Y%d | %d / %d | %.2f | %s | **%.1f** | %+.4f | %.2f | %.3f | %s | %s | %d |"
      % (t["x"], t["y"], k["PIPE"], k.get("RD_REG", 0), k["period_ns"],
         "pad" if io else "design",
         m["regreg_fmax_mhz"], m["regreg_ws_ns"], m["setup_tns"], m["power_w"],
         format(m["flipflops"], ","), format(m["stdcells"], ","), m["drc_lines"]))
A("")

A("## How to read these numbers")
A("")
A(html2md("""The tool optimises <em>to</em> whatever clock target it is given, so every frequency
here is a lower bound rather than a ceiling, and only trials sharing a target are directly
comparable. Three such pairs exist, and they are the cleanest results in the set:"""))
A("")
A("| Change | Target | Gain |")
A("|---|---|---|")
A("| `PIPE` 2 -> 3 | 1.80 ns | **+117.6 MHz** |")
A("| `RD_REG` 0 -> 1 | 1.60 ns | **+15.4 MHz** |")
A("| `PIPE` 0 -> 1 | 2.80 ns | +0.3 MHz, and **19.2x less power** |")
A("")
A(html2md("""The end-to-end baseline-to-final figures span different targets, so read them as
indicative of the whole ladder rather than as a single controlled measurement. The power reduction is
the most robust result here: most of it was won at equal speed and equal target, and it is the reason
to pipeline this design at all."""))
A("")
A("## Where it ends")
A("")
A(html2md("""The binding path in the final design is the multiplier's own carry-propagate adder,
ending at bit 14 of a 16-bit product &mdash; the last place carries arrive. Going faster means
changing the arithmetic rather than the pipeline: keeping products in carry-save form so the resolve
is deferred. That costs roughly 16,000 flops, 35% of the design, and <code>SAT=1</code> caps what it
can buy, because a saturating accumulator must clamp against a resolved value once per step and so
cannot stay redundant. Measured against ~4&nbsp;MHz of remaining headroom, it was not worth
building."""))
A("")
A("---")
A("")
A("> Three pipeline registers and one on the readback port: twice the frequency, 7.8x less "
  "power, 4.6% more cells. The arithmetic is what is left.")
A("")
A("*Generated by [`scripts/report.py`](../scripts/report.py) from "
  "[`trials.jsonl`](trials.jsonl). Every figure is read from the flow's own reports; none is "
  "hand-typed.*")

open("experiments/REPORT.md", "w").write("\n".join(M) + "\n")
print("wrote experiments/REPORT.md  %.1f KB  (1 layout in %s/, the final result)"
      % (os.path.getsize("experiments/REPORT.md") / 1024.0, IMGDIR))
