#!/usr/bin/env bash
# Compile and run tb_dot_product under xsim in batch mode.
#
# Usage:
#   source /opt/Xilinx/2025.1/Vivado/settings64.sh   # if not already on PATH
#   sim/step04_dot_product/run_sim.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
work_dir="$repo_root/build/step04_dot_product/_sim"

mkdir -p "$work_dir"
cd "$work_dir"

xvlog --sv \
    "$repo_root/rtl/step04_dot_product/dot_product.sv" \
    "$repo_root/sim/step04_dot_product/tb_dot_product.sv"

xelab tb_dot_product -s tb_dot_product_sim

xsim tb_dot_product_sim -R
