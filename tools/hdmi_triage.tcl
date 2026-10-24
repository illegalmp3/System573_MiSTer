# hdmi_triage.tcl -- the worst setup/hold paths into every clock with negative slack, at
# both slow corners, on an already-fitted project:  quartus_sta -t tools/hdmi_triage.tcl
# (2026-10-20: the pll_hdmi setup miss recurred across seeds; this names the paths.)
project_open Konami_System_573
create_timing_netlist
read_sdc
foreach oc {7_slow_1100mv_100c 7_slow_1100mv_-40c} {
  set_operating_conditions $oc
  update_timing_netlist
  puts "================ $oc"
  foreach_in_collection c [get_clocks *] {
    set n [get_clock_info -name $c]
    foreach kind {setup hold} {
      set r [report_timing -to_clock $n -$kind -npaths 1 -panel_name dummy]
      set slack [lindex $r 1]
      if {$slack ne "" && $slack < 0} {
        puts "--- $kind into $n : worst $slack"
        report_timing -to_clock $n -$kind -npaths 12 -detail summary -stdout
      }
    }
  }
}
delete_timing_netlist
project_close
