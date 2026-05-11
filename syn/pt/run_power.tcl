# Redirect the command log
set sh_command_log_file ./work/power_command.log

# ENABLE THE POWER ENGINE IN PRIMETIME
set power_enable_analysis true

set TOP pe
set LIB_DB $env(BASE_ID) 
# (Make sure your variables match what you had)
set LIB_DB $env(SAED14_LIB_DB)

set search_path [list . ./work ./work/netlist]
set target_library [list $LIB_DB]
set link_library "* $target_library"

read_verilog work/netlist/pe_mapped.v
current_design $TOP
link_design $TOP

# Read the SDC constraints so it knows the clocks
read_sdc work/netlist/pe_mapped.sdc

# Read the simulation activity file
read_saif work/dut.saif -strip_path tb_pe/dut

update_power
file mkdir $env(OUT_DIR)
report_power -hierarchy > $env(OUT_DIR)/power_hier_$env(BASE_ID).rpt

quit