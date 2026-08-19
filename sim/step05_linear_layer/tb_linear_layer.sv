// Self-checking testbench for linear_layer.
//
// Drives the two-packet protocol (vector, then weight rows) into the slave
// stream and checks every emitted result against a reference sum computed
// here in 64-bit arithmetic.
//
// As in step 04, the point is to mimic how the AXI DMA actually drives the
// kernel rather than only the happy path:
//   - TVALID gaps, because MM2S does not supply a beat every cycle
//   - randomized backpressure on the result stream (S2MM's TREADY)
//   - back-to-back invocations, proving the kernel returns to LOAD_X and
//     reloads a fresh vector without a reset
//   - negative operands, proving the lane multiplies are signed
//
// Plus two cases step 04 had no equivalent of:
//   - N = LANES, so every beat ends a row and a result is emitted every
//     other cycle. This is the hardest case for the global-stall flow
//     control, where several results would otherwise be in flight at once.
//   - a weight packet that ends mid-row, which must flush the partial
//     accumulator rather than wedge the DMA channel.
//
// Run: sim/step05_linear_layer/run_sim.sh (or `make sim_step05`).

`timescale 1ns / 1ps

module tb_linear_layer;

  localparam int DATA_WIDTH = 16;
  localparam int LANES      = 8;
  localparam int ACC_WIDTH  = 48;
  localparam int OUT_WIDTH  = 32;
  localparam int MAX_N      = 4096;
  localparam int BEAT_W     = LANES * DATA_WIDTH;

  localparam int TB_MAX_M   = 8;    // most rows any case below sends

  logic                  aclk = 0;
  logic                  aresetn = 0;

  logic [BEAT_W-1:0]     s_axis_tdata = '0;
  logic                  s_axis_tvalid = 0;
  wire                   s_axis_tready;
  logic                  s_axis_tlast = 0;

  wire [OUT_WIDTH-1:0]   m_axis_tdata;
  wire                   m_axis_tvalid;
  logic                  m_axis_tready = 0;
  wire                   m_axis_tlast;

  int errors = 0;

  linear_layer #(
      .DATA_WIDTH(DATA_WIDTH),
      .LANES     (LANES),
      .ACC_WIDTH (ACC_WIDTH),
      .OUT_WIDTH (OUT_WIDTH),
      .MAX_N     (MAX_N)
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
  // Operand storage and the reference model
  // ---------------------------------------------------------------------

  logic signed [DATA_WIDTH-1:0] x [0:MAX_N-1];
  logic signed [DATA_WIDTH-1:0] w [0:TB_MAX_M-1][0:MAX_N-1];

  // ---------------------------------------------------------------------
  // Result collection: a monitor with randomized backpressure, standing in
  // for S2MM's TREADY. Results land in a queue so a whole layer's worth can
  // be checked after the fact.
  // ---------------------------------------------------------------------

  logic [OUT_WIDTH-1:0] results [$];
  logic                 result_lasts [$];
  int                   backpressure_pct = 0;

  always_ff @(posedge aclk) begin
    if (!aresetn) m_axis_tready <= 1'b0;
    else          m_axis_tready <= ($urandom_range(99, 0) >= backpressure_pct);
  end

  always_ff @(posedge aclk) begin
    if (aresetn && m_axis_tvalid && m_axis_tready) begin
      results.push_back(m_axis_tdata);
      result_lasts.push_back(m_axis_tlast);
    end
  end

  // ---------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------

  // One input beat, honouring TREADY, optionally preceded by idle cycles
  // with TVALID low the way MM2S behaves between bursts.
  task automatic send_beat(input logic [BEAT_W-1:0] data,
                           input logic              last,
                           input int                gap);
    for (int g = 0; g < gap; g++) begin
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
  endtask

  // Pack LANES consecutive vector elements into one beat, lane 0 low.
  function automatic logic [BEAT_W-1:0] pack_x(input int base);
    logic [BEAT_W-1:0] beat;
    for (int l = 0; l < LANES; l++) beat[l*DATA_WIDTH +: DATA_WIDTH] = x[base+l];
    return beat;
  endfunction

  function automatic logic [BEAT_W-1:0] pack_w(input int row, input int base);
    logic [BEAT_W-1:0] beat;
    for (int l = 0; l < LANES; l++) beat[l*DATA_WIDTH +: DATA_WIDTH] = w[row][base+l];
    return beat;
  endfunction

  // Fill x and W with random operands in [-lim, lim].
  task automatic randomize_operands(input int n, input int m, input int lim);
    for (int i = 0; i < n; i++) x[i] = $urandom_range(2*lim, 0) - lim;
    for (int r = 0; r < m; r++)
      for (int i = 0; i < n; i++) w[r][i] = $urandom_range(2*lim, 0) - lim;
  endtask

  task automatic send_vector(input int n, input int max_gap);
    int words = n / LANES;
    for (int k = 0; k < words; k++)
      send_beat(pack_x(k*LANES), (k == words-1),
                (max_gap > 0) ? $urandom_range(max_gap, 0) : 0);
  endtask

  task automatic send_weights(input int n, input int m, input int max_gap);
    int words = n / LANES;
    for (int r = 0; r < m; r++)
      for (int k = 0; k < words; k++)
        send_beat(pack_w(r, k*LANES), (r == m-1) && (k == words-1),
                  (max_gap > 0) ? $urandom_range(max_gap, 0) : 0);
  endtask

  task automatic wait_for_results(input int count, input int limit);
    int t = 0;
    while (results.size() < count && t < limit) begin
      @(posedge aclk);
      t++;
    end
  endtask

  // ---------------------------------------------------------------------
  // One full layer: send x, send W, check M results.
  //
  // The reference sums in 64 bits while the kernel accumulates in 48. Every
  // case below stays well inside 48 bits, so comparing the low OUT_WIDTH
  // bits is exact -- the truncation under test is 48 -> 32, not the TB's.
  // ---------------------------------------------------------------------
  task automatic run_layer(input int    n,
                           input int    m,
                           input int    lim,
                           input int    max_gap,
                           input string name);
    longint signed        expected;
    logic [OUT_WIDTH-1:0] expected_trunc;
    logic                 ok;

    results.delete();
    result_lasts.delete();
    randomize_operands(n, m, lim);

    send_vector(n, max_gap);
    send_weights(n, m, max_gap);
    wait_for_results(m, 200000);

    if (results.size() != m) begin
      $display("FAIL %s: got %0d result beat(s), expected %0d%s",
               name, results.size(), m,
               (results.size() < m) ? " (kernel would hang the DMA here)" : "");
      errors++;
      return;
    end

    ok = 1'b1;
    for (int r = 0; r < m; r++) begin
      expected = 0;
      for (int i = 0; i < n; i++)
        expected += longint'(x[i]) * longint'(w[r][i]);
      expected_trunc = expected[OUT_WIDTH-1:0];

      if (results[r] !== expected_trunc) begin
        $display("FAIL %s: row %0d got 0x%08h, expected 0x%08h (exact %0d)",
                 name, r, results[r], expected_trunc, expected);
        ok = 1'b0;
      end else if (result_lasts[r] !== (r == m-1)) begin
        $display("FAIL %s: row %0d TLAST=%0b, expected %0b",
                 name, r, result_lasts[r], (r == m-1));
        ok = 1'b0;
      end
    end

    if (ok) $display("PASS %s: N=%0d M=%0d, %0d result(s) correct", name, n, m, m);
    else    errors++;
  endtask

  // ---------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------

  longint signed        expected;
  logic [OUT_WIDTH-1:0] expected_trunc;

  initial begin
    aresetn = 0;
    repeat (4) @(posedge aclk);
    aresetn = 1;
    @(posedge aclk);

    // Smallest layer: one beat, one row. Every beat is a row end.
    backpressure_pct = 0;
    run_layer(LANES, 1, 100, 0, "N=8 M=1, minimal");

    // Every beat ends a row, several rows back to back -- the hardest case
    // for the global stall, since without it multiple results would be in
    // flight simultaneously.
    run_layer(LANES, 4, 1000, 0, "N=8 M=4, result every row-beat");

    // A realistic small layer, dense stream.
    run_layer(64, 4, 1000, 0, "N=64 M=4, dense");

    // Idle gaps between beats, as MM2S produces between bursts.
    run_layer(64, 3, 32767, 3, "N=64 M=3, TVALID gaps");

    // Backpressure on the result stream.
    backpressure_pct = 70;
    run_layer(128, 4, 32767, 2, "N=128 M=4, backpressured");
    backpressure_pct = 0;

    // Back-to-back invocations with a different N each time: proves the
    // kernel returns to LOAD_X and re-learns the row length, with no reset.
    run_layer(32,  2, 500, 0, "reload 1 (N=32)");
    run_layer(16,  3, 500, 0, "reload 2 (N=16)");
    run_layer(256, 2, 500, 0, "reload 3 (N=256)");

    // Full-length rows with operands at the int16 limit: the exact sum
    // reaches ~2**40, so the emitted 32-bit beat is genuinely truncated.
    run_layer(1024, 2, 32767, 0, "N=1024 M=2, truncating");

    // Malformed weight packet: TLAST lands mid-row, so the last row is
    // short. The partial accumulator must be flushed as a final result
    // rather than the kernel stalling with the DMA still waiting.
    results.delete();
    result_lasts.delete();
    randomize_operands(16, 2, 500);
    send_vector(16, 0);
    send_beat(pack_w(0, 0), 1'b0, 0);   // row 0, first half
    send_beat(pack_w(0, 8), 1'b0, 0);   // row 0, second half -> result 0
    send_beat(pack_w(1, 0), 1'b1, 0);   // row 1, first half only, TLAST
    wait_for_results(2, 1000);

    if (results.size() != 2) begin
      $display("FAIL short final row: got %0d result(s), expected 2", results.size());
      errors++;
    end else begin
      expected = 0;
      for (int i = 0; i < 16; i++) expected += longint'(x[i]) * longint'(w[0][i]);
      expected_trunc = expected[OUT_WIDTH-1:0];
      if (results[0] !== expected_trunc) begin
        $display("FAIL short final row: row 0 got 0x%08h, expected 0x%08h",
                 results[0], expected_trunc);
        errors++;
      end

      // The flushed partial covers only the 8 elements actually sent.
      expected = 0;
      for (int i = 0; i < 8; i++) expected += longint'(x[i]) * longint'(w[1][i]);
      expected_trunc = expected[OUT_WIDTH-1:0];
      if (results[1] !== expected_trunc) begin
        $display("FAIL short final row: partial got 0x%08h, expected 0x%08h",
                 results[1], expected_trunc);
        errors++;
      end else if (result_lasts[1] !== 1'b1) begin
        $display("FAIL short final row: flushed result did not assert TLAST");
        errors++;
      end else begin
        $display("PASS short final row: partial row flushed, 0x%08h", results[1]);
      end
    end

    // And the kernel is usable again immediately afterwards.
    run_layer(64, 2, 500, 0, "recovery after short final row");

    if (errors == 0) $display("=== TB PASS: all checks passed ===");
    else             $display("=== TB FAIL: %0d check(s) failed ===", errors);

    $finish;
  end

  // Safety timeout in case a handshake never completes.
  initial begin
    #5000000;
    $display("=== TB FAIL: timeout ===");
    $finish;
  end

endmodule
