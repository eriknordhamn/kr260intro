# Step 03: scratch project for block design work.
#
# Unlike step 02, this design uses only stock Xilinx IP (Zynq PS + AXI
# DMA) - no custom IP to package or register in the catalog first.
#
# Usage:
#   source /opt/Xilinx/2025.1/Vivado/settings64.sh
#   vivado -mode batch -source vivado/step03_dma_loopback/create_bd_scratch_project.tcl
#   vivado build/step03_dma_loopback/_vivado_project/dma_loopback_bd.xpr

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ../..]]
set build_dir  [file join $repo_root build/step03_dma_loopback]
set proj_dir   [file join $build_dir _vivado_project]

file mkdir $build_dir

create_project dma_loopback_bd $proj_dir -part xck26-sfvc784-2LV-c -force
set_property board_part xilinx.com:kr260_som:part0:1.1 [current_project]

puts ""
puts "=== Scratch project ready ==="
puts "  [file join $proj_dir dma_loopback_bd.xpr]"
puts "Open in GUI: vivado [file join $proj_dir dma_loopback_bd.xpr]"
puts "Create a new block design named 'dma_loopback' and follow the"
puts "GUI steps in vivado/step03_dma_loopback/ (see chat/docs)."
