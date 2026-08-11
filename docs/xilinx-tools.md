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

## Cheat sheet: which tool do I reach for?

| I want to... | Tool |
|---|---|
| Turn RTL into a bitstream | Vivado (dev machine) |
| Check if the board sees the FPGA device at all | `xbutil examine` |
| Manually inspect/build an `.xclbin` | `xclbinutil` |
| Load a bitstream and talk to it from Python | PYNQ's `Overlay` class |
| Everything PYNQ needs at once, correctly | `sw/run_pynq.sh` — see `docs/pynq-venv.md` |
