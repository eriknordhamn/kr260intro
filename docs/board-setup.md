# KR260 Board Setup

How to prepare the Kria KR260 for use with this project. Do this once before running any step.

## Requirements

- KR260 running stock Kria Ubuntu (Ubuntu 22.04 ARM64)
- SSH access or monitor/keyboard on the board
- Internet access from the board (for pip)

## 1. Install PYNQ

Do **not** `pip install pynq` directly — on stock Ubuntu (not Xilinx's
all-in-one PYNQ board image) this fails building native extensions PYNQ
needs (DisplayPort, HDMI, CMA allocator), because headers and libraries that
Xilinx normally bundles into their custom image aren't present. See
`STATUS.md` for the full story of what we hit trying the raw pip route.

Use AMD's dedicated installer for PYNQ on Kria SOM Ubuntu instead. It
installs system dependencies, builds the native pieces PYNQ needs, and sets
up a Python virtual environment for PYNQ + JupyterLab:

```bash
git clone https://github.com/Xilinx/Kria-PYNQ.git
cd Kria-PYNQ
sudo bash install.sh -b KR260
```

This takes a while (native builds + a large download) — expect 15–30+
minutes depending on the board's network and CPU.

**PYNQ is installed into a dedicated virtual environment**, not system or
user Python:

```
/usr/local/share/pynq-venv
```

Verify:

```bash
/usr/local/share/pynq-venv/bin/python3 -c "import pynq; print(pynq.__version__)"
```

Plain `python3 -c "import pynq"` (outside the venv) will **not** find it —
don't use it to sanity-check the install.

The installer also stands up JupyterLab as a systemd service:
`http://<board-hostname-or-ip>:9090/lab`, password `xilinx`. This project
uses plain scripts (see below) rather than notebooks, but JupyterLab is
there if you want to explore interactively.

## 2. Step 01 — Load the Hello Overlay

After building the bitstream on the dev machine (`make step01`), copy the outputs to the board and run the test script.

**From the dev machine:**

```bash
# Create a directory on the board
ssh user@kr260 "mkdir -p ~/step01"

# Copy bitstream, hardware handoff, test script, and the PYNQ run wrapper
scp build/step01_hello/hello_overlay.bit user@kr260:~/step01/
scp build/step01_hello/hello_overlay.hwh user@kr260:~/step01/
scp sw/step01_hello/load_overlay.py      user@kr260:~/step01/
scp sw/run_pynq.sh                       user@kr260:~/step01/
```

**On the board:**

```bash
cd ~/step01
./run_pynq.sh load_overlay.py
```

Expected output:

```
Overlay loaded successfully.
IP cores in overlay: ['zynq_ultra_ps_e_0']
Step 01 PASS
```

If you see `Step 01 PASS`, the toolchain is validated end to end.

## Notes

- Replace `user@kr260` with your board's actual username and hostname/IP.
- The `.bit` and `.hwh` files must have the same base name and be in the same directory for PYNQ to load the overlay correctly.
- Overlay loading needs root (writes to `/sys/class/fpga_manager/.../firmware`), and it needs the PYNQ venv's own environment (`XILINX_XRT`, the venv's `PATH`) which normally comes from `/etc/profile.d/pynq_venv.sh` in a login shell — but `sudo` doesn't inherit login-shell environment, so a plain `sudo .../python3 script.py` fails in two different ways (see `STATUS.md`'s issue log for the full story). Always run PYNQ scripts on the board through **`sw/run_pynq.sh`**, which re-sources the board's environment as root before launching the venv's Python — the same pattern the board's own `jupyter.service` uses internally (`/usr/local/bin/start_jupyter.sh`), so it's the vendor-sanctioned way to do this, not a workaround we invented.
- If the board isn't on your LAN's DNS, check whether `avahi-daemon` is running (`systemctl status avahi-daemon`) — if so, `<hostname>.local` (e.g. `kria.local`) works in place of an IP.
