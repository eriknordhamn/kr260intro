"""
Step 02: AXI-Lite Echo Register
Loads the axi_lite_echo_overlay bitstream, then writes a handful of
values to the echo register and confirms each reads back unchanged.
Run this on the KR260 with axi_lite_echo_overlay.bit and
axi_lite_echo_overlay.hwh in the same directory, via run_pynq.sh.
"""
from pynq import Overlay

ol = Overlay("axi_lite_echo_overlay.bit")
print("Overlay loaded successfully.")
print(f"IP cores in overlay: {list(ol.ip_dict.keys())}")

echo = ol.axi_lite_echo_0
REG_OFFSET = 0x0

test_values = [0x00000000, 0xDEADBEEF, 0x12345678, 0xCAFEF00D, 0xFFFFFFFF]

for value in test_values:
    echo.write(REG_OFFSET, value)
    readback = echo.read(REG_OFFSET)
    status = "OK" if readback == value else "MISMATCH"
    print(f"wrote 0x{value:08X}  read 0x{readback:08X}  {status}")
    assert readback == value, f"echo register mismatch: wrote 0x{value:08X}, read 0x{readback:08X}"

print("Step 02 PASS")
