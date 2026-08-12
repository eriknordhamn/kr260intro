# Background: Jupyter, JupyterLab, Notebooks, and PYNQ

Context for why the Kria-PYNQ installer sets up JupyterLab by default, even
though this project doesn't use it (see `board-setup.md` — we drive the
board with plain Python scripts instead). Understanding the design intent
explains a lot of PYNQ's architecture, including things like the venv
layout and overlay-loading model discussed in `STATUS.md`.

## Project Jupyter

Jupyter began as **IPython**, an enhanced interactive Python shell. Around
2014 its interactive-computing pieces were split out into a
language-agnostic project — "Jupyter" (a nod to **Ju**lia, **Pyt**hon,
**R**, the first three languages it supported) — because the same
notebook interface and protocol turned out to be useful far beyond Python.

The core architectural idea is a split between:

- **Frontend** — the browser UI you interact with (a notebook document, a
  file browser, a terminal, etc.)
- **Kernel** — a separate process that actually executes code, communicating
  with the frontend over a message protocol (originally ZeroMQ-based)

This split matters here: the kernel runs wherever it's launched — on the
Kria board, with full access to the board's hardware, filesystem, and
installed Python environment — while the frontend can be viewed from any
browser on the network. That's the whole mechanism behind
`http://kria:9090/lab`: your laptop's browser is just rendering UI: the
Python code (including `pynq.Overlay(...)` calls) executes on the board
itself.

## Notebook format (`.ipynb`)

A notebook document interleaves:
- **Code cells** — executed by the kernel, with output (text, tables,
  plots, images) captured and stored inline
- **Markdown cells** — prose, headings, explanations
- **Outputs** — persisted in the file, so a notebook is simultaneously
  a script, its results, and its documentation

This is well suited to *exploratory* hardware work: load an overlay, poke
a register, see the result immediately below the cell, adjust, rerun —
without restarting a program each time. It's also why PYNQ's example
notebooks double as tutorials: markdown explanation, code, and live output
(including images/plots from sensors or video overlays) all in one
document.

## Jupyter Notebook vs. JupyterLab

| | Jupyter Notebook (classic) | JupyterLab |
|---|---|---|
| Released | ~2011 (as part of IPython, later spun off) | ~2018 |
| Interface | One notebook document per browser tab | IDE-style: file browser, multiple notebooks/terminals/text editors in one window, panels, extensions |
| Relationship | Predecessor | Built on the same kernel/notebook-format foundation; effectively supersedes it (modern Notebook 7 is itself built from JupyterLab's components) |

Both talk to the same kernels and read/write the same `.ipynb` format —
JupyterLab is a richer frontend, not a different execution model. When the
Kria-PYNQ installer says "connect via JupyterLab," it's just pointing you
at the more capable of the two frontends; the underlying PYNQ/kernel
mechanics are identical either way.

## The thinking behind PYNQ

PYNQ — **Py**thon productivity for Zy**nq** — started at Xilinx Research
Labs (~2016) with a specific goal: let people productive in Python
experiment with FPGA-accelerated hardware without first learning Vivado,
HDL, or low-level register programming for every iteration.

The central abstraction is the **overlay**: treat a bitstream the way you'd
treat a software library.

- `.bit` — the compiled hardware (analogous to compiled machine code)
- `.hwh` — a hardware description Vivado exports from the block design
  (interfaces, IP blocks, register maps, addresses) — analogous to a header
  file / type manifest

When you call `Overlay("design.bit")`, PYNQ parses the `.hwh` and
**dynamically builds a Python object model** matching your specific
hardware — you get `ol.<ip_block_name>` attributes with register
read/write methods generated from the actual design, rather than hand
writing bindings for each new block design. This is the same reason MMIO
and DMA are wrapped as Python classes (`pynq.MMIO`, DMA buffer allocation
via `pynq.allocate()`) rather than exposing raw `/dev/mem` mmap or manual
descriptor chains — the goal is "swap in a new overlay and immediately have
a matching Python API," the way importing a new library gives you new
functions.

Jupyter was the natural frontend for this because the target audience
PYNQ was designed for — Python/data-science-oriented engineers, students,
researchers — already worked that way for exploratory computation, and
because notebooks let hardware experimentation, live output (plots, video
frames, sensor readings), and explanation live in the same document. It's
why PYNQ's own tutorials and reference designs are still mostly delivered
as notebooks, and why installers like `Kria-PYNQ` default to setting up
JupyterLab as *the* intended experience.

## Why this project doesn't use notebooks

CLAUDE.md's stated approach is a fully scripted, reproducible pipeline —
each milestone is a plain `.py` script driven from the CLI (`ssh` +
`python3 script.py`), matching the same "CLI/scripted over GUI" philosophy
applied to the Vivado side. Notebooks are excellent for open-ended
exploration but don't fit a project structured around discrete, testable,
version-controlled milestones the way a script does.

The underlying mechanism is identical either way — a notebook cell calling
`Overlay(...)` and `sw/step01_hello/load_overlay.py` calling `Overlay(...)`
are doing exactly the same thing. JupyterLab is simply the frontend PYNQ
was designed around, running alongside our scripts on the same board,
unused but available.
