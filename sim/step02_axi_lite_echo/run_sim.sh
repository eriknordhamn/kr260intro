#!/usr/bin/env bash
# Compile and run tb_axi_lite_echo under xsim in batch mode.
#
# Usage:
#   source /opt/Xilinx/2025.1/Vivado/settings64.sh   # if not already on PATH
#   sim/step02_axi_lite_echo/run_sim.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
work_dir="$repo_root/build/step02_axi_lite_echo/_sim"

mkdir -p "$work_dir"
cd "$work_dir"

xvlog --sv \
    "$repo_root/rtl/step02_axi_lite_echo/axi_lite_echo.sv" \
    "$repo_root/sim/step02_axi_lite_echo/tb_axi_lite_echo.sv"

xelab tb_axi_lite_echo -s tb_axi_lite_echo_sim

xsim tb_axi_lite_echo_sim -R
