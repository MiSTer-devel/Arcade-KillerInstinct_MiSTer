# What binds clk93 once the I-cache hit check is out of the fetch cycle?
#
# Every clock fix so far attacked one path family and handed the lead to the
# next (see docs/OPTIMIZATION-HISTORY.md). A list of the worst N PATHS cannot
# show that: one endpoint such as stall1 contributes hundreds of paths within
# 0.1 ns, so the second family never reaches the listing. This reports ONE path
# per endpoint (-nworst 1), and removes the three consumers of instrcache_hit,
# i.e. what a perfect fetch redesign would still face.
#
# report_timing needs -stdout in a -t script, and its tables arrive as "Info"
# lines, so do not filter those out of the log.
#
# Run against a netlist a build has already produced - no fit required. Note
# whether that fit had KI_DEBUG_BUILD on: absolute slack differs by ~0.65 ns.
#   quartus_sta -t tools/report_clk93_beyond_fetch.tcl
project_open KillerInstinct
create_timing_netlist
read_sdc
update_timing_netlist

set c93 [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]

# instrcache_hit has exactly three consumers in cpu.vhd.
set hit_ends [get_registers {*|cpu:core|stall1}]
set hit_ends [add_to_collection $hit_ends [get_registers {*|cpu:core|instrcache_fill}]]
set hit_ends [add_to_collection $hit_ends [get_registers {*|cpu:core|cacheHitLast}]]
puts "hit endpoints found: [get_collection_size $hit_ends]"

puts "\n==== A. into the fetch-hit endpoints (binding before this) ===="
report_timing -setup -npaths 3 -nworst 1 -detail summary -stdout \
    -to $hit_ends -from_clock $c93 -to_clock $c93

puts "\n==== B. into PC (the fetch-address register) ===="
report_timing -setup -npaths 8 -nworst 1 -detail summary -stdout \
    -to [get_registers {*|cpu:core|PC[*]}] -from_clock $c93 -to_clock $c93

puts "\n==== C. into the I-cache data M10K (what a SYNCHRONOUS tag read would face) ===="
set dram [get_keepers {*|cpu:core|cpu_instrcache:icpu_instrcache|dpram_dif:icache|*}]
if {[get_collection_size $dram] > 0} {
    report_timing -setup -npaths 4 -nworst 1 -detail summary -stdout \
        -to $dram -from_clock $c93 -to_clock $c93
}

puts "\n==== D. everything in clk93 EXCEPT the fetch-hit endpoints (binds next) ===="
set rest [remove_from_collection [get_registers {*}] $hit_ends]
report_timing -setup -npaths 25 -nworst 1 -detail summary -stdout \
    -to $rest -from_clock $c93 -to_clock $c93

puts "\n==== E. the single worst path in D, hop by hop ===="
report_timing -setup -npaths 1 -detail path_only -stdout \
    -to $rest -from_clock $c93 -to_clock $c93

delete_timing_netlist
project_close
