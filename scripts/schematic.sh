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
# BOTH designs are drawn, with different strategies. mac_array is small enough
# that the views cut the whole array. amx_tdpbssd is not -- 1024 multipliers and
# 24,584 flops -- so its views show the UNIT it repeats (one DPBD), which is also
# where its one silent failure mode lives: which byte of A's dword meets which
# byte of B's dword.
#
# OUTPUT IS PER-CONFIGURATION. build/schematic/<nick>/, using the same nickname
# the measured artifacts use, so a figure set matches an EXPERIMENTS.md row. It
# was a single flat directory, which meant every run silently overwrote the last.
#
# Layout images are NOT produced here. ORFS already writes them during
# `make measure` to work/reports/nangate45/<nick>/base/final_*.webp. A layout
# is not a schematic and this script does not blur the two.
#
# Usage:  scripts/schematic.sh [-d DESIGN] [-n N] [-c C_PORT] [-r OUT_PAR]
#                             [-s SAT] [-o OUTDIR]
#
# -c selects the same C_PORT the RTL is built with. View 08 (the accumulator
# init path, i.e. where D = A@B + C happens) does not exist at C_PORT=0 and is
# skipped rather than drawn empty.
#
# -r selects OUT_PAR. Default 0, because the serial drain is the figure worth
# drawing: at OUT_PAR=1 view 04 is skipped, since the N*N:1 mux it shows has been
# deleted -- and a parallel readout is a bundle of wires with nothing to draw.
# Its absence IS the change.
# Requires: yosys, netlistsvg  (npm i -g netlistsvg)
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DESIGN=mac_array
# tpu_mmu. Schematics default to a SMALL array: readability is the entire point of
# this target and a 32x32 grid is not a readable page. TN=2 still shows the
# neighbour structure, which is the thing worth drawing.
TN=${TN:-2}; RDREG=${RDREG:-1}
# amx_fp8 accumulator arm. ACC=1 draws a DIFFERENT set of units, because the
# fixed-point arm does not instantiate fp8_mul at all.
ACC=${ACC:-0}; FXW=${FXW:-52}
N=2
CPORT=1
OUTPAR=0
SAT=1
OUT=""
YOSYS="${YOSYS_EXE:-yosys}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) DESIGN="$2"; shift 2 ;;
    -n) N="$2"; shift 2 ;;
    -c) CPORT="$2"; shift 2 ;;
    -r) OUTPAR="$2"; shift 2 ;;
    -s) SAT="$2"; shift 2 ;;
    -T) TN="$2"; shift 2 ;;
    -A) ACC="$2"; shift 2 ;;
    -W) FXW="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v "$YOSYS" >/dev/null \
  || { echo "FATAL: yosys not found. run 'make setup'" >&2; exit 1; }
command -v netlistsvg >/dev/null \
  || { echo "FATAL: netlistsvg not found.  npm i -g netlistsvg" >&2; exit 1; }

# shellcheck source=scripts/nick.sh
source "$HERE/scripts/nick.sh"

# Per-design: which RTL, which top, and the chparam string that configures it.
# The shared machinery below (caption/view/the three guards) is design-agnostic
# and reads these.
case "$DESIGN" in
  mac_array)
    RTL="$HERE/rtl/mac_array.v"
    TOPMOD=mac_array
    CHPARAM="-set N $N -set C_PORT $CPORT -set OUT_PAR $OUTPAR"
    CFG_DESC="N=$N C_PORT=$CPORT OUT_PAR=$OUTPAR"
    NICK="$(nick "$N" "$CPORT" "" "$OUTPAR")"
    ;;
  amx_tdpbssd)
    RTL="$HERE/rtl/amx_tdpbssd.v"
    TOPMOD=amx_tdpbssd
    CHPARAM="-set SAT $SAT"
    CFG_DESC="SAT=$SAT"
    NICK="$(nick_amx "$SAT")"
    ;;
  tpu_mmu)
    RTL="$HERE/rtl/tpu_mmu.v"
    TOPMOD=tpu_mmu
    CHPARAM="-set N $TN -set RD_REG $RDREG"
    CFG_DESC="N=$TN RD_REG=$RDREG"
    NICK="$(nick_tpu "$TN")"
    ;;
  amx_fp8)
    RTL="$HERE/rtl/amx_fp8.v $HERE/rtl/fp8_mul.v $HERE/rtl/fp32_add.v"
    RTL="$RTL $HERE/rtl/fx2fp32.v $HERE/rtl/maxmag64.v"
    TOPMOD=amx_fp8
    CHPARAM="-set RD_REG $RDREG -set ACC $ACC -set FX_W $FXW"
    if [[ "$ACC" == "0" ]]; then
      CFG_DESC="RD_REG=$RDREG ACC=0"
    else
      CFG_DESC="RD_REG=$RDREG ACC=1 FX_W=$FXW"
    fi
    NICK="$(nick_fp8 "$ACC" "$FXW")"
    ;;
  *)
    echo "FATAL: unknown design '$DESIGN'. Known: mac_array, amx_tdpbssd, tpu_mmu, amx_fp8" >&2
    exit 2 ;;
esac

# OUTPUT GOES IN A CONFIG-SPECIFIC DIRECTORY, reusing the same nickname the
# measured artifacts use, so a schematic set can be matched to an EXPERIMENTS.md
# row. It used to be a single build/schematic/, which meant every run silently
# overwrote the previous one -- a C_PORT=0 set replacing a C_PORT=1 set, or SN=4
# replacing SN=2, with only the caption to tell you it had happened. Captions are
# still there, but a caption is a mitigation and a distinct path is a fix.
OUT="${OUT:-$HERE/build/schematic/$NICK}"

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


echo "== schematics: $DESIGN ($CFG_DESC) -> $OUT =="

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
chparam $CHPARAM $TOPMOD
prep -top $TOPMOD
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
  caption "$OUT/$name.svg" "$title" "$DESIGN $CFG_DESC | $sub"

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


# ============================== mac_array views ==============================
# Anchors live INSIDE the function: anchor() aborts when a pattern is missing,
# and every pattern here is mac_array-specific, so running them for another
# design would kill the script rather than skip the views.
views_mac_array() {
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
#
# At OUT_PAR=1 none of it exists: out_all is a concatenation of the accumulator
# outputs, so the mux, both counters, the index multiply-add and the address
# decode are all pruned (-911 cells, measured). There is no figure to draw --
# the replacement is wires -- so this is skipped rather than faked.
if [[ "$OUTPAR" == "0" ]]; then
  view 04_drain_mux \
    "Result readout -- the $NN:1 accumulator mux, decode and index arithmetic" \
    "rtl/mac_array.v:$L_DRN + %co8 (one line of RTL becomes all of this)" \
    '$mul,$add,$eq,$pmux,$adff' \
    "$(c "$L_DRN") %co8"
else
  printf '   %-26s %s\n' "04_drain_mux.svg" \
    "SKIPPED -- OUT_PAR=1 pruned the ${NN}:1 mux; the readout is now plain wires"
fi

# ---- 5. control ----------------------------------------------------------
# Every control register plus the arithmetic computing its next value. This
# is the hardware that replaces the program counter a software loop has.
#
# The drow/dcol anchors have to come OUT at OUT_PAR=1. Their RTL lines still
# exist (inside the else branch) so anchor() still resolves them, but the cells
# are pruned -- and a select pattern matching no cell is exactly what GUARD 1
# treats as a moved anchor. It would abort the whole run.
CTRL_LINES="$L_K0 $L_ISS $L_CON $L_EQK"
CTRL_DESC="$L_K0,$L_ISS,$L_CON,$L_EQK"
if [[ "$OUTPAR" == "0" ]]; then
  CTRL_LINES="$CTRL_LINES $L_ROW $L_COL"
  CTRL_DESC="$CTRL_DESC,$L_ROW,$L_COL"
fi
view 05_control \
  "Control -- every state register and the logic that advances it" \
  "rtl/mac_array.v:$CTRL_DESC + %co1 + all registers" \
  '$add,$eq,$adff' \
  "$(c $CTRL_LINES) %co1" 't:$adff'

# ---- 6. real logic gates -- the bridge to the textbook -------------------
# Everything above is coarse blocks. This is ONE 4x4 signed multiplier
# decomposed into gates. Deliberately NOT run through abc: techmap's
# structural output still resembles an array multiplier, whereas abc
# optimises it into an unrecognisable soup.
cat > "$OUT/06_multiplier_gates.ys" <<EOF
read_verilog $RTL
chparam -set N $N -set C_PORT $CPORT -set OUT_PAR $OUTPAR mac_array
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
STATES=$("$YOSYS" -p "read_verilog $RTL; chparam -set N $N -set C_PORT $CPORT -set OUT_PAR $OUTPAR mac_array; \
prep -top mac_array; fsm_detect; fsm_extract; fsm_info" 2>/dev/null \
  | sed -n '/State encoding:/,/Transition Table/p' \
  | grep -cE "^[[:space:]]+[0-9]+:[[:space:]]+2'" || true)
if [[ "$STATES" != "3" ]]; then
  echo "FATAL: yosys fsm_extract reports $STATES states, but 07_fsm_states.svg" >&2
  echo "       is hand-drawn for 3 (IDLE/RUN/DRAIN). Redraw it or fix the RTL." >&2
  exit 1
fi

# The DRAIN state's behaviour is the one thing OUT_PAR changes, so the two arcs
# that describe it are substituted rather than hardcoded. At OUT_PAR=1 there is
# genuinely no drain self-loop -- S_DRAIN strobes once and leaves -- so drawing
# one would make the figure lie about the design it is captioned as.
if [[ "$OUTPAR" == "0" ]]; then
  NTRANS=9
  DRAIN_LOOP_A="out_we&lt;=1, one result per cycle"
  DRAIN_LOOP_C="else"
  DRAIN_LOOP_ARC='<path class="e" d="M896,203 C876,172 964,172 944,203"/>'
  DRAIN_EXIT_C="drow == N-1 &amp;&amp; dcol == N-1"
  DRAIN_EXIT_A="done&lt;=1, busy&lt;=0 &#8212; but out_we is STILL 1 this cycle, carrying the LAST result"
  DRAIN_NOTE="S_DRAIN always runs N*N cycles, whatever K is. Compute efficiency = K/(K + N*N)."
else
  NTRANS=8
  DRAIN_LOOP_A="(no self-loop: one cycle and out)"
  DRAIN_LOOP_C=""
  DRAIN_LOOP_ARC=""
  DRAIN_EXIT_C="unconditional (OUT_PAR=1)"
  DRAIN_EXIT_A="out_we&lt;=1 strobes ONCE; out_all already shows all N*N accumulators"
  DRAIN_NOTE="S_DRAIN runs 1 cycle: out_all is combinational, so there is nothing to sequence. Compute efficiency = K/(K + 4)."
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

<text x="14" y="28" class="s" font-size="18">mac_array control FSM &#8212; N=$N, C_PORT=$CPORT, OUT_PAR=$OUTPAR</text>
<text x="14" y="49" class="n">3 states / $NTRANS transitions &#8212; the state count is verified against yosys fsm_extract every time this is regenerated.</text>
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
<text x="920" y="146" class="a" text-anchor="middle">$DRAIN_LOOP_A</text>
<text x="920" y="160" class="c" text-anchor="middle">$DRAIN_LOOP_C</text>
<path class="e" d="M146,203 C126,172 214,172 194,203"/>
<path class="e" d="M521,203 C501,172 589,172 569,203"/>
$DRAIN_LOOP_ARC

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
<text x="545" y="416" class="c" text-anchor="middle">$DRAIN_EXIT_C</text>
<text x="545" y="431" class="a" text-anchor="middle">$DRAIN_EXIT_A</text>

<text x="14" y="464" class="n">Cost: S_RUN runs k_dim+1 cycles (the +1 is SRAM read latency). $DRAIN_NOTE</text>
</svg>
EOF
printf '   %-26s %s\n' "07_fsm_states.svg" \
  "3 states / $NTRANS transitions (hand-drawn, guarded by fsm_extract)"

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

}

# ============================= amx_tdpbssd views =============================
# The array itself is not drawable -- 1024 identical multipliers. But the UNIT it
# repeats is, and that unit is where the instruction's one silent failure mode
# lives: which byte of A's dword meets which byte of B's dword. So the figures
# here are one DPBD, the saturating fold, the control FSM, and one multiplier at
# gate level. No anchors: this design's cells are named by hierarchy path
# (g_m[0].g_n[0].sum4), which is stabler than a line number and needs no grep.
views_amx_tdpbssd() {

  # ---- 1. one DPBD -- the unit the instruction repeats 256 times ------------
  # 4 INT8 products -> adder tree -> 32-bit accumulate -> the fold. This is the
  # figure that shows the BYTE PAIRING: byte b of A's dword k multiplied by byte
  # b of B's dword n, four of them summed. Get that wrong and the instruction
  # transposes silently.
  #
  # Cell count differs by SAT, and the difference IS the saturation cost:
  #   SAT=1  12 cells   mul=4 add=4 mux=3 xor=1
  #   SAT=0  10 cells   mul=4 add=4 mux=2        <- no xor: ovf is pruned
  #
  # The accumulator flop is NOT in this cut. %co stops before it because all 256
  # accumulators share one mem2reg read structure, and forcing it in would drag
  # in all of them. Said here rather than pretended away.
  view 01_dpbd \
    "One DPBD unit -- 4 INT8 products, adder tree, INT32 accumulate" \
    "select prod* %ci1 %co7. The unit repeated 256x. Accumulator flop is OUTSIDE this cut." \
    '$mul,$add' \
    'w:g_m[0].g_n[0].prod* %ci1 %co7'

  # exactly four multipliers, or this is not one DPBD
  python3 - "$OUT/01_dpbd.json" <<'PY' || exit 1
import collections, json, sys
d = json.load(open(sys.argv[1]))
h = collections.Counter(c['type'] for m in d['modules'].values()
                        for c in m['cells'].values())
if h['$mul'] != 4:
    sys.exit("FATAL: 01_dpbd holds %d multipliers, expected exactly 4 -- a DPBD "
             "is four byte products by definition. Got: %s" % (h['$mul'], dict(h)))
PY

  # ---- 2. the saturating fold -- the deviation from Intel -------------------
  # Intel's DPBD wraps. This is the hardware that does not. 33-bit add, the
  # ovf = raw[32]^raw[31] detect, the rail select, the fold mux. It does not
  # exist at SAT=0, which is the point of showing it separately.
  if [[ "$SAT" != "0" ]]; then
    view 02_saturate \
      "The saturating fold -- INT32 clamp, a DELIBERATE deviation from Intel" \
      "select raw %ci1 %co3. ovf = raw[32]^raw[31]; the rail is chosen by raw[32]." \
      '$xor,$mux' \
      'w:g_m[0].g_n[0].raw %ci1 %co3'
  else
    printf '   %-26s %s\n' "02_saturate.svg" \
      "SKIPPED -- SAT=0 wraps (bit-exact Intel); there is no fold hardware"
  fi

  # ---- 3. control ----------------------------------------------------------
  # Two states and a 4-bit k counter. Contrast mac_array, which needs two KW-bit
  # counters and three comparators: this instruction has a FIXED trip count, so
  # the control is almost nothing.
  view 03_control \
    "Control -- 2 states, one 4-bit k counter, 16 fixed steps" \
    "select t:\$adff %ci3. A fixed trip count needs no comparator against a runtime bound." \
    '$adff' \
    't:$adff %ci3'

  # ---- 4. one INT8 multiplier at gate level --------------------------------
  # The bridge to the textbook, and the scale of the thing: mac_array's 4x4
  # signed multiplier is 84 gates, this 8x8 is 407 -- ~5x for 2x the width.
  # Deliberately NOT run through abc, same reason as mac_array's view 06:
  # techmap's structural output still resembles an array multiplier.
  cat > "$OUT/04_multiplier_gates.ys" <<EOF
read_verilog $RTL
chparam $CHPARAM $TOPMOD
prep -top $TOPMOD
select -set m w:g_m[0].g_n[0].prod[0] %ci1
submod -name mult8x8 @m
hierarchy -top mult8x8
techmap
opt -fast
opt_clean
write_json $OUT/04_multiplier_gates.json
EOF
  "$YOSYS" -q -s "$OUT/04_multiplier_gates.ys" 2>"$OUT/04_multiplier_gates.yslog" \
    || { echo "FATAL: yosys failed for 04_multiplier_gates -- see the yslog" >&2; exit 1; }
  netlistsvg "$OUT/04_multiplier_gates.json" -o "$OUT/04_multiplier_gates.svg" \
    >/dev/null 2>&1 || { echo "FATAL: netlistsvg failed for 04_multiplier_gates" >&2; exit 1; }
  MG=$(python3 -c "import json; d=json.load(open('$OUT/04_multiplier_gates.json')); \
print(sum(len(m['cells']) for m in d['modules'].values()))")
  caption "$OUT/04_multiplier_gates.svg" \
    "One 8x8 signed INT8 multiplier, decomposed to $MG logic gates" \
    "$DESIGN $CFG_DESC | ONE of the 1024. mac_array's 4x4 is 84 gates; 2x the width costs ~5x."
  printf '   %-26s %s\n' "04_multiplier_gates.svg" "$MG 2-input gates"

  echo
  echo "Read them in this order:"
  echo "   03_control            2 states, a 4-bit counter -- 16 fixed steps"
  echo "   01_dpbd               the unit repeated 256x, and the BYTE PAIRING"
  echo "   02_saturate           the INT32 clamp (absent at SAT=0)"
  echo "   04_multiplier_gates   real gates -- the bridge to the textbook"
  echo
  echo "Coarse cells BEFORE technology mapping. The full design is 407,034"
  echo "stdcells and 24,584 flops; no cut of the whole array is a readable page,"
  echo "which is why these show the repeated UNIT instead."
}

# ---------------------------------------------------------------- tpu_mmu ----
# The point of drawing this design is the CONTRAST with amx_tdpbssd: there, one
# operand row broadcasts to 16 units through a 16:1 mux. Here every PE talks only
# to its right and lower neighbour, so the figures that matter are a single PE and
# the accumulator that sits outside the array. Names are hierarchy paths
# (g_row[0].g_col[0]), not line anchors, for the same reason as the amx views.
views_tpu_mmu() {

  # ---- 1. one PE -- the unit repeated N*N times ----------------------------
  # One INT8xINT8 multiply, one psum add, and the registers that make the hops
  # systolic. Compare against 01_dpbd of amx_tdpbssd: that unit is 4 multipliers
  # plus a 3-level tree plus a saturating fold, all inside the accumulate loop.
  # This one is a multiply and an add, and nothing in it is in a loop at all.
  view 01_pe \
    "One PE -- one INT8 multiply, one psum add, one partial-sum register" \
    "select prod %ci1 %co3. Repeated N*N times; at TN=32 that is 1024 of these." \
    '$mul,$add' \
    'w:g_row[0].g_col[0].prod %ci1 %co3'

  # A PE is ONE multiplier. More than that means the selection pulled in a
  # neighbour and the figure is lying about what the unit is. %co2 was the first
  # attempt and reached all four PEs at N=2, which this guard caught.
  python3 - "$OUT/01_pe.json" <<'PECHK' || exit 1
import collections, json, sys
d = json.load(open(sys.argv[1]))
h = collections.Counter(c['type'] for m in d['modules'].values()
                        for c in m.get('cells', {}).values())
n = h.get('$mul', 0)
if n != 1:
    sys.exit("FATAL: 01_pe has %d multipliers, expected exactly 1 -- the cut is "
             "not one PE" % n)
print("   01_pe: 1 multiplier, %d adder(s), %d flop(s)"
      % (h.get('$add', 0), h.get('$adff', 0) + h.get('$dff', 0)))
PECHK

  # NO ACCUMULATOR VIEW, and this is deliberate rather than an omission. The
  # architectural point worth drawing is that the accumulators sit OUTSIDE the
  # array, so the array is pure feed-forward and only this one adder is in a
  # loop -- but no coarse selection isolates a single accumulator. Every cut
  # tried (acc* %ci2 %co1, and the fire enable at %ci3 %co3) either pulled in
  # all N*N accumulators or missed the adder entirely, because they share the
  # readback mux structure. Said here rather than shipping a figure that claims
  # to show one accumulator and shows four.

  echo
  echo "Views written to $OUT:"
  echo "   01_pe                 the repeated unit -- one multiply, one add"
  echo
  echo "Coarse cells BEFORE technology mapping, drawn at N=$TN. At N=32 the array"
  echo "is 1024 PEs and no cut of the whole thing is a readable page, which is why"
  echo "these show the repeated unit instead."
}

views_amx_fp8() {

  # THE REPEATED UNITS ARE ALREADY SEPARATE MODULES, so unlike mac_array and
  # tpu_mmu there is no selection surgery to do: drawing fp8_mul and fp32_add on
  # their own IS drawing the unit that is instantiated a thousand times. view()
  # reads $TOPMOD and $CHPARAM as globals, so retargeting it is a matter of
  # setting them -- and CHPARAM must be emptied, because `chparam -set RD_REG`
  # against a module that has no such parameter is an error, not a no-op.
  #
  # The view NAMES deliberately are not 01_fp8_mul etc: view() names the module
  # it extracts after the view with its NN_ prefix stripped, so that would try to
  # create a second module called fp8_mul and yosys aborts on the name clash.
  local save_top="$TOPMOD" save_par="$CHPARAM"
  CHPARAM=""

  # ---- 1. the fp8 multiplier -- and it is SMALLER than the INT8 one ---------
  # Both formats decode to a common 4-bit left-aligned significand, so one 4x4
  # unsigned multiply serves all four instructions. Compare 01_dpbd of
  # amx_tdpbssd: that unit is four 8x8 multipliers and a 3-level tree. The cost
  # of FP8 is not in the multiply.
  TOPMOD=fp8_mul
  view 01_mul8 \
    "fp8_mul -- one 4x4 significand multiply, exact into FP32" \
    "Instantiated 1024 times. Products NEVER round: 4+4 significand bits fit FP32's 24." \
    '$mul' \
    '*'

  # THE claim of this figure is "one 4x4 multiply". Assert it, the way
  # views_tpu_mmu does -- that guard is what caught a view captioned as one PE
  # that actually contained four.
  python3 - "$OUT/01_mul8.json" <<'MULCHK' || exit 1
import collections, json, sys
d = json.load(open(sys.argv[1]))
h = collections.Counter(c['type'] for m in d['modules'].values()
                        for c in m.get('cells', {}).values())
n = h.get('$mul', 0)
if n != 1:
    sys.exit("FATAL: 01_mul8 has %d multipliers, expected exactly 1" % n)
print("   01_mul8: exactly 1 multiplier (4x4), %d adder(s)" % h.get('$add', 0))
MULCHK

  # ---- 2. the fp8 decoder --------------------------------------------------
  # 128 of these on the array edges (16 rows x 4 lanes for A, 16 dwords x 4 for
  # B), shared by all 256 cells rather than one inside each multiplier.
  TOPMOD=fp8_dec
  view 02_dec8 \
    "fp8_dec -- E5M2 or E4M3 to a common significand, DAZ" \
    "One bit selects the format. exp==15 in E4M3 is a NORMAL, not a special." \
    '' \
    '*'

  # ---- 3. THE FLOOR ---------------------------------------------------------
  # This is the block the whole experiment is about: align, add, count leading
  # zeros, renormalise, round. Three barrel shifters and a carry chain in
  # series, 1198 mapped cells, and it sits inside the accumulate FEEDBACK loop
  # 1024 times over. amx_tdpbssd's equivalent loop is a 33-bit integer add.
  #
  # Under ACC=1 there are only 256 of these and NONE of them is in the loop --
  # they do the += C once per element, in the epilogue. That relocation is the
  # entire X2 hypothesis, so the caption has to say which arm it is describing.
  TOPMOD=fp32_add
  if [[ "$ACC" == "0" ]]; then
    view 03_add32 \
      "fp32_add -- the accumulate loop, and the predicted critical path" \
      "1024 instances, each in a feedback loop. Align + add + LZC + normalise + round." \
      '' \
      '*'
  else
    view 03_add32 \
      "fp32_add -- ACC=1 uses it ONCE per element, for the += C only" \
      "256 instances, none in the accumulate loop. Compare ACC=0: 1024, all in the loop." \
      '' \
      '*'
  fi

  # ---- 4 and 5. the ACC=1 units --------------------------------------------
  # NAMES: 04_fxcvt and 05_maxmag, not 04_fx2fp32 -- view() names the module it
  # extracts after the view with the NN_ prefix stripped, so 04_fx2fp32 tries to
  # create a SECOND module called fx2fp32 and yosys aborts with
  # `Assert modules_.count(module->name) == 0 failed`. Same reason 01_mul8 is not
  # called 01_fp8_mul. 05_maxmag is safe because the module is maxmag64.
  if [[ "$ACC" != "0" ]]; then
    # What replaced fp32_add inside the loop. The LZC, normalise shifter and
    # rounder still exist -- they have just moved OUT of the accumulation and into
    # a once-per-element epilogue, which is the whole arithmetic argument.
    TOPMOD=fx2fp32
    CHPARAM="-set ACC_W $FXW"
    view 04_fxcvt \
      "fx2fp32 -- the ONE rounding, moved out of the loop" \
      "256 instances. LZC + normalise + RNE, once per element instead of 64 times." \
      '' \
      '*'

    # How the alignment reference is found. 63 comparators, 6 levels, and it runs
    # on the start edge rather than in the loop.
    TOPMOD=maxmag64
    CHPARAM=""
    view 05_maxmag \
      "maxmag64 -- the alignment reference, 64 bytes to one exponent" \
      "32 instances, evaluated once on the start edge. Keys on byte[6:0], so one tree serves both FP8 formats." \
      '' \
      '*'
  fi

  TOPMOD="$save_top"; CHPARAM="$save_par"

  echo
  echo "Views written to $OUT:"
  echo "   01_mul8            the multiply -- 4x4, smaller than INT8's 8x8"
  echo "   02_dec8            format decode, one bit picks E5M2 or E4M3"
  if [[ "$ACC" == "0" ]]; then
    echo "   03_add32           the accumulate loop: THIS is the frequency floor"
    echo
    echo "Coarse cells BEFORE technology mapping. The array itself is 1024 of unit 1"
    echo "and 1024 of unit 3; no cut of the whole thing is a readable page, which is"
    echo "why these show the repeated units instead."
  else
    echo "   03_add32           now only the += C, 256 instances, OUT of the loop"
    echo "   04_fxcvt           the one rounding per element, FX_W=$FXW"
    echo "   05_maxmag          the alignment reference, once on the start edge"
    echo
    echo "Coarse cells BEFORE technology mapping. Unit 1 is still 1024 instances, but"
    echo "the loop now holds a CSA tree and one $FXW-bit adder instead of unit 3 --"
    echo "which is what X2 exists to measure."
  fi
}

# ============================== dispatch =====================================
views_"$DESIGN"
