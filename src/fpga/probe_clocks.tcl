# probe_clocks.tcl - just list the clocks (run via: quartus_sta apf_stream_video -t probe_clocks.tcl)
set f [open "clocks_probe.txt" w]
puts $f "=== get_clocks -quiet ==="
if {[catch {get_clocks -quiet} r]} { puts $f "get_clocks FAILED: $r" } else { puts $f $r }
puts $f "\n=== report_clocks ==="
if {[catch {report_clocks} r2]} { puts $f "report_clocks FAILED: $r2" } else { puts $f $r2 }
close $f
puts "wrote clocks_probe.txt"
