# Step 04 — Dot Product Kernel: state and next actions

Paused 2026-08-18 evening. Branch `step/04-dot-product`, which currently
points at the **same commit as `main`** (`579e774`) — no divergence in
either direction. Everything below except the uncommitted working-tree
changes listed under "Uncommitted" is already in that commit.

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

Vector length is implicit in `TLAST`, so the IP has no registers and no
AXI4-Lite interface at all.

## Status

| Piece | State |
|---|---|
| `rtl/step04_dot_product/dot_product.sv` | Committed, simulates clean |
| `sim/step04_dot_product/tb_dot_product.sv` | Committed, **all 10 checks pass** (re-run 2026-08-18) |
| `vivado/step04_dot_product/package_ip.tcl` | Committed, IP packages clean |
| `vivado/step04_dot_product/dot_product_accel_bd.tcl` | Committed **hand-edit — verified, see below** |
| `vivado/step04_dot_product/build.tcl` | Committed, **run successfully** |
| `build/step04_dot_product/dot_product_accel.bit` / `.hwh` | **Built** (gitignored) |
| `sw/step04_dot_product/dot_product_test.py` | Written, verified against a stub — **never run on hardware** |
| `sw/step04_dot_product/run_pynq.sh` | Copied in |
| `STATUS.md` step 04 section | Not written |

### Uncommitted working-tree changes

- `CLAUDE.md` — new SV coding convention (`logic` + `always_ff`/`always_comb`
  for internals, ports stay `wire`/`reg`); plus the export-verification rule
- `docs/xilinx-tools.md` — TKEEP gotcha added to block-design gotchas
- `docs/vivado-gui-session.md` — "confirm the export landed" step + checklist item
- `sw/step04_dot_product/` — both files, untracked
- `TODO_NEXT.md` — this rewrite

**Open question, unanswered:** commit the `CLAUDE.md`/docs changes on their
own, or fold them into the step 04 commit?

## The block-design surprise (read before touching the BD)

**The GUI export never landed.** `dot_product_accel_bd.tcl` is still the
hand-edited copy of step 03's export, mtime Aug 14 23:32, unchanged in git.
`build.tcl:47` sources that file — so the bitstream was built from the
hand-edit, not from the GUI session.

**It's fine, and that was checked rather than assumed.** Comparing the
scratch project's `dot_product_accel.bd` against the committed TCL:

- same 6 cells: `zynq_ultra_ps_e_0`, `axi_dma_0`, `dot_product_0`,
  `axi_smc`, `axi_smc_1`, `rst_ps8_0_99M`
- **all 8 interface nets identical**, including `M_AXIS_MM2S → s_axis`,
  `m_axis → S_AXIS_S2MM`, and `axi_smc_1/M00_AXI → S_AXI_HPC0_FPD`
- `c_include_sg = 0` in both

So the committed script is trustworthy and the design is reproducible from
source. **Decision: leave it alone.** Re-exporting would overwrite a
known-good, now-validated file with a functionally identical one.

Synthesis emitted one warning worth recognizing rather than chasing:
`[Synth 8-7071] port 'm_axis_mm2s_tkeep' ... is unconnected` — the kernel
has no TKEEP, the DMA's output has nowhere to go. Benign for a stream where
every beat carries all four bytes. Written up in `docs/xilinx-tools.md`.

## Next action: run it on the board

Nothing else can be verified from the dev machine.

```bash
scp build/step04_dot_product/dot_product_accel.{bit,hwh} \
    sw/step04_dot_product/{dot_product_test.py,run_pynq.sh} \
    <board>:~/step04/
# on the board:
./run_pynq.sh dot_product_test.py
```

Expected output ends with `Step 04 PASS`, preceded by per-length lines for
n = 1, 2, 8, 64, 1024 and three back-to-back packets.

The driver was verified off-board by stubbing PYNQ with a model of the RTL's
semantics and running the real script against it — all cases passed. That
validates the interleaving, the truncation masking, and the numpy/PYNQ API
usage. It validates **nothing** about DMA arming, cache coherency on HPC0, or
whether TLAST actually arrives.

### If it hangs

A hung `dma.recvchannel.wait()` means the S2MM never saw TLAST. Diagnose
from Python before rebuilding anything — read the DMA's S2MM status register
at offset `0x34` and check the IOC bit. A 20-minute rebuild is the expensive
way to learn something a register read will tell you.

If one debug pass doesn't explain it, *that's* the point where the Zynq
UltraScale+ VIP simulation earns its cost (see below) — not before.

## Remaining after the board run

1. Write the step 04 walkthrough into `STATUS.md`, matching the shape of the
   step 02 / step 03 sections, and move step 04 to COMPLETE. Include:
   - the BD-script-is-a-verified-hand-edit note above
   - the correction that step 03's notes say "enable HP0" while its exported
     design actually uses **HPC0**
2. Decide the commit split for the `CLAUDE.md`/docs changes.
3. Delete this file — per CLAUDE.md, anything durable in it moves to
   `STATUS.md`.
4. Merge `step/04-dot-product` → `main`. (Both refs are already identical, so
   this is bookkeeping rather than a real merge.)

## Deferred, deliberately

- **SystemVerilog short course.** The user asked for one aimed at a rusty
  VHDL background, then decided to hold it until all milestones are done —
  by step 07 there's a much larger body of their own RTL to teach from.
  Don't start it spontaneously.
- **Simulating the block design with the Zynq UltraScale+ VIP.**
  `set_property SELECTED_SIM_MODEL tlm [get_bd_cells /zynq_ultra_ps_e_0]`
  swaps the PS for a model exposing a SystemVerilog API on its AXI ports,
  backed by a DDR memory model, so the full PS→DMA→kernel→DMA→PS round trip
  runs in xsim. It catches wiring and DMA-behaviour bugs the unit TB can't,
  but sees nothing above the AXI layer — PYNQ buffers, cache coherency, and
  channel arming order stay invisible. Costs a project-based
  `launch_simulation` flow rather than the standalone `xvlog`/`xelab` one.
  Build it on the *second* board failure, not the first.
