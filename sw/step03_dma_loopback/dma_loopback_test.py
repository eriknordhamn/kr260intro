"""
Step 03: AXI DMA Loopback
Loads the dma_loopback bitstream and DMAs a test buffer PS->PL->PS
through the AXI DMA's MM2S/S2MM channels, which are wired directly to
each other in the PL (no processing in between - that's step 04).
Confirms the received buffer matches what was sent, validating the
bulk-transfer path.
Run this on the KR260 with dma_loopback.bit and dma_loopback.hwh in the
same directory, via run_pynq.sh.
"""
from pynq import Overlay, allocate
import numpy as np

ol = Overlay("dma_loopback.bit")
print("Overlay loaded successfully.")
print(f"IP cores in overlay: {list(ol.ip_dict.keys())}")

dma = ol.axi_dma_0

BUFFER_LEN = 1024  # words

send_buf = allocate(shape=(BUFFER_LEN,), dtype=np.uint32)
recv_buf = allocate(shape=(BUFFER_LEN,), dtype=np.uint32)

send_buf[:] = np.arange(BUFFER_LEN, dtype=np.uint32) ^ 0xA5A5A5A5

# Arm the receive side first so S_AXIS_S2MM's tready is already asserted
# by the time MM2S starts pushing data into the loopback wire.
dma.recvchannel.transfer(recv_buf)
dma.sendchannel.transfer(send_buf)
dma.sendchannel.wait()
dma.recvchannel.wait()

mismatches = np.where(recv_buf != send_buf)[0]
if len(mismatches):
    i = mismatches[0]
    print(f"MISMATCH at {len(mismatches)} of {BUFFER_LEN} words, "
          f"e.g. index {i}: sent 0x{send_buf[i]:08X} recv 0x{recv_buf[i]:08X}")
else:
    print(f"All {BUFFER_LEN} words matched.")

send_buf.freebuffer()
recv_buf.freebuffer()

assert len(mismatches) == 0, f"{len(mismatches)} word mismatches in DMA loopback"
print("Step 03 PASS")
