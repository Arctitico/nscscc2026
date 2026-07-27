if {$argc != 9} {
    puts stderr "usage: build.tcl <cpu_hz> <pll_divclk> <pll_mult> <pll_out_div> <sram_read_cycles> <sram_write_cycles> <sram_write_hold_cycles> <jobs> <report_dir>"
    exit 2
}

set cpu_hz     [lindex $argv 0]
set pll_divclk [lindex $argv 1]
set pll_mult   [lindex $argv 2]
set pll_outdiv [lindex $argv 3]
set sram_read_cycles       [lindex $argv 4]
set sram_write_cycles      [lindex $argv 5]
set sram_write_hold_cycles [lindex $argv 6]
set jobs       [lindex $argv 7]
set report_dir [file normalize [lindex $argv 8]]
set project_file [file normalize ./project/thinpad_top.xpr]
set expected_part xc7a200tfbg676-2

proc require_run_complete {run_name phase} {
    set run [get_runs $run_name]
    set progress [get_property PROGRESS $run]
    set status [get_property STATUS $run]
    if {$progress ne "100%" || ![string match "*Complete*" $status]} {
        puts stderr "$phase failed: $status (progress $progress)"
        close_project
        exit 1
    }
}

open_project $project_file
set project_part [get_property PART [current_project]]
if {$project_part ne $expected_part} {
    puts stderr "Project part mismatch: expected $expected_part, got $project_part. Re-run build_fpga.sh with --recreate-project."
    close_project
    exit 1
}
set generics [format \
    "SIMULATION=0 CPU_CLK_HZ=%s PLL_DIVCLK_DIVIDE=%s PLL_CLKFBOUT_MULT=%s PLL_CLKOUT0_DIVIDE=%s SRAM_READ_CYCLES=%s SRAM_WRITE_CYCLES=%s SRAM_WRITE_HOLD_CYCLES=%s" \
    $cpu_hz $pll_divclk $pll_mult $pll_outdiv \
    $sram_read_cycles $sram_write_cycles $sram_write_hold_cycles]
set_property generic $generics [get_filesets sources_1]
update_compile_order -fileset sources_1

reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
require_run_complete synth_1 Synthesis

# Match the official CI implementation flow: keep Vivado's normal pre-route
# phys_opt_design step, but do not run an additional post-route physical
# optimization pass.  Set this explicitly because the generated project is
# reused between builds and may retain the old AggressiveExplore property.
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED false [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
require_run_complete impl_1 Implementation

set bit_files [glob -nocomplain ./project/thinpad_top.runs/impl_1/*.bit]
if {[llength $bit_files] == 0} {
    puts stderr "Implementation completed without a bitstream"
    close_project
    exit 1
}

open_run impl_1
file mkdir $report_dir

report_clocks -file "$report_dir/clocks.rpt"
check_timing -verbose -file "$report_dir/check_timing.rpt"
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 20 \
    -file "$report_dir/timing_summary.rpt"
report_timing -delay_type max -sort_by group -max_paths 20 -nworst 1 \
    -path_type full_clock_expanded -input_pins \
    -file "$report_dir/setup_critical.rpt"
report_timing -delay_type min -sort_by group -max_paths 20 -nworst 1 \
    -path_type full_clock_expanded -input_pins \
    -file "$report_dir/hold_critical.rpt"
report_utilization -file "$report_dir/utilization.rpt"
report_utilization -hierarchical -file "$report_dir/utilization_hierarchical.rpt"

set cpu_clock [get_clocks cpu_clk]
set cpu_period [get_property PERIOD $cpu_clock]
set actual_frequency [expr {1000.0 / $cpu_period}]

set setup_path [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set hold_path  [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
set setup_wns [get_property SLACK [lindex $setup_path 0]]
set hold_whs  [get_property SLACK [lindex $hold_path 0]]

set failing_paths [get_timing_paths -delay_type max \
    -max_paths 100000 -nworst 1 -slack_lesser_than 0]
set setup_tns 0.0
foreach timing_path $failing_paths {
    set setup_tns [expr {$setup_tns + [get_property SLACK $timing_path]}]
}

set summary [open "$report_dir/build_summary.txt" w]
fconfigure $summary -translation lf
puts $summary "PROJECT_PART=$project_part"
puts $summary "CPU_CLK_HZ_GENERIC=$cpu_hz"
puts $summary "PLL_DIVCLK_DIVIDE=$pll_divclk"
puts $summary "PLL_CLKFBOUT_MULT=$pll_mult"
puts $summary "PLL_CLKOUT0_DIVIDE=$pll_outdiv"
puts $summary "SRAM_READ_CYCLES=$sram_read_cycles"
puts $summary "SRAM_WRITE_CYCLES=$sram_write_cycles"
puts $summary "SRAM_WRITE_HOLD_CYCLES=$sram_write_hold_cycles"
puts $summary [format "ACTUAL_CPU_FREQ_MHZ=%.6f" $actual_frequency]
puts $summary "CPU_PERIOD_NS=$cpu_period"
puts $summary "DESIGN_SETUP_WNS_NS=$setup_wns"
puts $summary [format "DESIGN_SETUP_TNS_NS=%.3f" $setup_tns]
puts $summary "DESIGN_SETUP_FAILING_ENDPOINTS=[llength $failing_paths]"
puts $summary "DESIGN_HOLD_WHS_NS=$hold_whs"
puts $summary "TIMING_MET=[expr {$setup_wns >= 0.0 && $hold_whs >= 0.0}]"
puts $summary "VIVADO_VERSION=[version -short]"
close $summary

file copy -force [lindex $bit_files 0] "$report_dir/thinpad_top.bit"
close_project
exit 0
