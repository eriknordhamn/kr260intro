# Step 05: scratch project for block design work.
#
# Creates a project with the packaged linear_layer IP registered in its IP
# catalog (via ip_repo_paths), so it appears alongside Xilinx IP when
# building the block design in the GUI. Not committed — only the exported
# block design TCL and build.tcl are.
#
# Prerequisite: run package_ip.tcl first (or `make package_step05`).
#
# Usage:
#   source /opt/Xilinx/2025.1/Vivado/settings64.sh
#   vivado -mode batch -source vivado/step05_linear_layer/create_bd_scratch_project.tcl
#   vivado build/step05_linear_layer/_vivado_project/linear_layer_bd.xpr
#
# The general GUI procedure is in docs/vivado-gui-session.md; what is
# specific to this step is the AXI DMA width change, spelled out in
# spec/step05_linear_layer.md under "Block design".

set script_dir  [file dirname [file normalize [info script]]]
set repo_root   [file normalize [file join $script_dir ../..]]
set build_dir   [file join $repo_root build/step05_linear_layer]
set proj_dir    [file join $build_dir _vivado_project]
set ip_repo_dir [file join $build_dir ip_repo]

if {![file exists [file join $ip_repo_dir component.xml]]} {
    error "No packaged IP found at $ip_repo_dir - run package_ip.tcl first."
}

create_project linear_layer_bd $proj_dir -part xck26-sfvc784-2LV-c -force
set_property board_part xilinx.com:kr260_som:part0:1.1 [current_project]
set_property ip_repo_paths $ip_repo_dir [current_project]
update_ip_catalog

puts ""
puts "=== Scratch project ready ==="
puts "  [file join $proj_dir linear_layer_bd.xpr]"
puts "Open in GUI: vivado [file join $proj_dir linear_layer_bd.xpr]"
puts "linear_layer should now appear in the IP catalog when building the block design."
puts "Name the block design 'linear_layer_accel' - build.tcl expects that name."
puts ""
puts "Step-specific settings (see spec/step05_linear_layer.md):"
puts "  AXI DMA: Scatter Gather off, both channels on"
puts "           MM2S memory-map width 128, MM2S stream width 128"
puts "           S2MM memory-map width  32, S2MM stream width  32"
puts "  Connect: M_AXIS_MM2S -> linear_layer_0/s_axis"
puts "           linear_layer_0/m_axis -> S_AXIS_S2MM"
