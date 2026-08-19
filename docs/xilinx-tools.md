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

Notes from building the block designs for steps 02–04 — things that cost
time because the GUI, the underlying Tcl properties, and Xilinx's own docs
don't always agree on names. The procedure these apply to is in
`docs/vivado-gui-session.md`.

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
- **"HP" in the dialog covers HP and HPC, and they're different ports.**
  The same Slave Interface → AXI HP page offers both the plain
  high-performance ports (`S_AXI_HP0..3_FPD`) and the cache-coherent ones
  (`S_AXI_HPC0/1_FPD`, which route through the CCI and can snoop the APU
  caches). Step 03 enabled **HPC0**, so its address segments read
  `SAXIGP0/HPC0_DDR_LOW`. Either works for DMA to DDR; just be aware the
  exported TCL names whichever you picked, and that a design written against
  one won't validate if the other is the one enabled.
- **Connection Automation does not wire AXI4-Stream.** It reasons about
  memory-mapped AXI, where there's an address map to work from. Which stream
  master feeds which stream slave is a design decision it won't guess, so
  point-to-point AXIS links (e.g. an AXI DMA's `M_AXIS_MM2S` into a custom
  kernel) must be dragged by hand. It won't complain about the missing link
  either — `validate_bd_design` catches genuinely unconnected pins, but a
  design where you forgot the kernel entirely and looped the DMA back on
  itself is perfectly valid.

- **A stream master without TKEEP connects anyway, and warns at synthesis.**
  Step 04's kernel carries only TDATA/TVALID/TREADY/TLAST — no TKEEP, no
  TSTRB. IP Integrator wires it to the AXI DMA without complaint, handling
  the two directions differently: on the S2MM side the DMA's TKEEP *input*
  is tied high automatically, which is the correct value for a 32-bit
  stream where all four bytes are always valid; on the MM2S side the DMA's
  TKEEP *output* has no destination and is left dangling, surfacing at
  synthesis as

  ```
  WARNING: [Synth 8-7071] port 'm_axis_mm2s_tkeep' of module
  'dot_product_accel_axi_dma_0_0' is unconnected for instance 'axi_dma_0'
  ```

  Both are benign as long as every beat carries all bytes, which is true
  for any stream of whole 32-bit words. TKEEP only starts to matter for
  streams with partial final beats, where it's what tells the receiver how
  many bytes of the last beat count — a byte-oriented stream whose length
  isn't a multiple of the bus width. Don't chase the warning; do add TKEEP
  to a kernel that will ever see a partial beat.

### AXI DMA's buffer length register defaults to 14 bits

*Width of Buffer Length Register* (`c_sg_length_width`) on the AXI DMA
defaults to **14**, capping any single transfer at `2**14 - 1` = 16383
bytes. The name is misleading — the `c_sg_` prefix reads like a Scatter
Gather setting, but it governs Direct Register mode too, which is the mode
PYNQ's simple `sendchannel`/`recvchannel` API drives.

That default is fine while transfers are a few KB, so steps 03 and 04 never
noticed. Step 05 hit it the moment a layer's weight packet reached 16384
bytes — a 4096x2 matrix — and it is a hard cap rather than an inconvenience
whenever a protocol uses `TLAST` to delimit a packet: each `transfer()` call
emits its own `TLAST`, so a packet cannot be split across two transfers
without ending it early.

Set it to **26** (the maximum, 64 MB) unless there is a reason not to. It
costs a handful of flip-flops in the DMA's length counter, and at 14 bits a
design is silently limited to layers of about 8191 int16 weights.

## IP packaging gotchas

From packaging step 04's streaming kernel — the AXI4-Stream equivalents of
what step 02 hit with AXI4-Lite.

- **Interface inference is reliable; clock *association* isn't.** Naming
  ports `s_axis_tdata`/`m_axis_tvalid`/… gets both streams inferred as
  `xilinx.com:interface:axis:1.0` with no manual work, same as `S_AXI_*`
  did for AXI4-Lite. But `ASSOCIATED_BUSIF` on the clock came out naming
  only the **master** stream (watch the `IP_Flow 19-4728` message during
  packaging). Without the slave stream listed, IP Integrator doesn't know
  `aclk` clocks it. Fix explicitly in `package_ip.tcl`:
  ```tcl
  foreach busif {s_axis m_axis} {
      ipx::associate_bus_interfaces -busif $busif -clock aclk [ipx::current_core]
  }
  ```
- **`associate_bus_interfaces` doesn't validate the interface name.** It
  appends whatever string it's handed, so passing `S_AXIS` when the inferred
  interface is `s_axis` produces the junk list
  `m_axis:s_axis:S_AXIS:M_AXIS` rather than an error. Match the case in
  `component.xml` exactly.
- **Localparams referenced by internal wires trigger parser warnings.**
  `[IP_Flow 19-587] HDL port or parameter '<wire>' has a dependency on the
  module local parameter ... '<NAME>'` — harmless, but it's noise on every
  packaging run, and it goes away if the localparam is replaced by a plain
  signal. Worth avoiding in code that gets packaged.
- **`ipx::check_integrity` passing is not the same as the IP being usable.**
  It checks the component is well-formed, not that the interfaces are
  associated the way IP Integrator needs. Read the inference messages.

## Cheat sheet: which tool do I reach for?

| I want to... | Tool |
|---|---|
| Turn RTL into a bitstream | Vivado (dev machine) |
| Check if the board sees the FPGA device at all | `xbutil examine` |
| Manually inspect/build an `.xclbin` | `xclbinutil` |
| Load a bitstream and talk to it from Python | PYNQ's `Overlay` class |
| Everything PYNQ needs at once, correctly | `sw/run_pynq.sh` — see `docs/pynq-venv.md` |
