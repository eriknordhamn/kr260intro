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

## PYNQ's `ip_dict` can disagree with the `.hwh` on disk

Observed on step 05, 2026-08-19. After rebuilding a bitstream with the AXI
DMA's `c_sg_length_width` raised from 14 to 26 and copying both the `.bit`
and the `.hwh` to the board, PYNQ still enforced the old 16383-byte transfer
ceiling:

```
DMA ceiling: hwh=26 ip_dict=14 -> using 26 bits (67108863 bytes)
             limits before (16383, 16383, 16383)
```

The `.hwh` in the same directory as the bitstream carried `VALUE="26"` in
both its uppercase and lowercase `PARAMETER` blocks, but
`ol.ip_dict['axi_dma_0']['parameters']['c_sg_length_width']` came back
**14** — the value from the *previous* build of the same-named overlay.
PYNQ's DMA driver computes its limit from that dict
(`pynq/lib/dma.py`, ~line 617), so the stale value won.

The likely mechanism is PYNQ's PL server caching parsed overlay metadata
keyed on the overlay's name or path, which did not change between builds.
Not confirmed — a reboot was not tried, and the workaround made it moot.

**What to do about it:** when a hardware parameter changes and the board
does not seem to notice, read the `.hwh` yourself and compare against
`ip_dict` before assuming the copy failed or the rebuild didn't take. The
step 05 driver does exactly this in `unlock_dma_transfer_size()`: it prefers
the `.hwh` value, falls back to `ip_dict`, then to a constant matching the
block design, and prints all of them. Limits that live only in Python — as
this one does — can be corrected in Python once you know the hardware
really supports it.

## Alternative: source as yourself, `sudo -E` for the script

`run_pynq.sh` elevates once and does the sourcing *inside* that root
process. The environment only needs to exist in whichever process finally
`exec`s Python — it doesn't have to be root that does the sourcing. A
two-step version, splitting the unprivileged and privileged parts instead
of bundling them:

```bash
source /etc/profile.d/pynq_venv.sh                          # unprivileged, fine — no sudo needed
sudo -E /usr/local/share/pynq-venv/bin/python3 load_overlay.py   # one sudo, -E carries the env over
```

`-E` preserves your already-sourced environment variables (`XILINX_XRT`,
etc.) into the `sudo`'d process, and the explicit full interpreter path
means `sudo` doesn't need to consult `PATH` to find `python3` in the first
place.

**Caveat, not just a style preference:** Ubuntu's default `sudoers` sets
`secure_path`, which overrides `PATH` specifically — even under `-E` — for
whatever `sudo` invokes. So while `XILINX_XRT` survives via `-E`, the
venv-first `PATH` ordering that makes the *working* `xclbinutil` get found
(see above) does **not** survive, even though `python3` itself is given by
full path. Python still shells out to `xclbinutil` *by name*, so it would
resolve via `sudo`'s `secure_path`-restored `PATH` — landing back on the
broken system copy at `/usr/bin/xclbinutil`, reproducing the second step
01 failure. Fixing that would need explicitly re-injecting `PATH` past
`secure_path`, e.g.:

```bash
sudo -E env "PATH=$PATH" /usr/local/share/pynq-venv/bin/python3 load_overlay.py
```

(`env` here is the thing `sudo` actually execs — once running, it's free to
set `PATH` for its own child (`python3`) regardless of `secure_path`, which
only constrains the lookup for the command `sudo` itself launches.)

This hasn't been tried on the board — reasoned through, not confirmed. It's
noted here as the two-step alternative to `run_pynq.sh`'s single-`sudo`
approach, not a replacement recommendation: it requires remembering to
source *and* get the `PATH` re-injection right in every new shell, whereas
`run_pynq.sh` is a single self-contained command that works regardless of
what the calling shell has or hasn't sourced.
