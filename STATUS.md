# Project Status

## Current Step: 02 — AXI-Lite Echo Register — COMPLETE

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

## Upcoming Steps

| # | Goal |
|---|------|
| 3 | DMA data path — bulk buffer transfer PS↔PL |
| 4 | Dot product kernel — first real compute in RTL |
| 5 | Linear layer — matrix-vector multiply |
| 6 | Activation + chaining — ReLU, layer fusion |
| 7 | ML inference — full MLP end-to-end |
