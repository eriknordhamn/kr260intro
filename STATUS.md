# Project Status

## Current Step: 01 — Environment / Hello Overlay

Bitstream built successfully. One remaining manual step before the step is
complete: deploy to the KR260 and run the load test.

### Remaining to complete step 01

1. **Copy build outputs** (bitstream already built, just needs copying):
   ```bash
   mkdir -p build/step01_hello
   cp build/step01_hello/_vivado_project/hello_overlay.runs/impl_1/hello_overlay_wrapper.bit \
      build/step01_hello/hello_overlay.bit
   cp build/step01_hello/_vivado_project/hello_overlay.gen/sources_1/bd/hello_overlay/hw_handoff/hello_overlay.hwh \
      build/step01_hello/hello_overlay.hwh
   ```

2. **Install PYNQ on the KR260** (if not already done):
   ```bash
   pip install pynq   # on the KR260
   ```

3. **Deploy and test** — see `docs/board-setup.md` for full instructions:
   ```bash
   scp build/step01_hello/hello_overlay.{bit,hwh} user@kr260:~/step01/
   scp sw/step01_hello/load_overlay.py user@kr260:~/step01/
   ssh user@kr260 "cd ~/step01 && python3 load_overlay.py"
   ```
   Expected: `Step 01 PASS`

### Notes

- `build.tcl` had a bug where the `.hwh` glob path used `.srcs/` instead of
  `.gen/` — fixed. Future `make step01` runs will complete without the manual
  copy above.
- The full build takes ~20 min on an i5-8500 (synthesis dominates).

---

## Completed Steps

_None yet (step 01 pending board test)._

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
