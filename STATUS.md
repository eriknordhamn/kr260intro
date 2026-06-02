# Project Status

## Current Step: 01 — Environment / Hello Overlay

Step 01 scaffold is complete and merged to main. The Vivado TCL build script
and PYNQ load script are in place. The bitstream has not been built yet.

### Remaining to complete step 01

1. **Install PYNQ on the KR260** — the board runs stock Kria Ubuntu; PYNQ needs
   to be installed before `load_overlay.py` can run:
   ```bash
   pip install pynq   # on the KR260
   ```

2. **Build the bitstream** — on the dev machine (no GUI needed):
   ```bash
   source /opt/Xilinx/2025.1/Vivado/settings64.sh
   make step01
   ```
   Outputs: `build/step01_hello/hello_overlay.bit` and `.hwh`

3. **Deploy and test** — copy outputs to the KR260 and run:
   ```bash
   scp build/step01_hello/hello_overlay.{bit,hwh} user@kr260:~/step01/
   scp sw/step01_hello/load_overlay.py user@kr260:~/step01/
   ssh user@kr260 "cd ~/step01 && python3 load_overlay.py"
   ```
   Expected: `Step 01 PASS`

---

## Completed Steps

_None yet._

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
