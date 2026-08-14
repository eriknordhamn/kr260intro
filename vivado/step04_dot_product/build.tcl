# Step 04: dot-product accelerator.
# Zynq UltraScale+ PS (M_AXI_HPM0_FPD) -> SmartConnect -> AXI DMA control
# (S_AXI_LITE). AXI DMA's M_AXI_MM2S/M_AXI_S2MM -> SmartConnect ->
# S_AXI_HPC0_FPD for bulk DDR access. Where step 03 looped M_AXIS_MM2S
# straight back into S_AXIS_S2MM, the stream now runs through dot_product_0:
# interleaved (a, b) operands in, one sum out per packet.
#
# Combines step 02's flow (custom IP packaged into ip_repo/, registered in
# the catalog) with step 03's (AXI DMA moving the data).
#
# Requires package_ip.tcl to have run first - `make step04` chains it.
#
# Usage:
#   source /opt/Xilinx/2025.1/Vivado/settings64.sh
#   vivado -mode batch -source vivado/step04_dot_product/build.tcl
#
# Optional: pass -tclargs validate to stop after the block design validates,
# skipping synthesis and implementation. Useful for checking BD edits in
# ~1 minute instead of ~20.
#
# Outputs: build/step04_dot_product/dot_product_accel.bit
#          build/step04_dot_product/dot_product_accel.hwh

set script_dir  [file dirname [file normalize [info script]]]
set repo_root   [file normalize [file join $script_dir ../..]]
set build_dir   [file join $repo_root build/step04_dot_product]
set proj_dir    [file join $build_dir _vivado_project]
set ip_repo_dir [file join $build_dir ip_repo]
set proj_name   dot_product_overlay
set design_name dot_product_accel

set validate_only [expr {[llength $argv] > 0 && [lindex $argv 0] eq "validate"}]

if {![file exists [file join $ip_repo_dir component.xml]]} {
    error "Packaged IP not found at $ip_repo_dir - run package_ip.tcl first"
}

file mkdir $build_dir

# Create project
create_project $proj_name $proj_dir -part xck26-sfvc784-2LV-c -force
set_property board_part xilinx.com:kr260_som:part0:1.1 [current_project]

# Register the packaged dot_product IP so the block design can resolve it.
set_property ip_repo_paths $ip_repo_dir [current_project]
update_ip_catalog -rebuild

# Block design (PS + AXI DMA + dot_product; validates and saves internally).
source [file join $script_dir dot_product_accel_bd.tcl]

if {$validate_only} {
    puts ""
    puts "=== Block design validated (validate-only run, nothing built) ==="
    return
}

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
set hwh [glob ${proj_dir}/${proj_name}.gen/sources_1/bd/${design_name}/hw_handoff/${design_name}.hwh]

file copy -force $bit [file join $build_dir ${design_name}.bit]
file copy -force $hwh [file join $build_dir ${design_name}.hwh]

puts ""
puts "=== Build complete ==="
puts "  [file join $build_dir ${design_name}.bit]"
puts "  [file join $build_dir ${design_name}.hwh]"
puts "Copy both files to the KR260 and run sw/step04_dot_product's driver script"
