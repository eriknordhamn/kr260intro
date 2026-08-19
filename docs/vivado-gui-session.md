# Simulation and the once-per-milestone GUI session

Two procedures that recur at every milestone, written down once here so
they're not re-derived from an old step's Tcl each time.

Everything below assumes the toolchain is on PATH:

```bash
source /opt/Xilinx/2025.1/Vivado/settings64.sh
```

---

## Part 1: Simulation

The fast loop. Seconds per run against the ~20 minutes a bitstream costs, so
an RTL bug should be caught here, not on the board.

### Running a step's testbench

```bash
make sim_step04                      # or: bash sim/step04_dot_product/run_sim.sh
```

Each `sim/<step>/run_sim.sh` is three commands with no Vivado project
anywhere — this is deliberate, and worth preserving in new steps:

```bash
xvlog --sv rtl/<step>/<module>.sv sim/<step>/tb_<module>.sv   # compile
xelab tb_<module> -s tb_<module>_sim                          # elaborate
xsim tb_<module>_sim -R                                       # run to completion
```

`-R` means "run until `$finish` and exit", which is what makes it usable from
a Makefile. Scratch files land in `build/<step>/_sim/` (gitignored).

### Debugging with waveforms

Batch mode prints `$display` output and nothing else. To actually look at
signals, elaborate with debug info and launch the viewer:

```bash
cd build/<step>/_sim
xelab tb_<module> -s tb_dbg --debug typical
xsim tb_dbg -gui
```

Then add signals to the wave window and `run -all`. `--debug typical` is
required — without it the signals aren't probeable, and the failure looks
like an empty waveform rather than an error.

### What a testbench here should cover

The house style (see `sim/step02_axi_lite_echo/`, `sim/step04_dot_product/`)
is self-checking: the TB compares against an expected value it computes
itself, counts errors, and prints one final `=== TB PASS ===` or
`=== TB FAIL: N check(s) failed ===` line. Nothing requires a human to read a
waveform to know whether it passed.

Beyond the happy path, the cases that have actually mattered on this project:

- **Reset values**, before any transaction.
- **Back-to-back transactions** with no idle cycles between them — catches
  handshake state machines that only work with gaps.
- For streams, **irregular `TVALID` and randomized `TREADY` backpressure**.
  The AXI DMA does not present a beat every cycle and does not accept one
  every cycle; a TB that never stalls is testing a stream that doesn't exist.
- **Malformed input**, where the sensible response is usually to keep the
  data path moving. A kernel that wedges on a bad packet hangs the DMA
  channel with no error surfaced to the PS, which is expensive to diagnose
  from Python.
- A **safety timeout** (`initial #N; $display("timeout"); $finish;`) so a
  broken handshake fails the run instead of hanging CI or your terminal.

Note that `xvlog --sv` accepts more SystemVerilog than Vivado's IP packager
is comfortable with — packaging warns `19-5101` about SystemVerilog top
files. Keep module *ports and parameters* plain (no packed structs,
interfaces, or enums on the boundary) even where the internals use SV
niceties.

---

## Part 2: The GUI block-design session

Per `CLAUDE.md`, the GUI is a one-time scaffolding tool: it's needed once per
milestone **that introduces new IP into the block design**, and its output is
an exported Tcl script that gets committed. Routine RTL edits inside an
already-packaged module never need it — repackage and rebuild headlessly.

### Before opening the GUI

If the step has custom RTL, package it first. The block-design canvas places
IP-XACT components, not raw source files, so an unpackaged module simply
won't appear:

```bash
make package_step04      # -> build/step04_dot_product/ip_repo/component.xml
```

Then create the scratch project. This is a throwaway project whose only jobs
are to carry the right part/board and to register `ip_repo/` in the IP
catalog so your module shows up next to Xilinx's:

```bash
make bd_step04           # runs create_bd_scratch_project.tcl
vivado build/step04_dot_product/_vivado_project/dot_product_bd.xpr
```

The project directory is gitignored and disposable — the exported Tcl is the
artifact, not the `.xpr`.

### In the GUI

1. **Create Block Design.** The name must match `design_name` in that step's
   `build.tcl`; the build globs for `<design_name>.bd` and its `.hwh`.
2. **Add the Zynq UltraScale+ MPSoC block**, then **Run Block Automation** to
   apply the KR260 board preset. Skipping the preset leaves DDR and MIO
   unconfigured and the design will not work on the board.
3. **Enable the PS ports this design needs**, by re-customizing the PS block:
   - AXI-Lite control from the PS → a master port (`AXI HPM0 FPD`), which the
     board preset already enables.
   - Bulk DDR access from a PL master such as an AXI DMA → a **slave** port
     (`AXI HP*` / `AXI HPC*`), under PS-PL Configuration → PS-PL Interfaces →
     Slave Interface → AXI HP. **These are off by default.** This is the
     single most expensive trap in this flow: with no slave port enabled,
     Connection Automation silently offers nothing for the DMA's
     `M_AXI_MM2S`/`M_AXI_S2MM`, and `validate_bd_design` does not flag it. See
     `docs/xilinx-tools.md` → Block design gotchas.
   - Disable master ports you don't use — an enabled-but-unwired AXI master
     *does* fail validation.
4. **Add and configure the stock Xilinx IP.** For the AXI DMA on this
   project: uncheck Scatter Gather (Direct Register mode, which is what
   PYNQ's simple `sendchannel`/`recvchannel` API drives), keep the channels
   you need, and set the stream width to match your kernel.
5. **Add your packaged IP** from the catalog — it appears under the taxonomy
   `package_ip.tcl` gave it (`/UserIP`) with your vendor string.
6. **Hand-wire the point-to-point stream connections.** Connection Automation
   handles memory-mapped AXI, where there's an address map to reason about.
   It will not guess which AXI4-Stream master should feed which stream slave;
   drag those yourself.
7. **Run Connection Automation, then run it again**, until it offers nothing
   new. Running it once per interface in separate passes has left DMA clock
   inputs unconnected before.
8. **Check every cell's clock and reset actually landed** — particularly on
   custom IP, where a missing `ASSOCIATED_BUSIF` in the packaged component
   can leave automation with nothing to offer.
9. **Validate Design.** Expect it to catch unconnected pins; do not expect it
   to catch a missing PS port (see 3).
10. **Export the block design as Tcl — from the Tcl Console, not the menu.**

    ```tcl
    write_bd_tcl -force /abs/path/to/vivado/<step>/<design_name>_bd.tcl
    ```

    This is the same call *File → Export → Export Block Design as TCL*
    makes, with the destination stated explicitly. The dialog defaults to
    the **project directory** and names the file after the block design, so
    it happily writes `build/<step>/_vivado_project/<bd_name>.tcl` while you
    believe you exported into the repo. That has now happened on two
    separate milestones (steps 04 and 05); the console form either writes
    the path you named or raises a visible error. Commit the script; never
    the project directory.

### After the GUI

**First confirm the export actually landed.** The export dialog can write
somewhere other than where you meant, or not happen at all if the session
ran long and the last step got skipped:

```bash
git status --short vivado/<step>/
```

The BD script should show as modified. This check matters more than it
looks: `build.tcl` sources the *committed* Tcl, never your GUI project. If
the export silently didn't land, the next `make step<NN>` builds the old
script and **succeeds**, handing you a bitstream that has nothing to do with
the session you just spent an hour on — with no error anywhere to suggest it.

Step 04 hit exactly this. It was caught afterwards by comparing the scratch
project's live design against the committed script:

```bash
python3 -c "
import json
bd=json.load(open('build/<step>/_vivado_project/<proj>.srcs/sources_1/bd/<name>/<name>.bd'))['design']
print(sorted(bd['components']))
for k,v in sorted(bd.get('interface_nets',{}).items()):
    print(k, '->', v['interface_ports'])
"
grep -oE "connect_bd_intf_net -intf_net [A-Za-z0-9_]+ .*" vivado/<step>/<name>_bd.tcl
```

Matching cell lists and matching interface nets mean the two designs agree
and the committed script is trustworthy regardless of its provenance. That's
worth knowing either way — it's the same comparison that tells you whether a
hand-edit still reflects reality.

Then confirm the export replays headlessly before spending a full build on it. A
`validate`-only mode in `build.tcl` (see step 04's) sources the exported BD,
validates, and stops — about a minute instead of twenty:

```bash
make validate_step04
make step04              # full bitstream once validation is clean
```

This matters because an exported script can reference IP that only resolves
in the project it came from. If `validate` passes from a clean project, the
design is genuinely reproducible from source.

### Renaming a block design

Vivado offers no way to rename a block design in the GUI. The exported
script parameterizes it, though — near the top, under a generated comment
that reads `# CHANGE DESIGN NAME HERE`:

```tcl
set design_name <name>
```

Editing that one line is the intended mechanism and is the cheapest fix when
the BD ended up named differently from `build.tcl`'s `design_name`. Watch
that the old name is not also a cell or IP name before reaching for a global
substitution — in step 05 the design, the IP, and the cell were all called
some form of `linear_layer`, so only the one line could safely change.
Validate headlessly afterwards.

### Hand-editing an exported script

The exported Tcl is generated code and is committed close to verbatim, but
it's ordinary Tcl and small deltas are legible — inserting one cell and
rewiring a net is a handful of lines against step 03's export. That's a
reasonable way to *prototype* a change, provided it's validated headlessly
before being believed.

What it is not is a substitute for re-exporting. Once a design has been
hand-edited and then also touched in the GUI, the two diverge silently. If a
GUI session happens, let the export overwrite the file wholesale rather than
merging by hand.

### Checklist

- [ ] Custom IP packaged (`make package_step<NN>`)
- [ ] Scratch project created with `ip_repo/` registered
- [ ] BD named to match `build.tcl`'s `design_name`
- [ ] Board preset applied via Block Automation
- [ ] PS slave HP port enabled if any PL master touches DDR
- [ ] Unused PS master ports disabled
- [ ] Stream connections wired by hand
- [ ] Connection Automation run until exhausted
- [ ] Clocks and resets present on every cell
- [ ] Validate Design clean
- [ ] Exported with `write_bd_tcl -force <abs path>` from the Tcl Console
- [ ] `git status` confirms that file actually changed
- [ ] `make validate_step<NN>` passes from a clean project
