#!/usr/bin/env bash
# Run a script with the PYNQ venv's Python on the board, as root.
#
# systemd (like sudo) doesn't inherit the login shell's environment, so
# /etc/profile.d/pynq_venv.sh (which sets XILINX_XRT, activates the PYNQ
# venv, etc.) never runs for a plain `sudo .../python3 script.py`. The
# board's own jupyter.service works around this by re-sourcing
# /etc/environment and /etc/profile.d/*.sh itself before starting Jupyter
# (see /usr/local/bin/start_jupyter.sh) — this script does the same thing
# for our one-off PYNQ scripts.
#
# Usage: ./run_pynq.sh <script.py> [args...]
# (the script elevates itself via sudo — don't prefix with sudo yourself)
set -euo pipefail

sudo bash -c '
  . /etc/environment
  for f in /etc/profile.d/*.sh; do . "$f"; done
  exec /usr/local/share/pynq-venv/bin/python3 "$@"
' _ "$@"
