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
import time

LANES  = 8           # int16 operands per 128-bit beat
MAX_N  = 4096        # vector cache depth in the kernel
MASK32 = 0xFFFFFFFF

ol = Overlay("linear_layer_accel.bit")
print("Overlay loaded successfully.")
print(f"IP cores in overlay: {list(ol.ip_dict.keys())}")

dma = ol.axi_dma_0


def unlock_dma_transfer_size(overlay, dma):
    """Raise PYNQ's transfer-size ceiling to what the DMA actually implements.

    PYNQ derives its limit from the AXI DMA's buffer-length register width,
    looked up as the *lowercase* key 'c_sg_length_width' in the IP's
    parameter dict (see pynq/lib/dma.py). Vivado 2025.1 writes both an
    uppercase and a lowercase PARAMETER block into the .hwh; when the dict
    PYNQ builds carries the uppercase names, that lookup misses and PYNQ
    falls back to a 14-bit default -- a 16383-byte ceiling -- even though
    this design implements 26 bits, i.e. 64 MB.

    That ceiling is a Python-side check, not a hardware one, so correcting
    it is safe: the width is read back from the same .hwh the bitstream was
    built with, and the ceiling is only ever raised, never lowered.

    Without this, the weight packet for any layer above M*N = 8191 int16 is
    rejected before it reaches the hardware -- and the packet cannot be
    split, because each transfer() emits its own TLAST and TLAST is what
    delimits the packet.
    """
    params = getattr(overlay, "ip_dict", {}).get("axi_dma_0", {}).get("parameters", {})
    width = next((int(v) for k, v in params.items()
                  if k.lower() == "c_sg_length_width"), None)
    if width is None:
        if params:
            # The .hwh carries this parameter, so not finding it here means
            # PYNQ's parameter dict is shaped differently than assumed --
            # say so rather than silently leaving the ceiling in place.
            print("note: c_sg_length_width absent from PYNQ's parameter dict; "
                  f"{len(params)} params seen, e.g. {sorted(params)[:4]}")
        return
    hw_max = (1 << width) - 1
    if getattr(dma, "buffer_max_size", hw_max) >= hw_max:
        return
    print(f"note: raising PYNQ's DMA transfer ceiling "
          f"{dma.buffer_max_size} -> {hw_max} bytes (c_sg_length_width={width})")
    dma.buffer_max_size = hw_max
    for ch in (dma.sendchannel, dma.recvchannel):
        if hasattr(ch, "_max_size"):
            ch._max_size = hw_max


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
