`timescale 1ns / 1ps

// Step 04: streaming dot-product kernel.
//
// One AXI4-Stream slave port in, one AXI4-Stream master port out. The two
// operand vectors arrive interleaved on the single input stream:
//
//   beat:  0   1   2   3        2N-2  2N-1
//   data:  a0  b0  a1  b1  ...  a[N-1] b[N-1](TLAST)
//
// Even beats latch an `a` element, odd beats supply the matching `b`,
// multiply, and accumulate. TLAST on the final beat ends the packet: the
// accumulator is emitted as a single output beat (also marked TLAST, which
// is what tells the DMA's S2MM channel the transfer is complete) and the
// accumulator resets, so back-to-back packets are independent.
//
// Vector length is therefore implicit in the packet — no length register
// and no AXI4-Lite interface on this IP at all.
//
// Arithmetic: operands are treated as signed DATA_WIDTH integers; products
// accumulate into a wider ACC_WIDTH register so a long vector can't silently
// wrap mid-sum. The output beat carries the low DATA_WIDTH bits of that
// accumulator, i.e. the true sum modulo 2**DATA_WIDTH.
//
// Malformed packets: if TLAST arrives on an even beat (odd total beat count,
// so the last `a` has no matching `b`), the dangling element is discarded and
// the accumulator is emitted anyway. Flushing beats hanging — a stalled
// kernel would wedge the DMA channel with no error reported to the PS.
//
// Port naming (`s_axis_*` / `m_axis_*`, `aclk`, `aresetn`) follows Xilinx's
// convention so the IP packager infers both stream interfaces automatically,
// the same trick step 02 used for its AXI4-Lite ports.

module dot_product #(
    parameter integer DATA_WIDTH = 32,
    parameter integer ACC_WIDTH  = 64
) (
    input  wire                   aclk,
    input  wire                   aresetn,

    // Slave stream: interleaved operands
    input  wire [DATA_WIDTH-1:0]  s_axis_tdata,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,
    input  wire                   s_axis_tlast,

    // Master stream: one result beat per input packet
    output reg  [DATA_WIDTH-1:0]  m_axis_tdata,
    output reg                    m_axis_tvalid,
    input  wire                   m_axis_tready,
    output reg                    m_axis_tlast
);

  // High when an `a` element is latched and waiting for its `b`, i.e. the
  // next input beat completes a pair.
  reg                   have_a;
  reg  [DATA_WIDTH-1:0] a_reg;
  reg  [ACC_WIDTH-1:0]  acc;

  // Stall the input while a result is waiting to be drained. Only one result
  // exists per packet, so this costs a cycle at end-of-packet and nothing in
  // steady state. Deliberately not a function of m_axis_tready: keeping the
  // two streams' handshakes independent avoids a combinational path from the
  // downstream TREADY into the upstream TREADY.
  assign s_axis_tready = !m_axis_tvalid;

  wire input_beat = s_axis_tvalid && s_axis_tready;

  // Product of the pair completed by the current beat, sign-extended to the
  // accumulator width.
  wire signed [2*DATA_WIDTH-1:0] product =
      $signed(a_reg) * $signed(s_axis_tdata);
  wire [ACC_WIDTH-1:0] acc_next =
      acc + {{(ACC_WIDTH-2*DATA_WIDTH){product[2*DATA_WIDTH-1]}}, product};

  // The value emitted when the packet ends: includes the current beat's
  // product only if that beat completed a pair.
  wire [ACC_WIDTH-1:0] acc_flush = have_a ? acc_next : acc;

  always @(posedge aclk) begin
    if (!aresetn) begin
      have_a <= 1'b0;
      a_reg  <= {DATA_WIDTH{1'b0}};
      acc    <= {ACC_WIDTH{1'b0}};
    end else if (input_beat) begin
      if (s_axis_tlast) begin
        // End of packet — start the next one from a clean accumulator.
        have_a <= 1'b0;
        acc    <= {ACC_WIDTH{1'b0}};
      end else if (!have_a) begin
        a_reg  <= s_axis_tdata;
        have_a <= 1'b1;
      end else begin
        acc    <= acc_next;
        have_a <= 1'b0;
      end
    end
  end

  always @(posedge aclk) begin
    if (!aresetn) begin
      m_axis_tvalid <= 1'b0;
      m_axis_tlast  <= 1'b0;
      m_axis_tdata  <= {DATA_WIDTH{1'b0}};
    end else if (input_beat && s_axis_tlast) begin
      m_axis_tvalid <= 1'b1;
      m_axis_tlast  <= 1'b1;
      m_axis_tdata  <= acc_flush[DATA_WIDTH-1:0];
    end else if (m_axis_tvalid && m_axis_tready) begin
      m_axis_tvalid <= 1'b0;
      m_axis_tlast  <= 1'b0;
    end
  end

endmodule
