# Step 01: Hello Overlay
# Minimal block design — Zynq UltraScale+ PS only, no custom PL logic.
# Validates the full toolchain: Vivado -> .bit + .hwh -> PYNQ on KR260.
#
# Usage:
#   source /opt/Xilinx/2025.1/Vivado/settings64.sh
#   vivado -mode batch -source vivado/step01_hello/build.tcl
#
# Outputs: build/step01_hello/hello_overlay.bit
#          build/step01_hello/hello_overlay.hwh

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ../..]]
set build_dir  [file join $repo_root build/step01_hello]
set proj_dir   [file join $build_dir _vivado_project]
set proj_name  hello_overlay
set design_name hello_overlay

file mkdir $build_dir

# Create project
create_project $proj_name $proj_dir -part xck26-sfvc784-2LV-c -force
set_property board_part xilinx.com:kr260_som:part0:1.1 [current_project]

# Block design
create_bd_design $design_name

# Add Zynq UltraScale+ PS and apply KR260 board preset
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0
apply_bd_automation \
    -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} \
    [get_bd_cells zynq_ultra_ps_e_0]

validate_bd_design
save_bd_design

# Generate output products (produces .hwh in hw_handoff/)
generate_target all [get_files ${design_name}.bd]

# HDL wrapper (top-level for synthesis)
set wrapper [make_wrapper -files [get_files ${design_name}.bd] -top]
add_files -norecurse $wrapper
set_property top ${design_name}_wrapper [current_fileset]

# Synthesis
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "Synthesis failed"
}

# Implementation + bitstream
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "Implementation failed"
}

# Copy deliverables to build/
set bit [glob ${proj_dir}/${proj_name}.runs/impl_1/*.bit]
set hwh [glob ${proj_dir}/${proj_name}.srcs/sources_1/bd/${design_name}/hw_handoff/${design_name}.hwh]

file copy -force $bit [file join $build_dir ${design_name}.bit]
file copy -force $hwh [file join $build_dir ${design_name}.hwh]

puts ""
puts "=== Build complete ==="
puts "  [file join $build_dir ${design_name}.bit]"
puts "  [file join $build_dir ${design_name}.hwh]"
puts "Copy both files to the KR260 and run sw/step01_hello/load_overlay.py"
