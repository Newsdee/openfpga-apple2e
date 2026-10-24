# sta_body.tcl — report script run via:  quartus_sta apf_stream_video --report_script=sta_body.tcl
puts "=============================================================="
puts "### [1] SETUP to SDRAM CONTROLLER clock (npaths 20, full_path)"
puts "=============================================================="
report_timing -setup -to_clock {ic|mp2|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} -npaths 20 -detail full_path

puts "=============================================================="
puts "### [2] SETUP to SDRAM CHIP clock (npaths 10, full_path)"
puts "=============================================================="
report_timing -setup -to_clock {ic|mp2|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk} -npaths 10 -detail full_path

puts "=============================================================="
puts "### [3] report_clocks (all clocks + the unconstrained latch clock)"
puts "=============================================================="
report_clocks

# NOTE: report_timing in this TimeQuest (17.0.2) has no -corner option; the
# corner is selected first via set_operating_conditions. Available corners for
# this part: 8_slow_1100mv_85c 8_slow_1100mv_0c MIN_fast_1100mv_85c MIN_fast_1100mv_0c.
puts "=============================================================="
puts "### [4] SETUP to SDRAM CONTROLLER clock @ Slow 1100mV 0C corner (npaths 20, full_path)"
puts "=============================================================="
set_operating_conditions 8_slow_1100mv_0c
report_timing -setup -to_clock {ic|mp2|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} -npaths 20 -detail full_path
