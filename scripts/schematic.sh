#!/usr/bin/env bash
#=============================================================================
# schematic.sh -- emit human-readable schematics of the design.
#
# THREE DECISIONS SEPARATE A FIGURE FROM A HAIRBALL.
#
# 1. ABSTRACTION LEVEL. `yosys -p show` on a synthesised netlist gives a
#    5,000-node mess that teaches nothing. This dumps BEFORE technology
#    mapping (yosys `prep`), where the design is still coarse cells named
#    $mul, $add, $mux, $dff, $eq, $lt -- the vocabulary of a first
#    digital-electronics course.
#
#      abstraction level                 size at N=4   one readable figure?
#      prep, coarse cells (used here)      88 cells*   yes         (* at N=2)
#      synth, generic 2-input gates     4,937 cells    one slice at a time
#      Nangate45 mapped                44,468 lines    no
#      placed + routed                 33,534 lines    no -- that is a LAYOUT
#
#    Default is N=2, not N=4: same architecture, a quarter of the drawing.
#
# 2. WHERE EACH FIGURE IS CUT. Yosys names expression cells after the RTL line
#    that created them ($mul$rtl/mac_array.v:182), so each view is anchored on
#    real source lines, found by grep and never hardcoded.
#
#    CAVEAT, learned the hard way: only 21 of the 88 cells carry a source line.
#    The other 67 are $procmux/$procdff, synthesised from the always blocks,
#    and carry no line info at all. So a line anchor alone silently UNDER-cuts
#    any view involving a clocked block. Each view therefore anchors on the
#    tagged expression cells and expands a fixed, stated number of levels to
#    pick up the registers and select muxes that proc built around them.
#
# 3. GUARDS, because both failure modes here are silent.
#      - A yosys select pattern that matches NOTHING does not error: the
#        selection falls back to the whole module, and you get a plausible
#        wrong figure. Every view greps its own log for "did not match".
#      - A view can be cut in the wrong place and still look fine. Every view
#        declares the cell types it MUST contain, and the array view asserts
#        it found exactly N*N multipliers and N*N accumulators -- proof the
#        drawing shows the whole array and nothing but the array.
#
# The FSM state diagram is the one figure NOT from a netlist dump -- a state
# graph is not a schematic. It is hand-drawn from the case statement, and
# guarded by yosys fsm_extract reporting the same state count.
#
# Layout images are NOT produced here. ORFS already writes them during
# `make measure` to work/reports/nangate45/<nick>/base/final_*.webp. A layout
# is not a schematic and this script does not blur the two.
#
# Usage:  scripts/schematic.sh [-n N] [-c C_PORT] [-o OUTDIR]
#
# -c selects the same C_PORT the RTL is built with. View 08 (the accumulator
# init path, i.e. where D = A@B + C happens) does not exist at C_PORT=0 and is
# skipped rather than drawn empty.
# Requires: yosys, netlistsvg  (npm i -g netlistsvg)
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

N=2
CPORT=1
OUT="$HERE/build/schematic"
YOSYS="${YOSYS_EXE:-yosys}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) N="$2"; shift 2 ;;
    -c) CPORT="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v "$YOSYS" >/dev/null \
  || { echo "FATAL: yosys not found. run 'make setup'" >&2; exit 1; }
command -v netlistsvg >/dev/null \
  || { echo "FATAL: netlistsvg not found.  npm i -g netlistsvg" >&2; exit 1; }

RTL="$HERE/rtl/mac_array.v"
NN=$((N*N))
mkdir -p "$OUT"

# ------------------------------------------------------------------ anchors
# Resolve an RTL line from anchor text; comment lines are skipped so that a
# comment mentioning the same expression cannot shadow the real one.
anchor() {
  local pat="$1" n
  n=$(grep -nE "$pat" "$RTL" | awk -F: '$2 !~ /^[[:space:]]*\/\// {print $1; exit}')
  [[ -n "$n" ]] || { echo "FATAL: RTL anchor not found: /$pat/" >&2; exit 1; }
  echo "$n"
}

L_REQ=$(anchor 'act_req  *= \(state')
L_K0=$(anchor 'k_dim == \{KW\{1.b0\}\}\) \? S_DRAIN')
L_ISS=$(anchor 'issued <= issued \+')
L_CON=$(anchor 'consumed <= consumed \+')
L_EQK=$(anchor 'consumed \+ 1.b1 == k_dim')
L_DRN=$(anchor 'out_wdata <= acc\[drow\]\[dcol\]')
L_ROW=$(anchor 'drow <= drow \+')
L_COL=$(anchor 'dcol <= dcol \+')
L_MUL=$(anchor 'product = a_lane \* w_lane')
L_ACC=$(anchor 'acc\[gr\]\[gc\] <= acc\[gr\]\[gc\]')

c() { local l; for l in "$@"; do printf 'c:*mac_array.v:%s* ' "$l"; done; }

echo "== schematics for N=$N C_PORT=$CPORT into $OUT =="

# ------------------------------------------------------------------ caption
# An uncaptioned schematic is indistinguishable from a schematic of a
# different revision. Every figure carries its own provenance.
caption() {  # caption <svg> <title> <subtitle>
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
path, title, sub = sys.argv[1:4]
s = open(path).read()
m = re.search(r'<svg([^>]*)>', s)
a = m.group(1)
w = float(re.search(r'width="([\d.]+)"',  a).group(1))
h = float(re.search(r'height="([\d.]+)"', a).group(1))
PAD = 56
W, H = max(w, 660), h + PAD

# netlistsvg emits width/height but NO viewBox, so a renderer is free to scale
# the canvas and crop the drawing (macOS Quick Look does exactly that). Since
# we are changing the height anyway, set all three explicitly.
tag = m.group(0)
for attr in ('width', 'height', 'viewBox'):
    tag = re.sub(r'\s%s="[^"]*"' % attr, '', tag)
tag = '%s width="%g" height="%g" viewBox="0 0 %g %g">' % (tag[:-1].rstrip(), W, H, W, H)

body = s[m.end():].rsplit('</svg>', 1)[0]
e = lambda t: t.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
open(path, 'w').write(
    s[:m.start()] + tag
    + '<rect x="0" y="0" width="%g" height="%g" fill="#ffffff"/>' % (W, H)
    + '<text x="12" y="25" font-family="Helvetica,Arial,sans-serif" font-size="17"'
      ' font-weight="bold" fill="#111">%s</text>' % e(title)
    + '<text x="12" y="44" font-family="monospace" font-size="11" fill="#666">%s</text>'
      % e(sub)
    + '<g transform="translate(0,%g)">' % PAD + body + '</g></svg>')
PY
}

# view <name> <title> <subtitle> <must-contain csv> <yosys selection...>
view() {
  local name="$1" title="$2" sub="$3" need="$4"; shift 4
  local mod="${name#??_}"
  cat > "$OUT/$name.ys" <<EOF
read_verilog $RTL
chparam -set N $N -set C_PORT $CPORT mac_array
prep -top mac_array
select -set v $*
submod -name $mod @v
hierarchy -top $mod
opt_clean
write_json $OUT/$name.json
EOF
  "$YOSYS" -q -s "$OUT/$name.ys" 2>"$OUT/$name.yslog" \
    || { echo "FATAL: yosys failed for $name -- see $OUT/$name.yslog" >&2; exit 1; }

  # GUARD 1: an unmatched pattern silently selects the whole module.
  if grep -qi 'did not match' "$OUT/$name.yslog"; then
    echo "FATAL: $name has a select pattern matching nothing (an anchor moved);" >&2
    echo "       yosys would have silently selected the entire module." >&2
    grep -i 'did not match' "$OUT/$name.yslog" >&2
    exit 1
  fi

  # GUARD 2: the view must contain the cell types it claims to be about.
  local shape
  shape=$(python3 - "$OUT/$name.json" "$need" "$name" <<'PY'
import collections, json, sys
path, need, name = sys.argv[1:4]
d = json.load(open(path))
h = collections.Counter(c['type'] for m in d['modules'].values()
                        for c in m['cells'].values())
missing = [t for t in need.split(',') if t and h[t] == 0]
if missing:
    sys.exit("FATAL: %s is missing %s -- cut in the wrong place. Got: %s"
             % (name, ' '.join(missing), dict(h)))
print(' '.join('%s=%d' % (k.lstrip('$'), v) for k, v in sorted(h.items())))
PY
  ) || exit 1

  netlistsvg "$OUT/$name.json" -o "$OUT/$name.svg" >/dev/null 2>&1 \
    || { echo "FATAL: netlistsvg failed for $name" >&2; exit 1; }
  # C_PORT changes what hardware exists, and every view shares one output
  # directory, so the configuration has to be on the face of each drawing --
  # otherwise a C_PORT=0 run silently overwrites a C_PORT=1 set.
  caption "$OUT/$name.svg" "$title" "N=$N C_PORT=$CPORT | $sub"

  # GUARD 3: caption() rewrites the SVG header by hand. Prove the result still
  # parses, still has the caption, and still has the netlist body under it.
  python3 - "$OUT/$name.svg" "$title" <<'PY'
import sys, xml.etree.ElementTree as ET
NS = '{http://www.w3.org/2000/svg}'
path, title = sys.argv[1:3]
try:
    root = ET.parse(path).getroot()
except ET.ParseError as e:
    sys.exit("FATAL: %s is not well-formed XML after captioning: %s" % (path, e))
txt = ''.join(t.text or '' for t in root.iter(NS + 'text'))
if title[:24] not in txt:
    sys.exit("FATAL: %s lost its caption" % path)
if root.find(NS + 'g') is None:
    sys.exit("FATAL: %s lost its netlist body" % path)
PY
  printf '   %-26s %s\n' "$name.svg" "$shape"
}

# ---- 1. one MAC cell -- the circuit the entire chip repeats N*N times ------
view 01_mac_cell \
  "One multiply-accumulate cell -- the chip repeats this $NN times" \
  "rtl/mac_array.v:$L_MUL,$L_ACC, one instance of the generate block" \
  '$mul,$add' \
  'w:*g_row[0].g_col[0].product %ci1 %co4'

# ---- 2. the whole array -- shows BROADCAST fanout -------------------------
# One activation lane drives a whole row of multipliers; one weight lane
# drives a whole column. That fanout grows with N and is what ultimately caps
# a broadcast architecture. %co2 reaches the enable/clear mux proc inserted.
view 02_array \
  "The ${N}x${N} broadcast array -- $NN cells sharing $((2*N)) input lanes" \
  "v:$L_MUL,$L_ACC +%co2 +accumulators. STOPS BEFORE the c_in init mux -- see 08." \
  '$mul,$add,$mux,$dff' \
  "$(c "$L_MUL" "$L_ACC") %co2" 't:$dff'

# This is the one figure where "did I capture the WHOLE array" is checkable:
# a correct cut has exactly N*N multipliers and N*N accumulators, no more.
python3 - "$OUT/02_array.json" "$NN" <<'PY' || exit 1
import collections, json, sys
d = json.load(open(sys.argv[1])); nn = int(sys.argv[2])
h = collections.Counter(c['type'] for m in d['modules'].values()
                        for c in m['cells'].values())
bad = {t: h[t] for t in ('$mul', '$add', '$mux', '$dff') if h[t] != nn}
if bad:
    sys.exit("FATAL: 02_array should hold exactly %d of each of $mul/$add/$mux/"
             "$dff (N*N); got %s. The cut is wrong, or the array changed shape."
             % (nn, bad))
PY

# ---- 3. request generation -----------------------------------------------
# rtl/mac_array.v flags this as the first fmax bottleneck: a KW-bit magnitude
# comparator ($lt) sitting combinationally on an output port. Here it is.
view 03_request_gen \
  "Read-request generation -- the KW-bit comparator on an output port" \
  "rtl/mac_array.v:$L_REQ + %ci2 (reaches the state register it tests)" \
  '$lt,$logic_and' \
  "$(c "$L_REQ") %ci2"

# ---- 4. the drain readout ------------------------------------------------
# acc[drow][dcol] with variable indices. The full path is visible here:
# index arithmetic ($mul drow*N, $add +dcol) -> address decode ($eq) ->
# the select itself ($pmux) -> the output register ($adff). The header of
# rtl/mac_array.v warns this becomes the critical path as N scales.
view 04_drain_mux \
  "Result readout -- the $NN:1 accumulator mux, decode and index arithmetic" \
  "rtl/mac_array.v:$L_DRN + %co8 (one line of RTL becomes all of this)" \
  '$mul,$add,$eq,$pmux,$adff' \
  "$(c "$L_DRN") %co8"

# ---- 5. control ----------------------------------------------------------
# Every control register plus the arithmetic computing its next value. This
# is the hardware that replaces the program counter a software loop has.
view 05_control \
  "Control -- every state register and the logic that advances it" \
  "rtl/mac_array.v:$L_K0,$L_ISS,$L_CON,$L_EQK,$L_ROW,$L_COL + %co1 + all registers" \
  '$add,$eq,$adff' \
  "$(c "$L_K0" "$L_ISS" "$L_CON" "$L_EQK" "$L_ROW" "$L_COL") %co1" 't:$adff'

# ---- 6. real logic gates -- the bridge to the textbook -------------------
# Everything above is coarse blocks. This is ONE 4x4 signed multiplier
# decomposed into gates. Deliberately NOT run through abc: techmap's
# structural output still resembles an array multiplier, whereas abc
# optimises it into an unrecognisable soup.
cat > "$OUT/06_multiplier_gates.ys" <<EOF
read_verilog $RTL
chparam -set N $N -set C_PORT $CPORT mac_array
prep -top mac_array
select -set m w:*g_row[0].g_col[0].product %ci1
submod -name mult4x4 @m
hierarchy -top mult4x4
techmap
opt -fast
opt_clean
write_json $OUT/06_multiplier_gates.json
EOF
"$YOSYS" -q -s "$OUT/06_multiplier_gates.ys" 2>"$OUT/06_multiplier_gates.yslog" \
  || { echo "FATAL: yosys failed for 06_multiplier_gates" >&2; exit 1; }
netlistsvg "$OUT/06_multiplier_gates.json" -o "$OUT/06_multiplier_gates.svg" \
  >/dev/null 2>&1 || { echo "FATAL: netlistsvg failed for 06_multiplier_gates" >&2; exit 1; }
MG=$(python3 -c "import json; d=json.load(open('$OUT/06_multiplier_gates.json')); \
print(sum(len(m['cells']) for m in d['modules'].values()))")
caption "$OUT/06_multiplier_gates.svg" \
  "One 4x4 signed multiplier, decomposed to $MG logic gates" \
  "rtl/mac_array.v:$L_MUL after techmap. A poster, not a page: this is ONE of the $NN cells."
printf '   %-26s %s\n' "06_multiplier_gates.svg" "$MG 2-input gates"

# ---- 7. FSM state diagram (hand-drawn, guarded) --------------------------
STATES=$("$YOSYS" -p "read_verilog $RTL; chparam -set N $N -set C_PORT $CPORT mac_array; \
prep -top mac_array; fsm_detect; fsm_extract; fsm_info" 2>/dev/null \
  | sed -n '/State encoding:/,/Transition Table/p' \
  | grep -cE "^[[:space:]]+[0-9]+:[[:space:]]+2'" || true)
if [[ "$STATES" != "3" ]]; then
  echo "FATAL: yosys fsm_extract reports $STATES states, but 07_fsm_states.svg" >&2
  echo "       is hand-drawn for 3 (IDLE/RUN/DRAIN). Redraw it or fix the RTL." >&2
  exit 1
fi

cat > "$OUT/07_fsm_states.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="1140" height="480" viewBox="0 0 1140 480">
<rect width="1140" height="480" fill="#fff"/>
<style>
 .s{font:bold 16px Helvetica,Arial,sans-serif;fill:#111}
 .c{font:11px monospace;fill:#0a6}
 .a{font:11px monospace;fill:#b34700}
 .n{font:11px Helvetica,Arial,sans-serif;fill:#555}
 .e{stroke:#333;stroke-width:1.6;fill:none;marker-end:url(#h)}
</style>
<defs><marker id="h" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7"
 markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#333"/>
</marker></defs>

<text x="14" y="28" class="s" font-size="18">mac_array control FSM</text>
<text x="14" y="49" class="n">3 states / 9 transitions &#8212; the state count is verified against yosys fsm_extract every time this is regenerated.</text>
<text x="14" y="64" class="n">Hand-drawn from the case statement in rtl/mac_array.v, because a state graph is not a netlist and cannot be dumped from one.</text>

<!-- the K=0 shortcut, arcing over the top. Control points sit at y=95 so the
     curve's midpoint lands near y=124, clear of the self-loop labels at 146. -->
<text x="545" y="84" class="n" text-anchor="middle">degenerate start: must drain zeros, not hang (testbench case T3)</text>
<text x="545" y="98" class="c" text-anchor="middle">start &amp;&amp; k_dim == 0</text>
<path class="e" d="M141,213 C210,95 880,95 893,211"/>

<!-- self-loop labels, clear of the arcs below them -->
<text x="170" y="160" class="c" text-anchor="middle">!start</text>
<text x="545" y="146" class="a" text-anchor="middle">issue a read; accumulate if rd_valid</text>
<text x="545" y="160" class="c" text-anchor="middle">else</text>
<text x="920" y="146" class="a" text-anchor="middle">out_we&lt;=1, one result per cycle</text>
<text x="920" y="160" class="c" text-anchor="middle">else</text>
<path class="e" d="M146,203 C126,172 214,172 194,203"/>
<path class="e" d="M521,203 C501,172 589,172 569,203"/>
<path class="e" d="M896,203 C876,172 964,172 944,203"/>

<!-- the two forward transitions -->
<text x="357" y="224" class="a" text-anchor="middle">acc&lt;=0, counters&lt;=0, busy&lt;=1</text>
<text x="357" y="238" class="c" text-anchor="middle">start &amp;&amp; k_dim != 0</text>
<path class="e" d="M222,250 L487,250"/>

<text x="732" y="224" class="a" text-anchor="middle">drow/dcol &lt;= 0</text>
<text x="732" y="238" class="c" text-anchor="middle">rd_valid &amp;&amp; consumed+1 == k_dim</text>
<path class="e" d="M597,250 L862,250"/>

<!-- states -->
<circle cx="170" cy="250" r="52" fill="#eef4ff" stroke="#333" stroke-width="2"/>
<circle cx="170" cy="250" r="45" fill="none" stroke="#333"/>
<text x="170" y="247" class="s" text-anchor="middle">S_IDLE</text>
<text x="170" y="263" class="n" text-anchor="middle">reset state</text>
<circle cx="545" cy="250" r="52" fill="#eef4ff" stroke="#333" stroke-width="2"/>
<text x="545" y="247" class="s" text-anchor="middle">S_RUN</text>
<text x="545" y="263" class="n" text-anchor="middle">busy=1</text>
<circle cx="920" cy="250" r="52" fill="#eef4ff" stroke="#333" stroke-width="2"/>
<text x="920" y="247" class="s" text-anchor="middle">S_DRAIN</text>
<text x="920" y="263" class="n" text-anchor="middle">busy=1</text>

<!-- the return arc, underneath -->
<path class="e" d="M893,290 C830,392 250,392 196,289"/>
<text x="545" y="416" class="c" text-anchor="middle">drow == N-1 &amp;&amp; dcol == N-1</text>
<text x="545" y="431" class="a" text-anchor="middle">done&lt;=1, busy&lt;=0 &#8212; but out_we is STILL 1 this cycle, carrying the LAST result</text>

<text x="14" y="464" class="n">Cost: S_RUN runs k_dim+1 cycles (the +1 is SRAM read latency). S_DRAIN always runs N*N cycles, whatever K is. Compute efficiency = K/(K + N*N).</text>
</svg>
EOF
printf '   %-26s %s\n' "07_fsm_states.svg" "3 states (hand-drawn, guarded by fsm_extract)"

# ---- 8. the addend: where D = A@B + C is actually built -------------------
# c_in touches the design in exactly one place -- one branch of the
# accumulator's D input -- so it gets its own figure. 02_array deliberately
# stops before this: its %co2 cut walks forward from the multipliers and never
# reaches a mux that c_in feeds from the side, and forcing it to would need a
# selection whose boundary is no longer one sentence.
#
# `w:c_in %co1` alone is exactly the N*N c_in select muxes (verified). %co3 also
# picks up the load-vs-accumulate mux behind them, which is what makes the
# three-way init (zero / c_in / hold) legible as one drawing.
if [[ "$CPORT" != "0" ]]; then
  view 08_acc_init \
    "Accumulator init -- where D = A@B + C is actually built" \
    "select w:c_in %co3 + the accumulators. The ONLY place c_in touches the design." \
    '$mux,$dff' \
    'w:c_in %co3' 't:$dff'
else
  printf '   %-26s %s\n' "08_acc_init.svg" \
    "SKIPPED -- C_PORT=0, no c_in hardware exists to draw"
fi

echo
echo "Read them in this order:"
echo "   07_fsm_states         what the machine does over time"
echo "   01_mac_cell           the one circuit the whole chip repeats"
echo "   02_array              how $NN of them share $((2*N)) input lanes"
echo "   05_control / 03_request_gen / 04_drain_mux    the plumbing around it"
echo "   08_acc_init           where D = A@B + C is built (the addend)"
echo "   06_multiplier_gates   real logic gates -- the bridge to the textbook"
echo
echo "Netlist views: N=$N, coarse cells BEFORE technology mapping. Same"
echo "architecture as N=4, but NOT the mapped netlist and NOT a layout."
echo "Layout: work/reports/nangate45/*/base/final_*.webp, from 'make measure'."
