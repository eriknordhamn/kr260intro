# Project Status

## Current Step: 01 — Environment / Hello Overlay — COMPLETE

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

---

## Upcoming Steps

| # | Goal |
|---|------|
| 2 | AXI-Lite echo register — first RTL, read/write from Python |
| 3 | DMA data path — bulk buffer transfer PS↔PL |
| 4 | Dot product kernel — first real compute in RTL |
| 5 | Linear layer — matrix-vector multiply |
| 6 | Activation + chaining — ReLU, layer fusion |
| 7 | ML inference — full MLP end-to-end |
