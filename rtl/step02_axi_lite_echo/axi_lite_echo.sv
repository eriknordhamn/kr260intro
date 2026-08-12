`timescale 1ns / 1ps

// Step 02: minimal AXI4-Lite slave with a single 32-bit echo register.
//
// Register map (byte address, word-aligned):
//   0x0  ECHO  read/write, resets to 0
//
// Only one register exists, so address bits above the word offset are
// not decoded — every address reads/writes the same register. That's
// enough to prove the PS-PL AXI-Lite control path; a real register map
// with address decode comes when a milestone actually needs >1 register.

module axi_lite_echo #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 4
) (
    input  wire                              S_AXI_ACLK,
    input  wire                              S_AXI_ARESETN,

    // Write address channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_AWADDR,
    input  wire [2:0]                        S_AXI_AWPROT,
    input  wire                              S_AXI_AWVALID,
    output reg                               S_AXI_AWREADY,

    // Write data channel
    input  wire [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_WDATA,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] S_AXI_WSTRB,
    input  wire                              S_AXI_WVALID,
    output reg                               S_AXI_WREADY,

    // Write response channel
    output reg  [1:0]                        S_AXI_BRESP,
    output reg                               S_AXI_BVALID,
    input  wire                              S_AXI_BREADY,

    // Read address channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_ARADDR,
    input  wire [2:0]                        S_AXI_ARPROT,
    input  wire                              S_AXI_ARVALID,
    output reg                               S_AXI_ARREADY,

    // Read data channel
    output reg  [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_RDATA,
    output reg  [1:0]                        S_AXI_RRESP,
    output reg                               S_AXI_RVALID,
    input  wire                              S_AXI_RREADY
);

  localparam integer STRB_WIDTH = C_S_AXI_DATA_WIDTH / 8;

  reg [C_S_AXI_DATA_WIDTH-1:0] echo_reg;

  // Write address / write data: accept together, unpipelined (one
  // outstanding write at a time).
  always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
      S_AXI_AWREADY <= 1'b0;
      S_AXI_WREADY  <= 1'b0;
    end else begin
      S_AXI_AWREADY <= !S_AXI_AWREADY && S_AXI_AWVALID && S_AXI_WVALID;
      S_AXI_WREADY  <= !S_AXI_WREADY  && S_AXI_AWVALID && S_AXI_WVALID;
    end
  end

  integer i;
  always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
      echo_reg <= {C_S_AXI_DATA_WIDTH{1'b0}};
    end else if (S_AXI_AWREADY && S_AXI_AWVALID && S_AXI_WREADY && S_AXI_WVALID) begin
      for (i = 0; i < STRB_WIDTH; i = i + 1) begin
        if (S_AXI_WSTRB[i]) begin
          echo_reg[i*8 +: 8] <= S_AXI_WDATA[i*8 +: 8];
        end
      end
    end
  end

  // Write response
  always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
      S_AXI_BVALID <= 1'b0;
      S_AXI_BRESP  <= 2'b00;
    end else if (S_AXI_AWREADY && S_AXI_AWVALID && S_AXI_WREADY && S_AXI_WVALID && !S_AXI_BVALID) begin
      S_AXI_BVALID <= 1'b1;
      S_AXI_BRESP  <= 2'b00;  // OKAY
    end else if (S_AXI_BVALID && S_AXI_BREADY) begin
      S_AXI_BVALID <= 1'b0;
    end
  end

  // Read address
  always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
      S_AXI_ARREADY <= 1'b0;
    end else begin
      S_AXI_ARREADY <= !S_AXI_ARREADY && S_AXI_ARVALID;
    end
  end

  // Read data / response
  always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
      S_AXI_RVALID <= 1'b0;
      S_AXI_RRESP  <= 2'b00;
    end else if (S_AXI_ARREADY && S_AXI_ARVALID && !S_AXI_RVALID) begin
      S_AXI_RVALID <= 1'b1;
      S_AXI_RRESP  <= 2'b00;  // OKAY
    end else if (S_AXI_RVALID && S_AXI_RREADY) begin
      S_AXI_RVALID <= 1'b0;
    end
  end

  always @(posedge S_AXI_ACLK) begin
    if (S_AXI_ARREADY && S_AXI_ARVALID) begin
      S_AXI_RDATA <= echo_reg;
    end
  end

endmodule
