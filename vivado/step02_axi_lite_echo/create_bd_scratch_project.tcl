# Step 02: scratch project for block design work.
#
# Creates a project with the packaged axi_lite_echo IP registered in its
# IP catalog (via ip_repo_paths), so it shows up alongside Xilinx IP when
# building the block design in the GUI. Not committed - only the
# exported block design TCL and the final build.tcl are.
#
# Prerequisite: run package_ip.tcl first (or `make package_step02`).
#
# Usage:
#   source /opt/Xilinx/2025.1/Vivado/settings64.sh
#   vivado -mode batch -source vivado/step02_axi_lite_echo/create_bd_scratch_project.tcl
#   vivado build/step02_axi_lite_echo/_vivado_project/axi_lite_echo_bd.xpr

set script_dir  [file dirname [file normalize [info script]]]
set repo_root   [file normalize [file join $script_dir ../..]]
set build_dir   [file join $repo_root build/step02_axi_lite_echo]
set proj_dir    [file join $build_dir _vivado_project]
set ip_repo_dir [file join $build_dir ip_repo]

if {![file exists [file join $ip_repo_dir component.xml]]} {
    error "No packaged IP found at $ip_repo_dir - run package_ip.tcl first."
}

create_project axi_lite_echo_bd $proj_dir -part xck26-sfvc784-2LV-c -force
set_property board_part xilinx.com:kr260_som:part0:1.1 [current_project]
set_property ip_repo_paths $ip_repo_dir [current_project]
update_ip_catalog

puts ""
puts "=== Scratch project ready ==="
puts "  [file join $proj_dir axi_lite_echo_bd.xpr]"
puts "Open in GUI: vivado [file join $proj_dir axi_lite_echo_bd.xpr]"
puts "axi_lite_echo should now appear in the IP catalog when building the block design."
