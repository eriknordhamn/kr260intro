# KR260 ML Accelerator

Custom ML inference accelerator for the Xilinx Kria KR260, driven from Python on the PS via PYNQ. Development is stepwise — each milestone is a working, testable system before moving to the next.

## Platform

- **Board**: Kria KR260 Robotics Starter Kit (ZU5EV MPSoC)
- **PS**: Quad-core ARM Cortex-A53, Ubuntu + PYNQ
- **PL**: UltraScale+ FPGA fabric, custom RTL accelerator
- **PS–PL interface**: AXI4-Lite (control), AXI4/AXI4-Stream + DMA (data)

## Milestones

| # | Branch | Goal |
|---|--------|------|
| 1 | `step/01-environment` | Hello overlay — PS-only bitstream loads via PYNQ, validates toolchain |
| 2 | `step/02-axi-lite-echo` | Echo register in PL, read/write from Python |
| 3 | `step/03-dma-data-path` | Move buffers PS→PL→PS via AXI DMA |
| 4 | `step/04-dot-product` | Vector dot product kernel in RTL, verified from Python |
| 5 | `step/05-linear-layer` | Matrix-vector multiply (dense layer) |
| 6 | `step/06-activation` | ReLU in PL, layer-to-layer chaining |
| 7 | `step/07-ml-inference` | Full MLP inference end-to-end |

## Repository Layout

```
rtl/              RTL source (Verilog/SystemVerilog), one subdir per step
sim/              Testbenches and simulation scripts
sw/               Python host code and PYNQ scripts, one subdir per step
vivado/           Vivado TCL build scripts, one subdir per step
constraints/      XDC constraint files
build/            Generated artifacts (gitignored) — bitstreams, .hwh files
```

## Toolchain

- **Vivado 2025.1** at `/opt/Xilinx/2025.1/`
  - Device: `xck26-sfvc784-2LV-c`
  - Board part: `xilinx.com:kr260_som:part0:1.1`
- **Python 3.10** with PYNQ

Activate Vivado:
```bash
source /opt/Xilinx/2025.1/Vivado/settings64.sh
```

Set up the Python venv (first time):
```bash
sudo apt install python3.10-venv   # if not already installed
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## Step 01: Hello Overlay

Validates the full toolchain. Builds a bitstream with only the Zynq PS block (no custom PL logic), loads it on the KR260 via PYNQ.

**Files:**
- `vivado/step01_hello/build.tcl` — Vivado build script; creates the block design, runs synthesis and implementation, copies outputs to `build/step01_hello/`
- `sw/step01_hello/load_overlay.py` — PYNQ script to run on the KR260

**Build (on the dev machine):**
```bash
make step01
# or directly:
# vivado -mode batch -notrace -source vivado/step01_hello/build.tcl
```

Outputs: `build/step01_hello/hello_overlay.bit` and `build/step01_hello/hello_overlay.hwh`

**Deploy and test (on the KR260):**
```bash
# Copy both output files to the board
scp build/step01_hello/hello_overlay.{bit,hwh} user@kr260:~/step01/
scp sw/step01_hello/load_overlay.py user@kr260:~/step01/

# SSH to the board and run
ssh user@kr260
cd ~/step01
python3 load_overlay.py
```

Expected output:
```
Overlay loaded successfully.
IP cores in overlay: ['(none — PS only, as expected)']
Step 01 PASS
```
