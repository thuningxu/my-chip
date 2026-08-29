#=============================================================================
# my-chip
#
# Run ./setup.sh once; it writes local.mk with the resolved tool paths so no
# target here needs you to export anything.
#
# NOTE: nothing in this Makefile invokes klayout at parse time. ORFS's own
# Makefile does (KLAYOUT_VERSION via $(shell ...)), which is why measure.sh
# always passes KLAYOUT_CMD explicitly.
#=============================================================================

N      ?= 4
PERIOD ?= 1.00
UTIL   ?= 40
TAG    ?=

# Schematics get their own size, defaulting to 2 rather than N. Readability is
# the entire point of that target and N=2 is a quarter of the drawing for the
# same architecture. Override with `make schematic SN=4`.
SN     ?= 2

# C_PORT=0 prunes the external-C preload hardware (INIT_C). Measured as its own
# row: the parameter is worthless if the flow cannot build both configurations.
CPORT  ?= 1

# OUT_PAR=1 reads all N*N results out in one cycle instead of draining them one
# per cycle: K+4 cycles instead of K+N*N+3. Defaults to 0 so `make measure` with
# no arguments still reproduces the published v0/f1 rows.
OUTPAR ?= 0

# Which design. mac_array is the INT4 outer-product baseline; amx_tdpbssd is the
# Intel AMX TDPBSSD implementation (INT8, 1024 multipliers, 16 cycles).
DESIGN ?= mac_array

# amx_tdpbssd only. SAT=0 wraps, which is BIT-EXACT Intel; SAT=1 saturates to
# INT32, which is a deliberate deviation. Both are built and measured.
SAT    ?= 1

-include local.mk

IVERILOG ?= iverilog
PYTHON   ?= python3
BUILD    := build

RTL := rtl/mac_array.v
TB  := tb/tb_mac_array.v

.DEFAULT_GOAL := help

#-----------------------------------------------------------------------------
.PHONY: help
help:
	@echo "my-chip -- INT4 MAC array hill-climbing project"
	@echo ""
	@echo "  make setup           check + install dependencies, write local.mk"
	@echo "  make check           check dependencies only, install nothing"
	@echo ""
	@echo "  make sim             run the regression            (N=$(N))"
	@echo "  make sim-amx         AMX TDPBSSD regression        (SAT=$(SAT))"
	@echo "  make sim-matrix      both designs, all parameter states (14 configs)"
	@echo "  make sim-all         run the regression at N=4,8,16"
	@echo "  make golden          run the Python reference model"
	@echo ""
	@echo "  make schematic       readable circuit schematics   (SN=$(SN))"
	@echo "                       coarse cells, pre-techmap. Per-config output:"
	@echo "                       $(BUILD)/schematic/<nick>/"
	@echo ""
	@echo "  make measure         sim-gated synth+P&R, print a QoR row"
	@echo "                       (DESIGN=$(DESIGN) N=$(N) CPORT=$(CPORT) OUTPAR=$(OUTPAR)"
	@echo "                        SAT=$(SAT) PERIOD=$(PERIOD) UTIL=$(UTIL))"
	@echo "  make gds             build+verify the GDS of a routed config"
	@echo "  make path            worst timing path of the last measure -- WHY"
	@echo "                       the clock is what it is"
	@echo "  make sweep-period    measure at 1.6/1.4/1.2/1.0 ns"
	@echo "  make sweep-n         measure at N=4,8,16"
	@echo ""
	@echo "  make clean           remove build/ (keeps work/)"
	@echo "  make prune-work      drop intermediate .odb from work/, keep results"
	@echo "  make clean-work      remove work/ -- all flow artifacts and images"
	@echo "  make distclean       clean + clean-work + remove local.mk"
	@echo ""
	@echo "  Override any variable: make measure N=8 PERIOD=1.4 UTIL=45"
	@echo ""
	@echo "  ORFS        = $(if $(ORFS),$(ORFS),$(shell printf '\033[31mUNSET -- run make setup\033[0m'))"
	@echo "  YOSYS_EXE   = $(YOSYS_EXE)"
	@echo "  KLAYOUT_CMD = $(KLAYOUT_CMD)"

#-----------------------------------------------------------------------------
.PHONY: setup check
setup:
	@./setup.sh

check:
	@./setup.sh --check

# Fail early and helpfully rather than emitting a confusing ORFS error.
.PHONY: require-setup
require-setup:
	@if [ ! -f local.mk ]; then \
	  echo "local.mk missing -- run 'make setup' first"; exit 1; fi
	@if [ -z "$(ORFS)" ]; then \
	  echo "ORFS unset in local.mk -- re-run 'make setup'"; exit 1; fi

#-----------------------------------------------------------------------------
# Simulation. This is the gate: if it fails, no PPA number is allowed to exist.
$(BUILD):
	@mkdir -p $(BUILD)

.PHONY: sim
# CPORT is passed here too: simulating a different configuration than the one
# `make measure` synthesises would make the gate meaningless. The artifact names
# carry it for the same reason.
sim: $(BUILD)
	@echo "== regression N=$(N) CPORT=$(CPORT) OUTPAR=$(OUTPAR) =="
	@$(IVERILOG) -g2005 -o $(BUILD)/tb_n$(N)_c$(CPORT)_r$(OUTPAR).vvp \
	  -Ptb_mac_array.N=$(N) -Ptb_mac_array.C_PORT=$(CPORT) \
	  -Ptb_mac_array.OUT_PAR=$(OUTPAR) $(TB) $(RTL)
	@vvp $(BUILD)/tb_n$(N)_c$(CPORT)_r$(OUTPAR).vvp \
	  | tee $(BUILD)/sim_n$(N)_c$(CPORT)_r$(OUTPAR).log
	@grep -q '^RESULT: PASS' $(BUILD)/sim_n$(N)_c$(CPORT)_r$(OUTPAR).log \
	  || { echo "regression FAILED"; exit 1; }

.PHONY: sim-all
sim-all:
	@for n in 4 8 16; do $(MAKE) --no-print-directory sim N=$$n || exit 1; done
	@echo "== all sizes PASS =="

# The full parameter matrix: 3 sizes x 2 C_PORT x 2 OUT_PAR. A parameter that is
# never built in both states is not a parameter, it is dead code with a name.
.PHONY: sim-matrix
sim-matrix:
	@for n in 4 8 16; do for c in 0 1; do for r in 0 1; do \
	  $(MAKE) --no-print-directory sim N=$$n CPORT=$$c OUTPAR=$$r >/dev/null \
	    && echo "  PASS  mac_array   N=$$n CPORT=$$c OUTPAR=$$r" \
	    || { echo "  FAIL  mac_array   N=$$n CPORT=$$c OUTPAR=$$r"; exit 1; }; \
	done; done; done
	@for s in 0 1; do \
	  $(MAKE) --no-print-directory sim-amx SAT=$$s >/dev/null \
	    && echo "  PASS  amx_tdpbssd SAT=$$s" \
	    || { echo "  FAIL  amx_tdpbssd SAT=$$s"; exit 1; }; \
	done
	@echo "== all 14 configurations PASS =="

.PHONY: sim-amx
# The AMX regression. Separate target rather than a DESIGN switch on `sim`,
# because the two testbenches take different parameters and silently accepting
# N= for a design that has no N would be worse than refusing it.
sim-amx: $(BUILD)
	@echo "== AMX TDPBSSD regression SAT=$(SAT) =="
	@$(IVERILOG) -g2005 -o $(BUILD)/tb_amx_s$(SAT).vvp \
	  -Ptb_amx_tdpbssd.SAT=$(SAT) tb/tb_amx_tdpbssd.v rtl/amx_tdpbssd.v
	@vvp $(BUILD)/tb_amx_s$(SAT).vvp | tee $(BUILD)/sim_amx_s$(SAT).log
	@grep -q '^RESULT: PASS' $(BUILD)/sim_amx_s$(SAT).log \
	  || { echo "AMX regression FAILED"; exit 1; }

.PHONY: golden
golden:
	@$(PYTHON) tb/golden.py --n $(N) --k 37 --seed 1
	@$(PYTHON) tb/amx_golden.py

#-----------------------------------------------------------------------------
# Schematics. Not gated on sim: these are drawings of the RTL, not claims about
# what it computes, so they are useful even while the design is broken.
.PHONY: schematic
schematic:
	@YOSYS_EXE="$(YOSYS_EXE)" ./scripts/schematic.sh -d $(DESIGN) -n $(SN) -c $(CPORT) \
	     -r $(OUTPAR) -s $(SAT)

#-----------------------------------------------------------------------------
# Physical flow. measure.sh re-runs the regression itself and refuses to
# produce a QoR row unless it passes.
.PHONY: measure
measure: require-setup
	@ORFS="$(ORFS)" YOSYS_EXE="$(YOSYS_EXE)" KLAYOUT_CMD="$(KLAYOUT_CMD)" \
	  ./scripts/measure.sh -d $(DESIGN) -n $(N) -c $(CPORT) -r $(OUTPAR) -s $(SAT) \
	     -p $(PERIOD) -u $(UTIL) $(if $(TAG),-t $(TAG),)

# Build/rebuild the GDS for an already-routed config, without re-running the
# flow. measure.sh does this inline now; this is for configs routed before that
# fix, or to regenerate. Verifies the stream, it does not just check the file.
.PHONY: gds
gds: require-setup
	@./scripts/gds.sh -d $(DESIGN) -n $(N) -c $(CPORT) -r $(OUTPAR) -s $(SAT) $(if $(TAG),-t $(TAG),)

# Why the clock is what it is. Requires a completed `make measure N=<N>`.
.PHONY: path
path: require-setup
	@./scripts/report_path.sh -d $(DESIGN) -n $(N) --cport $(CPORT) --outpar $(OUTPAR) \
	     --sat $(SAT) $(if $(TAG),-t $(TAG),)

.PHONY: sweep-period
sweep-period: require-setup
	@for p in 1.60 1.40 1.20 1.00; do \
	  $(MAKE) --no-print-directory measure PERIOD=$$p TAG=p$${p//./} || true; \
	done

.PHONY: sweep-n
sweep-n: require-setup
	@for n in 4 8 16; do \
	  $(MAKE) --no-print-directory measure N=$$n || true; \
	done

#-----------------------------------------------------------------------------
.PHONY: clean clean-work distclean
# `clean` deliberately does NOT touch work/: it holds every measured artifact
# (.odb/.def/.gds, layout images, metrics) and is easily 100+ MB per run.
# Losing it silently to a routine `make clean` would be a bad surprise.
clean:
	@rm -rf $(BUILD)
	@echo "cleaned $(BUILD)/  (work/ kept -- use 'make clean-work' to drop flow artifacts)"

clean-work:
	@printf "work/ is %s -- removing\n" "$$(du -sh work 2>/dev/null | cut -f1)"
	@rm -rf work
	@echo "removed work/"

# The middle ground between `clean` and `clean-work`. ORFS writes an .odb
# snapshot after every stage as a resume/debug point -- roughly 115 MB per
# config, and 311 MB of the 555 MB this repo had accumulated. None of it backs a
# row. This drops those and keeps everything that does:
#   6_final.odb/.sdc/.spef   report_path.sh reads exactly these, so `make path`
#                            keeps working -- verified, not assumed
#   6_final.def/.v           the routed design itself
#   6_report.json            the metrics every EXPERIMENTS.md row quotes
#   5_route_drc.rpt, *.webp  the DRC count and the layout images
#   6_final.gds              the layout itself -- the actual built chip
# Also drops 6_1_merged.gds: ORFS's rule is literally `cp $(GDS_MERGED_FILE)
# $(GDS_FINAL_FILE)`, so it is a byte-identical duplicate, and `make gds`
# regenerates it from 6_final.def if anything ever needs it.
# NOTE the parentheses around the whole alternation below. `find A -o B -delete`
# binds -delete to B only, so an unparenthesised version silently deleted the
# duplicate GDS and left every .odb in place while reporting success.
# A pruned config cannot be *resumed* mid-flow; re-run `make measure` for that.
.PHONY: prune-work
prune-work:
	@if [ ! -d work ]; then echo "no work/ to prune"; exit 0; fi
	@before=$$(du -sk work | cut -f1); \
	 expr='( ( -name *.odb ! -name 6_final.odb ) -o -name 6_1_merged.gds )'; \
	 n=$$(find work/results $$expr | wc -l | tr -d ' '); \
	 find work/results $$expr -delete; \
	 after=$$(du -sk work | cut -f1); \
	 printf "pruned %s intermediates -- work/ %.0f MB -> %.0f MB (freed %.0f MB)\n" \
	   "$$n" "$$(echo "$$before/1024" | bc -l)" "$$(echo "$$after/1024" | bc -l)" \
	   "$$(echo "($$before-$$after)/1024" | bc -l)"
	@echo "kept: 6_final.* ('make path' works), 6_report.json, DRC report, layout images"

distclean: clean clean-work
	@rm -f local.mk
	@echo "removed local.mk"
