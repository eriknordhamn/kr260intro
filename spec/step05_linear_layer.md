# Step 05 — Linear Layer (matrix-vector multiply)

Design spec for the `linear_layer` kernel: the contract it implements, the
reasoning behind that contract, and how it is verified. This is the document
to read before changing the RTL or writing a driver against it.

Status: RTL, testbench, block design and bitstream complete; hardware
verification outstanding.

---

## 1. Goal

Compute **y = W · x**, where `W` is an M×N matrix and `x` an N-element
vector — the arithmetic core of a dense neural-network layer. Step 04 proved
one MAC per cycle on a 32-bit stream; this step raises that to **8 MACs per
cycle** by carrying 8 int16 operands per 128-bit beat.

Non-goals for this step, deliberately: activation functions, layer chaining,
requantization, and weight reuse across invocations. Each belongs to a later
milestone and each would change the interface, so they are named here to keep
them from creeping in.

---

## 2. Interface

Module `linear_layer`, in `rtl/step05_linear_layer/linear_layer.sv`.

### Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `DATA_WIDTH` | 16 | Operand width, signed |
| `LANES` | 8 | Operands per beat = MACs per cycle |
| `ACC_WIDTH` | 48 | Accumulator width (DSP48E2's native width) |
| `OUT_WIDTH` | 32 | Result beat width |
| `MAX_N` | 4096 | Longest vector the on-chip cache holds |

Stream width is `LANES * DATA_WIDTH` = 128 bits at the defaults. Changing
`LANES` changes the slave stream's TDATA width, and the AXI DMA's stream
width must then be changed to match by hand — nothing checks this.

### Ports

| Port | Dir | Width | Notes |
|---|---|---|---|
| `aclk` | in | 1 | Single clock domain |
| `aresetn` | in | 1 | Synchronous, active low |
| `s_axis_tdata` | in | 128 | `LANES` int16 lanes, lane 0 in the low bits |
| `s_axis_tvalid` / `s_axis_tready` / `s_axis_tlast` | — | 1 | Standard AXI4-Stream |
| `m_axis_tdata` | out | 32 | One int32 result per weight row |
| `m_axis_tvalid` / `m_axis_tready` / `m_axis_tlast` | — | 1 | Standard AXI4-Stream |

No AXI4-Lite interface and no registers — see §3.

Ports are plain Verilog-compatible per the project convention; the internals
are SystemVerilog (`logic`, `always_ff`, `always_comb`).

---

## 3. Protocol: two packets, no control interface

```
packet 1   x0 x1 ... x[N-1](TLAST)             the vector, cached in BRAM
packet 2   w00 w01 ... w0[N-1]                 row 0    -> y0
           w10 w11 ... w1[N-1]                 row 1    -> y1
           ...
           w[M-1][0] ... w[M-1][N-1](TLAST)    row M-1  -> y[M-1] (TLAST)

out        y0 y1 ... y[M-1](TLAST)             one int32 beat per row
```

`N` is learned from packet 1's beat count (`N = beats × LANES`). `M` is
implicit in how many rows packet 2 carries. Neither is ever written to a
register, which is why the IP has no control interface at all.

**Why this shape.** Three alternatives were considered:

- *Replay x per row* (step 04's interleaving, extended): simplest RTL, no
  cache — but sends 2·M·N words instead of N + M·N, doubling the traffic on
  the resource that is already the bottleneck (§7).
- *AXI4-Lite config registers for M and N*: explicit rather than implicit,
  and closer to how a production accelerator is driven — but adds an
  interconnect path and GUI wiring for information the packet boundaries
  already carry.
- *Two DMA channels, one for x and one for W*: better separation, but a
  second channel's worth of block design for no arithmetic benefit at this
  step's scale.

The chosen scheme costs one BRAM cache and buys minimum traffic with zero
control-plane surface.

**State.** Two states. `LOAD_X` writes beats into the cache; its `TLAST`
latches the row length and switches to `COMPUTE`. `COMPUTE` emits one result
per row; packet 2's `TLAST` returns to `LOAD_X`. A fresh (x, W) pair may
follow immediately — no reset, no reconfiguration, no reload of anything
else. After reset the kernel is always in `LOAD_X`, so the first packet it
ever sees is a vector.

---

## 4. Numeric contract

- Operands are **signed int16**. Lane slices are unsigned by declaration, so
  each is reinterpreted with `$signed` at the multiply — both operands, since
  Verilog evaluates a mixed-signedness expression as unsigned.
- Products (32-bit) accumulate into **48 bits**. With N ≤ 4096 and operands
  at the int16 limit the exact sum reaches ~2⁴², so 48 bits cannot overflow
  in any legal configuration.
- The emitted beat carries the **low 32 bits** of the accumulator: the true
  sum modulo 2³². This truncation is real, not theoretical — an N=1024 row
  of full-range operands exceeds 32 bits routinely — so **every reference
  model must reproduce it** rather than assume it never bites.
- Negative results arrive as two's complement in that 32-bit word.

A consequence worth recording: because only bits [31:0] are emitted,
sign-extension errors in bits ≥ 32 are unobservable at the output. The
testbench confirms this — declaring the product array unsigned still passes
every case (§8). The declaration is nonetheless kept correct, because it
becomes load-bearing the moment a result is requantized with a right shift
(§9).

---

## 5. PS-side contract

The driver **must**:

1. **Zero-pad to a multiple of `LANES`.** `x` and every row of `W` are padded
   with zeros up to a multiple of 8. A zero operand contributes exactly zero,
   so padding needs no lane masking or `TKEEP` logic in hardware. This is the
   single most important contract: an unpadded N silently misaligns every row
   after the first.
2. **Keep N ≤ `MAX_N`** (4096). A longer vector packet clamps at the cache's
   last word rather than wrapping, producing an obviously wrong answer rather
   than a subtly corrupted one.
3. **Send the vector packet before the weight packet**, as two separate DMA
   transfers with `TLAST` on each — that is what `dma.sendchannel.transfer()`
   produces per call.
4. **Arm the receive channel before sending**, as in steps 03 and 04, so
   `S2MM` is already accepting when the first result beat appears.
5. **Allocate `pynq.allocate()` buffers**, not plain numpy arrays: int16 for
   the two input buffers, uint32 (M entries) for the result buffer.

Malformed input is handled rather than rejected: if packet 2 ends mid-row,
the partial accumulator is flushed as a final result with `TLAST`. The
reasoning is the same as step 04's odd-beat case — a kernel that quietly
stopped would wedge the DMA channel with no error visible to the PS, which
is far harder to debug than a wrong number.

---

## 6. Microarchitecture

```
 stage 0            stage 1              stage 2            stage 3
 ────────           ────────             ────────           ────────
 handshake          w1  <- weight beat   prod2[0..7] <-     tree_sum (comb)
 state machine      x_rd <- BRAM word    w1[l] * x_rd[l]    acc += tree_sum
 col_ptr / wr_addr  flags v1/row/pkt     flags v2/row/pkt   emit on row_end2
 BRAM read issued
```

Latency is 3 cycles from a beat entering to its contribution landing in the
accumulator; throughput is one beat — 8 MACs — per cycle.

**Flow control.** `s_axis_tready = !m_axis_tvalid`, and *every* pipeline
stage shares the same `!stall` enable. Two properties follow:

- No combinational path runs from the downstream `TREADY` back into the
  upstream one, the same choice step 04 made.
- Freezing the whole pipeline, not just the input, makes multiple in-flight
  results structurally impossible. This matters when a row is a single beat
  (N = 8): gating only the input would let beats already inside the pipeline
  emit a second result while the first is undrained.

Cost: one bubble cycle per emitted result, i.e. one per row.

**Vector cache.** One write port (during `LOAD_X`) and one registered read
port (during `COMPUTE`), both in a single clocked block with no reset on the
read register — the pattern Vivado matches to simple dual-port BRAM. The
phases are disjoint, so there is no read/write collision behaviour to reason
about. At the defaults it is 128 bits × 512 words = **2 BRAM36 of 144**.

---

## 7. Performance and resources

| Quantity | Value |
|---|---|
| MACs/cycle | 8 |
| Clock | ~100 MHz (PL clock from the PS) |
| Peak | ~800 MMAC/s |
| Cycles per layer | `N/8` (vector load) + `M · (N/8 + 1)` |
| Example: 256×256 | ~8.4k cycles ≈ **84 µs** |
| DSP48E2 | 8 of 1248 — **measured 8** |
| BRAM36 | 2 of 144 for the cache — **measured 3.5 tiles** for the whole design, cache plus the DMA's FIFOs |
| Timing | **WNS +2.013 ns** at 100 MHz, hold +0.010 ns, all constraints met |

**The stream is the bottleneck, not the arithmetic.** A 128-bit beat per
cycle at 100 MHz is 1.6 GB/s, which is exactly 8 int16 operands per cycle —
so the kernel consumes the entire stream and a wider MAC array would idle.
The 256×256 example needs 8192 weight beats and takes ~8.4k cycles, i.e. it
runs at essentially 100% stream utilization. Going faster requires a wider
stream, a faster PL clock, or keeping weights on-chip — not more
multipliers. With 1248 DSPs available, arithmetic is nowhere near the limit.

---

## 8. Verification

**Simulation** — `sim/step05_linear_layer/tb_linear_layer.sv`, run by
`make sim_step05`, self-checking, prints a single `=== TB PASS ===` line.
Eleven cases, all passing:

| Case | What it pins down |
|---|---|
| N=8 M=1 | Minimal layer; every beat is a row end |
| N=8 M=4 | Result every row-beat — hardest case for the global stall |
| N=64 M=4 dense | Ordinary operation |
| N=64 M=3 with TVALID gaps | MM2S does not supply a beat every cycle |
| N=128 M=4 backpressured | S2MM's TREADY deasserting randomly |
| Reload ×3 (N=32, 16, 256) | Return to `LOAD_X`, row length re-learned, no reset |
| N=1024 M=2 | Sum genuinely exceeds 32 bits; truncation |
| Short final row | Partial accumulator flushed rather than wedging |
| Recovery after short row | Kernel usable immediately afterwards |

**Mutation testing.** Passing on the first run means nothing until the
testbench is shown capable of failing, so the RTL was deliberately broken in
scratch copies:

| Mutation | Result |
|---|---|
| Drop `$signed` on one lane operand | Killed — 12 checks fail |
| Remove the accumulator reset at row end | Killed — 11 checks fail |
| Declare `prod2` unsigned | **Survived** — see §4; not observable at a 32-bit output |

**What simulation cannot cover**, and hardware must: DMA arming order, cache
coherency on `S_AXI_HPC0_FPD`, whether `TLAST` actually arrives from MM2S,
and whether the 128-bit width change through SmartConnect behaves. Those are
the failure modes to suspect first if the board run misbehaves.

---

## 9. Block design

Step 04's design with two changes: the kernel swapped, and the DMA widened.

| Setting | Value |
|---|---|
| AXI DMA — Scatter Gather | Disabled (Direct Register mode) |
| AXI DMA — channels | Both MM2S and S2MM enabled |
| AXI DMA — MM2S memory-map width | **128** |
| AXI DMA — MM2S stream width | **128** |
| AXI DMA — S2MM memory-map width | 32 |
| AXI DMA — S2MM stream width | 32 |
| PS slave port | `S_AXI_HPC0_FPD` (enabled; off by default — see `docs/xilinx-tools.md`) |

Connections: `M_AXIS_MM2S → linear_layer_0/s_axis`,
`linear_layer_0/m_axis → S_AXIS_S2MM`, everything else by Connection
Automation, re-run until it offers nothing further.

128 bits is `S_AXI_HPC0_FPD`'s native width, so the memory-map side needs no
width conversion. The asymmetry (128 in, 32 out) is deliberate: results are
one int32 each, and a 128-bit S2MM would pad each one into 16 bytes.

Expect the `[Synth 8-7071] m_axis_mm2s_tkeep unconnected` warning again —
benign, for the reason recorded in `docs/xilinx-tools.md`.

---

## 10. Known limits and what comes next

- **Truncation, not requantization.** A real quantized layer rescales with a
  right shift and saturates; this one truncates. Step 06/07 will need the
  shift, and that is the change that makes the accumulator's upper bits —
  and `prod2`'s signedness — observable.
- **No weight reuse.** Every invocation re-streams all of `W`. A
  weight-stationary variant would cache `W` instead of `x`, which is the
  right structure once the same layer runs repeatedly.
- **Parallelism is stream-limited.** More lanes need a wider stream or a
  faster PL clock first (§7).
- **One clock domain** at ~100 MHz. Raising the PL clock is the cheapest
  remaining throughput lever, but only to a point: the implemented design
  closes with **WNS +2.013 ns** on a 10 ns period, i.e. a critical path of
  ~8 ns, so it reaches roughly **125 MHz** with no RTL change and no
  further. Past that the adder tree and accumulator need a pipeline stage,
  which also means carrying the row-end flags one stage deeper.
