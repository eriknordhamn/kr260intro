"""
Step 01: Hello Overlay
Loads the minimal Zynq PS bitstream and confirms PYNQ is working.
Run this on the KR260 with hello_overlay.bit and hello_overlay.hwh
in the same directory.
"""
from pynq import Overlay

ol = Overlay("hello_overlay.bit")

print("Overlay loaded successfully.")
print(f"IP cores in overlay: {list(ol.ip_dict.keys()) or ['(none — PS only, as expected)']}")
print("Step 01 PASS")
