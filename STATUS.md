# Project Status

## Current Step: 01 — Environment / Hello Overlay

Bitstream built successfully. PYNQ is now installed and working on the
board via the Kria-PYNQ installer (see below). Remaining: deploy the
bitstream and run the load test using the venv interpreter.

### Remaining to complete step 01

1. **Copy build outputs** (bitstream already built, just needs copying):
   ```bash
   mkdir -p build/step01_hello
   cp build/step01_hello/_vivado_project/hello_overlay.runs/impl_1/hello_overlay_wrapper.bit \
      build/step01_hello/hello_overlay.bit
   cp build/step01_hello/_vivado_project/hello_overlay.gen/sources_1/bd/hello_overlay/hw_handoff/hello_overlay.hwh \
      build/step01_hello/hello_overlay.hwh
   ```

2. **Deploy and test** — see `docs/board-setup.md` for full instructions:
   ```bash
   scp build/step01_hello/hello_overlay.{bit,hwh} user@kr260:~/step01/
   scp sw/step01_hello/load_overlay.py user@kr260:~/step01/
   ssh user@kr260 "cd ~/step01 && sudo /usr/local/share/pynq-venv/bin/python3 load_overlay.py"
   ```
   Expected: `Step 01 PASS`

### Notes

- `build.tcl` had a bug where the `.hwh` glob path used `.srcs/` instead of
  `.gen/` — fixed. Future `make step01` runs will complete without the manual
  copy above.
- The full build takes ~20 min on an i5-8500 (synthesis dominates).

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

## Completed Steps

_None yet (step 01 pending board test — PYNQ install is now done, bitstream deploy/load test still to run)._

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
