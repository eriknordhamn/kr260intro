"""
Step 04: Dot Product Kernel

Loads the dot_product_accel bitstream and exercises the streaming
dot-product kernel sitting between the DMA's MM2S and S2MM channels.

Both operand vectors travel on the single MM2S stream, interleaved:

    beat:  0   1   2   3        2N-2   2N-1
    data:  a0  b0  a1  b1  ...  a[N-1] b[N-1](TLAST)

The kernel latches each `a` on an even beat, multiplies with the `b` that
follows, and accumulates into a 64-bit register. TLAST on the final beat
emits the accumulator as a single result beat — the low 32 bits, i.e. the
true sum modulo 2**32 — and resets the accumulator so packets are
independent.

Vector length is implicit in TLAST: the IP has no control registers and no
AXI4-Lite interface, so there is nothing to configure from here.

Run this on the KR260 with dot_product_accel.bit and dot_product_accel.hwh
in the same directory, via run_pynq.sh.
"""
from pynq import Overlay, allocate
import numpy as np

MASK32 = 0xFFFFFFFF

ol = Overlay("dot_product_accel.bit")
print("Overlay loaded successfully.")
print(f"IP cores in overlay: {list(ol.ip_dict.keys())}")

dma = ol.axi_dma_0

# Operands are drawn from +/-2**15 so that a long vector's sum comfortably
# exceeds 2**32 — that is what exercises the truncation on the way out,
# rather than letting the test pass on small numbers alone.
OPERAND_LIMIT = 1 << 15

rng = np.random.default_rng(seed=20260818)


def reference(a, b):
    """Exact sum, then truncated the way the kernel truncates it.

    Computed with Python ints rather than numpy: 1024 products of ~2**30
    each would be at risk of overflowing int64 accumulation, and a silently
    wrapped reference would 'confirm' a wrapped result.
    """
    exact = sum(int(x) * int(y) for x, y in zip(a, b))
    return exact & MASK32, exact


def run_packet(a, b):
    """Send one interleaved (a, b) packet, return the kernel's result word."""
    n = len(a)
    send_buf = allocate(shape=(2 * n,), dtype=np.int32)
    recv_buf = allocate(shape=(1,), dtype=np.uint32)

    send_buf[0::2] = a
    send_buf[1::2] = b

    # Arm the receive side first, same ordering step 03 needed: S2MM must
    # already be accepting before the kernel emits its single result beat.
    dma.recvchannel.transfer(recv_buf)
    dma.sendchannel.transfer(send_buf)
    dma.sendchannel.wait()
    dma.recvchannel.wait()

    result = int(recv_buf[0])
    send_buf.freebuffer()
    recv_buf.freebuffer()
    return result


failures = 0

# Mix of lengths: 1 exercises the single-pair path, 1024 pushes the
# accumulator past 32 bits. Negative operands prove the multiply is signed —
# an unsigned multiply passes an all-positive test perfectly.
for n in (1, 2, 8, 64, 1024):
    a = rng.integers(-OPERAND_LIMIT, OPERAND_LIMIT, size=n, dtype=np.int32)
    b = rng.integers(-OPERAND_LIMIT, OPERAND_LIMIT, size=n, dtype=np.int32)

    expected, exact = reference(a, b)
    result = run_packet(a, b)

    # Flag whenever the emitted word differs from the exact sum — either
    # because the sum overflowed 32 bits or because it is negative and
    # comes back as two's complement.
    wrapped = "" if 0 <= exact <= MASK32 else " (wrapped)"
    if result == expected:
        print(f"PASS n={n:5d}: 0x{result:08X}  exact {exact}{wrapped}")
    else:
        failures += 1
        print(f"FAIL n={n:5d}: got 0x{result:08X} expected 0x{expected:08X}"
              f"  exact {exact}{wrapped}")

# Back-to-back packets, no reload in between: proves the accumulator really
# resets on TLAST rather than carrying the previous packet's sum forward.
print("back-to-back packets:")
for i in range(3):
    n = 4
    a = rng.integers(-OPERAND_LIMIT, OPERAND_LIMIT, size=n, dtype=np.int32)
    b = rng.integers(-OPERAND_LIMIT, OPERAND_LIMIT, size=n, dtype=np.int32)

    expected, _ = reference(a, b)
    result = run_packet(a, b)

    if result == expected:
        print(f"  PASS packet {i + 1}: 0x{result:08X}")
    else:
        failures += 1
        print(f"  FAIL packet {i + 1}: got 0x{result:08X} "
              f"expected 0x{expected:08X}")

assert failures == 0, f"{failures} dot-product mismatches"
print("Step 04 PASS")
