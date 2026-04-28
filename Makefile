VCS ?= vcs
SIMV ?= simv
VCS_FLAGS ?= -sverilog -full64 -debug_access+all -l vcs.log

PE_SV := pe_artur.sv
TB_SV := tb_pe_artur.sv

CIN ?= 1
PEQ ?= 1
SEED ?= 1
NIN ?= 1
OUTDIR ?= vectors

# expected outputs from generator (used as build artifacts)
WEIGHTS_FILE  := $(OUTDIR)/weights.txt
INPUTS_FILE   := $(OUTDIR)/inputs.txt
EXPECTED_FILE := $(OUTDIR)/expected.txt

.PHONY: all vectors build run clean

all: run

# Generate vectors only if missing or generator changed
vectors: $(WEIGHTS_FILE) $(INPUTS_FILE) $(EXPECTED_FILE)

$(WEIGHTS_FILE) $(INPUTS_FILE) $(EXPECTED_FILE): Golden_Model.py
	python3 Golden_Model.py \
		--cin $(CIN) --pe_qnt $(PEQ) --seed $(SEED) --n_inputs $(NIN) --out_dir $(OUTDIR)

# Build simv only if RTL/TB changed
build: $(SIMV)

$(SIMV): $(PE_SV) $(TB_SV)
	$(VCS) $(VCS_FLAGS) $(PE_SV) $(TB_SV) -o $(SIMV)

run: vectors build
	./$(SIMV) +VEC_DIR=$(OUTDIR) +CIN=$(CIN) +PEQ=$(PEQ) +NIN=$(NIN) | tee sim.log

clean:
	rm -rf $(SIMV) csrc simv.daidir ucli.key *.vpd *.log $(OUTDIR) sim.log vcs.log