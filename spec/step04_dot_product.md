# Step 04 — Dot Product Kernel

Design spec for the `dot_product` kernel: the contract it implements, the
reasoning behind that contract, and how it is verified.

Status: **complete and verified on hardware** (2026-08-18) —
`dot_product_test.py` printed `Step 04 PASS`.

**Backfilled 2026-08-20.** The `spec/<step>.md` convention was introduced
during step 05, so this document was written after the fact, from the RTL,
the testbench, the driver, and the step 04 walkthrough in `STATUS.md`. It
describes the design as built and hardware-verified; nothing here is a
proposal. It exists because step 04's packet protocol is the direct ancestor
of step 05's and of step 06's chaining, and that reasoning was otherwise
recorded only as build narrative.

---

## 1. Goal

Put real arithmetic in the stream path step 03 proved out: compute the
**dot product** of two N-element vectors, `sum(a[i] * b[i])`, on data
travelling PS → PL → PS. Step 03 looped `M_AXIS_MM2S` straight back into
`S_AXIS_S2MM`; this step cuts that wire and drops a kernel in between, so a
buffer read out of DDR is *processed* on its way back rather than copied.

Non-goals, deliberately: any control interface, more than one MAC per cycle,
operand reuse across packets, saturation, and rescaling of the result. The
point of the step is the first working compute path, not its throughput.

---

## 2. Interface

Module `dot_product`, in `rtl/step04_dot_product/dot_product.sv`.

### Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `DATA_WIDTH` | 32 | Operand and result width, signed |
| `ACC_WIDTH` | 64 | Accumulator width |

`DATA_WIDTH` is the stream width on both ports; changing it obliges a
matching change to the AXI DMA's MM2S and S2MM stream widths in the block
design, and to the numpy dtypes in the driver. Nothing checks this.
`ACC_WIDTH` must be at least `2*DATA_WIDTH`; the sign-extension of the
product into the accumulator assumes it.

### Ports

| Port | Dir | Width | Notes |
|---|---|---|---|
| `aclk` | in | 1 | Single clock domain, ~100 MHz PL clock from the PS |
| `aresetn` | in | 1 | Synchronous, active low |
| `s_axis_tdata` | in | 32 | Interleaved operands, one per beat |
| `s_axis_tvalid` / `s_axis_tready` / `s_axis_tlast` | — | 1 | Standard AXI4-Stream |
| `m_axis_tdata` | out | 32 | One int32 result per input packet |
| `m_axis_tvalid` / `m_axis_tready` / `m_axis_tlast` | — | 1 | Standard AXI4-Stream |

No AXI4-Lite interface and no registers — see §3. There is no `TKEEP` on
either port; every beat carries all four bytes. The `s_axis_*` / `m_axis_*`
/ `aclk` / `aresetn` naming is Xilinx's convention, which is what makes the
IP packager infer both stream interfaces without manual mapping — the same
trick step 02 used for its AXI4-Lite ports.

Step 04 predates the project's SystemVerilog convention and is Verilog-2001
throughout (`reg`/`wire`, bare `always @(posedge …)`). Leave it that way
unless the file is being edited for another reason.

---

## 3. Protocol: one interleaved packet, no control interface

```
beat:  0   1   2   3        2N-2   2N-1
data:  a0  b0  a1  b1  ...  a[N-1] b[N-1](TLAST)
                 |
                 v
out:   sum(TLAST)     one beat, S2MM writes 4 bytes back to DDR
```

Both operand vectors arrive interleaved on the single MM2S stream. `N` is
never written anywhere: it is implicit in `TLAST`, so the IP has **no
registers and no AXI4-Lite port at all**, and the block design is step 03's
with one wire cut.

**Why this shape.** The alternatives were:

- *A second DMA channel*, one vector per channel. Cleaner operand
  separation, but a second channel's worth of block design and Connection
  Automation for no arithmetic benefit at this scale.
- *AXI4-Lite-loaded operands or a length register.* Explicit, and closer to
  how a production accelerator is driven — but it adds an interconnect path
  and GUI wiring for information the packet already carries, and step 02
  had already proved the AXI4-Lite path works.

Interleaving was chosen precisely because it reuses step 03's design almost
verbatim, which keeps the step's risk in the arithmetic rather than in the
block design. The pairing convention is the artificial part of it: it costs
2N words of traffic for N MACs, and the stream is the scarce resource.
**Step 05 revisits exactly this** — a matrix needs real operand bandwidth,
so it splits into two packets with the vector cached on-chip, sending
N + M·N words instead of 2·M·N.

**Malformed packets.** If `TLAST` arrives on an even beat — an odd total
beat count, so the final `a` has no matching `b` — the dangling element is
discarded and the accumulator is emitted anyway. The reasoning is not
politeness: a kernel that stalled instead would wedge the DMA channel with
no error visible to the PS, and a hung `wait()` is far harder to diagnose
than a wrong number. Step 05 carries the same rule forward for a weight
packet that ends mid-row.

---

## 4. Numeric contract

- Operands are **signed `DATA_WIDTH` integers**. Both are reinterpreted with
  `$signed` at the multiply, because Verilog evaluates a mixed-signedness
  expression as unsigned — one bare operand silently makes the whole
  product unsigned.
- The 64-bit product is **sign-extended to `ACC_WIDTH`** and added to the
  accumulator, so a long vector cannot wrap mid-sum: at `DATA_WIDTH` = 32
  and `ACC_WIDTH` = 64 the accumulator absorbs N up to 2³² full-range
  products.
- The emitted beat carries the **low `DATA_WIDTH` bits** of the accumulator,
  i.e. the true sum modulo 2³². Negative results arrive as two's complement
  in that word.
- The accumulator is cleared by `TLAST`, so consecutive packets are
  independent with no reset or reconfiguration between them.

This truncation is real, not theoretical: the hardware test draws operands
from ±2¹⁵ so that a 1024-element sum comfortably exceeds 2³². **Any
reference model must reproduce the truncation**, and must not compute the
exact sum in a type that can itself wrap — see §5.

---

## 5. PS-side contract

The driver must:

1. **Interleave the operands into one buffer** — `send_buf[0::2] = a`,
   `send_buf[1::2] = b` — and send it as a single `transfer()` call, so one
   `TLAST` delimits the whole packet.
2. **Arm the receive channel before the send channel**, as in step 03, so
   `S2MM` is already accepting when the single result beat appears.
3. **Use `pynq.allocate()` buffers**, not plain numpy arrays: int32 for the
   send buffer (2N entries), uint32 for the 1-entry result buffer.
4. **Mask the reference to 32 bits** and compute it with Python ints, not
   numpy. 1024 products of ~2³⁰ risk overflowing int64 accumulation, and a
   silently wrapped reference would "confirm" a wrapped result.

Test design worth keeping, and reused by step 05:

- operands large enough that the sum genuinely exceeds the output width,
  rather than passing on small numbers
- negative operands throughout — an unsigned multiply passes an
  all-positive test perfectly
- back-to-back packets with no reload, proving `TLAST` really clears the
  accumulator

---

## 6. Microarchitecture

One register file, no pipeline:

```
have_a=0 : latch s_axis_tdata into a_reg, have_a <- 1
have_a=1 : acc <- acc + $signed(a_reg) * $signed(s_axis_tdata), have_a <- 0
TLAST    : emit acc_flush[31:0] with TLAST, acc <- 0, have_a <- 0
```

`acc_flush` is `acc_next` when the terminating beat completed a pair and
`acc` when it did not — that single mux is the malformed-packet rule of §3.

**Flow control.** `s_axis_tready = !m_axis_tvalid`: the input stalls only
while a result is waiting to be drained, and is **not** a function of
`m_axis_tready`. That deliberately keeps a combinational path from running
the downstream `TREADY` back into the upstream `TREADY`. It costs one cycle
at end-of-packet and nothing in steady state. Since a packet produces
exactly one result, one in-flight result is all the design must hold — step
05, whose rows produce a result every few beats, has to extend the same idea
into a global pipeline stall for the same reason.

Throughput is **one MAC per two beats** (the interleaving), i.e. one MAC per
two cycles at full stream rate.

---

## 7. Performance and resources

| Quantity | Value |
|---|---|
| MACs/cycle | 0.5 — one per operand pair, two beats per pair |
| Clock | ~100 MHz (PL clock from the PS) |
| Peak | ~50 MMAC/s |
| Cycles per packet | `2N + 1` |
| Stream traffic | `2N` words for `N` MACs |
| DSP48E2 | 1 expected (a 32×32 signed multiply maps to a small DSP cluster) |
| BRAM | none — no on-chip storage at all |

Post-implementation utilization and timing were not recorded for this step;
the numbers above are analytic except where noted. Step 05's build, which is
strictly larger, closes at WNS +2.013 ns on the same 100 MHz clock, so
timing was never a concern here.

**The bottleneck is the stream, and the interleaving doubles it.** 32 bits
per cycle at 100 MHz is 400 MB/s carrying one operand per beat. This is the
observation that drives step 05's entire protocol.

---

## 8. Verification

**Simulation** — `sim/step04_dot_product/tb_dot_product.sv`, run by
`make sim_step04`, self-checking, prints a single `=== TB PASS ===` line.
Ten cases, all passing:

| Case | What it pins down |
|---|---|
| n=1 | Smallest meaningful packet; `TLAST` on beat 1 |
| n=8 dense | Ordinary operation, positive operands |
| n=16 with `TVALID` gaps | MM2S does not supply a beat every cycle |
| n=32, 70% backpressure | `m_axis_tready` deasserting randomly |
| Back-to-back ×3 (n=4) | Accumulator cleared by `TLAST`, not leaking |
| n=1024 | The length the hardware test uses; sum exceeds 32 bits |
| Odd beat count | Dangling `a` discarded, result still emitted |
| Recovery after malformed | Kernel usable immediately afterwards |

**Off-board driver check.** Before the board run the driver was verified by
stubbing PYNQ with a model of the RTL's semantics and running the real
script against it. That validated the interleaving, the truncation masking
and the numpy/PYNQ API usage — and nothing about DMA arming, cache
coherency on `S_AXI_HPC0_FPD`, or whether `TLAST` actually arrives. Those
only hardware can answer.

**Verified on hardware:** `./run_pynq.sh dot_product_test.py` — n = 1, 2, 8,
64, 1024 and three back-to-back packets all matched, ending in
`Step 04 PASS`.

**Deferred deliberately:** simulating the whole block design with the Zynq
UltraScale+ VIP (`set_property SELECTED_SIM_MODEL tlm [get_bd_cells
/zynq_ultra_ps_e_0]`) would run the full PS→DMA→kernel→DMA→PS round trip in
xsim, catching wiring and DMA-behaviour bugs the unit testbench cannot. It
still sees nothing above the AXI layer — PYNQ buffers, cache coherency and
arming order stay invisible — and it costs a project-based
`launch_simulation` flow rather than the standalone `xvlog`/`xelab` one.
Step 04 passed on the first board run, so it was never built. Build it on a
*second* unexplained board failure, not the first.

---

## 9. Block design

Step 03's design with the loopback wire cut and the kernel inserted:
`M_AXIS_MM2S → dot_product_0/s_axis`, `dot_product_0/m_axis → S_AXIS_S2MM`.
Everything else is Connection Automation.

| Setting | Value |
|---|---|
| AXI DMA — Scatter Gather | Disabled (`c_include_sg = 0`, Direct Register mode) |
| AXI DMA — channels | Both MM2S and S2MM |
| AXI DMA — stream widths | 32 both directions |
| AXI DMA — Width of Buffer Length Register | **left at the default 14** — see §10 |
| PS slave port | `S_AXI_HPC0_FPD` |

`vivado/step04_dot_product/dot_product_accel_bd.tcl` is **a hand-edited copy
of step 03's export, not a GUI export** — the GUI's *File → Export Block
Design as TCL* never wrote the file. It was checked cell-by-cell against the
scratch project's `.bd` (same 6 cells, all 8 interface nets identical,
`c_include_sg = 0` in both) and left alone rather than re-exported over a
known-good, hardware-validated file. The general lesson is now a rule in
`CLAUDE.md` and a checklist item in `docs/vivado-gui-session.md`: confirm
with `git status` that an export actually landed. Step 05 hit the same
failure again.

Synthesis emits `[Synth 8-7071] port 'm_axis_mm2s_tkeep' … is unconnected`.
Benign — the kernel has no `TKEEP` input and every beat is full width.
Written up in `docs/xilinx-tools.md`.

---

## 10. Known limits and what they implied

- **Packet size is capped at 16383 bytes.** The buffer length register was
  left at its 14-bit default, so a single `transfer()` cannot exceed 16383
  bytes and `TLAST` means the packet cannot be split across two calls. At
  8 bytes per operand pair that caps this design at **N ≤ 2047**, just
  above the 1024 the hardware test used — which is why step 04 never hit
  it. Step 05 did, immediately, and the project rule (`c_sg_length_width` =
  26 on every DMA) came out of that.
- **Interleaving wastes half the stream.** Directly answered by step 05's
  two-packet protocol and on-chip vector cache.
- **One MAC per cycle at best.** Answered by step 05's 8 int16 lanes in a
  128-bit beat.
- **Truncation, not requantization.** Still true in step 05, and it becomes
  load-bearing in step 06: chaining layers means a layer's output must be
  a legal *input* operand, which forces a rescaling shift and saturation.
  See `spec/step06_activation_chaining.md` §4.
- **One host round trip per dot product.** Invisible at step 04's scale and
  never measured here; step 05 measured it at ~0.55 ms and it turned out to
  dominate everything. That measurement is what step 06 is organised
  around.
