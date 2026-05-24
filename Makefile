VCS ?= vcs
VCS_FLAGS ?= -sverilog -full64 \
             -debug_access+all \
             -debug_region+cell+lib \
             -l vcs.log

DC_SHELL ?= dc_shell
PT_SHELL ?= pt_shell
VCD2SAIF ?= vcd2saif

PE_SV := pe_artur.sv
TB_SV := tb_pe_artur.sv

# -------------------------------
# IMPORTANT PARAMETERS
# -------------------------------

# Hardware parameters attached to software
SIMD ?= 16
DATA_WIDTH ?= 8

# Hardware parameters
PE           ?= 32
MAX_CHANNELS ?= 56
KERNEL_X     ?= 3
KERNEL_Y     ?= 3
# Below is the TARGET frequency used for synthesis/STA.
FCLK_HZ      ?= 7e7

# Software / workload parameters
PEQNT ?= 32
CIN   ?= 56
KX    ?= 3
KY    ?= 3

# Testing parameters
SEED ?= 3
NIN  ?= 4

# Memory model parameters
USE_FCLK_SYNTH  ?= True
MEM_B_GBPS      ?= 100
MEM_L_S         ?= 2e-9

# SAED14 library
SAED14_LIB_DB ?= $(HOME)/SAED_LIB/lib/stdcell_lvt/db_ccs/saed14lvt_tt0p8v25c.db

# Synthesis target clock used by DC as starting point (PT reports actual slack/Fmax)
CLK_PERIOD_NS := $(shell awk "BEGIN {printf \"%.2f\", 1e9 / $(FCLK_HZ)}")

# -------------------------------
# Directories & IDs
# -------------------------------
WORKDIR      := work
RESULTS_DIR  := results
SYN_DIR      := syn

SIMV_BIN     := $(WORKDIR)/simv
CFG_SVH      := $(WORKDIR)/rtl_cfg.svh

# IDs - Separating Hardware from Software Workloads
HARDWARE_ID  := simd$(SIMD)_pe$(PE)_maxchannels$(MAX_CHANNELS)_tgtclkfreq$(FCLK_HZ)
SIM_ID       := $(HARDWARE_ID)_cin$(CIN)_peqnt$(PEQNT)_seed$(SEED)_nin$(NIN)_bw$(MEM_B_GBPS)_lat$(MEM_L_S)

# Nested Directory Paths
HW_DIR       := $(RESULTS_DIR)/$(HARDWARE_ID)
DC_DIR       := $(HW_DIR)/dc
PT_DIR       := $(HW_DIR)/pt
SIM_OUT_DIR  := $(HW_DIR)/sim

PT_LOG       := $(PT_DIR)/pt_$(HARDWARE_ID).log

FMAX_FILE    := $(WORKDIR)/fmax_hz_$(HARDWARE_ID).txt

WEIGHTS_FILE  := $(WORKDIR)/weights.txt
INPUTS_FILE   := $(WORKDIR)/inputs.txt
EXPECTED_FILE := $(WORKDIR)/expected.txt

# Activity files
VCD_FILE     := $(WORKDIR)/dut.vcd
SAIF_FILE    := $(WORKDIR)/dut.saif

# -------------------------------
# Parameter/signature stamps (drive rebuilds only when inputs change)
# -------------------------------
CFG_STAMP   := $(WORKDIR)/.cfg_params.stamp
VEC_STAMP   := $(WORKDIR)/.vec_params.stamp
SIM_STAMP   := $(WORKDIR)/.sim_params.stamp
SYN_STAMP   := $(WORKDIR)/.syn_params.stamp
STA_STAMP   := $(WORKDIR)/.sta_params.stamp
POWER_STAMP := $(WORKDIR)/.power_params.stamp

# Synthesis/STA outputs
NETLIST_V := $(WORKDIR)/netlist/pe_mapped.v
NETLIST_SDC := $(WORKDIR)/netlist/pe_mapped.sdc

.PHONY: all cfg vectors build sim synth sta saif power clean FORCE
all: sim

# -------------------------------
# Stamps (cmp trick)
# -------------------------------

$(CFG_STAMP): $(SYN_DIR)/dc/run_dc.tcl Makefile FORCE
	@mkdir -p $(WORKDIR)
	@printf "%s\n" \
		"SIMD=$(SIMD)" \
		"PE=$(PE)" \
		"MAX_CHANNELS=$(MAX_CHANNELS)" \
		"KERNEL_X=$(KERNEL_X)" \
		"KERNEL_Y=$(KERNEL_Y)" \
		"DATA_WIDTH=$(DATA_WIDTH)" \
		> $@.tmp
	@cmp -s $@.tmp $@ || mv $@.tmp $@
	@rm -f $@.tmp

$(VEC_STAMP): FORCE
	@mkdir -p $(WORKDIR)
	@printf "%s\n" \
		"CIN=$(CIN)" \
		"KX=$(KX)" \
		"KY=$(KY)" \
		"PEQNT=$(PEQNT)" \
		"SIMD=$(SIMD)" \
		"SEED=$(SEED)" \
		"NIN=$(NIN)" \
		> $@.tmp
	@cmp -s $@.tmp $@ || mv $@.tmp $@
	@rm -f $@.tmp

$(SIM_STAMP): FORCE
	@mkdir -p $(WORKDIR)
	@printf "%s\n" \
		"SIMD=$(SIMD)" \
		"PE=$(PE)" \
		"MAX_CHANNELS=$(MAX_CHANNELS)" \
		"KERNEL_X=$(KERNEL_X)" \
		"KERNEL_Y=$(KERNEL_Y)" \
		"DATA_WIDTH=$(DATA_WIDTH)" \
		> $@.tmp
	@cmp -s $@.tmp $@ || mv $@.tmp $@
	@rm -f $@.tmp

$(SYN_STAMP): FORCE
	@mkdir -p $(WORKDIR)
	@printf "%s\n" \
		"SIMD=$(SIMD)" \
		"PE=$(PE)" \
		"MAX_CHANNELS=$(MAX_CHANNELS)" \
		"KERNEL_X=$(KERNEL_X)" \
		"KERNEL_Y=$(KERNEL_Y)" \
		"DATA_WIDTH=$(DATA_WIDTH)" \
		"SAED14_LIB_DB=$(SAED14_LIB_DB)" \
		"CLK_PERIOD_NS=$(CLK_PERIOD_NS)" \
		> $@.tmp
	@cmp -s $@.tmp $@ || mv $@.tmp $@
	@rm -f $@.tmp

$(STA_STAMP): FORCE
	@mkdir -p $(WORKDIR)
	@printf "%s\n" \
		"SAED14_LIB_DB=$(SAED14_LIB_DB)" \
		> $@.tmp
	@cmp -s $@.tmp $@ || mv $@.tmp $@
	@rm -f $@.tmp

$(POWER_STAMP): FORCE
	@mkdir -p $(WORKDIR)
	@printf "%s\n" \
		"SAED14_LIB_DB=$(SAED14_LIB_DB)" \
		"SAIF_INSTANCE=tb_pe/dut" \
		> $@.tmp
	@cmp -s $@.tmp $@ || mv $@.tmp $@
	@rm -f $@.tmp

# -------------------------------
# Generate unified RTL config header
# -------------------------------
cfg: $(CFG_SVH)

$(CFG_SVH): $(CFG_STAMP)
	@mkdir -p $(WORKDIR)
	@echo "// Auto-generated. Do not edit." > $(CFG_SVH)
	@echo "\`define SIMD $(SIMD)" >> $(CFG_SVH)
	@echo "\`define PE $(PE)" >> $(CFG_SVH)
	@echo "\`define MAX_CHANNELS $(MAX_CHANNELS)" >> $(CFG_SVH)
	@echo "\`define KERNEL_X $(KERNEL_X)" >> $(CFG_SVH)
	@echo "\`define KERNEL_Y $(KERNEL_Y)" >> $(CFG_SVH)
	@echo "\`define DATA_WIDTH $(DATA_WIDTH)" >> $(CFG_SVH)

# -------------------------------
# Vectors
# -------------------------------
vectors: $(WEIGHTS_FILE) $(INPUTS_FILE) $(EXPECTED_FILE)

$(WEIGHTS_FILE) $(INPUTS_FILE) $(EXPECTED_FILE): Golden_Model.py $(VEC_STAMP)
	@mkdir -p $(WORKDIR)
	python3 Golden_Model.py \
		--cin $(CIN) --kx $(KX) --ky $(KY) \
		--pe_qnt $(PEQNT) --simd $(SIMD) \
		--seed $(SEED) --n_inputs $(NIN) --out_dir $(WORKDIR)

# -------------------------------
# Build RTL simulation
# -------------------------------
build: cfg $(SIMV_BIN)

$(SIMV_BIN): $(PE_SV) $(TB_SV) $(CFG_SVH) $(SIM_STAMP)
	@mkdir -p $(WORKDIR)
	$(VCS) $(VCS_FLAGS) +incdir+$(WORKDIR) $(PE_SV) $(TB_SV) -o $(SIMV_BIN)

# -------------------------------
# Simulation (produces VCD)
# -------------------------------
sim: vectors build
	@mkdir -p $(SIM_OUT_DIR)
	@set -e; \
	FCLK_USED="$(FCLK_HZ)"; \
	if [ "$(USE_FCLK_SYNTH)" = "True" ] || [ "$(USE_FCLK_SYNTH)" = "true" ] || [ "$(USE_FCLK_SYNTH)" = "1" ]; then \
		if [ ! -f "$(PT_LOG)" ] || [ "$(PE_SV)" -nt "$(PT_LOG)" ]; then \
			echo "Notice: STA log missing or RTL ($(PE_SV)) was modified. Running Synthesis & STA..."; \
			$(MAKE) sta; \
		else \
			echo "Notice: RTL is unchanged. Reusing existing PrimeTime results!"; \
		fi; \
		FCLK_USED=$$(grep "PT_FMAX_HZ    :" $(PT_LOG) | tail -1 | awk '{print $$3}'); \
		if [ -z "$$FCLK_USED" ]; then \
			echo "ERROR: Could not extract PT_FMAX_HZ from $(PT_LOG)."; \
			exit 1; \
		fi; \
		echo "Extracted Fmax from results: $$FCLK_USED Hz"; \
	fi; \
	RUN_ID="$(SIM_ID)_fclkused$${FCLK_USED}"; \
	./$(SIMV_BIN) \
		+VEC_DIR=$(WORKDIR) \
		+CIN=$(CIN) +KX=$(KX) +KY=$(KY) \
		+PEQNT=$(PEQNT) +NIN=$(NIN) \
		+FCLK_HZ=$${FCLK_USED} +MEM_L_S=$(MEM_L_S) +MEM_B_GBPS=$(MEM_B_GBPS) \
		| tee $(SIM_OUT_DIR)/sim_$${RUN_ID}.log; \
	echo "Log saved to: $(SIM_OUT_DIR)/sim_$${RUN_ID}.log"
	@echo "VCD generated at: $(VCD_FILE)"

# -------------------------------
# VCD -> SAIF conversion (for power)
# -------------------------------
saif: $(SAIF_FILE)

$(SAIF_FILE): $(VCD_FILE) $(POWER_STAMP)
	@mkdir -p $(WORKDIR)
	$(VCD2SAIF) -input $(VCD_FILE) -output $(SAIF_FILE) -instance tb_pe/dut
	@echo "SAIF generated at: $(SAIF_FILE)"

# -------------------------------
# Synthesis (Design Compiler)
# -------------------------------
synth: $(NETLIST_V) $(NETLIST_SDC)

$(NETLIST_V) $(NETLIST_SDC): $(PE_SV) $(CFG_SVH) $(SYN_DIR)/dc/run_dc.tcl $(SYN_STAMP)
	@mkdir -p $(DC_DIR) $(WORKDIR)/netlist
	BASE_ID="$(HARDWARE_ID)" SAED14_LIB_DB="$(SAED14_LIB_DB)" CLK_PERIOD_NS="$(CLK_PERIOD_NS)" OUT_DIR="$(DC_DIR)" \
	$(DC_SHELL) -f $(SYN_DIR)/dc/run_dc.tcl | tee $(DC_DIR)/dc_$(HARDWARE_ID).log

# -------------------------------
# STA (PrimeTime)
# -------------------------------
sta: $(FMAX_FILE)

$(FMAX_FILE): $(NETLIST_V) $(NETLIST_SDC) $(SYN_DIR)/pt/run_pt.tcl $(STA_STAMP)
	@mkdir -p $(PT_DIR)
	BASE_ID="$(HARDWARE_ID)" SAED14_LIB_DB="$(SAED14_LIB_DB)" OUT_DIR="$(PT_DIR)" FCLK_HZ="$(FCLK_HZ)" \
	$(PT_SHELL) -f $(SYN_DIR)/pt/run_pt.tcl | tee $(PT_DIR)/pt_$(HARDWARE_ID).log
	@grep "PT_FMAX_HZ=" $(PT_DIR)/pt_$(HARDWARE_ID).log | tail -1 | sed 's/.*PT_FMAX_HZ=//' > $(FMAX_FILE)
	@echo "Fmax written to $(FMAX_FILE): $$(cat $(FMAX_FILE))"

# -------------------------------
# Power (PrimeTime PX)
# -------------------------------
power: $(SIM_OUT_DIR)/power_$(SIM_ID).log
$(VCD_FILE): sim
	@true

$(SIM_OUT_DIR)/power_$(SIM_ID).log: $(SAIF_FILE) $(NETLIST_V) $(NETLIST_SDC) $(SYN_DIR)/pt/run_power.tcl $(POWER_STAMP)
	@mkdir -p $(SIM_OUT_DIR)
	BASE_ID="$(SIM_ID)" SAED14_LIB_DB="$(SAED14_LIB_DB)" OUT_DIR="$(SIM_OUT_DIR)" \
	$(PT_SHELL) -f $(SYN_DIR)/pt/run_power.tcl | tee $(SIM_OUT_DIR)/power_$(SIM_ID).log

clean:
	rm -rf $(WORKDIR) csrc *.daidir ucli.key *.vpd vcs.log \
	.rce/ alib-52/ cksum_dir/ *.svf \
	crte_*.txt Synopsys_stack_trace_*.txt \
	pwr_shell_command.log filenames.log default.svf

FORCE: