# Project: Kria KR260 Custom Accelerator

## Platform

- **Board**: Xilinx Kria KR260 Robotics Starter Kit
- **SoC**: Zynq UltraScale+ MPSoC (ZU5EV)
  - PS (Processing System): Quad-core ARM Cortex-A53 running Ubuntu
  - PL (Programmable Logic): UltraScale+ FPGA fabric
- **OS**: Ubuntu on the PS (ARM64)

## Project Goal

Build a custom ML inference accelerator in the PL, driven from Python on the PS via PYNQ. Development is stepwise — each milestone is a working, testable system before moving to the next.

## Key Concepts

- The PS runs Ubuntu + PYNQ and acts as the host/controller
- The PL contains the custom RTL accelerator logic
- PS-PL communication uses AXI interfaces:
  - **AXI4-Lite**: control/status registers (start, done, config)
  - **AXI4 / AXI4-Stream + DMA**: bulk data transfer (weights, activations)
- PYNQ loads bitstreams as overlays and exposes PL registers/DMA to Python

## Toolchain

- **RTL**: Verilog or SystemVerilog
- **Synthesis/Implementation**: Vivado
- **PS software**: Python on Ubuntu ARM64 via PYNQ
- **Integration**: PYNQ overlay flow (`.bit` + `.hwh`), Xilinx DMA IP

## Development Milestones (planned)

1. **Environment** — PYNQ installed on KR260, Vivado targeting the board, "hello overlay" bitstream loads cleanly
2. **AXI-Lite passthrough** — trivial RTL (echo register) controlled from Python; validates the PS-PL control path
3. **DMA data path** — move a buffer PS→PL→PS via AXI DMA; validates bulk transfer
4. **Compute kernel v1** — vector dot product or MAC array in RTL, driven by DMA, verified numerically from Python
5. **Linear layer** — matrix-vector multiply; the core of a neural network dense layer
6. **Activation + chaining** — ReLU (or similar) in PL, layer-to-layer data flow without returning to PS
7. **ML inference** — run a small model (e.g. MLP) end-to-end on the accelerator from Python

## Vivado: CLI vs GUI

The goal is a fully scripted, reproducible build. The GUI is used as a one-time scaffolding tool.

**Fully CLI / scripted:**
- RTL source (Verilog/SystemVerilog) — plain text files
- Simulation — `xvlog`/`xelab`/`xsim` or Verilator via Makefile
- Synthesis, implementation, bitstream — `vivado -mode batch -source build.tcl`
- Constraints (`.xdc`) — plain text
- Python/PYNQ code on the PS

**GUI needed once per milestone that introduces new IP:**
- **Block Design (IP Integrator)** — wire up Zynq PS, AXI Interconnect, AXI DMA, custom IP. The Zynq PS block has hundreds of settings; configure in GUI, then `File → Export Block Design as TCL`. That script recreates the design headlessly and generates the `.hwh` PYNQ needs.
- **IP Packager** — package custom RTL as a Vivado IP core for the block design; export to TCL after first use.

**Workflow per milestone:**
1. Configure new IP blocks in the Vivado GUI (one-off)
2. Export block design as TCL → commit the script, not the project dir
3. All iteration (RTL edits, re-synthesis, re-sim) runs from CLI

## Directory Layout

- `rtl/` — RTL source (Verilog/SystemVerilog), organized by module
- `sim/` — testbenches and simulation scripts
- `sw/` — Python host code and PYNQ notebooks/drivers
- `vivado/` — TCL scripts to recreate the Vivado project; no generated files committed
- `constraints/` — XDC constraint files

## Conventions

- Do not commit Vivado-generated files: `.xpr`, `project.runs/`, `project.cache/`, IP output products, bitstreams
- Each milestone gets its own subdirectory under `rtl/`, `sim/`, and `sw/` so previous steps stay runnable
- Bitstreams and `.hwh` files are build artifacts — generate locally, deploy to board manually or via script

## Git Workflow

- Main branch: `main`
- Each milestone is developed on a feature branch (e.g. `step/01-environment`, `step/02-axi-lite-echo`)
- Merge to `main` when the milestone is complete and working
