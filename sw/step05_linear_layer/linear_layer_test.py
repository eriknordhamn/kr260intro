"""
Step 05: Linear Layer (matrix-vector multiply)

Loads the linear_layer_accel bitstream and exercises the streaming
matrix-vector kernel sitting between the DMA's MM2S and S2MM channels.

The protocol is two packets on the single MM2S stream (see
spec/step05_linear_layer.md §3):

    packet 1   x0 x1 ... x[N-1](TLAST)          the vector, cached in BRAM
    packet 2   row 0 | row 1 | ... | row M-1(TLAST)

Each beat is 128 bits = 8 int16 lanes, so the kernel performs 8 MACs per
cycle. N is learned from packet 1's beat count and M from how many rows
packet 2 carries — the IP has no control registers and no AXI4-Lite port.

Results come back on a 32-bit S2MM stream, one int32 per row, carrying the
low 32 bits of a 48-bit accumulator (i.e. the true sum modulo 2**32).

Run this on the KR260 with linear_layer_accel.bit and linear_layer_accel.hwh
in the same directory, via run_pynq.sh.
"""
from pynq import Overlay, allocate
import numpy as np
import os
import re
import time

LANES  = 8           # int16 operands per 128-bit beat
MAX_N  = 4096        # vector cache depth in the kernel
MASK32 = 0xFFFFFFFF

BITFILE = "linear_layer_accel.bit"

ol = Overlay(BITFILE)
print("Overlay loaded successfully.")
print(f"IP cores in overlay: {list(ol.ip_dict.keys())}")

dma = ol.axi_dma_0


def unlock_dma_transfer_size(overlay, dma, bitfile=BITFILE):
    """Raise PYNQ's transfer-size ceiling to what the DMA actually implements.

    PYNQ derives its limit from the AXI DMA's buffer-length register width,
    looked up as the *lowercase* key 'c_sg_length_width' in the IP's
    parameter dict (pynq/lib/dma.py:617), falling back to a 14-bit default
    when it misses -- a 16383-byte ceiling. This design implements 26 bits,
    i.e. 64 MB, and both PARAMETER blocks in the .hwh say so.

    That ceiling is a Python-side check, not a hardware limit, so correcting
    it is safe: the width is read back from the same .hwh the bitstream was
    built with, and limits are only ever raised, never lowered.

    Two places hold the limit and they are not necessarily in sync -- the
    DMA's buffer_max_size, and each channel's _max_size, which is what
    transfer() actually tests. Both are checked independently.

    Without this, any layer above M*N = 8191 int16 is rejected before it
    reaches the hardware, and the packet cannot be split around it: each
    transfer() emits its own TLAST, and TLAST is what delimits the packet.
    """
    entry = getattr(overlay, "ip_dict", {}).get("axi_dma_0", {}) or {}
    params = entry.get("parameters", {}) or {}
    width = next((int(v) for k, v in params.items()
                  if k.lower() == "c_sg_length_width"), None)

    if width is None:
        # Not in the parsed dict -- read it straight out of the .hwh, which
        # is the same file PYNQ itself parsed and is known to carry it.
        hwh = os.path.splitext(bitfile)[0] + ".hwh"
        try:
            m = re.search(r'NAME="c_sg_length_width"\s+VALUE="(\d+)"',
                          open(hwh).read(), re.I)
            width = int(m.group(1)) if m else None
        except OSError:
            width = None
        if params or width is not None:
            print(f"note: c_sg_length_width not in ip_dict "
                  f"(entry keys: {sorted(entry)}); read {width} from {hwh}")

    if width is None:
        return

    hw_max = (1 << width) - 1
    raised = []
    if getattr(dma, "buffer_max_size", hw_max) < hw_max:
        raised.append(f"buffer_max_size {dma.buffer_max_size}")
        dma.buffer_max_size = hw_max
    for name in ("sendchannel", "recvchannel"):
        ch = getattr(dma, name, None)
        if ch is not None and getattr(ch, "_max_size", hw_max) < hw_max:
            raised.append(f"{name}._max_size {ch._max_size}")
            ch._max_size = hw_max
    if raised:
        print(f"note: raised DMA ceiling to {hw_max} bytes "
              f"(c_sg_length_width={width}); was {', '.join(raised)}")


unlock_dma_transfer_size(ol, dma)

# Operands are drawn from +/-2**14 so that a 1024-wide row's sum comfortably
# exceeds 2**32 — that is what exercises the truncation on the way out,
# rather than letting the test pass on small numbers alone.
OPERAND_LIMIT = 1 << 14

rng = np.random.default_rng(seed=20260819)


def pad_to_lanes(a):
    """Zero-pad along the last axis up to a multiple of LANES.

    This is the kernel's central contract: it has no lane masking and no
    TKEEP, so a row whose length is not a multiple of LANES would misalign
    every subsequent row. Zero operands contribute exactly zero to the sum,
    so padding is arithmetically free.
    """
    n = a.shape[-1]
    pad = (-n) % LANES
    if pad == 0:
        return a
    width = [(0, 0)] * (a.ndim - 1) + [(0, pad)]
    return np.pad(a, width, mode="constant")


def reference(x, w_row):
    """Exact sum, then truncated the way the kernel truncates it.

    Computed with Python ints rather than numpy: 1024 products of ~2**28
    each would risk overflowing int64 accumulation, and a silently wrapped
    reference would 'confirm' a wrapped result.
    """
    exact = sum(int(a) * int(b) for a, b in zip(x, w_row))
    return exact & MASK32, exact


def run_layer(x, w):
    """Send one (vector, matrix) pair, return M result words and elapsed time.

    Ordering matters twice over: the receive channel is armed before
    anything is sent (so S2MM is already accepting when the first result
    beat appears, as in steps 03 and 04), and the vector packet must precede
    the weight packet because the kernel starts in its vector-loading state.
    """
    m = w.shape[0]
    xp = pad_to_lanes(x)
    wp = pad_to_lanes(w)
    assert xp.shape[-1] == wp.shape[-1] <= MAX_N

    vec_buf = allocate(shape=xp.shape, dtype=np.int16)
    wgt_buf = allocate(shape=(wp.size,), dtype=np.int16)
    res_buf = allocate(shape=(m,), dtype=np.uint32)

    vec_buf[:] = xp
    wgt_buf[:] = wp.reshape(-1)

    t0 = time.perf_counter()
    dma.recvchannel.transfer(res_buf)
    dma.sendchannel.transfer(vec_buf)      # packet 1: the vector
    dma.sendchannel.wait()
    dma.sendchannel.transfer(wgt_buf)      # packet 2: all M rows, one TLAST
    dma.sendchannel.wait()
    dma.recvchannel.wait()
    elapsed = time.perf_counter() - t0

    results = [int(v) for v in res_buf]
    vec_buf.freebuffer()
    wgt_buf.freebuffer()
    res_buf.freebuffer()
    return results, elapsed


def check(name, n, m):
    global failures
    x = rng.integers(-OPERAND_LIMIT, OPERAND_LIMIT, size=n, dtype=np.int16)
    w = rng.integers(-OPERAND_LIMIT, OPERAND_LIMIT, size=(m, n), dtype=np.int16)

    results, elapsed = run_layer(x, w)

    if len(results) != m:
        print(f"FAIL {name}: got {len(results)} results, expected {m}")
        failures += 1
        return

    bad = 0
    wrapped = 0
    for r in range(m):
        expected, exact = reference(x, w[r])
        if not (0 <= exact <= MASK32):
            wrapped += 1
        if results[r] != expected:
            if bad == 0:      # only the first mismatch, to keep output readable
                print(f"FAIL {name}: row {r} got 0x{results[r]:08X} "
                      f"expected 0x{expected:08X} (exact {exact})")
            bad += 1

    if bad:
        print(f"FAIL {name}: {bad}/{m} rows wrong")
        failures += 1
    else:
        note = f", {wrapped} wrapped" if wrapped else ""
        macs = m * ((n + LANES - 1) // LANES * LANES)
        rate = macs / elapsed / 1e6 if elapsed > 0 else 0
        print(f"PASS {name}: N={n} M={m}, {m} rows correct{note} "
              f"[{elapsed*1e3:.2f} ms, {rate:.0f} MMAC/s incl. overhead]")


failures = 0

# Smallest layer: one beat, one row.
check("minimal", LANES, 1)

# Several single-beat rows: a result every row-beat, the case the kernel's
# global stall exists for.
check("single-beat rows", LANES, 4)

# Ordinary small layers.
check("small", 64, 4)
check("medium", 256, 8)

# N not a multiple of LANES — exercises the driver's zero-padding. The
# result must be identical to the unpadded dot product, since the padding
# contributes zero.
check("unaligned N=100", 100, 3)
check("unaligned N=1", 1, 2)

# Full-length rows: the exact sums exceed 32 bits, so the emitted words are
# genuinely truncated and the reference has to reproduce that.
check("truncating", 1024, 4)

# Back-to-back invocations with different N: proves the kernel returns to
# its vector-loading state and re-learns the row length with no reset.
check("reload 1", 32, 2)
check("reload 2", 512, 2)
check("reload 3", 128, 6)

# The largest vector the cache holds.
check("max vector", MAX_N, 2)

assert failures == 0, f"{failures} linear-layer mismatches"
print("Step 05 PASS")
