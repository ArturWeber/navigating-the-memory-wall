# Redirect the PrimeTime command.log
set sh_command_log_file ./work/pt_command.log

set TOP pe
set LIB_DB $env(SAED14_LIB_DB)

set search_path [list . ./work ./work/netlist]
set target_library [list $LIB_DB]
set link_library "* $target_library"

read_verilog work/netlist/pe_mapped.v
current_design $TOP
link_design $TOP

read_sdc work/netlist/pe_mapped.sdc

file mkdir $env(OUT_DIR)

report_qor > $env(OUT_DIR)/qor_$env(BASE_ID).rpt
report_timing -max_paths 20 -delay_type max > $env(OUT_DIR)/timing_max_$env(BASE_ID).rpt

# Critical path report
report_timing -max_paths 1 -delay_type max -input_pins -transition_time -capacitance -nets \
  > $env(OUT_DIR)/critical_path_$env(BASE_ID).rpt

# Compute Fmax estimate from worst slack
set period [get_attribute [get_clocks core_clk] period]
set worst_slack [get_attribute [get_timing_paths -max_paths 1] slack]
set tcrit [expr {$period - $worst_slack}]
set fmax_hz [expr {1.0/($tcrit*1e-9)}]

puts "PT_PERIOD_NS=$period"
puts "PT_WORST_SLACK_NS=$worst_slack"
puts "PT_TCRIT_NS=$tcrit"
puts "PT_FMAX_HZ=$fmax_hz"

quit