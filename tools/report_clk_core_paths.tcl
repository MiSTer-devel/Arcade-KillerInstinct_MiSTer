# Where is the clk_core critical path, and does the SDRAM controller own it?
#
# The queue item "raise the SDRAM clock" rested on KI_SDRAM_CLK's +12.03 ns
# slack. That is a create_generated_clock on the SDRAM_CLK *port*, so it
# constrains the I/O paths against the device, not the controller's fabric
# logic. ki_sdram_burst runs on clk_core (PLL outclk_0 = general[0]), whose
# design-wide setup slack is what actually bounds it.
#
# report_timing needs -stdout in a -t script or the panels go to the GUI
# database and nothing is printed.
#
# Run against a netlist a build has already produced - no fit required:
#   quartus_sta -t tools/report_clk_core_paths.tcl
project_open KillerInstinct
create_timing_netlist
read_sdc
update_timing_netlist

set clk_core {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}

puts ""
puts "==== clk_core -> clk_core (fabric logic inside the domain) ===="
report_timing -setup -npaths 10 -detail summary -stdout \
    -from_clock [get_clocks $clk_core] -to_clock [get_clocks $clk_core]

puts ""
puts "==== anything -> clk_core (includes the cross-domain captures) ===="
report_timing -setup -npaths 10 -detail summary -stdout \
    -to_clock [get_clocks $clk_core]

puts ""
puts "==== clk_core -> anything ===="
report_timing -setup -npaths 10 -detail summary -stdout \
    -from_clock [get_clocks $clk_core]

puts ""
puts "==== how much of clk_core's slack the SDRAM controller owns ===="
# If this comes back close to the design-wide clk_core slack, the controller IS
# the ceiling and a faster SDRAM domain needs it pipelined first. If it comes
# back far above, the ceiling is elsewhere and a separate domain is on the table.
report_timing -setup -npaths 5 -detail summary -stdout \
    -to [get_registers {*ki_sdram_burst*|*}]
report_timing -setup -npaths 5 -detail summary -stdout \
    -from [get_registers {*ki_sdram_burst*|*}]

delete_timing_netlist
project_close
