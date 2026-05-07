VCS ?= vcs
VCS_FLAGS ?= -sverilog -full64 -debug_access+all -l vcs.log
SIMV ?= simv

PE_SV := pe_artur.sv
TB_SV := tb_pe_artur.sv

# -------------------------------
# IMPORTANT PARAMETERS
# -------------------------------

# Software / workload parameters
PEQNT ?= 16
CIN   ?= 16
KX    ?= 3
KY    ?= 3

# Hardware parameters attached to software
SIMD ?= 64

# Hardware parameters
PE           ?= 16
MAX_CHANNELS ?= 16
KERNEL_X     ?= 3
KERNEL_Y     ?= 3

# Testing parameters
SEED ?= 5
NIN  ?= 5

# Memory model parameters
FCLK_HZ    ?= 1e9
USE_FCLK_SYNTH ?= False
MEM_B_GBPS ?= 30.0
MEM_L_S    ?= 2e-9
DATA_WIDTH ?= 8

# -------------------------------
# Unified Working Directory (Prevents Disk Bloat)
# -------------------------------
WORKDIR       := work
SIMV_BIN      := $(WORKDIR)/simv
WEIGHTS_FILE  := $(WORKDIR)/weights.txt
INPUTS_FILE   := $(WORKDIR)/inputs.txt
EXPECTED_FILE := $(WORKDIR)/expected.txt

# Descriptive name saved ONLY for the final log result
RUN_ID := cin$(CIN)_kx$(KX)_ky$(KY)_peq$(PEQNT)_simd$(SIMD)_pe$(PE)_mc$(MAX_CHANNELS)_seed$(SEED)_nin$(NIN)_clk$(FCLK_HZ)_bw$(MEM_B_GBPS)_lat$(MEM_L_S)
RESULTS_DIR := results

.PHONY: all vectors build run clean printcfg FORCE

all: run

printcfg:
	@echo "--- Configuration ---"
	@echo "MAX_DOT_LANES=$(MAX_DOT_LANES) | MAX_FOLDS=$(MAX_FOLDS) | PAD_LANES=$(PAD_LANES)"
	@echo "MAX_INPUT_DIM=$(MAX_INPUT_DIM) | MAX_OUTPUT_DIM=$(MAX_OUTPUT_DIM)"
	@echo "RUN_ID=$(RUN_ID)"

vectors: $(WEIGHTS_FILE)

# FORCE ensures Golden_Model.py runs even if weights.txt already exists
$(WEIGHTS_FILE): Golden_Model.py FORCE
	@mkdir -p $(WORKDIR)
	python3 Golden_Model.py \
		--cin $(CIN) --kx $(KX) --ky $(KY) \
		--pe_qnt $(PEQNT) --simd $(SIMD) \
		--seed $(SEED) --n_inputs $(NIN) --out_dir $(WORKDIR)

build: $(SIMV_BIN)

# FORCE ensures VCS recompiles the hardware with the latest parameters
$(SIMV_BIN): $(PE_SV) $(TB_SV) FORCE
	@mkdir -p $(WORKDIR)
	$(VCS) $(VCS_FLAGS) $(PE_SV) $(TB_SV) -o $(SIMV_BIN) \
		-pvalue+tb_pe.SIMD=$(SIMD) \
		-pvalue+tb_pe.PE=$(PE) \
		-pvalue+tb_pe.DATA_WIDTH=$(DATA_WIDTH) \
		-pvalue+tb_pe.MAX_CHANNELS=$(MAX_CHANNELS) \
		-pvalue+tb_pe.KERNEL_X=$(KERNEL_X) \
		-pvalue+tb_pe.KERNEL_Y=$(KERNEL_Y) \
		-pvalue+tb_pe.dut.SIMD=$(SIMD) \
		-pvalue+tb_pe.dut.PE=$(PE) \
		-pvalue+tb_pe.dut.DATA_WIDTH=$(DATA_WIDTH) \
		-pvalue+tb_pe.dut.MAX_CHANNELS=$(MAX_CHANNELS) \
		-pvalue+tb_pe.dut.KERNEL_X=$(KERNEL_X) \
		-pvalue+tb_pe.dut.KERNEL_Y=$(KERNEL_Y)

# Run the simulation and save the log to a permanent results folder
run: vectors build
	@mkdir -p $(RESULTS_DIR)
	./$(SIMV_BIN) \
		+VEC_DIR=$(WORKDIR) \
		+CIN=$(CIN) +KX=$(KX) +KY=$(KY) \
		+PEQNT=$(PEQNT) +NIN=$(NIN) \
		+FCLK_HZ=$(FCLK_HZ) +MEM_L_S=$(MEM_L_S) +MEM_B_GBPS=$(MEM_B_GBPS) \
		| tee $(RESULTS_DIR)/sim_$(RUN_ID).log
	@echo "Log saved to: $(RESULTS_DIR)/sim_$(RUN_ID).log"

clean:
	rm -rf $(WORKDIR) $(RESULTS_DIR) csrc *.daidir ucli.key *.vpd *.log vcs.log