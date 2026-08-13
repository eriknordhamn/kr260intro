VIVADO_SETTINGS := /opt/Xilinx/2025.1/Vivado/settings64.sh
VIVADO := vivado -mode batch -notrace

.PHONY: step01 sim_step02 package_step02 step02 step03 clean help

help:
	@echo "Targets:"
	@echo "  step01         Build hello overlay (step 01)"
	@echo "  sim_step02     Simulate the AXI-Lite echo register (step 02)"
	@echo "  package_step02 Package axi_lite_echo as a Vivado IP core (step 02)"
	@echo "  step02         Build the AXI-Lite echo overlay bitstream (step 02)"
	@echo "  step03         Build the DMA loopback overlay bitstream (step 03)"
	@echo "  clean          Remove build artifacts"

step01:
	bash -c "source $(VIVADO_SETTINGS) && $(VIVADO) -source vivado/step01_hello/build.tcl"

sim_step02:
	bash sim/step02_axi_lite_echo/run_sim.sh

package_step02:
	bash -c "source $(VIVADO_SETTINGS) && $(VIVADO) -source vivado/step02_axi_lite_echo/package_ip.tcl"

step02: package_step02
	bash -c "source $(VIVADO_SETTINGS) && $(VIVADO) -source vivado/step02_axi_lite_echo/build.tcl"

step03:
	bash -c "source $(VIVADO_SETTINGS) && $(VIVADO) -source vivado/step03_dma_loopback/build.tcl"

clean:
	rm -rf build/
