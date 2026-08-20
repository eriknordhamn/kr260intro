# Step 06 — Activation + Chaining (DRAFT)

Design spec for the step 06 kernel: ReLU in the PL, and layer-to-layer data
flow that stays in the fabric instead of returning to the PS between layers.

Status: **DRAFT — no RTL written.** Sections 1–3 are settled by the step 05
measurements. Sections 4–6 are a proposal; §10 lists the decisions that are
genuinely open and should be closed before the RTL starts. Nothing here has
been simulated or built.

---

## 1. Why this step is about chaining, not ReLU

ReLU is a comparator and a mux. It is the smallest piece of arithmetic in
the project so far, and if it were the point of the step there would be no
step. The measurement that makes this milestone worth doing came out of
step 05's hardware run.

**Every invocation cost ~0.55 ms of wall clock, independent of size.**

| Case | Compute | Wall clock | Duty cycle |
|---|---|---|---|
| 4096×2 = 8192 MACs | 1024 cycles ≈ **10 µs** | ~560 µs | **under 2%** |
| Best measured throughput | — | — | **15 MMAC/s** |
| Kernel ceiling (§7 of step 05) | — | — | ~800 MMAC/s |

The kernel is idle 98% of the time. The gap between 15 and 800 MMAC/s is
**a factor of 53**, and no amount of work on the datapath closes any of it.
Doubling the lanes to 16 would move a 10 µs compute to 5 µs inside the same
560 µs and change the measured throughput by nothing perceptible.

### What the 0.55 ms actually is

Worth being precise, because it determines whether hardware is even the
right fix. In `sw/step05_linear_layer/linear_layer_test.py` the timer starts
at line 160, **after** `allocate()` and after the buffers are filled. The
measured interval contains exactly six PYNQ calls:

```python
t0 = time.perf_counter()
dma.recvchannel.transfer(res_buf)
dma.sendchannel.transfer(vec_buf)      # packet 1
dma.sendchannel.wait()
dma.sendchannel.transfer(wgt_buf)      # packet 2
dma.sendchannel.wait()
dma.recvchannel.wait()
elapsed = time.perf_counter() - t0
```

So it is **~90 µs per PYNQ call**, or ~180 µs per transfer/wait pair —
register writes over AXI4-Lite plus polled completion, through Python. It is
*not* buffer allocation. (`STATUS.md`'s step 05 walkthrough says "`allocate`
plus two `transfer`/`wait` round trips"; the `allocate` part is wrong, and
that matters here.) Two consequences:

- **Software cannot amortise this away.** Hoisting `allocate()` out of the
  loop and reusing buffers — worth doing regardless — removes none of the
  0.55 ms, because none of it was inside the timed region.
- **The cost scales with the number of DMA transfers, not bytes.** That is
  precisely what chaining removes: an L-layer network today costs `3L`
  PYNQ calls, and chained it costs 4 in total.

### The projection

A 3-layer MLP, 256×256 per layer (84 µs of compute each, §7 of step 05):

| | PYNQ calls | Host overhead | Compute | Total | Duty |
|---|---|---|---|---|---|
| Today, one layer per call | 9 | ~1.65 ms | 252 µs | ~1.9 ms | 13% |
| Chained, one call | 4 | ~0.36 ms | 252 µs | ~0.61 ms | 41% |

**~3× on a 3-layer network, and it grows with depth** — the host cost stops
being per-layer, so a 10-layer network is ~7×. This is the entire argument
for the step, and it should be re-measured on hardware before and after, not
assumed.

### Cheap experiments to run first

Before any RTL, two measurements that cost a board round trip each and could
change the design:

1. **Time each of the six calls separately.** If `wait()` dominates, it is
   polled-completion latency and chaining removes it. If `transfer()`
   dominates, part of it is Python/driver cost per call that chaining also
   removes — but the split tells us how much of the 0.55 ms the projection
   above can actually claim.
2. **Time two back-to-back `transfer()` calls on the same channel** without
   an intervening `wait()`, to see whether PYNQ pipelines them at all. If it
   does, some of the win is available without hardware.

Neither is a reason to skip the step. Both stop us from attributing a win to
the wrong change.

---

## 2. Goal

Run **L dense layers with ReLU between them, from a single host
invocation**, keeping every intermediate activation inside the PL.

```
x -> [ W1 · x ] -> requantize -> ReLU -> [ W2 · h1 ] -> requantize -> ReLU -> ... -> y
     |________________________ all inside the fabric _______________________|
```

The PS sends the input vector and all the weights, and reads back only the
final output vector.

Non-goals, deliberately: convolution, batching (one vector at a time),
training or backprop, activations other than ReLU (a leaky variant is a
parameter change, not a design change), weights persisting across
invocations, and any change to the 8-lane int16 datapath. Step 07 runs a
real model on top of this; it should not need new RTL.

---

## 3. What carries over from step 05

Unchanged, and deliberately so:

- 8 int16 lanes on a 128-bit beat, 8 MACs/cycle, 48-bit accumulator
- the vector cache in BRAM, `N` learned from the vector packet's beat count
- `s_axis_tready = !m_axis_tvalid` with a **global pipeline stall**, so only
  one result is ever in flight
- malformed packets flushed rather than wedging the DMA channel
- zero-padding every vector and every weight row to a multiple of `LANES`,
  in the driver

The step 05 kernel already returns to `LOAD_X` on the weight packet's
`TLAST` and re-learns `N`. **Chaining is mostly a matter of where the result
beat goes**: to the output stream on the last layer, or back into a vector
cache on every other one.

---

## 4. Chaining forces requantization — this is the real design content

Step 05 emits the **low 32 bits** of a 48-bit accumulator. That is a fine
answer to hand to the PS, and an illegal input to the next layer, which
needs **int16 operands**. So chaining cannot be added without deciding how a
32/48-bit sum becomes a 16-bit activation. This is the change step 05's §10
flagged as "the change that makes the accumulator's upper bits — and
`prod2`'s signedness — observable", and it is the part of step 06 that can
be numerically wrong in ways that simulate fine on small numbers.

Proposed contract, per layer:

```
acc (48-bit signed)
  -> arithmetic shift right by SHIFT      rounding: truncate toward -inf (>>>)
  -> ReLU: max(0, ·)                      before saturation, so only the
                                          positive side can ever clip
  -> saturate to int16 [0, 32767]         clamp, never wrap
  -> int16 activation, fed to the next layer's vector cache
```

Points that need to be stated rather than assumed:

- **Saturation, not truncation.** Wrapping an over-range activation turns a
  large positive into a large negative and the network's output becomes
  noise with no error anywhere. Clamping is one comparator per lane.
- **ReLU before saturation** means the negative clamp is unreachable when
  ReLU is on; keep the clamp anyway, so the same datapath is correct if a
  later step makes the activation optional or leaky.
- **`SHIFT` is per layer** and comes from the model's quantization, not from
  hardware. It must be configurable — see §10, decision A.
- **The final layer's output is different.** It should leave as the 32-bit
  value step 05 already returns (no shift, no ReLU), because the PS wants
  logits, not a clamped activation. So the last layer is not just "the one
  that emits" — it is also the one that skips the activation path.
- **`$signed` on both multiply operands is now load-bearing.** Step 05's
  mutation test showed an unsigned `prod2` *survives* because the upper bits
  are invisible at a 32-bit output. Shifting right makes them visible. The
  step 06 testbench must kill that mutation.

---

## 5. Proposed microarchitecture

Step 05's datapath with a ping-pong vector cache and an activation stage.

```
                 ┌──────────── cache A ◄─┐
 s_axis ──► MAC array ──► acc ──► shift ──► ReLU ──► sat16 ──┤
                 └──────────── cache B ◄─┘        │
                        ▲                          └──► m_axis (last layer,
                        └─ read: the other cache          32-bit, unshifted)
```

- **Two vector caches**, `MAX_N` × 128 bits each. Layer `k` reads from one
  and writes its activations into the other; the roles swap at each layer
  boundary. At `MAX_N` = 4096 that is 2 BRAM36 each, **4 of 144** — cheap.
- **Write side is a gather.** Results arrive one int16 at a time (one per
  weight row) but the cache is written 128 bits wide, so activations are
  packed into a `LANES`-wide staging register and written every 8th row.
  The tail row count must be zero-padded to a multiple of `LANES` in
  hardware, since the *next* layer's `N` is this layer's `M` and the driver
  cannot pad something it never sees. **This is the one genuinely new piece
  of control logic in the step** and the most likely place for an off-by-one.
- **The activation stage is combinational** on the result path: a shift, a
  comparator, a clamp. It adds no pipeline stage and no stall behaviour.
- **`N` for layer k+1 is `M` for layer k**, latched at each layer boundary
  rather than learned from a packet.

Estimated cost over step 05: +2 BRAM36, a handful of LUTs for the shift and
clamp, no extra DSP. Timing should be unaffected — the shift/clamp sits on
the emit path, which is not the critical path (step 05 closes at WNS
+2.013 ns, ~8 ns critical path in the adder tree and accumulator).

---

## 6. Proposed protocol

```
packet 1        x0 … x[N-1](TLAST)                  input vector
packet 2        layer 1 weights, M1 rows (TLAST)
packet 3        layer 2 weights, M2 rows (TLAST)
...
packet L+1      layer L weights, ML rows (TLAST)

out             y0 … y[ML-1](TLAST)                 final layer only, int32
```

Same shape as step 05, with the vector packet sent once instead of per
layer. Two things the stream alone does not carry:

- **which weight packet is the last one** (so the kernel emits instead of
  recirculating), and
- **the per-layer `SHIFT`**.

`TLAST` delimits packets but says nothing about the sequence. Resolving this
is decision A in §10 — it is the first point in the project where the
"no control interface at all" property of steps 04 and 05 may have to end.

**PS-side contract**, in addition to step 05's:

1. Weight packets in layer order, immediately after the vector packet.
2. Every layer's `M` padded to a multiple of `LANES`, because it becomes the
   next layer's `N`. (Hardware pads the cache tail as a safety net; the
   driver should still do it so the row count is explicit on both sides.)
3. Each weight packet inside one `transfer()` call — `TLAST` per call, as in
   step 05 contract 6. `c_sg_length_width` = 26 makes this a non-limit.
4. The receive channel armed once, before anything is sent, sized to the
   **final** layer's `M`.

---

## 7. Performance target

| Quantity | Value |
|---|---|
| MACs/cycle | 8, unchanged |
| Cycles for L layers | `N/8 + Σ Mk·(Nk/8 + 1)` |
| 3×(256×256) | ~25k cycles ≈ **252 µs** |
| Host overhead | **one** ~0.55 ms round trip for the whole network, not L |
| Target duty cycle | ~40% on a 3-layer MLP, vs 13% today |
| Extra BRAM36 | 2 (second cache) |
| Extra DSP | 0 |

The success criterion for the step is a **measured** wall-clock comparison
of the same 3-layer network run chained versus run layer-by-layer through
the step 05 flow, on hardware. Not a cycle count.

After chaining, the next bottleneck is the weight stream itself: `Σ Mk·Nk`
int16 words at 1.6 GB/s. At that point weight-stationary caching (step 05
§10) becomes the interesting lever, not lanes.

---

## 8. Verification plan

Simulation, `sim/step06_.../tb_*.sv`, self-checking, one `=== TB PASS ===`
line, following step 05's structure. Cases the step specifically needs:

| Case | What it pins down |
|---|---|
| L=1 | Degenerates to step 05 exactly — same numbers, same output width |
| L=2 minimal (N=8, M=8) | The cache swap, with one write-side gather |
| L=3, `Mk` not a multiple of 8 | The gather's zero-padded tail — the likely bug |
| Negative pre-activation | ReLU actually zeroes it |
| Pre-activation over 32767 after shift | Saturates, does not wrap |
| `SHIFT` = 0 and a large `SHIFT` | Both extremes of the rescale |
| Final layer output | Unshifted 32-bit, ReLU *not* applied |
| Two networks back-to-back | State returns cleanly, caches re-roled |
| Weight packet ending mid-row | Flushed, not wedged, as in step 05 |

**Mutation tests to run, and which must be killed:** unsigned `prod2` (must
now die, unlike step 05); logical instead of arithmetic right shift; clamp
replaced by truncation; cache roles not swapped between layers.

**Golden model in Python**, shared by the testbench and the driver, so the
driver's reference and the RTL's reference cannot drift apart — the shift/
ReLU/saturate chain is exactly where a mismatch would otherwise hide.

**What only hardware can cover:** whether the fabric-resident path actually
saves the wall clock (§7), plus step 05's list — DMA arming order, cache
coherency on `S_AXI_HPC0_FPD`, `TLAST` arrival.

---

## 9. Block design

Expected to be **step 05's design unchanged**: same DMA, same 128-bit MM2S,
32-bit S2MM, `c_sg_length_width` = 26, same `S_AXI_HPC0_FPD`. Only the
packaged kernel is swapped — unless decision A adds an AXI4-Lite port, which
adds an interconnect path and a GUI session. That is the main reason
decision A is worth thinking about before the RTL rather than during it.

---

## 10. Open decisions

**A. How the kernel learns the layer count and per-layer `SHIFT`.**
The three candidates:

- *A header packet* — one beat (or one per layer) before the vector,
  carrying `L` and each layer's `SHIFT`. Keeps the zero-control-surface
  property and the block design untouched; costs a third packet type and
  makes the stream protocol stateful in a new way.
- *An AXI4-Lite register block* — `L`, and a small `SHIFT` array. Explicit,
  inspectable from Python, and the honest structure for a design that now
  has real configuration. Costs a GUI session and an interconnect path, and
  ends the "no control interface" streak that steps 04 and 05 kept.
- *`TUSER` / `TID` sidebands* — mark the last packet on the stream itself.
  Cheapest in RTL; requires the DMA to be configured to carry the sideband
  and PYNQ to set it per transfer, which is the least well-trodden path of
  the three.

Recommendation: **AXI4-Lite.** The configuration is genuinely per-invocation
control state, not data, and step 07 will want to change `SHIFT` per model
without re-streaming a header. Step 02 already proved the path.

**B. Fixed or per-layer `SHIFT`.** Per-layer is what real quantized models
need; a single global shift is one register instead of an array and is
enough to prove the mechanism. Suggest building per-layer from the start —
the array is cheap and retrofitting it means revisiting decision A.

**C. Where the final layer's output width is decided.** Emitting 32-bit
unshifted for the last layer only means the emit path has two modes. The
alternative — always emit int16 activations and let the PS handle the last
layer — is simpler in hardware but throws away precision exactly where the
model wants it (logits, argmax). Suggest the two-mode emit path.

**D. Whether `MAX_N` still covers it.** With activations recirculating, the
cache must hold the widest *intermediate* layer, not just the input. 4096 is
almost certainly still fine for an MLP; confirm against the step 07 model
before committing BRAM.

**E. Whether to build the Zynq VIP block-design simulation now.** Deferred
twice (step 04 §8). Chaining is the first design where a wiring or
DMA-behaviour bug would be hard to distinguish from a numeric bug on the
board. Still: build it on a *second* unexplained board failure, not the
first.
