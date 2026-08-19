`timescale 1ns / 1ps

// Step 05: streaming matrix-vector multiply (dense / linear layer).
//
// Computes y = W . x, where W is M x N and x is N long, one row at a time.
// Where step 04 chewed one 32-bit operand pair per cycle, this kernel takes
// LANES int16 pairs per cycle out of a wide AXI4-Stream beat, so throughput
// is LANES MACs/cycle instead of one.
//
// -------------------------------------------------------------------------
// Protocol: two input packets, no control interface
// -------------------------------------------------------------------------
//
//   packet 1   x0 x1 ... x[N-1](TLAST)          the vector, cached in BRAM
//   packet 2   w00 w01 ... w0[N-1]              row 0    -> y0
//              w10 w11 ... w1[N-1]              row 1    -> y1
//              ...
//              w[M-1][0] ... w[M-1][N-1](TLAST) row M-1  -> y[M-1] (TLAST)
//
// Each input beat carries LANES int16 values, lane 0 in the low bits. N is
// learned from packet 1's beat count, so it needs no length register; M is
// implicit in how many rows packet 2 carries. The IP therefore has no
// AXI4-Lite interface at all, exactly as in step 04.
//
// After packet 2's TLAST the kernel returns to the vector-loading state, so
// a fresh (x, W) pair can follow immediately with no reset and no reload of
// anything else.
//
// -------------------------------------------------------------------------
// Contracts the PS side must honour
// -------------------------------------------------------------------------
//
//  * N is a multiple of LANES. The driver zero-pads x and every row up to
//    that multiple; a zero operand contributes exactly zero to the sum, so
//    padding needs no lane-masking or TKEEP logic in hardware.
//  * N <= MAX_N. A longer vector packet clamps at the cache's last word
//    rather than wrapping and silently corrupting earlier elements.
//  * Operands are signed int16. Products accumulate into ACC_WIDTH bits;
//    the emitted beat carries the low OUT_WIDTH bits of that accumulator,
//    i.e. the true sum modulo 2**OUT_WIDTH. With N = 4096 the exact sum can
//    reach 2**42, so this truncation is real and the driver's reference
//    model has to reproduce it rather than assume it never bites.
//
// A malformed packet 2 (total beats not a whole number of rows) flushes the
// partial accumulator as a final result rather than swallowing it. Same
// reasoning as step 04: a kernel that quietly stops mid-packet would wedge
// the DMA channel with no error visible to the PS.

module linear_layer #(
    parameter integer DATA_WIDTH = 16,   // operand width, signed
    parameter integer LANES      = 8,    // operands per beat = MACs per cycle
    parameter integer ACC_WIDTH  = 48,   // DSP48E2's native accumulator width
    parameter integer OUT_WIDTH  = 32,   // result beat width
    parameter integer MAX_N      = 4096  // longest vector the cache holds
) (
    input  wire                        aclk,
    input  wire                        aresetn,

    // Slave stream: packet 1 = vector, packet 2 = weight rows
    input  wire [LANES*DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                        s_axis_tvalid,
    output wire                        s_axis_tready,
    input  wire                        s_axis_tlast,

    // Master stream: one result beat per weight row
    output reg  [OUT_WIDTH-1:0]        m_axis_tdata,
    output reg                         m_axis_tvalid,
    input  wire                        m_axis_tready,
    output reg                         m_axis_tlast
);

  localparam integer BEAT_W = LANES * DATA_WIDTH;      // stream width
  localparam integer DEPTH  = MAX_N / LANES;           // cache words
  localparam integer ADDR_W = $clog2(DEPTH);
  localparam integer PROD_W = 2 * DATA_WIDTH;

  localparam logic LOAD_X  = 1'b0;
  localparam logic COMPUTE = 1'b1;

  // ------------------------------------------------------------------
  // Flow control
  // ------------------------------------------------------------------
  // The whole datapath freezes while a result sits undrained in the output
  // register. Deliberately a function of m_axis_tvalid and *not* of
  // m_axis_tready, so no combinational path runs from the downstream TREADY
  // back into the upstream one -- same reasoning as step 04, but here it
  // also has to hold the pipeline stages, not just the input.
  //
  // Cost: one bubble per emitted result. With one result per row of N/LANES
  // beats that is invisible unless a row is a single beat.

  logic stall;
  assign stall         = m_axis_tvalid;
  assign s_axis_tready = !stall;

  logic in_beat;
  assign in_beat = s_axis_tvalid && s_axis_tready;

  // ------------------------------------------------------------------
  // Stage 0: packet state machine, vector cache, row bookkeeping
  // ------------------------------------------------------------------

  logic              state;
  logic [ADDR_W-1:0] wr_addr;      // write pointer while loading x
  logic [ADDR_W-1:0] row_len_m1;   // address of x's last word = N/LANES - 1
  logic [ADDR_W-1:0] col_ptr;      // read pointer while streaming weights

  logic load_beat, compute_beat, row_end, pkt_end;

  always_comb begin
    load_beat    = in_beat && (state == LOAD_X);
    compute_beat = in_beat && (state == COMPUTE);
    // A row ends on its last column, or early if the packet ends there.
    row_end      = compute_beat && ((col_ptr == row_len_m1) || s_axis_tlast);
    pkt_end      = compute_beat && s_axis_tlast;
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      state      <= LOAD_X;
      wr_addr    <= '0;
      row_len_m1 <= '0;
      col_ptr    <= '0;
    end else if (!stall) begin
      if (load_beat) begin
        if (s_axis_tlast) begin
          row_len_m1 <= wr_addr;
          wr_addr    <= '0;
          col_ptr    <= '0;
          state      <= COMPUTE;
        end else if (wr_addr != ADDR_W'(DEPTH-1)) begin
          // Clamp rather than wrap: an over-long vector then produces an
          // obviously wrong answer instead of a subtly corrupted one.
          wr_addr <= wr_addr + 1'b1;
        end
      end else if (compute_beat) begin
        col_ptr <= row_end ? '0 : col_ptr + 1'b1;
        if (s_axis_tlast) state <= LOAD_X;
      end
    end
  end

  // The cache: one write port used during LOAD_X, one registered read port
  // used during COMPUTE. Write and read never target the same word in the
  // same cycle -- the phases are disjoint -- so no collision behaviour to
  // reason about. Vivado infers this as simple dual-port BRAM: at the
  // default 4096 x int16 that is 128 bits x 512, i.e. 2 BRAM36 of 144.
  logic [BEAT_W-1:0] x_mem [0:DEPTH-1];
  logic [BEAT_W-1:0] x_rd;

  always_ff @(posedge aclk) begin
    if (!stall) begin
      if (load_beat) x_mem[wr_addr] <= s_axis_tdata;
      x_rd <= x_mem[col_ptr];
    end
  end

  // ------------------------------------------------------------------
  // Stage 1: weight beat registered alongside the cache read
  // ------------------------------------------------------------------

  logic              v1, row_end1, pkt_end1;
  logic [BEAT_W-1:0] w1;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      v1       <= 1'b0;
      row_end1 <= 1'b0;
      pkt_end1 <= 1'b0;
    end else if (!stall) begin
      v1       <= compute_beat;
      row_end1 <= row_end;
      pkt_end1 <= pkt_end;
      w1       <= s_axis_tdata;
    end
  end

  // ------------------------------------------------------------------
  // Stage 2: LANES parallel signed multiplies -- one DSP48E2 each
  // ------------------------------------------------------------------

  // `signed` here drives the sign-extension in the adder tree below. Note
  // that with OUT_WIDTH < ACC_WIDTH it is not currently observable at the
  // output: getting it wrong perturbs the accumulator only in bits >= 32,
  // which truncation discards, and the testbench confirms an unsigned
  // declaration still passes every case. It becomes load-bearing the moment
  // a result is requantized with a right shift (step 06/07) or saturated
  // instead of truncated, so it stays correct here rather than lucky.
  logic signed [PROD_W-1:0] prod2 [LANES];
  logic                     v2, row_end2, pkt_end2;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      v2       <= 1'b0;
      row_end2 <= 1'b0;
      pkt_end2 <= 1'b0;
    end else if (!stall) begin
      v2       <= v1;
      row_end2 <= row_end1;
      pkt_end2 <= pkt_end1;
      for (int l = 0; l < LANES; l++) begin
        prod2[l] <= $signed(w1  [l*DATA_WIDTH +: DATA_WIDTH]) *
                    $signed(x_rd[l*DATA_WIDTH +: DATA_WIDTH]);
      end
    end
  end

  // ------------------------------------------------------------------
  // Stage 3: adder tree + accumulator + output register
  // ------------------------------------------------------------------

  // Written as a loop for readability; synthesis balances it into a
  // log2(LANES)-deep tree rather than the literal serial chain.
  logic signed [ACC_WIDTH-1:0] tree_sum;

  always_comb begin
    tree_sum = '0;
    for (int l = 0; l < LANES; l++) begin
      tree_sum = tree_sum + ACC_WIDTH'(prod2[l]);
    end
  end

  logic signed [ACC_WIDTH-1:0] acc, acc_next;
  assign acc_next = acc + tree_sum;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      acc           <= '0;
      m_axis_tdata  <= '0;
      m_axis_tvalid <= 1'b0;
      m_axis_tlast  <= 1'b0;
    end else begin
      if (m_axis_tvalid && m_axis_tready) begin
        m_axis_tvalid <= 1'b0;
        m_axis_tlast  <= 1'b0;
      end
      // stall is m_axis_tvalid, so this arm only runs with the output free.
      if (!stall && v2) begin
        if (row_end2) begin
          acc           <= '0;
          m_axis_tdata  <= acc_next[OUT_WIDTH-1:0];
          m_axis_tvalid <= 1'b1;
          m_axis_tlast  <= pkt_end2;
        end else begin
          acc <= acc_next;
        end
      end
    end
  end

endmodule
