// Self-checking testbench for axi_lite_echo. Drives a handful of
// AXI4-Lite write/read transactions and checks the value read back
// matches the value written.
//
// Run: see sim/step02_axi_lite_echo/run_sim.sh (or `make sim_step02`).

`timescale 1ns / 1ps

module tb_axi_lite_echo;

  localparam integer DATA_WIDTH = 32;
  localparam integer ADDR_WIDTH = 4;

  reg                      ACLK = 0;
  reg                      ARESETN = 0;

  reg  [ADDR_WIDTH-1:0]    AWADDR = 0;
  reg  [2:0]                AWPROT = 0;
  reg                      AWVALID = 0;
  wire                     AWREADY;

  reg  [DATA_WIDTH-1:0]    WDATA = 0;
  reg  [DATA_WIDTH/8-1:0]  WSTRB = '1;
  reg                      WVALID = 0;
  wire                     WREADY;

  wire [1:0]                BRESP;
  wire                     BVALID;
  reg                      BREADY = 0;

  reg  [ADDR_WIDTH-1:0]    ARADDR = 0;
  reg  [2:0]                ARPROT = 0;
  reg                      ARVALID = 0;
  wire                     ARREADY;

  wire [DATA_WIDTH-1:0]    RDATA;
  wire [1:0]                RRESP;
  wire                     RVALID;
  reg                      RREADY = 0;

  integer errors = 0;

  axi_lite_echo #(
      .C_S_AXI_DATA_WIDTH(DATA_WIDTH),
      .C_S_AXI_ADDR_WIDTH(ADDR_WIDTH)
  ) dut (
      .S_AXI_ACLK(ACLK),
      .S_AXI_ARESETN(ARESETN),
      .S_AXI_AWADDR(AWADDR),
      .S_AXI_AWPROT(AWPROT),
      .S_AXI_AWVALID(AWVALID),
      .S_AXI_AWREADY(AWREADY),
      .S_AXI_WDATA(WDATA),
      .S_AXI_WSTRB(WSTRB),
      .S_AXI_WVALID(WVALID),
      .S_AXI_WREADY(WREADY),
      .S_AXI_BRESP(BRESP),
      .S_AXI_BVALID(BVALID),
      .S_AXI_BREADY(BREADY),
      .S_AXI_ARADDR(ARADDR),
      .S_AXI_ARPROT(ARPROT),
      .S_AXI_ARVALID(ARVALID),
      .S_AXI_ARREADY(ARREADY),
      .S_AXI_RDATA(RDATA),
      .S_AXI_RRESP(RRESP),
      .S_AXI_RVALID(RVALID),
      .S_AXI_RREADY(RREADY)
  );

  always #5 ACLK = ~ACLK;  // 100 MHz

  task automatic axi_write(input [ADDR_WIDTH-1:0] addr, input [DATA_WIDTH-1:0] data);
    begin
      @(posedge ACLK);
      AWADDR  <= addr;
      AWVALID <= 1'b1;
      WDATA   <= data;
      WSTRB   <= '1;
      WVALID  <= 1'b1;
      BREADY  <= 1'b1;

      @(posedge ACLK);
      while (!(AWREADY && WREADY)) @(posedge ACLK);
      AWVALID <= 1'b0;
      WVALID  <= 1'b0;

      while (!BVALID) @(posedge ACLK);
      @(posedge ACLK);
      BREADY <= 1'b0;
    end
  endtask

  task automatic axi_read(input [ADDR_WIDTH-1:0] addr, output [DATA_WIDTH-1:0] data);
    begin
      @(posedge ACLK);
      ARADDR  <= addr;
      ARVALID <= 1'b1;
      RREADY  <= 1'b1;

      @(posedge ACLK);
      while (!ARREADY) @(posedge ACLK);
      ARVALID <= 1'b0;

      while (!RVALID) @(posedge ACLK);
      data = RDATA;
      @(posedge ACLK);
      RREADY <= 1'b0;
    end
  endtask

  task automatic check(input [DATA_WIDTH-1:0] got, input [DATA_WIDTH-1:0] expected, input string name);
    begin
      if (got !== expected) begin
        $display("FAIL %s: got 0x%08h, expected 0x%08h", name, got, expected);
        errors = errors + 1;
      end else begin
        $display("PASS %s: 0x%08h", name, got);
      end
    end
  endtask

  reg [DATA_WIDTH-1:0] rdata;

  initial begin
    ARESETN = 0;
    repeat (4) @(posedge ACLK);
    ARESETN = 1;
    @(posedge ACLK);

    // Register resets to zero.
    axi_read(4'h0, rdata);
    check(rdata, 32'h0000_0000, "reset value");

    // Basic write / read-back.
    axi_write(4'h0, 32'hDEADBEEF);
    axi_read(4'h0, rdata);
    check(rdata, 32'hDEADBEEF, "echo DEADBEEF");

    // Second value, to be sure it's not stuck.
    axi_write(4'h0, 32'h12345678);
    axi_read(4'h0, rdata);
    check(rdata, 32'h12345678, "echo 12345678");

    // Back-to-back write/read without extra idle cycles.
    axi_write(4'h0, 32'hCAFEF00D);
    axi_read(4'h0, rdata);
    check(rdata, 32'hCAFEF00D, "echo CAFEF00D back-to-back");

    if (errors == 0) begin
      $display("=== TB PASS: all checks passed ===");
    end else begin
      $display("=== TB FAIL: %0d check(s) failed ===", errors);
    end

    $finish;
  end

  // Safety timeout in case a handshake never completes.
  initial begin
    #10000;
    $display("=== TB FAIL: timeout ===");
    $finish;
  end

endmodule
