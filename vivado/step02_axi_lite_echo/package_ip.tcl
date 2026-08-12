# Step 02: package axi_lite_echo.sv as a Vivado IP core.
#
# Captured from a one-off interactive "Package IP" GUI session (used to
# confirm Vivado's bus-interface auto-detection correctly recognized the
# S_AXI_* ports as an AXI4-Lite slave interface) and cleaned up to run
# headlessly from here on. RTL is referenced from rtl/, not copied.
#
# Usage:
#   source /opt/Xilinx/2025.1/Vivado/settings64.sh
#   vivado -mode batch -source vivado/step02_axi_lite_echo/package_ip.tcl
#
# Output: build/step02_axi_lite_echo/ip_repo/component.xml

set script_dir  [file dirname [file normalize [info script]]]
set repo_root   [file normalize [file join $script_dir ../..]]
set build_dir   [file join $repo_root build/step02_axi_lite_echo]
set proj_dir    [file join $build_dir _vivado_project]
set ip_repo_dir [file join $build_dir ip_repo]

# Scratch project containing just the RTL to package.
file mkdir $build_dir
create_project axi_lite_echo_pkg $proj_dir -part xck26-sfvc784-2LV-c -force

add_files -norecurse [file join $repo_root rtl/step02_axi_lite_echo/axi_lite_echo.sv]
set_property top axi_lite_echo [current_fileset]
update_compile_order -fileset sources_1

# package_project infers the AXI4-Lite (aximm), clock, and reset bus
# interfaces automatically from the S_AXI_* / S_AXI_ACLK / S_AXI_ARESETN
# signal naming convention used in the RTL - no manual interface wiring.
file delete -force $ip_repo_dir
ipx::package_project -root_dir $ip_repo_dir -vendor user.org -library user \
    -taxonomy /UserIP -import_files -set_current false

ipx::unload_core [file join $ip_repo_dir component.xml]
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project \
    -directory $ip_repo_dir [file join $ip_repo_dir component.xml]
update_compile_order -fileset sources_1

set_property vendor kr260intro.local [ipx::current_core]
set_property description {AXI4-Lite echo register} [ipx::current_core]
set_property core_revision 1 [ipx::current_core]

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
