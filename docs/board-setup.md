# KR260 Board Setup

How to prepare the Kria KR260 for use with this project. Do this once before running any step.

## Requirements

- KR260 running stock Kria Ubuntu (Ubuntu 22.04 ARM64)
- SSH access or monitor/keyboard on the board
- Internet access from the board (for pip)

## 1. Install PYNQ

On the board:

```bash
pip install pynq
```

PYNQ pulls in its own dependencies (numpy, cffi, etc.). This takes a few minutes.

Verify:

```bash
python3 -c "import pynq; print(pynq.__version__)"
```

## 2. Step 01 — Load the Hello Overlay

After building the bitstream on the dev machine (`make step01`), copy the outputs to the board and run the test script.

**From the dev machine:**

```bash
# Create a directory on the board
ssh user@kr260 "mkdir -p ~/step01"

# Copy bitstream, hardware handoff, and test script
scp build/step01_hello/hello_overlay.bit user@kr260:~/step01/
scp build/step01_hello/hello_overlay.hwh user@kr260:~/step01/
scp sw/step01_hello/load_overlay.py      user@kr260:~/step01/
```

**On the board:**

```bash
cd ~/step01
python3 load_overlay.py
```

Expected output:

```
Overlay loaded successfully.
IP cores in overlay: ['(none — PS only, as expected)']
Step 01 PASS
```

If you see `Step 01 PASS`, the toolchain is validated end to end.

## Notes

- Replace `user@kr260` with your board's actual username and hostname/IP.
- The `.bit` and `.hwh` files must have the same base name and be in the same directory for PYNQ to load the overlay correctly.
- PYNQ requires root or the user to be in the `sudo` group on some Ubuntu configurations. If the overlay load fails with a permissions error, try `sudo python3 load_overlay.py`.
