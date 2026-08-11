# How the PYNQ venv Works

Explains what `/usr/local/share/pynq-venv` actually is, why it needs
special handling under `sudo`, and why `sw/run_pynq.sh` exists instead of
just calling Python directly. See `docs/xilinx-tools.md` first for what
XRT/`zocl`/`xclbinutil` are — this doc is about how they get *wired up*
for our scripts specifically.

## Why a dedicated virtual environment at all

`pip install pynq` on stock Ubuntu fails — PYNQ needs native extensions
(DisplayPort support, a CMA memory allocator, etc.) that require headers
and libraries Xilinx normally pre-bundles into their own board image, not
stock Ubuntu. The **Kria-PYNQ installer**
(`github.com/Xilinx/Kria-PYNQ`, run once via `install.sh -b KR260`) builds
all of that from source and installs the result into its own virtual
environment, `/usr/local/share/pynq-venv`, rather than system or user
Python. That keeps PYNQ's specific dependency versions isolated from the
rest of the OS.

Consequence: **any** Python code that does `import pynq` must run through
that venv's interpreter — `/usr/local/share/pynq-venv/bin/python3` — not
plain `python3`.

## What's actually inside it

Beyond the `pynq` Python package itself, the installer also drops in a
**vendored copy of `xclbinutil`**
(`/usr/local/share/pynq-venv/bin/xclbinutil`) — a second copy of that tool
alongside the one the Ubuntu `xrt` apt package already installs at
`/usr/bin/xclbinutil`. That turned out to matter: the apt package's copy
**segfaults** on this board, and the pynq-venv's own copy is the one that
actually works. This is presumably exactly why the installer vendors its
own — to sidestep whatever bug makes the system one crash here.

## `/etc/profile.d/pynq_venv.sh` — the piece that ties it together

The installer also drops a script into `/etc/profile.d/`, which any
*normal login shell* runs automatically:

```bash
source /usr/local/share/pynq-venv/bin/activate
export PYNQ_JUPYTER_NOTEBOOKS=/root/jupyter_notebooks
export BOARD=KR260
export XILINX_XRT=/usr
export PATH=$PATH:/usr/local/share/pynq-venv/bin/microblazeel-xilinx-elf/bin/
python3 /usr/local/share/pynq-venv/pynq-dts/insert_dtbo.py
```

Two things it does that matter for us:

- `source .../activate` — the venv's own activation script, which prepends
  `/usr/local/share/pynq-venv/bin` to `PATH`. This is *why* a normal
  interactive shell finds the working vendored `xclbinutil` before the
  broken system one — pure PATH ordering, nothing PYNQ-specific.
- `export XILINX_XRT=/usr` — tells XRT (and PYNQ, which asks XRT to
  enumerate devices) where this board's XRT install actually lives. Without
  it, PYNQ's `Device.devices` comes back empty — you get a
  `No devices found, is the XRT environment sourced?` warning even though
  the FPGA device is fine (`xbutil examine` confirms it outside Python).

So a normal interactive SSH session has everything it needs, automatically,
because logging in is what triggers `/etc/profile.d/*.sh`.

## Why `sudo` breaks this — and why you need `sudo` at all

Loading a bitstream writes to a privileged kernel interface, so it
requires root. But `sudo <command>` runs `<command>` with a **fresh
environment**, not your shell's environment — by design, so that running
something as root doesn't accidentally inherit whatever a regular user's
shell happened to have set (a security boundary). That means:

```bash
sudo /usr/local/share/pynq-venv/bin/python3 load_overlay.py
```

runs as root, but *without* `XILINX_XRT` set and *without* the venv's
`PATH` prepended — even though those were both set correctly one line
earlier in the same terminal. This produced exactly the two failures hit
during step 01: no devices found, then (once XRT was found) a crash
building the `.xclbin` because the wrong `xclbinutil` got picked up.

This isn't specific to `sudo`, either — `systemd` services have the exact
same property (they don't inherit a login shell's environment). The
board's own `jupyter.service` needs PYNQ working too, and its startup
script (`/usr/local/bin/start_jupyter.sh`) has to work around it the same
way, with this comment right at the top:

```bash
# Source the environment as the init system won't
set -a
. /etc/environment
for f in /etc/profile.d/*.sh; do source $f; done
set +a
```

## `sw/run_pynq.sh` — doing the same thing for our scripts

Rather than hand-typing `XILINX_XRT=/usr PATH=...` before every command
(easy to forget, easy to get subtly wrong), `sw/run_pynq.sh` copies the
exact pattern above:

```bash
sudo bash -c '
  . /etc/environment
  for f in /etc/profile.d/*.sh; do . "$f"; done
  exec /usr/local/share/pynq-venv/bin/python3 "$@"
' _ "$@"
```

It becomes root first (`sudo`), *then* re-runs the same environment setup
a login shell would have done, *then* launches the venv's Python with
whatever script/arguments you passed. Usage:

```bash
./run_pynq.sh load_overlay.py
```

Any future board-side script in this project (step 02's AXI-Lite driver,
step 03's DMA driver, etc.) should be run the same way — deploy the
script to the board alongside `run_pynq.sh` and invoke it through the
wrapper, rather than calling `sudo python3` directly.
