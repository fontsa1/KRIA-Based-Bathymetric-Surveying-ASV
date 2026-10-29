# add_pwm_gpio.tcl -- re-apply the ASV PWM/GPIO additions to the Vivado project that Vitis (v++)
# generates for the DPU app, then (optionally) build the bitstream.
#
# What it adds to block design design_1 (the same edits as the October 2026 board test):
#   axi_timer_1/pwm0      -> port PWM_0             pin H12  (PMOD1 upper row, pin 1)   @ 0xA003_0000
#   axi_timer_0/pwm0      -> port PWM_1             pin E10  (PMOD1 upper row, pin 2)   @ 0xA002_0000
#   axi_gpio_0 (1 output) -> port gpio_rtl_tri_o[0] pin B10  (PMOD1 lower row, pin 1)   @ 0xA001_0000
#   all three on M_AXI_HPM0_FPD, clocked by the platform's 300 MHz clk_wiz_0/clk_out4;
#   pins come from kr260_pwm_pins.xdc (next to this script).
#
# Use it after building <app>_system_hw_link (Hardware) in Vitis:
#   GUI:   open <workspace>/<app>_system_hw_link/Hardware/dpu.build/link/vivado/vpl/prj/prj.xpr,
#          then Tools > Run Tcl Script... > pick this file (or in the Tcl Console:
#          source {<repo>/SoC files/kr260_dpu_pwm/vivado/add_pwm_gpio.tcl}), and click Generate Bitstream.
#   Batch: vivado -mode batch -source add_pwm_gpio.tcl -tclargs <path/to/prj.xpr> build
# Running it on a project that already has the blocks only re-checks addresses and constraints.

set here [file dirname [file normalize [info script]]]
set xdc  [file join $here kr260_pwm_pins.xdc]
if {![info exists argv]} { set argv {} }
set do_build [expr {[lsearch -exact $argv build] >= 0}]

if {[llength [get_projects -quiet]] == 0} {
    set xpr [lindex [lsearch -all -inline -not -exact $argv build] 0]
    if {$xpr eq ""} { error "Open the v++ project (prj.xpr) first, or pass it: -tclargs <prj.xpr> \[build\]" }
    open_project $xpr
}
open_bd_design [get_files design_1.bd]

if {[llength [get_bd_cells -quiet axi_timer_0]] > 0} {
    puts "INFO: PWM/GPIO blocks are already in design_1 - skipping the block-design edits"
} else {
    # 1-bit output-only GPIO (motor-driver enable)
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0
    set_property -dict [list CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_GPIO_WIDTH {1}] [get_bd_cells axi_gpio_0]
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gpio_rtl:1.0 gpio_rtl
    connect_bd_intf_net [get_bd_intf_ports gpio_rtl] [get_bd_intf_pins axi_gpio_0/GPIO]
    # two AXI Timers; pwm_test.py puts them in PWM mode at run time
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_timer:2.0 axi_timer_0
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_timer:2.0 axi_timer_1
    foreach ip {axi_gpio_0 axi_timer_0 axi_timer_1} {
        apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
            Clk_master {/clk_wiz_0/clk_out4 (299 MHz)} Clk_slave {Auto} \
            Clk_xbar {/clk_wiz_0/clk_out4 (299 MHz)} Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_FPD} \
            Slave "/$ip/S_AXI" ddr_seg {Auto} intc_ip {/axi_ic_zynq_ultra_ps_e_0_M_AXI_HPM0_FPD} \
            master_apm {0}] [get_bd_intf_pins $ip/S_AXI]
    }
    create_bd_port -dir O PWM_0
    connect_bd_net [get_bd_ports PWM_0] [get_bd_pins axi_timer_1/pwm0]
    create_bd_port -dir O PWM_1
    connect_bd_net [get_bd_ports PWM_1] [get_bd_pins axi_timer_0/pwm0]
}

# Fixed addresses (pwm_test.py on the board depends on these)
proc pin_address {ip offset} {
    set seg [get_bd_addr_segs -quiet zynq_ultra_ps_e_0/Data/SEG_${ip}_Reg]
    if {[llength $seg] == 0} {
        set seg [lsearch -all -inline -glob [get_bd_addr_segs -quiet zynq_ultra_ps_e_0/Data/*] *${ip}*]
    }
    if {[llength $seg] != 1} { error "could not find the address segment of $ip in zynq_ultra_ps_e_0/Data" }
    set_property range 64K $seg
    set_property offset $offset $seg
    puts "INFO: $ip at [get_property offset $seg]"
}
pin_address axi_gpio_0  0xA0010000
pin_address axi_timer_0 0xA0020000
pin_address axi_timer_1 0xA0030000

validate_bd_design
save_bd_design
make_wrapper -files [get_files design_1.bd] -top

# Pin constraints: add kr260_pwm_pins.xdc unless an enabled .xdc already places PWM_0
set have_pins 0
foreach f [get_files -quiet -of_objects [get_filesets constrs_1] -filter {FILE_TYPE == XDC}] {
    if {![get_property IS_ENABLED $f] || ![file exists $f]} { continue }
    set fh [open $f r]; set txt [read $fh]; close $fh
    if {[regexp {get_ports\s+\{?PWM_0\}?\]} $txt]} { set have_pins 1; puts "INFO: pins already set in $f" }
}
if {!$have_pins} {
    import_files -fileset constrs_1 -norecurse $xdc
    puts "INFO: added [file tail $xdc]"
}

if {$do_build} {
    reset_run synth_1
    launch_runs synth_1 -jobs 6
    wait_on_run synth_1
    if {![string match -nocase *complete* [get_property STATUS [get_runs synth_1]]]} {
        error "synthesis failed - see [get_property DIRECTORY [get_runs synth_1]]/runme.log"
    }
    launch_runs impl_1 -to_step write_bitstream -jobs 6
    wait_on_run impl_1
    set run [get_runs impl_1]
    puts "impl_1: [get_property STATUS $run]   WNS [get_property STATS.WNS $run] ns   WHS [get_property STATS.WHS $run] ns"
    if {![string match "*write_bitstream Complete*" [get_property STATUS $run]]} {
        error "no bitstream - see [get_property DIRECTORY $run]/runme.log"
    }
    puts "bitstream: [glob -nocomplain [get_property DIRECTORY $run]/*.bit]"
}
