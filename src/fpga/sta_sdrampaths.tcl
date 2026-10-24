# sta_sdrampaths.tcl — robust TimeQuest report for the mp2 (SDRAM) timing review.
# Every command is wrapped in its own `catch` so one rejected option cannot abort the run.

set f [open "sdram_timing_paths.txt" w]
puts $f "TimeQuest detailed paths - mp2 SDRAM clocks (robust run)"
puts $f "=============================================================="

# open the fitted project (try both name forms)
if {[catch {project open apf_stream_video} e]} {
    puts $f "NOTE: project open apf_stream_video -> $e"
    if {[catch {project open apf_stream_video.qpf} e2]} { puts $f "NOTE: project open .qpf -> $e2" }
}

set C_CONT "ic|mp2|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk"
set C_CHIP "ic|mp2|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk"

# confirm the controller clock resolves (if not, dump the clock list and stop)
if {[catch {get_clocks $C_CONT} ec]} {
    puts $f "CONTROLLER CLOCK DID NOT RESOLVE: $ec"
    puts $f "Clocks the design sees (get_clocks -quiet):"
    catch {puts $f [get_clocks -quiet]}
    close $f
    puts "Wrote sdram_timing_paths.txt (clock lookup failed - see clock list)."
    return
}
puts $f "Controller clock OK: $C_CONT"
if {[catch {get_clocks $C_CHIP} ec2]} {
    puts $f "NOTE: chip clock did not resolve: $ec2"
    set C_CHIP ""
}

# 1) SETUP paths ENDING on the controller clock - the key report (the failing domain)
puts $f "\n### [1] SETUP to controller clock (npaths 20, -detail)"
if {[catch {report_timing -setup -to_clock $C_CONT -npaths 20 -detail} r]} {
    puts $f "FAILED: $r"
} else { puts $f $r }

# 1b) same with the explicit full_path detail level (in case -detail needs a value)
puts $f "\n### [1b] SETUP to controller clock (npaths 20, -detail full_path)"
if {[catch {report_timing -setup -to_clock $C_CONT -npaths 20 -detail full_path} r]} {
    puts $f "FAILED: $r"
} else { puts $f $r }

# 2) SETUP paths ending on the chip clock (related domain)
if {$C_CHIP ne {}} {
    puts $f "\n### [2] SETUP to chip clock (npaths 10, -detail)"
    if {[catch {report_timing -setup -to_clock $C_CHIP -npaths 10 -detail} r]} {
        puts $f "FAILED: $r"
    } else { puts $f $r }
}

# 3) HOLD paths ending on the controller clock (confirm hold is truly met)
puts $f "\n### [3] HOLD to controller clock (npaths 10, -detail)"
if {[catch {report_timing -hold -to_clock $C_CONT -npaths 10 -detail} r]} {
    puts $f "FAILED: $r"
} else { puts $f $r }

# 4) All clocks (spot the unconstrained OSK-reset-derived latch clock)
puts $f "\n### [4] report_clocks"
if {[catch {report_clocks} r]} { puts $f "FAILED: $r" } else { puts $f $r }

# 4b) Unconstrained paths (may not be a valid option on this build)
puts $f "\n### [4b] Unconstrained paths (npaths 20)"
if {[catch {report_timing -unconstrained -npaths 20 -detail} r]} {
    puts $f "FAILED (ok if -unconstrained is unsupported): $r"
} else { puts $f $r }

# 5) Timing exceptions (multicycle / false_path) - two possible command forms
puts $f "\n### [5] report_timing -exceptions -all"
if {[catch {report_timing -exceptions -all} r]} { puts $f "FAILED: $r" } else { puts $f $r }
puts $f "\n### [5b] report_timing_exceptions -report_all_exceptions"
if {[catch {report_timing_exceptions -report_all_exceptions} r]} { puts $f "FAILED: $r" } else { puts $f $r }

close $f
puts "Wrote sdram_timing_paths.txt."
