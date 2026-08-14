# Step 04 — Dot Product Kernel: state and next actions

Paused mid-milestone on 2026-08-14. Branch `step/04-dot-product`, **nothing
committed** — all of the below is uncommitted working-tree state.

## What step 04 is

First real compute in the PL. A streaming dot-product kernel sits in the
stream path step 03 proved out: where step 03 looped the DMA's `M_AXIS_MM2S`
straight back into its own `S_AXIS_S2MM`, the kernel now sits between them.

Both operand vectors arrive interleaved on the single MM2S stream:

```
beat:  0   1   2   3        2N-2   2N-1
data:  a0  b0  a1  b1  ...  a[N-1] b[N-1](TLAST)
                 |
                 v
out:   sum(TLAST)      one beat, S2MM writes 4 bytes back to DDR
```

Chosen over a second DMA channel or AXI-Lite-loaded weights because it reuses
step 03's block design almost verbatim and needs no control interface at all
— vector length is implicit in `TLAST`, so the IP has no registers.

## Status

| Piece | State |
|---|---|
| `rtl/step04_dot_product/dot_product.sv` | Written, simulates clean |
| `sim/step04_dot_product/tb_dot_product.sv` | Written, **all 10 checks pass** |
| `sim/step04_dot_product/run_sim.sh` | Working (`make sim_step04`) |
| `vivado/step04_dot_product/package_ip.tcl` | Working, IP packages clean |
| `vivado/step04_dot_product/create_bd_scratch_project.tcl` | Written, not yet run |
| `vivado/step04_dot_product/dot_product_accel_bd.tcl` | **Provisional placeholder — see below** |
| `vivado/step04_dot_product/build.tcl` | Written, never run |
| `sw/step04_dot_product/` | **Not started** |
| `Makefile` targets | Added: `sim_step04`, `package_step04`, `bd_step04`, `validate_step04`, `step04` |
| `STATUS.md` step 04 section | Not written |

Packaged IP (regenerate any time with `make package_step04`):
`build/step04_dot_product/ip_repo/component.xml`, VLNV
**`kr260intro.local:user:dot_product:1.0`**, interface pins `s_axis` /
`m_axis` / `aclk` / `aresetn` (lowercase), both streams associated to `aclk`.

Last simulation run:

```
PASS single pair / 8 pairs dense / 16 pairs with gaps
PASS 32 pairs backpressured result
PASS back-to-back packets 1,2,3
PASS 1024 pairs
PASS odd beat count: dangling element discarded
PASS recovery after malformed packet
=== TB PASS: all checks passed ===
```

## Review pass (do this first)

Re-run the sim to see it live — seconds, no board, no project:

```bash
source /opt/Xilinx/2025.1/Vivado/settings64.sh
make sim_step04
```

Read in this order:

1. **`rtl/step04_dot_product/dot_product.sv`** (115 lines). AXI4-Stream is a
   much smaller protocol than step 02's AXI4-Lite: `TDATA`/`TVALID`/`TREADY`
   plus `TLAST` for end-of-packet, one handshake rule — a beat transfers on
   the cycle both `TVALID` and `TREADY` are high, and `TVALID` must never
   wait on `TREADY`.
2. **`sim/step04_dot_product/tb_dot_product.sv`** (248 lines). Same
   self-checking shape as step 02's TB, plus randomized backpressure and
   idle gaps, because the DMA will not present a beat every cycle.
3. **`vivado/step04_dot_product/package_ip.tcl`** — a near-copy of step 02's;
   the one real addition is the explicit clock association, see below.

### Four decisions worth a second opinion

- **`s_axis_tready = !m_axis_tvalid`** (RTL). Input stalls while a result
  waits to be drained. Deliberately *not* a function of `m_axis_tready`,
  which would create a combinational path from the downstream `TREADY` into
  the upstream one. Costs one cycle per packet, nothing in steady state.
- **Truncated output.** Products accumulate into a 64-bit register but the
  output beat carries only the low 32 bits, i.e. the true sum mod 2^32. The
  driver should mask the reference sum the same way, rather than the test
  quietly depending on small operands.
- **Malformed packets flush rather than hang.** If `TLAST` lands on an even
  beat the dangling `a` has no `b`; it's discarded and the accumulator is
  emitted anyway. Rationale: a stalled kernel wedges the DMA channel with no
  error visible to the PS — exactly the failure that costs a rebuild cycle to
  diagnose. Alternative would be signalling the error somehow, but there's no
  control interface to signal it on.
- **Explicit clock association in `package_ip.tcl`.** Vivado's inference
  associates only the *master* stream with `aclk` (watch for the `19-4728`
  message naming just `m_axis`). Left alone, IP Integrator wouldn't know
  `aclk` clocks the slave stream. Also note the interface names must be given
  in lowercase — `associate_bus_interfaces` appends whatever string it's
  handed, so `S_AXIS` produced a junk list `m_axis:s_axis:S_AXIS:M_AXIS`.

## Next action: the block design, in the GUI

`dot_product_accel_bd.tcl` currently holds a **hand-edited copy of step 03's
export** — step 03's design with the kernel spliced in. Vivado has never
parsed it. It's there as a reference for what the finished design should
contain; the GUI export should **overwrite it wholesale**, not be merged into
it.

The general procedure — plus the simulation loop, waveform debugging, and a
checklist — is in `docs/vivado-gui-session.md`. What follows is the
step-04-specific version of it.

Create the scratch project (registers the packaged IP in the catalog):

```bash
make bd_step04       # packages the IP, then creates the project
vivado build/step04_dot_product/_vivado_project/dot_product_bd.xpr
```

In the GUI:

1. Create Block Design, **name it `dot_product_accel`** — `build.tcl`
   expects that name.
2. Add **Zynq UltraScale+ MPSoC**, then Run Block Automation to apply the
   KR260 board preset.
3. **Re-customize the PS → PS-PL Configuration → PS-PL Interfaces → Slave
   Interface → AXI HP → enable a slave port.** Step 03 ended up on
   `S_AXI_HPC0_FPD`. This is off by default and is the step-03 trap worth
   remembering: with no slave port enabled, Connection Automation silently
   offers nothing for the DMA's `M_AXI_MM2S`/`M_AXI_S2MM` and validation does
   *not* flag it. (`STATUS.md`'s step-03 notes say "enable HP0" but the
   exported design actually uses HPC0 — worth correcting there while you're
   in the area.)
4. Add **AXI Direct Memory Access**. Re-customize: **uncheck Scatter Gather**
   (Direct Register mode, as step 03), keep both Read and Write channels,
   stream width 32 bits to match the kernel.
5. Add **dot_product** from the catalog (under `/UserIP`, vendor
   `kr260intro.local`).
6. Wire the stream by hand — Connection Automation won't guess this:
   - `axi_dma_0/M_AXIS_MM2S` → `dot_product_0/s_axis`
   - `dot_product_0/m_axis` → `axi_dma_0/S_AXIS_S2MM`
7. Run **Connection Automation**, and keep re-running it until it stops
   offering anything new — the other step-03 trap was running it in separate
   passes for `S_AXI_LITE` and `M_AXI`, which left DMA clock inputs
   unconnected.
8. Check `dot_product_0/aclk` and `aresetn` actually landed on the PS clock
   and the `proc_sys_reset` output. Validate Design.
9. **File → Export Block Design as TCL** → overwrite
   `vivado/step04_dot_product/dot_product_accel_bd.tcl`.

Then confirm the export replays headlessly before spending a full build:

```bash
make validate_step04     # sources the exported BD, validates, stops. ~1 min
make step04              # full bitstream, ~20 min
```

Both gotchas above are already recorded in `docs/xilinx-tools.md`'s
block-design gotchas section.

## Remaining after the block design

1. **`sw/step04_dot_product/dot_product_test.py`** — not written. Shape:
   allocate a `pynq.allocate()` send buffer of `2N` int32 with the two
   vectors interleaved, and a **1-word** receive buffer; arm
   `dma.recvchannel.transfer()` *before* `dma.sendchannel.transfer()` (same
   ordering step 03 needed); wait on both; compare against
   `np.dot(a, b) & 0xFFFFFFFF`. Test a few vector lengths, include negative
   values to exercise the signed multiply, and print `Step 04 PASS`.
2. Copy `sw/run_pynq.sh` alongside it, per the CLAUDE.md board-side
   convention — never a bare `sudo python3`.
3. Deploy `.bit` + `.hwh` to the board, run, capture output.
4. Write the step 04 walkthrough into `STATUS.md`, matching the shape of the
   step 02 / step 03 sections, and move step 04 to COMPLETE.
5. Commit and merge `step/04-dot-product` → `main`.

## Optional side quest, raised while working

Whether a block design containing the PS and DMA can be simulated: yes, via
the **Zynq UltraScale+ VIP** — `set_property SELECTED_SIM_MODEL tlm
[get_bd_cells /zynq_ultra_ps_e_0]` swaps the PS for a model that exposes a
SystemVerilog API on its AXI ports and backs the HP slave ports with a DDR
memory model, so the full PS→DMA→kernel→DMA→PS round trip runs in xsim.

Costs: it's a project-based flow (BD output products, then
`launch_simulation`), not the standalone `xvlog`/`xelab` flow `sim/` uses; no
ARM cores execute, so the TB pokes the DMA's registers by hand rather than
calling PYNQ; and it's slow. Worth it mainly to catch a missing `TLAST` that
would otherwise hang `dma.recvchannel.wait()` on the board and cost a
20-minute rebuild to diagnose. Deferred — the unit TB covers the same
protocol bugs far faster.
