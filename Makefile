VIVADO_SETTINGS := /opt/Xilinx/2025.1/Vivado/settings64.sh
VIVADO := vivado -mode batch -notrace

.PHONY: step01 clean help

help:
	@echo "Targets:"
	@echo "  step01   Build hello overlay (step 01)"
	@echo "  clean    Remove build artifacts"

step01:
	bash -c "source $(VIVADO_SETTINGS) && $(VIVADO) -source vivado/step01_hello/build.tcl"

clean:
	rm -rf build/
