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
- **Synthesis/Implementation**: Vivado 2025.1, installed at `/opt/Xilinx/2025.1/Vivado/`
- **Simulation**: Vivado `xsim` (bundled with Vivado)
- **PS software**: Python on Ubuntu ARM64 via PYNQ
- **Integration**: PYNQ overlay flow (`.bit` + `.hwh`), Xilinx DMA IP

To activate the toolchain in a shell session:
```bash
source /opt/Xilinx/2025.1/Vivado/settings64.sh
```
This puts `vivado`, `xvlog`, `xelab`, `xsim`, etc. on PATH. Add to shell config or run before invoking any Vivado/xsim commands.

Key identifiers for the KR260:
- Device part: `xck26-sfvc784-2LV-c`
- Board part: `xilinx.com:kr260_som:part0:1.1`

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
- **IP Packager** — package custom RTL as a Vivado IP core for the block design; export to TCL after first use. The packager should **reference** RTL files from `rtl/`, not copy them, so `rtl/` stays the single source of truth. Export the packaging steps as `package_ip.tcl` (next to `build.tcl` under `vivado/<step>/`) — the packaged IP output itself (`component.xml`, `xgui/`, etc.) is generated, not committed; see Directory Layout.

**Workflow per milestone:**
1. Configure new IP blocks in the Vivado GUI (one-off)
2. Export block design as TCL → commit the script, not the project dir
3. All iteration (RTL edits, re-synthesis, re-sim) runs from CLI

The step-by-step procedure for both the GUI session and the simulation loop
is in `docs/vivado-gui-session.md` — follow it rather than reconstructing it
from a previous step's TCL. Zynq UltraScale+ traps that cost time before are
in `docs/xilinx-tools.md` → Block design gotchas.

An exported block-design TCL may be hand-edited to prototype a small change,
but it must validate headlessly before being believed, and a later GUI export
**overwrites the file wholesale** — never merge an export into hand edits.

## Directory Layout

- `rtl/` — RTL source (Verilog/SystemVerilog), organized by module
- `sim/` — testbenches and simulation scripts
- `sw/` — Python host code and PYNQ notebooks/drivers
- `vivado/` — TCL scripts to recreate the Vivado project; no generated files committed
- `constraints/` — XDC constraint files
- `docs/` — reference docs (board setup, Xilinx tooling, PYNQ internals) — not step-specific, read once and reused across milestones
- `build/` — everything Vivado generates, gitignored entirely. Per step:
  `build/<step>/_vivado_project/` (scratch project state — runs, cache, IP
  output products), `build/<step>/ip_repo/` (packaged custom IP, output of
  `package_ip.tcl` — same tier as `_vivado_project/`, never a top-level
  source dir), and the final deliverables `build/<step>/*.bit` + `*.hwh`
  copied out for board deploy.

## Conventions

- Do not commit Vivado-generated files: `.xpr`, `project.runs/`, `project.cache/`, IP output products, bitstreams
- Each milestone gets its own subdirectory under `rtl/`, `sim/`, and `sw/` so previous steps stay runnable
- Every milestone with custom RTL gets a self-checking testbench under `sim/<step>/`, runnable standalone through `xvlog`/`xelab`/`xsim` with no Vivado project — it prints a single `=== TB PASS ===` / `=== TB FAIL ===` line, so passing never depends on reading a waveform
- Keep module ports and parameters plain Verilog-compatible (no packed structs, interfaces, or enums on the boundary) even when the internals use SystemVerilog — the IP packager only partially supports SystemVerilog top files
- Each step's Makefile targets follow the same names: `sim_step<NN>`, `package_step<NN>`, `bd_step<NN>` (scratch project for GUI work), `validate_step<NN>` (block design only, no synthesis), `step<NN>` (full bitstream)
- `build.tcl` takes `-tclargs validate` to source the block design, validate, and stop — a ~1 minute check on a block-design change instead of a ~20 minute build. Run it on any exported or edited BD script before a full build
- The block design's name must match `design_name` in that step's `build.tcl`; the build globs for `<design_name>.bd` and its `.hwh`
- Bitstreams and `.hwh` files are build artifacts — generate locally, deploy to board manually or via script
- Every board-side PYNQ script must run through `sw/run_pynq.sh`, not a bare `sudo .../python3`. `sudo` and systemd both skip the login-shell environment PYNQ depends on (`XILINX_XRT`, venv-first `PATH`) — see `docs/pynq-venv.md`. Deploy `run_pynq.sh` alongside each step's driver script and invoke it as `./run_pynq.sh <script.py>`.

## Git Workflow

- Main branch: `main`
- Each milestone is developed on a feature branch (e.g. `step/01-environment`, `step/02-axi-lite-echo`)
- Merge to `main` when the milestone is complete and working
