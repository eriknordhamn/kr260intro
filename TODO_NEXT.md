# Step 06 — Activation + Chaining — where work stopped

Session of 2026-08-20. Branch: `step/06-activation-chaining`, one commit
(`be85c8a`), clean tree. `main` is pushed and current at `4721617`.

## Done and committed

- `spec/step04_dot_product.md` — backfill, **on `main` and pushed**. Closes
  the item carried over from step 05.
- `spec/step06_activation_chaining.md` — draft spec, on this branch only.
  §1–3 settled, §4–6 proposed, §10 open decisions.
- `STATUS.md` — corrected the ~0.55 ms attribution (it is six PYNQ calls at
  ~90 µs each, measured *after* `allocate()`, so buffer reuse cannot amortise
  it) and added spec pointers.

## Not started

Everything else. No RTL, no testbench, no TCL, no driver for step 06.

## Next commands

Nothing to run — the next move is a decision, not a build.

**Blocking: §10 decision A** — how the kernel learns the layer count `L` and
the per-layer `SHIFT`. Header packet / AXI4-Lite / `TUSER`. The draft
recommends AXI4-Lite, which ends the no-control-interface property steps 04
and 05 kept and costs a GUI session for the interconnect path. Decide before
writing RTL; it changes both the block design and the packet protocol.

Also worth closing at the same time: B (per-layer vs global `SHIFT`),
C (two-mode emit path for the final layer), D (`MAX_N` vs the widest
intermediate layer).

**Non-blocking, and cheap** — the two board measurements in §1, which can run
against the *existing* step 05 bitstream:

```bash
# on the KR260, in the step 05 deploy dir
./run_pynq.sh linear_layer_test.py     # after adding per-call timing
```

1. Time each of the six PYNQ calls separately — if `wait()` dominates it is
   polled completion, which chaining removes wholesale.
2. Time two back-to-back `transfer()` calls with no intervening `wait()`, to
   see whether PYNQ pipelines them at all.

These decide how much of the projected ~3× the chaining can actually claim.
Run them before the RTL, so the win is attributed to the right change.

## Open thread from this session

Step 04's spec §10 forward-references `spec/step06_activation_chaining.md`,
which does not exist on `main` until this branch merges. Intentional; soften
it if the branch is going to sit for a while.

Unrelated aside worth acting on eventually: the step 05 BRAM cache reads one
word per beat during `COMPUTE` and nothing during `LOAD_X`. If `EN` is tied
high it pays full read energy through the whole load phase. `report_power`
per-instance would confirm; gating `EN` is the cheapest dynamic-power lever
in the design.
