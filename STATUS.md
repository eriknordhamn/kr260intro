# Project Status

## Current Step: 05 — Linear Layer — NOT STARTED

Matrix-vector multiply — the core of a dense NN layer. Design not chosen
yet; the open questions are how the weight matrix reaches the PL (streamed
alongside the vector as in step 04, preloaded into BRAM, or a second DMA
channel) and whether rows are computed serially by one dot-product engine
or in parallel by a MAC array.

## Step 04 — Dot Product Kernel — COMPLETE

First real compute in the PL. A streaming dot-product kernel sits where step
03 looped the DMA's `M_AXIS_MM2S` straight back into its `S_AXIS_S2MM`. Both
operand vectors arrive interleaved on the single stream (`a0 b0 a1 b1 …`,
`TLAST` on the final beat), so the vector length is implicit in the packet
and the IP needs no control interface at all — no AXI4-Lite, no registers.
Built to a bitstream, deployed, and verified on the KR260:
`dot_product_test.py` printed `Step 04 PASS`. See the walkthrough below.

## Step 03 — DMA Loopback — COMPLETE

AXI DMA wired in a block design with its MM2S (read) stream looped
directly back into its S2MM (write) stream — no PL logic in between.
Built to a bitstream, deployed, and verified on the KR260.
`dma_loopback_test.py` DMA'd a 1024-word buffer PS→PL→PS and confirmed
every word matched, printing `Step 03 PASS`. See the walkthrough below.

## Step 02 — AXI-Lite Echo Register — COMPLETE

RTL simulated, packaged as a Vivado IP core, wired to the Zynq PS in a
block design, built to a bitstream, deployed, and verified on the KR260.
`echo_test.py` wrote and read back five test values (including
`0x00000000` and `0xFFFFFFFF`) through the AXI-Lite register and printed
`Step 02 PASS`. See the walkthrough below for how the pipeline fits
together, or `docs/vivado-flow.html` for the diagrammed version.

## Step 01 — Environment / Hello Overlay — COMPLETE

Bitstream built, PYNQ installed via the Kria-PYNQ installer, overlay
deployed and loaded on the board. `load_overlay.py` printed `Step 01 PASS`.

### Notes

- `build.tcl` had a bug where the `.hwh` glob path used `.srcs/` instead of
  `.gen/` — fixed. Future `make step01` runs will complete without a manual
  copy step.
- The full build takes ~20 min on an i5-8500 (synthesis dominates).
- Deploy/load required two `sudo` env fixes not obvious from the plain
  instructions — see the "Issue Log: overlay load on the board" section
  below and `docs/board-setup.md` for the working command.

---

## Issue Log: PYNQ install on the KR260

Getting PYNQ working on the board took several rounds of troubleshooting.
Recorded here so we don't re-derive this from scratch on a future board
re-image.

**Root cause of all of it:** the KR260 runs *stock Canonical Ubuntu*, not
Xilinx's all-in-one custom PYNQ board image. A plain `pip install pynq`
assumes the latter — it expects headers, libraries, and a CMA allocator
that Xilinx normally pre-bundles. On stock Ubuntu, none of that exists yet,
so pip's source build fails repeatedly, one missing piece at a time:

1. **Read timeout mid-download.** `pynq` ships only as a ~60MB source
   tarball (no prebuilt ARM64 wheel). A slow/flaky board connection hit
   pip's default socket read timeout partway through. Not fixed directly —
   superseded by switching to the Kria-PYNQ installer (see below), which
   handles retries as part of its own flow.

2. **`fatal error: xf86drm.h: No such file or directory`.** Missing
   `libdrm-dev` — needed to build PYNQ's DisplayPort extension. (The KR260
   does have a DisplayPort output, so this dependency is genuinely used,
   not dead weight.)

3. **`fatal error: libxlnk_cma.h: No such file or directory`.** Missing the
   legacy `xlnk` CMA allocator header/library. This one isn't available via
   `apt` at all — it's something Xilinx builds and bundles themselves as
   part of their board image tooling, not a package in Ubuntu's repos.
   This is what confirmed raw `pip install pynq` wasn't the right approach
   on stock Ubuntu — chasing missing native headers one apt package at a
   time wasn't converging.

### Plan change: use the Kria-PYNQ installer, not raw pip

Switched to AMD/Xilinx's dedicated installer, built for exactly this
situation (PYNQ on stock Ubuntu for Kria SOMs):

```bash
git clone https://github.com/Xilinx/Kria-PYNQ.git
cd Kria-PYNQ
sudo bash install.sh -b KR260
```

This installs system dependencies, builds the native CMA/display pieces,
and — importantly — **installs PYNQ into a dedicated virtual environment**
at `/usr/local/share/pynq-venv`, rather than system or user Python. It also
stands up JupyterLab as a systemd service (`:9090/lab`, password `xilinx`),
which this project doesn't use but is available.

**Consequence for how we run scripts on the board:** every script that
touches PYNQ must use that venv's interpreter explicitly —
`/usr/local/share/pynq-venv/bin/python3` — not plain `python3` or
`sudo python3` (which resolves to system Python and won't find PYNQ).
`docs/board-setup.md` and `sw/step01_hello`'s deploy instructions are
updated to reflect this.

Confirmed working: `import pynq` succeeds and reports a version when
run through the venv interpreter.

---

## Issue Log: overlay load on the board

Even with PYNQ installed and the bitstream copied over, `load_overlay.py`
failed twice more under plain `sudo /usr/local/share/pynq-venv/bin/python3`,
both times because `sudo` doesn't inherit the calling shell's environment
the way the plain instructions assumed.

1. **`Device.devices` was empty** — `pynq.Device` warned
   `No devices found, is the XRT environment sourced?`, even though
   `sudo xbutil examine` (outside Python) showed the device as ready.

2. **`FileNotFoundError: .../t.xclbin`** — once the device was found,
   `Overlay()` failed building the temporary xclbin. PYNQ shells out to
   `xclbinutil`, and there are two copies on this board: the Ubuntu `xrt`
   apt package's (`/usr/bin/xclbinutil`), which **segfaults** on this
   board, and a working one bundled in the pynq-venv.

Chasing each with a hand-plumbed `sudo VAR=... PATH=...` line worked but
felt like guesswork, so before settling for it we looked for where the
board's own tooling solves the same problem — `jupyter.service` also runs
as root via systemd and also needs PYNQ working, so however it gets a
correct environment must be the vendor-intended mechanism, not something
to reverse-engineer ourselves.

Found it: `/usr/local/bin/start_jupyter.sh` (systemd's `ExecStart`) begins
with a comment — *"Source the environment as the init system won't"* — and
explicitly re-sources `/etc/environment` and every `/etc/profile.d/*.sh`.
`/etc/profile.d/pynq_venv.sh` is where `XILINX_XRT=/usr` actually comes
from, plus it activates the PYNQ venv (which is what puts the working
`xclbinutil` first on `PATH` in a normal login shell) and runs a
device-tree-overlay insert step. None of that runs under a plain `sudo`
because `sudo`, like systemd, doesn't inherit login-shell environment.

**Resolution:** rather than pass `XILINX_XRT`/`PATH` by hand, mirror what
`start_jupyter.sh` does — re-source `/etc/environment` +
`/etc/profile.d/*.sh` as root, then launch the venv's Python. Wrapped as
`sw/run_pynq.sh`; any script that touches PYNQ on the board should run
through it:

```bash
./run_pynq.sh load_overlay.py
```

Output: `Overlay loaded successfully.` / `IP cores in overlay:
['zynq_ultra_ps_e_0']` / `Step 01 PASS`.

---

## Completed Steps

- **Step 01 — Environment / Hello Overlay.** Vivado build → PYNQ install via
  Kria-PYNQ installer → bitstream deployed and loaded on the board,
  `Step 01 PASS`. See issue logs above for the PYNQ-install and
  overlay-load gotchas hit along the way.

- **Step 02 — AXI-Lite Echo Register.** First custom RTL, packaged as a
  Vivado IP core and wired to the Zynq PS. Verified on hardware —
  `echo_test.py` printed `Step 02 PASS` after five write/read-back checks.
  See the walkthrough below.

- **Step 03 — DMA Loopback.** Stock Xilinx AXI DMA IP only, no custom
  RTL — validates the bulk-transfer path ahead of step 04's compute
  kernel. Verified on hardware — `dma_loopback_test.py` DMA'd a
  1024-word buffer PS→PL→PS and printed `Step 03 PASS`. See the
  walkthrough below.

- **Step 04 — Dot Product Kernel.** First compute in the PL: a streaming
  dot-product kernel between the DMA's MM2S and S2MM channels, operands
  interleaved on one stream, length implicit in `TLAST`. Verified on
  hardware — `dot_product_test.py` printed `Step 04 PASS`. See the
  walkthrough below.

---

## Step 02 walkthrough: AXI-Lite Echo Register

Goal: prove the PS↔PL *control* path (register read/write over
AXI4-Lite) before attempting bulk data movement (step 03, DMA). The
whole pipeline, file by file:

```
rtl/step02_axi_lite_echo/axi_lite_echo.sv     hand-written RTL
sim/step02_axi_lite_echo/                     xsim testbench, no Vivado project needed
vivado/step02_axi_lite_echo/package_ip.tcl    RTL -> Vivado IP core (headless)
vivado/step02_axi_lite_echo/axi_lite_echo_overlay_bd.tcl   PS + IP block design (from GUI export)
vivado/step02_axi_lite_echo/build.tcl         ties it together -> .bit + .hwh
sw/step02_axi_lite_echo/                      PYNQ driver (board-side)
```

### RTL — `rtl/step02_axi_lite_echo/axi_lite_echo.sv`

A minimal AXI4-Lite slave: one 32-bit register at address 0x0, write
then read back. Deliberately the simplest legal AXI4-Lite slave —
unpipelined (one write or read in flight at a time), single register so
address bits aren't decoded. Port names follow Xilinx's standard
`S_AXI_*` naming convention on purpose: Vivado's IP packager and block
design tooling auto-infer the AXI4-Lite interface, clock, and reset
purely from those names, which is what makes `package_ip.tcl` below
fully scriptable instead of requiring manual interface wiring in the
GUI.

### Simulation — `sim/step02_axi_lite_echo/`

`tb_axi_lite_echo.sv` drives the DUT directly (no Vivado project, no
board) with self-checking write/read-back transactions — reset value,
two distinct values, and a back-to-back write/read to catch handshake
bugs. `run_sim.sh` (→ `make sim_step02`) compiles and runs it under
`xsim` in batch mode. This is the fast inner loop for RTL changes —
seconds, not the ~20 minutes a full bitstream rebuild takes.

### `vivado/step02_axi_lite_echo/package_ip.tcl`

Turns the RTL into a Vivado IP core Vivado's block-design canvas can
place. Fully headless — no GUI needed to *run* it (a one-off GUI
session was used earlier only to confirm Vivado's interface
auto-detection worked as expected; those exact commands, journaled by
Vivado, were cleaned up into this script). Steps:

1. Creates a throwaway project (`build/step02_axi_lite_echo/_vivado_project`)
   containing only `axi_lite_echo.sv`, added by reference (not copied).
2. `ipx::package_project` — packages it as IP, auto-inferring the
   `S_AXI` AXI4-Lite (`aximm`), clock, and reset bus interfaces from the
   signal names.
3. Re-opens the packaged core (`ipx::edit_ip_in_project`) to set
   vendor/description/revision metadata.
4. Regenerates GUI/checksum files and saves (`ipx::create_xgui_files`,
   `ipx::update_checksums`, `ipx::save_core`).
5. Closes both scratch projects it opened.

Output: `build/step02_axi_lite_echo/ip_repo/component.xml` (gitignored,
regenerated on demand — `make package_step02`).

### `vivado/step02_axi_lite_echo/axi_lite_echo_overlay_bd.tcl`

Not hand-written — this is Vivado's own **File → Export Block Design as
TCL** output, committed close to verbatim, per CLAUDE.md's
GUI-once-then-export convention. Recreates the block design:

- Zynq UltraScale+ PS, board preset applied, with `M_AXI_HPM0_FPD`
  (labelled `M_AXI_GP0` in the underlying Tcl properties — Xilinx's GUI
  and property-name conventions disagree here) enabled and GP1/GP2
  disabled — the one AXI-Lite master port we need, nothing else.
- An instance of the packaged `axi_lite_echo` IP.
- An AXI SmartConnect between them (auto-inserted by Connection
  Automation during the interactive session), plus a
  `proc_sys_reset` block generating the synchronized reset the
  SmartConnect and echo IP need.
- Address map: `axi_lite_echo`'s register is mapped at `0xA0000000`
  (4 KB address window — AXI's minimum decode granularity, even though
  the register itself is 4 bytes).

The GUI session that produced this only happens again if the block
design itself changes (new IP, new connections) — routine RTL edits
inside `axi_lite_echo.sv` don't touch this file at all.

### `vivado/step02_axi_lite_echo/build.tcl`

The end-to-end headless build, structured like step01's but sourcing
the exported block-design script instead of inlining `create_bd_cell`
calls directly:

1. Creates the project, registers `ip_repo/` as an IP repository
   (`set_property ip_repo_paths`) so `axi_lite_echo` resolves in the
   catalog.
2. Sources `axi_lite_echo_overlay_bd.tcl` — builds, validates, and
   saves the block design.
3. `make_wrapper` generates the HDL top-level wrapping the block
   design, added to the project as the synthesis top.
4. Runs synthesis, then implementation through bitstream generation,
   checking `PROGRESS` after each and erroring out on failure rather
   than silently continuing.
5. Copies the `.bit` and `.hwh` deliverables out to
   `build/step02_axi_lite_echo/`.

Requires `package_ip.tcl` to have already run (`make step02` chains
`package_step02` before `build.tcl` automatically).

### Makefile targets

| Target | Does |
|---|------|
| `make sim_step02` | RTL testbench under `xsim` — seconds |
| `make package_step02` | RTL → Vivado IP core (headless) |
| `make step02` | Full bitstream build (packages IP first, then `build.tcl`) — ~20 min |

### Software (planned)

`sw/step02_axi_lite_echo/` — a PYNQ driver script (run via
`./run_pynq.sh`, per the established board-side convention) that loads
the overlay, writes a value to the echo register through PYNQ's
register/MMIO access, reads it back, and asserts it matches.

---

## Step 03 walkthrough: DMA Loopback

Goal: prove the PS↔PL *bulk-transfer* path (AXI DMA moving a buffer
PS→PL→PS) before attempting a compute kernel that actually processes
the stream (step 04). No custom RTL — the DMA's `M_AXIS_MM2S` output is
wired straight into its own `S_AXIS_S2MM` input, so a buffer read out
of DDR streams directly back into a second DDR buffer with no PL logic
between them. File by file:

```
vivado/step03_dma_loopback/create_bd_scratch_project.tcl   scratch project for GUI block-design work
vivado/step03_dma_loopback/dma_loopback_bd.tcl              PS + AXI DMA block design (from GUI export)
vivado/step03_dma_loopback/build.tcl                        ties it together -> .bit + .hwh
sw/step03_dma_loopback/                                     PYNQ driver (board-side)
```

Unlike step 02, there's no `package_ip.tcl` — both IP blocks (Zynq PS,
AXI DMA) are stock Xilinx IP, nothing to package.

### Block design

Built interactively in the GUI (Direct Register mode — Scatter Gather
disabled, both MM2S and S2MM channels enabled), then exported via
**File → Export Block Design as TCL**. Two gotchas hit along the way,
now recorded in `docs/xilinx-tools.md`'s block-design gotchas section
so they don't cost time again:

1. **Validation failed with unconnected clocks** the first pass — some
   of the DMA's clock inputs weren't picked up because Connection
   Automation was run in separate passes for `S_AXI_LITE` and `M_AXI`
   rather than all at once. Fixed by re-running Connection Automation
   until it stopped offering anything new.
2. **`M_AXI_MM2S`/`M_AXI_S2MM` were never offered for auto-wiring at
   all**, and validation didn't flag it as an error. Root cause: the
   PS's `S_AXI_HP0_FPD` slave port — needed for any PL master to reach
   DDR at DMA-relevant bandwidth — is **off by default**, unlike
   `M_AXI_HPM0_FPD` which the board preset enables automatically.
   Connection Automation has no compatible slave to route to when it's
   disabled, so it silently offers nothing instead of erroring. Fixed
   by re-customizing the Zynq PS block (PS-PL Configuration → PS-PL
   Interfaces → Slave Interface → AXI HP), then re-running Connection
   Automation, which then wired both ports through.

   Note the port that actually ended up enabled was **`S_AXI_HPC0_FPD`**,
   the cache-coherent one — the exported TCL sets `PSU__USE__S_AXI_GP0` and
   its address segments read `SAXIGP0/HPC0_DDR_LOW`, not HP0. Both live on
   the same "AXI HP" page of the dialog, which is why the distinction is
   easy to lose; see `docs/xilinx-tools.md`.

### `vivado/step03_dma_loopback/build.tcl`

Same shape as step 02's `build.tcl` minus the IP-packaging
prerequisite: create project → source the exported block-design script
→ `make_wrapper` → synthesis → implementation/bitstream → copy `.bit`/
`.hwh` out to `build/step03_dma_loopback/`. Clean build: 0 errors, 0
critical warnings, synthesis ~46s / implementation ~4 min on this
design.

### `sw/step03_dma_loopback/dma_loopback_test.py`

Allocates two `pynq.allocate()` buffers (physically-contiguous,
cache-coherent — a regular numpy array isn't safe to hand to a DMA
engine), fills the send buffer with a 1024-word test pattern, arms
`dma.recvchannel.transfer()` before `dma.sendchannel.transfer()` (so
`S_AXIS_S2MM`'s `tready` is already asserted when MM2S starts pushing
data into the loopback wire), waits on both channels, then compares
buffers word-for-word.

**Verified on hardware:**
```
$ ./run_pynq.sh dma_loopback_test.py
Overlay loaded successfully.
IP cores in overlay: ['axi_dma_0', 'zynq_ultra_ps_e_0']
All 1024 words matched.
Step 03 PASS
```

### Makefile targets

| Target | Does |
|---|------|
| `make step03` | Full bitstream build (no IP packaging step needed) |

---

## Step 04 walkthrough: Dot Product Kernel

Goal: put real arithmetic in the stream path step 03 proved out. The DMA
loopback wire is cut and the kernel dropped in between, so a buffer read out
of DDR is *processed* on its way back rather than merely copied.

```
rtl/step04_dot_product/dot_product.sv              the kernel
sim/step04_dot_product/tb_dot_product.sv           self-checking testbench (10 checks)
vivado/step04_dot_product/package_ip.tcl           packages the kernel as an IP core
vivado/step04_dot_product/dot_product_accel_bd.tcl PS + AXI DMA + kernel block design
vivado/step04_dot_product/build.tcl                ties it together -> .bit + .hwh
sw/step04_dot_product/dot_product_test.py          PYNQ driver (board-side)
```

### Interface: no control interface

Both operand vectors arrive interleaved on the single MM2S stream:

```
beat:  0   1   2   3        2N-2   2N-1
data:  a0  b0  a1  b1  ...  a[N-1] b[N-1](TLAST)
                 |
                 v
out:   sum(TLAST)     one beat, S2MM writes 4 bytes back to DDR
```

Vector length is implicit in `TLAST`, so the IP has **no registers and no
AXI4-Lite port at all** — the entire block design is step 03's with the
loopback wire cut. Chosen over a second DMA channel or AXI-Lite-loaded
weights precisely because it reuses step 03's design almost verbatim; the
pairing convention is the artificial part, and step 05 revisits it when a
matrix needs real operand bandwidth.

### RTL — `rtl/step04_dot_product/dot_product.sv`

Even beats latch an `a`, odd beats supply the matching `b`, multiply signed,
and accumulate into a 64-bit register. `TLAST` emits the accumulator's low 32
bits as one output beat (also marked `TLAST`, which is what tells S2MM the
transfer is done) and clears the accumulator, so back-to-back packets are
independent. Two deliberate choices worth remembering:

- `s_axis_tready = !m_axis_tvalid` — the input stalls only while a result is
  waiting to be drained, and is **not** a function of `m_axis_tready`. That
  keeps a combinational path from running downstream `TREADY` into upstream
  `TREADY`. Costs one cycle at end-of-packet, nothing in steady state.
- A malformed packet (`TLAST` on an even beat, so the last `a` has no `b`)
  discards the dangling element and emits the accumulator anyway. Flushing
  beats hanging: a stalled kernel would wedge the DMA channel with no error
  visible to the PS.

Step 04 predates the project's SystemVerilog convention and is Verilog-2001
throughout (`reg`/`wire`, bare `always @(posedge …)`).

### Simulation — `sim/step04_dot_product/`

Ten self-checking cases under xsim, all passing: signed operands, `TVALID`
gaps, randomized backpressure, back-to-back packets, 1024 pairs, and the
malformed odd-beat packet.

### Block design — the export that never landed

`dot_product_accel_bd.tcl` is **a hand-edited copy of step 03's export, not
a GUI export**. The GUI session's *File → Export Block Design as TCL* never
wrote the file — it stayed at its pre-session mtime and unchanged in git —
and `build.tcl` sources the committed script, so the bitstream was built from
the hand-edit.

That was caught and checked rather than assumed. Comparing the scratch
project's `dot_product_accel.bd` against the committed TCL:

- same 6 cells: `zynq_ultra_ps_e_0`, `axi_dma_0`, `dot_product_0`, `axi_smc`,
  `axi_smc_1`, `rst_ps8_0_99M`
- all 8 interface nets identical, including `M_AXIS_MM2S → s_axis`,
  `m_axis → S_AXIS_S2MM`, and `axi_smc_1/M00_AXI → S_AXI_HPC0_FPD`
- `c_include_sg = 0` in both

The committed script is therefore trustworthy and the design reproducible
from source. **Decision: left alone** — re-exporting would overwrite a
known-good, now hardware-validated file with a functionally identical one.
The general lesson (confirm with `git status` that an export actually landed)
is now a rule in `CLAUDE.md` and a checklist item in
`docs/vivado-gui-session.md`.

Synthesis emits one warning worth recognising rather than chasing:
`[Synth 8-7071] port 'm_axis_mm2s_tkeep' … is unconnected` — the kernel has
no `TKEEP` input, so the DMA's output has nowhere to go. Benign for a stream
where every beat carries all four bytes. Written up in
`docs/xilinx-tools.md`.

### `sw/step04_dot_product/dot_product_test.py`

Same buffer discipline as step 03 (`pynq.allocate()`, receive channel armed
before the send channel), with the operands interleaved into one send buffer
via `send_buf[0::2] = a` / `send_buf[1::2] = b`. Test design worth keeping:

- operands drawn from ±2**15 so a 1024-element sum comfortably exceeds
  2**32 — that is what actually exercises the output truncation, instead of
  passing on small numbers
- the reference sum is computed with Python ints, not numpy: 1024 products of
  ~2**30 risk overflowing int64 accumulation, and a silently wrapped
  reference would "confirm" a wrapped result
- negative operands throughout — an unsigned multiply passes an all-positive
  test perfectly
- three back-to-back packets with no reload, proving the accumulator really
  clears on `TLAST`

Before the board run, the driver was verified off-board by stubbing PYNQ with
a model of the RTL's semantics and running the real script against it. That
validated the interleaving, the truncation masking, and the numpy/PYNQ API
usage — and nothing about DMA arming, cache coherency on HPC0, or whether
`TLAST` actually arrives. Those only the board can answer, and it did.

**Verified on hardware:** `./run_pynq.sh dot_product_test.py` — all five
lengths (n = 1, 2, 8, 64, 1024) and all three back-to-back packets matched,
ending in `Step 04 PASS`.

### Makefile targets

| Target | Does |
|---|------|
| `make sim_step04` | Standalone xsim testbench run |
| `make package_step04` | Packages the kernel into `build/step04_dot_product/ip_repo/` |
| `make bd_step04` | Scratch project for GUI block-design work |
| `make validate_step04` | Sources + validates the block design only (~1 min) |
| `make step04` | Full bitstream build |

### Deferred deliberately

Simulating the whole block design with the **Zynq UltraScale+ VIP**
(`set_property SELECTED_SIM_MODEL tlm [get_bd_cells /zynq_ultra_ps_e_0]`)
would run the full PS→DMA→kernel→DMA→PS round trip in xsim, catching wiring
and DMA-behaviour bugs the unit testbench cannot. It sees nothing above the
AXI layer, though — PYNQ buffers, cache coherency, and channel arming order
stay invisible — and it costs a project-based `launch_simulation` flow rather
than the standalone `xvlog`/`xelab` one. Step 04 passed on the first board
run, so it was never needed. Build it on a *second* unexplained board
failure, not the first.

---

## Upcoming Steps

| # | Goal |
|---|------|
| 6 | Activation + chaining — ReLU, layer fusion |
| 7 | ML inference — full MLP end-to-end |
