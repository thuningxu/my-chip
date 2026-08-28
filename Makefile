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
	@echo "  make sim-all         run the regression at N=4,8,16"
	@echo "  make golden          run the Python reference model"
	@echo ""
	@echo "  make measure         sim-gated synth+P&R, print a QoR row"
	@echo "                       (N=$(N) PERIOD=$(PERIOD) UTIL=$(UTIL))"
	@echo "  make path            worst timing path of the last measure -- WHY"
	@echo "                       the clock is what it is"
	@echo "  make sweep-period    measure at 1.6/1.4/1.2/1.0 ns"
	@echo "  make sweep-n         measure at N=4,8,16"
	@echo ""
	@echo "  make clean           remove build/ (keeps work/)"
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
sim: $(BUILD)
	@echo "== regression N=$(N) =="
	@$(IVERILOG) -g2005 -o $(BUILD)/tb_n$(N).vvp -Ptb_mac_array.N=$(N) $(TB) $(RTL)
	@vvp $(BUILD)/tb_n$(N).vvp | tee $(BUILD)/sim_n$(N).log
	@grep -q '^RESULT: PASS' $(BUILD)/sim_n$(N).log \
	  || { echo "regression FAILED"; exit 1; }

.PHONY: sim-all
sim-all:
	@for n in 4 8 16; do $(MAKE) --no-print-directory sim N=$$n || exit 1; done
	@echo "== all sizes PASS =="

.PHONY: golden
golden:
	@$(PYTHON) tb/golden.py --n $(N) --k 37 --seed 1

#-----------------------------------------------------------------------------
# Physical flow. measure.sh re-runs the regression itself and refuses to
# produce a QoR row unless it passes.
.PHONY: measure
measure: require-setup
	@ORFS="$(ORFS)" YOSYS_EXE="$(YOSYS_EXE)" KLAYOUT_CMD="$(KLAYOUT_CMD)" \
	  ./scripts/measure.sh -n $(N) -p $(PERIOD) -u $(UTIL) $(if $(TAG),-t $(TAG),)

# Why the clock is what it is. Requires a completed `make measure N=<N>`.
.PHONY: path
path: require-setup
	@./scripts/report_path.sh -n $(N) $(if $(TAG),-t $(TAG),)

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

distclean: clean clean-work
	@rm -f local.mk
	@echo "removed local.mk"
