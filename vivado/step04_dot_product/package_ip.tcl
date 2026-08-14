# Step 04: package dot_product.sv as a Vivado IP core.
#
# Same shape as step 02's package_ip.tcl — scratch project, RTL referenced
# from rtl/ rather than copied, ipx::package_project, metadata, save. The one
# addition is explicit clock/reset association (see below).
#
# Usage:
#   source /opt/Xilinx/2025.1/Vivado/settings64.sh
#   vivado -mode batch -source vivado/step04_dot_product/package_ip.tcl
#
# Output: build/step04_dot_product/ip_repo/component.xml

set script_dir  [file dirname [file normalize [info script]]]
set repo_root   [file normalize [file join $script_dir ../..]]
set build_dir   [file join $repo_root build/step04_dot_product]
set proj_dir    [file join $build_dir _vivado_project]
set ip_repo_dir [file join $build_dir ip_repo]

# Scratch project containing just the RTL to package.
file mkdir $build_dir
create_project dot_product_pkg $proj_dir -part xck26-sfvc784-2LV-c -force

add_files -norecurse [file join $repo_root rtl/step04_dot_product/dot_product.sv]
set_property top dot_product [current_fileset]
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
set_property description {Streaming dot-product kernel (interleaved operands)} [ipx::current_core]
set_property core_revision 1 [ipx::current_core]

# Interface inference finds both streams but only associates the *master*
# with aclk on its own (watch the 19-4728 message: ASSOCIATED_BUSIF comes out
# as just 'm_axis'). Left that way, IP Integrator doesn't know aclk clocks the
# slave stream, so Connection Automation has less to work with — the same
# class of silent gap step 03 hit with the PS's disabled HP slave port.
#
# Names must match the inferred interfaces exactly, which are lowercase here:
# associate_bus_interfaces appends whatever string it's given, so passing
# S_AXIS/M_AXIS yields a list with bogus duplicate entries.
foreach busif {s_axis m_axis} {
    ipx::associate_bus_interfaces -busif $busif -clock aclk [ipx::current_core]
}

# Likewise tie aresetn to aclk so the reset is recognized as this clock's
# synchronous reset (active-low is inferred from the trailing 'n').
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
