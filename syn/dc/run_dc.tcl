##############################################################
#            Projeto de Formatura I - SCC0670                #
#                                                            #
#      By: Artur Brenner Weber                               #
#      email: arturweber@usp.br                              #
#      Last Update: 26/5/2026                                #
#                                                            #
###############################################################

# ==========================================================================
# SYNOPSYS GARBAGE REDIRECTION
# ==========================================================================
# Redirect .mr, .pvl, and .syn files (Presto intermediate files)
define_design_lib WORK -path ./work

# Redirect the Setup Verification File (default.svf)
set_svf ./work/pe.svf

# Redirect the alib-52 folder (Advanced Library Characterization cache)
set alib_library_analysis_path ./work

# Redirect the command.log
set sh_command_log_file ./work/command.log
# ==========================================================================

set TOP pe

set LIB_DB $env(SAED14_LIB_DB)
set CLK_PERIOD_NS $env(CLK_PERIOD_NS)

# Make sure DC can see the generated header and local RTL
set search_path [list . ./work]
set target_library [list $LIB_DB]
set link_library "* $target_library"

# Read RTL
analyze -format sverilog [list pe_artur.sv]
elaborate $TOP
current_design $TOP
link

# ==========================================================================
# VIRTUAL HIERARCHY GROUPING
# ==========================================================================
# Group the Weight Registers
group -design_name VIRTUAL_WEIGHTS -cell_name BLK_WEIGHTS [get_cells "weights_reg*"]

# Group the Input Data Registers
group -design_name VIRTUAL_INPUTS -cell_name BLK_INPUTS [get_cells "inp_data_reg_reg*"]

# Group the Accumulators
group -design_name VIRTUAL_ACCUM -cell_name BLK_ACCUM [get_cells "out_acc_reg*"]

# Group the Output Registers
group -design_name VIRTUAL_OUTPUT -cell_name BLK_OUTPUT [get_cells "out_PE_reg*"]
# ==========================================================================

# Check for structural RTL issues
check_design > $env(OUT_DIR)/check_design_$env(BASE_ID).rpt

# Clock constraint (starting point)
create_clock -name core_clk -period $CLK_PERIOD_NS [get_ports clk]
set_clock_uncertainty 0.05 [get_clocks core_clk]

# Simple IO constraints (keeps DC from assuming infinite IO time)
set_input_delay  0.1 -clock core_clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 0.1 -clock core_clk [all_outputs]
set_load 0.05 [all_outputs]

set_fix_multiple_port_nets -all -buffer_constants

compile_ultra

file mkdir $env(OUT_DIR)
file mkdir work/netlist

report_qor > $env(OUT_DIR)/qor_$env(BASE_ID).rpt
report_area -hierarchy > $env(OUT_DIR)/area_hier_$env(BASE_ID).rpt
report_timing -max_paths 10 -delay_type max > $env(OUT_DIR)/timing_max_$env(BASE_ID).rpt
report_power -hierarchy > $env(OUT_DIR)/power_est_hier_$env(BASE_ID).rpt

write -format verilog -hierarchy -output work/netlist/pe_mapped.v
write_sdc work/netlist/pe_mapped.sdc

quit