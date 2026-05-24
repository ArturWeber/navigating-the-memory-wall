##############################################################
#            Projeto de Formatura I - SCC0670                #
#                                                            #
#      By: Artur Brenner Weber                               #
#      email: arturweber@usp.br                              #
#      Last Update: 26/5/2026                                #
#                                                            #
###############################################################

# Redirect the PrimeTime command.log
set sh_command_log_file ./work/pt_command.log

set TOP pe
set LIB_DB $env(SAED14_LIB_DB)

set search_path [list . ./work ./work/netlist]
set target_library [list $LIB_DB]
set link_library "* $target_library"

set power_enable_analysis true

read_verilog work/netlist/pe_mapped.v
current_design $TOP
link_design $TOP

# Load initial constraints from Design Compiler
read_sdc work/netlist/pe_mapped.sdc
file mkdir $env(OUT_DIR)

# ==========================================================================
# PASS 1: POWER AT TARGET FREQUENCY
# ==========================================================================
puts "--- PASS 1: Analyzing at Target Frequency ($env(FCLK_HZ) Hz) ---"

update_timing
set_switching_activity -static_probability 0.5 -toggle_rate 0.1 -base_clock core_clk [all_inputs]
update_power

report_power -hierarchy > $env(OUT_DIR)/power_target_$env(BASE_ID).rpt
report_timing -max_paths 5 > $env(OUT_DIR)/timing_target_$env(BASE_ID).rpt

# Critical path report
report_timing -max_paths 1 -delay_type max -input_pins -transition_time -capacitance -nets \
  > $env(OUT_DIR)/critical_path_target_$env(BASE_ID).rpt

report_qor > $env(OUT_DIR)/qor_target_$env(BASE_ID).rpt

# ==========================================================================
# PASS 2: POWER AT ACTUAL FMAX (Silicon Limit)
# ==========================================================================
puts "--- PASS 2: Analyzing at Maximum Reachable Frequency (Fmax) ---"

# Extract the Worst Negative Slack (WNS) from the Target Run
set wns 0.0
set timing_paths [get_timing_paths -max_paths 1 -delay_type max]
if {[sizeof_collection $timing_paths] > 0} {
    set wns [get_attribute $timing_paths slack]
}

# Calculate the real minimum clock period
set target_period [expr 1000000000.0 / $env(FCLK_HZ)]
set real_period [expr {$target_period - $wns}]

# Overwrite the clock with the REAL period for Fmax analysis
create_clock -name core_clk -period $real_period [get_ports clk]
update_timing

# Update power for the new, higher frequency
update_power

report_power -hierarchy > $env(OUT_DIR)/power_fmax_$env(BASE_ID).rpt
report_timing -max_paths 5 > $env(OUT_DIR)/timing_fmax_$env(BASE_ID).rpt

# Critical path report at max frequency
report_timing -max_paths 1 -delay_type max -input_pins -transition_time -capacitance -nets \
  > $env(OUT_DIR)/critical_path_fmax_$env(BASE_ID).rpt

report_qor > $env(OUT_DIR)/qor_fmax_$env(BASE_ID).rpt

set fmax_hz [expr {0.99/($real_period*1e-9)}]

puts "--------------------------------------------------------"
puts "SUMMARY FOR BASE_ID: $env(BASE_ID)"
puts "Target Period : $target_period ns"
puts "Worst Slack   : $wns ns"
puts "Real Period   : $real_period ns"
puts "PT_FMAX_HZ    : $fmax_hz"
puts "--------------------------------------------------------"

quit