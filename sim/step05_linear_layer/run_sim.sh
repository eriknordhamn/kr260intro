#!/usr/bin/env bash
# Compile and run tb_linear_layer under xsim in batch mode.
#
# Usage:
#   source /opt/Xilinx/2025.1/Vivado/settings64.sh   # if not already on PATH
#   sim/step05_linear_layer/run_sim.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
work_dir="$repo_root/build/step05_linear_layer/_sim"

mkdir -p "$work_dir"
cd "$work_dir"

xvlog --sv \
    "$repo_root/rtl/step05_linear_layer/linear_layer.sv" \
    "$repo_root/sim/step05_linear_layer/tb_linear_layer.sv"

xelab tb_linear_layer -s tb_linear_layer_sim

xsim tb_linear_layer_sim -R
