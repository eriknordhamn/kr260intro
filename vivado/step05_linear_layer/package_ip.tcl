# Step 05: package linear_layer.sv as a Vivado IP core.
#
# Same shape as step 04's package_ip.tcl — scratch project, RTL referenced
# from rtl/ rather than copied, ipx::package_project, explicit clock/reset
# association, save.
#
# The one thing to watch that step 04 did not have: this module's stream
# widths are parameterized (LANES * DATA_WIDTH). With the defaults
# LANES=8, DATA_WIDTH=16 the slave stream resolves to 128 bits and the
# master stream to OUT_WIDTH=32, which is what the block design expects. If
# a parameter is ever overridden in IP Integrator, TDATA follows it — but
# the AXI DMA's stream width must then be changed to match by hand, since
# nothing checks that for you.
#
# Usage:
#   source /opt/Xilinx/2025.1/Vivado/settings64.sh
#   vivado -mode batch -source vivado/step05_linear_layer/package_ip.tcl
#
# Output: build/step05_linear_layer/ip_repo/component.xml

set script_dir  [file dirname [file normalize [info script]]]
set repo_root   [file normalize [file join $script_dir ../..]]
set build_dir   [file join $repo_root build/step05_linear_layer]
set proj_dir    [file join $build_dir _vivado_project]
set ip_repo_dir [file join $build_dir ip_repo]

# Scratch project containing just the RTL to package.
file mkdir $build_dir
create_project linear_layer_pkg $proj_dir -part xck26-sfvc784-2LV-c -force

add_files -norecurse [file join $repo_root rtl/step05_linear_layer/linear_layer.sv]
set_property top linear_layer [current_fileset]
update_compile_order -fileset sources_1

# package_project infers both AXI4-Stream (axis) interfaces, the clock, and
# the reset from the s_axis_* / m_axis_* / aclk / aresetn naming convention.
file delete -force $ip_repo_dir
ipx::package_project -root_dir $ip_repo_dir -vendor user.org -library user \
    -taxonomy /UserIP -import_files -set_current false

ipx::unload_core [file join $ip_repo_dir component.xml]
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project \
    -directory $ip_repo_dir [file join $ip_repo_dir component.xml]
update_compile_order -fileset sources_1

set_property vendor kr260intro.local [ipx::current_core]
set_property description {Streaming matrix-vector multiply (linear layer), LANES int16 MACs/cycle} [ipx::current_core]
set_property core_revision 1 [ipx::current_core]

# As in step 04: interface inference associates only the *master* stream
# with aclk on its own (message 19-4728). Associate both explicitly, or IP
# Integrator does not know aclk clocks the slave stream and Connection
# Automation has less to work with. Names must match the inferred
# (lowercase) interface names exactly.
foreach busif {s_axis m_axis} {
    ipx::associate_bus_interfaces -busif $busif -clock aclk [ipx::current_core]
}

# Tie aresetn to aclk so the reset is recognized as this clock's synchronous
# reset (active-low is inferred from the trailing 'n').
set clk_if [ipx::get_bus_interfaces aclk -of_objects [ipx::current_core]]
set assoc_reset [ipx::get_bus_parameters ASSOCIATED_RESET -of_objects $clk_if -quiet]
if {$assoc_reset eq ""} {
    set assoc_reset [ipx::add_bus_parameter ASSOCIATED_RESET $clk_if]
}
set_property value aresetn $assoc_reset

ipx::create_xgui_files [ipx::current_core]
ipx::update_checksums [ipx::current_core]
ipx::check_integrity [ipx::current_core]
ipx::save_core [ipx::current_core]
ipx::move_temp_component_back -component [ipx::current_core]

close_project -delete
close_project -delete

puts ""
puts "=== IP packaged ==="
puts "  $ip_repo_dir/component.xml"
