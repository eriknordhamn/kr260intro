// Self-checking testbench for dot_product.
//
// Drives interleaved (a, b) packets into the slave stream and checks the
// single result beat against a reference sum computed in the testbench.
//
// The point of this TB is to mimic how the AXI DMA will actually drive the
// kernel on hardware, not just the happy path:
//   - TVALID gaps, because MM2S does not supply a beat every cycle
//   - randomized backpressure on the result stream (S2MM's TREADY)
//   - TLAST only on the final beat of each packet
//   - back-to-back packets, to prove the accumulator resets between them
//   - negative operands, to prove the multiply is signed
//
// Run: see sim/step04_dot_product/run_sim.sh (or `make sim_step04`).

`timescale 1ns / 1ps

module tb_dot_product;

  localparam integer DATA_WIDTH = 32;
  localparam integer ACC_WIDTH  = 64;

  reg                    aclk = 0;
  reg                    aresetn = 0;

  reg  [DATA_WIDTH-1:0]  s_axis_tdata = 0;
  reg                    s_axis_tvalid = 0;
  wire                   s_axis_tready;
  reg                    s_axis_tlast = 0;

  wire [DATA_WIDTH-1:0]  m_axis_tdata;
  wire                   m_axis_tvalid;
  reg                    m_axis_tready = 0;
  wire                   m_axis_tlast;

  integer errors = 0;

  dot_product #(
      .DATA_WIDTH(DATA_WIDTH),
      .ACC_WIDTH (ACC_WIDTH)
  ) dut (
      .aclk         (aclk),
      .aresetn      (aresetn),
      .s_axis_tdata (s_axis_tdata),
      .s_axis_tvalid(s_axis_tvalid),
      .s_axis_tready(s_axis_tready),
      .s_axis_tlast (s_axis_tlast),
      .m_axis_tdata (m_axis_tdata),
      .m_axis_tvalid(m_axis_tvalid),
      .m_axis_tready(m_axis_tready),
      .m_axis_tlast (m_axis_tlast)
  );

  always #5 aclk = ~aclk;  // 100 MHz

  // ---------------------------------------------------------------------
  // Result collection: a background monitor accepts result beats with
  // randomized backpressure, mirroring S2MM's TREADY behaviour.
  // ---------------------------------------------------------------------

  reg [DATA_WIDTH-1:0] result_data;
  reg                  result_seen = 0;
  reg                  result_last = 0;
  integer              backpressure_pct = 0;

  always @(posedge aclk) begin
    if (!aresetn) begin
      m_axis_tready <= 1'b0;
    end else begin
      m_axis_tready <= ($urandom_range(99, 0) >= backpressure_pct);
    end
  end

  always @(posedge aclk) begin
    if (aresetn && m_axis_tvalid && m_axis_tready) begin
      result_data <= m_axis_tdata;
      result_last <= m_axis_tlast;
      result_seen <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------
  // Stimulus tasks
  // ---------------------------------------------------------------------

  // Drive one input beat, honouring TREADY and optionally inserting an idle
  // gap first (TVALID low), the way MM2S does between bursts.
  task automatic send_beat(input [DATA_WIDTH-1:0] data,
                           input                  last,
                           input integer          gap);
    integer g;
    begin
      for (g = 0; g < gap; g = g + 1) begin
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
        @(posedge aclk);
      end

      s_axis_tdata  <= data;
      s_axis_tlast  <= last;
      s_axis_tvalid <= 1'b1;
      @(posedge aclk);
      while (!s_axis_tready) @(posedge aclk);
      s_axis_tvalid <= 1'b0;
      s_axis_tlast  <= 1'b0;
    end
  endtask

  // Stream one packet of `n` (a, b) pairs and check the emitted result.
  // Operands are drawn in [-lim, lim] so the reference sum stays exact in
  // the testbench's 64-bit arithmetic.
  task automatic run_packet(input integer n,
                            input integer lim,
                            input integer max_gap,
                            input string  name);
    integer               i;
    integer signed        a;
    integer signed        b;
    longint signed        expected;
    reg [DATA_WIDTH-1:0]  expected_trunc;
    integer               timeout;
    begin
      expected    = 0;
      result_seen = 0;

      for (i = 0; i < n; i = i + 1) begin
        a = $urandom_range(2*lim, 0) - lim;
        b = $urandom_range(2*lim, 0) - lim;
        expected = expected + (longint'(a) * longint'(b));

        send_beat(a[DATA_WIDTH-1:0], 1'b0, (max_gap > 0) ? $urandom_range(max_gap, 0) : 0);
        // TLAST rides the final `b`, which is the last beat of the packet.
        send_beat(b[DATA_WIDTH-1:0], (i == n-1), (max_gap > 0) ? $urandom_range(max_gap, 0) : 0);
      end

      timeout = 0;
      while (!result_seen && timeout < 1000) begin
        @(posedge aclk);
        timeout = timeout + 1;
      end

      expected_trunc = expected[DATA_WIDTH-1:0];

      if (!result_seen) begin
        $display("FAIL %s: no result beat (kernel would hang the DMA here)", name);
        errors = errors + 1;
      end else if (result_data !== expected_trunc) begin
        $display("FAIL %s: got 0x%08h, expected 0x%08h (sum %0d)",
                 name, result_data, expected_trunc, expected);
        errors = errors + 1;
      end else if (!result_last) begin
        $display("FAIL %s: result beat did not assert TLAST", name);
        errors = errors + 1;
      end else begin
        $display("PASS %s: n=%0d result 0x%08h (sum %0d)", name, n, result_data, expected);
      end
    end
  endtask

  // ---------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------

  integer               i;
  longint signed        expected;
  reg [DATA_WIDTH-1:0]  expected_trunc;
  integer               timeout;

  initial begin
    aresetn = 0;
    repeat (4) @(posedge aclk);
    aresetn = 1;
    @(posedge aclk);

    // Smallest meaningful packet: a single pair, no gaps, no backpressure.
    backpressure_pct = 0;
    run_packet(1, 10, 0, "single pair");

    // Positive-only operands, dense stream.
    run_packet(8, 100, 0, "8 pairs, dense");

    // Signed operands with idle gaps between beats.
    run_packet(16, 1000, 3, "16 pairs, gaps");

    // Backpressure on the result stream.
    backpressure_pct = 70;
    run_packet(32, 1000, 2, "32 pairs, backpressured result");

    // Back-to-back packets with no idle time between them — proves the
    // accumulator is cleared by TLAST rather than leaking into the next
    // packet.
    backpressure_pct = 0;
    run_packet(4, 50, 0, "back-to-back packet 1");
    run_packet(4, 50, 0, "back-to-back packet 2");
    run_packet(4, 50, 0, "back-to-back packet 3");

    // Length the hardware test will actually use.
    run_packet(1024, 1000, 0, "1024 pairs");

    // Malformed packet: TLAST on an even beat, so the final `a` has no
    // matching `b`. The dangling element must be discarded and a result
    // emitted anyway rather than the kernel wedging.
    expected    = 0;
    result_seen = 0;
    for (i = 0; i < 3; i = i + 1) begin
      expected = expected + (longint'(i + 1) * longint'(i + 2));
      send_beat(i + 1, 1'b0, 0);
      send_beat(i + 2, 1'b0, 0);
    end
    send_beat(32'h7FFF_FFFF, 1'b1, 0);  // dangling `a`, carries TLAST

    timeout = 0;
    while (!result_seen && timeout < 1000) begin
      @(posedge aclk);
      timeout = timeout + 1;
    end
    expected_trunc = expected[DATA_WIDTH-1:0];
    if (!result_seen) begin
      $display("FAIL odd beat count: no result beat");
      errors = errors + 1;
    end else if (result_data !== expected_trunc) begin
      $display("FAIL odd beat count: got 0x%08h, expected 0x%08h",
               result_data, expected_trunc);
      errors = errors + 1;
    end else begin
      $display("PASS odd beat count: dangling element discarded, 0x%08h", result_data);
    end

    // And the kernel still works normally afterwards.
    run_packet(4, 50, 0, "recovery after malformed packet");

    if (errors == 0) begin
      $display("=== TB PASS: all checks passed ===");
    end else begin
      $display("=== TB FAIL: %0d check(s) failed ===", errors);
    end

    $finish;
  end

  // Safety timeout in case a handshake never completes.
  initial begin
    #500000;
    $display("=== TB FAIL: timeout ===");
    $finish;
  end

endmodule
