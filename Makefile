VIVADO_SETTINGS := /opt/Xilinx/2025.1/Vivado/settings64.sh
VIVADO := vivado -mode batch -notrace

.PHONY: step01 sim_step02 package_step02 step02 step03 \
        sim_step04 package_step04 bd_step04 validate_step04 step04 \
        sim_step05 package_step05 bd_step05 validate_step05 step05 clean help

help:
	@echo "Targets:"
	@echo "  step01         Build hello overlay (step 01)"
	@echo "  sim_step02     Simulate the AXI-Lite echo register (step 02)"
	@echo "  package_step02 Package axi_lite_echo as a Vivado IP core (step 02)"
	@echo "  step02         Build the AXI-Lite echo overlay bitstream (step 02)"
	@echo "  step03         Build the DMA loopback overlay bitstream (step 03)"
	@echo "  sim_step04     Simulate the streaming dot-product kernel (step 04)"
	@echo "  package_step04 Package dot_product as a Vivado IP core (step 04)"
	@echo "  bd_step04      Create the scratch project for GUI block-design work (step 04)"
	@echo "  validate_step04 Build the block design and validate only, no synthesis (step 04)"
	@echo "  step04         Build the dot-product overlay bitstream (step 04)"
	@echo "  sim_step05     Simulate the matrix-vector linear layer (step 05)"
	@echo "  package_step05 Package linear_layer as a Vivado IP core (step 05)"
	@echo "  bd_step05      Create the scratch project for GUI block-design work (step 05)"
	@echo "  validate_step05 Build the block design and validate only, no synthesis (step 05)"
	@echo "  step05         Build the linear-layer overlay bitstream (step 05)"
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

sim_step04:
	bash sim/step04_dot_product/run_sim.sh

package_step04:
	bash -c "source $(VIVADO_SETTINGS) && $(VIVADO) -source vivado/step04_dot_product/package_ip.tcl"

bd_step04: package_step04
	bash -c "source $(VIVADO_SETTINGS) && $(VIVADO) -source vivado/step04_dot_product/create_bd_scratch_project.tcl"

validate_step04:
	bash -c "source $(VIVADO_SETTINGS) && $(VIVADO) -source vivado/step04_dot_product/build.tcl -tclargs validate"

step04: package_step04
	bash -c "source $(VIVADO_SETTINGS) && $(VIVADO) -source vivado/step04_dot_product/build.tcl"

sim_step05:
	bash sim/step05_linear_layer/run_sim.sh

package_step05:
	bash -c "source $(VIVADO_SETTINGS) && $(VIVADO) -source vivado/step05_linear_layer/package_ip.tcl"

bd_step05: package_step05
	bash -c "source $(VIVADO_SETTINGS) && $(VIVADO) -source vivado/step05_linear_layer/create_bd_scratch_project.tcl"

validate_step05:
	bash -c "source $(VIVADO_SETTINGS) && $(VIVADO) -source vivado/step05_linear_layer/build.tcl -tclargs validate"

step05: package_step05
	bash -c "source $(VIVADO_SETTINGS) && $(VIVADO) -source vivado/step05_linear_layer/build.tcl"

clean:
	rm -rf build/
