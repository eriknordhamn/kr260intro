# Xilinx/AMD Tools Reference

A plain-language map of the tools involved in getting a bitstream from
Vivado onto the KR260 and running it from Python. Written after debugging
the step 01 overlay load, where several of these showed up in error
messages without much introduction.

## The big picture

Two very different worlds have to talk to each other:

- **The PL (Programmable Logic)** — the FPGA fabric. It doesn't run an OS;
  it just *is* whatever circuit you configured it to be, described by a
  **bitstream** (`.bit` file).
- **The PS (Processing System)** — four ARM cores running Ubuntu. This is
  a normal Linux machine.

Everything below exists to answer one question: *how does a Linux process
on the PS load a bitstream into the PL, and then talk to whatever circuit
is now running there?*

## The tools, roughly in the order they touch your data

### Vivado (dev machine only)

Xilinx/AMD's EDA tool. Takes your RTL (Verilog/SystemVerilog) plus
constraints and produces:

- **`.bit`** — the actual bitstream: the configuration data that gets
  loaded into the FPGA fabric.
- **`.hwh`** — the "hardware handoff" file: an XML description of what's
  *in* that bitstream (which AXI peripherals exist, their register maps,
  their addresses). PYNQ reads this to know what Python objects to expose
  for a given overlay — it's the bridge between "opaque blob of
  configuration bits" and "here's a `.ip_dict` you can call `.read()`
  and `.write()` on."

Vivado runs only on the dev machine in this project. Nothing Vivado-shaped
runs on the board itself.

### zocl (kernel driver, on the board)

A Linux kernel module (`lsmod | grep zocl`) that's the actual low-level
interface to the FPGA on Zynq/Zynq UltraScale+ chips (as opposed to a PCIe
card like an Alveo). It's what creates `/dev/dri/*` device nodes and is
what ultimately performs the bitstream download into the PL fabric. You
don't call it directly — everything above it (XRT, PYNQ) talks to it on
your behalf.

### XRT — Xilinx (now AMD) Runtime (on the board)

The userspace library/driver stack that sits between applications and
`zocl`. Originally built for datacenter PCIe accelerator cards (Alveo),
extended to also support embedded Zynq boards like the KR260. It provides:

- A C/C++ API that PYNQ and other tools use to talk to the device.
- Command-line tools, notably:
  - **`xbutil`** — inspect/manage the device itself (`xbutil examine`
    lists what devices XRT sees and whether they're "ready").
  - **`xclbinutil`** — packages/unpacks **`.xclbin`** files, XRT's binary
    container format for "a bitstream plus metadata." PYNQ generates a
    `.xclbin` on the fly from your `.bit`/`.hwh` pair every time you load
    an overlay — that's the tool that was silently failing during step 01
    (two conflicting copies were installed; see `docs/pynq-venv.md`).

On this board, XRT is installed as the Ubuntu **`xrt`** apt package
(`dpkg -l | grep xrt`), which lands under `/usr` rather than the
`/opt/xilinx/xrt` path Xilinx's own installers traditionally use — that
path difference is why `XILINX_XRT=/usr` matters (see below).

### `fpga_manager` (kernel subsystem, mentioned for context)

An older, more generic Linux kernel framework for FPGA configuration that
predates `zocl`/XRT's embedded support. Some PYNQ documentation and error
messages still reference it (e.g. `/sys/class/fpga_manager/.../firmware`)
because it's the historical mechanism PYNQ used on Zynq before the
XRT-based flow. On this install, `zocl` + XRT do the actual work.

### `XILINX_XRT` environment variable

Tells XRT-aware tools (and PYNQ) where XRT's own support files live. On
boards using Xilinx's own installer this is `/opt/xilinx/xrt`; on this
board (Ubuntu's `xrt` package) it's `/usr`. Nothing about XRT itself
requires this exact value — it just has to match wherever XRT was
actually installed. See `docs/pynq-venv.md` for where it gets set and why
that setting doesn't always reach the process that needs it.

### PYNQ (Python, on the board)

The layer this project actually codes against. `from pynq import Overlay`
wraps all of the above: reads the `.hwh` to know what's in your design,
calls into XRT to push the `.bit`/`.xclbin` into the PL via `zocl`, and
then exposes the peripherals it found as Python attributes/objects
(`ol.ip_dict`, register read/write, DMA channels, etc.) so the rest of
your code never has to think about bitstreams or XRT calls directly.

## Block design gotchas (Zynq UltraScale+)

Notes from building step 02's block design — things that cost time
because the GUI, the underlying Tcl properties, and Xilinx's own docs
don't always agree on names.

- **`M_AXI_GP0` is not what the GUI calls it.** On Zynq-7000, the PS's
  general-purpose AXI master port really is labelled `M_AXI_GP0` in the
  GUI. On Zynq UltraScale+ (this board), the underlying Tcl property is
  still `CONFIG.PSU__USE__M_AXI_GP0`, but the GUI checkbox and the port
  that appears on the PS block are both labelled **`AXI HPM0 FPD`**
  ("High Performance Master 0, Full Power Domain") — same signal,
  different name depending on which layer you're looking at. `M_AXI_GP1`
  ↔ `AXI HPM1 FPD` the same way.
- **Leave unused master ports disabled.** An enabled-but-unwired AXI
  master interface on the PS fails `validate_bd_design` with an
  unconnected-pin error — it won't silently sit there the way an unused
  physical FPGA pin could. If a design only needs one AXI-Lite master,
  disable the others rather than leaving them on.
- **Connection Automation inserts a SmartConnect, not an Interconnect.**
  Zynq-7000 designs typically get an `axi_interconnect`; on UltraScale+
  designs Vivado 2025.1 reaches for `xilinx.com:ip:smartconnect`
  instead, plus a `proc_sys_reset` block for the synchronized reset it
  needs. Both just route AXI transactions between masters/slaves — the
  substitution is a UltraScale+ default, not a decision to second-guess.
- **Address windows round up to 4 KB minimum**, even for a single
  32-bit register — that's AXI's minimum decode granularity, not
  something the IP declares. Don't expect `assign_bd_address` to hand
  back a window sized to what the peripheral actually uses.
- **HP slave ports are disabled by default — GP master ports aren't.**
  `M_AXI_HPM0_FPD` ("AXI HPM0 FPD") comes enabled from the board preset
  since basic PS-PL control needs it, but the high-bandwidth `S_AXI_HP0_FPD`
  ("AXI HP0 FPD") slave port used for bulk DDR access from PL masters
  (e.g. an AXI DMA's `M_AXI_MM2S`/`M_AXI_S2MM`) is off until you enable it
  yourself: re-customize the Zynq PS block, PS-PL Configuration → PS-PL
  Interfaces → Slave Interface → AXI HP. With it disabled, Connection
  Automation doesn't error — it just silently offers nothing for those
  master pins, which looks identical to a missed wiring step.

## Cheat sheet: which tool do I reach for?

| I want to... | Tool |
|---|---|
| Turn RTL into a bitstream | Vivado (dev machine) |
| Check if the board sees the FPGA device at all | `xbutil examine` |
| Manually inspect/build an `.xclbin` | `xclbinutil` |
| Load a bitstream and talk to it from Python | PYNQ's `Overlay` class |
| Everything PYNQ needs at once, correctly | `sw/run_pynq.sh` — see `docs/pynq-venv.md` |
