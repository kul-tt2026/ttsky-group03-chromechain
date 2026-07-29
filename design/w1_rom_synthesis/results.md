# Chrome Chain v1 — W1-as-ROM synthesis trial — RESULTS

**Date:** 2026-07-24 · **Gate on:** 32h-vs-16h architecture lock (Aug 1)
**Method:** all numbers **measured**. Yosys 0.67+86 (oss-cad-suite darwin-arm64), flow
`read_verilog; synth -flatten; dfflibmap -liberty; abc -liberty; opt_clean; stat -liberty`,
mapped to `sky130_fd_sc_hd__tt_025C_1v80`. Real trained weights
`ternary_tapeout/artifacts/H{32,16}_fold_a_shift.npz`. Every combinational style
**functionally verified bit-exact against the npz** (iverilog, 64/64 addresses).
Tile denominator: TT `tt-support-tools/tile_sizes.yaml` 1×1 = 161.00 × 111.52 µm =
**17,954.72 µm²**. Raw logs in `raw/` and `raw_sparsity/`.

> **Independently re-verified** (2026-07-24, 4 adversarial agents reproducing from scratch,
> all CONFIRMED): ROM area **2718.8576 µm²** and DFF baseline **155,555.44 µm² / 4096 flops**
> reproduced to the decimal (ratio 57.21×); all four styles **64/64** vs npz; controls
> re-synthesized independently and the `rand0` `n=~p` degeneracy proven in code; test accuracy
> re-derived from raw IDX (own reader/pooling/integer forward) = **87.15 / 90.84 / 92.97%**,
> with the cache confirmed bit-identical to from-raw preprocessing (no leakage).

---

## VERDICT

**1. Does 32h W1-as-ROM fit?** Yes — overwhelmingly.
32h W1 = **493 cells, 2,718.9 µm² = 0.151 tiles** (100% util) / **0.216 tiles @ 70%**.
It is a *measured array* (no soft-logic tax); at the 0.85-taxed planning util still ≈ 0.18 t.
In full-chip context (prior measured datapath ≈ 3.9 t + W2/θ ROM + calibration latch,
`cc_32h_area_cookbook.md`) the whole 32h design lands **~5.1–5.3 tiles — fits a 4×2 die with
~2.7 t slack.** The supposed blocker is **1/50th of the die.**

**2. Which coding style won?**
`case`, `flat` (packed-vector bit-slice) and `annot` (`full_case,parallel_case`) **tie exactly**
(493 cells / 2,718.9 µm² / 7 levels / 1.61 ns) — ABC re-derives the same optimum. Hand-minimized
`bool` (per-bit Quine-McCluskey SOP) is **6.8% worse** (531 cells): pre-decomposing starves ABC
of AOI/OAI packing (138 compound cells vs 225 for `case`). **Winner: `case`. Do not pre-minimize.**

**3. What sparsity buys (measured, Step 4).**
Worthless as an area lever here. Full 7-point curve below. To save even **0.1 tile** you sacrifice
**~4–8 accuracy points**, and the *entire* W1 block is only **0.23 t** — the maximum you could
ever reclaim (pruning to 94.5% zeros) is **0.18 t at the cost of ~20 pp**. Best-case exchange
(40→51% zeros) is ~24 pp lost per whole tile, and you can't even free one whole tile. **W1 area
is not the constraint; do not trade accuracy for it.**

**4. Timing — one pipeline register or two?** One suffices.
Standalone ROM = **7 logic levels, 1.61 ns** (H32; H16 = 6 levels, 1.10 ns), liberty-based, pre-P&R.
The ROM contributes ~1.6 ns + 1 gate ahead of the ~12-level accumulator; at any realistic TT clock
(≥10 ns) the single register after the priority encoder is comfortable. A second register between
ROM and the MAC array is **not needed for timing**. Confirm on the full path with STA/OpenLane
(wire load not modelled here).

**5. 16h vs 32h accuracy — keep 32h.**
Measured (full 10k test): H16 = 87.15% / H32 = **90.84%** shift-only (**+3.69 pp**); 87.98% / 91.63%
fixed. The Step-0 "kill 32h if equal" condition does **not** fire. Naming checked: checkpoints index
**hidden units** (W1 32×64 / 16×64), not training-hours.

---

## Step 3 — coding-style sweep + controls (32h, real W1 = 64×32 ternary, ROM out = 64 bits)

| Variant | Cells | Area µm² | Tiles@100% | Tiles@70% | Levels | Delay ns | Note |
|---|--:|--:|--:|--:|--:|--:|---|
| **`case` (real)** ⭐ | **493** | **2,718.9** | **0.151** | **0.216** | 7 | 1.61 | winner |
| `flat` (real) | 493 | 2,718.9 | 0.151 | 0.216 | 7 | 1.61 | ties case |
| `annot` (real) | 493 | 2,718.9 | 0.151 | 0.216 | 7 | 1.61 | ties case |
| `bool` (real, QM-SOP) | 531 | 2,904.0 | 0.162 | 0.231 | 6 | 1.61 | +6.8% |
| **DFF baseline** | 7,498 | 155,555.4 | 8.664 | 12.377 | 9 | 29.97 | 4,096 flops (edfxtp_1) + rd-mux |
| _ctrl_ randmatch (random, ~40% z) | 572 | 3,180.6 | 0.177 | 0.253 | 7 | 2.08 | structure test |
| _ctrl_ rand0 (0% zeros) | 392 | 2,346.0 | 0.131 | 0.187 | 8 | 1.55 | degenerate (below) |
| _ctrl_ allzero (floor) | 0 | 0.0 | 0.000 | 0.000 | — | — | flow sanity ✓ |

16h (fallback): `case` = 278 cells / 1,503.9 µm² / 0.120 t@70% / 6 lev / 1.10 ns; DFF baseline
3,741 cells / 77,997 µm² / 6.21 t@70%.

**Headline ratio:** the 32h W1 ROM is **57.2× smaller than its DFF equivalent** (2,718.9 vs
155,555.4 µm²) and **45× smaller than the flops alone** (4,096 flops = 122,998 µm²).

### Controls read carefully (where the hypothesis is tested)
- **Real (2,718.9) < random-at-matched-sparsity (3,180.6): 14.5% smaller.** Trained weights carry
  **structure beyond sparsity** that synthesis exploits — not a pure-sparsity artifact. (Verifier
  nuance: the random draw realized 40.0% zeros vs the real 40.6%, so it is actually *slightly less*
  sparse than real — the 0.6 pp gap cannot explain 14.5% area; and the real W1 is strongly
  sign-imbalanced, 432 `+1` vs 784 `−1`, which is part of the exploitable structure.)
- **Measured zero fraction = 40.6%, not the 50–70% the brief assumed.** The win comes mostly from
  combinational density (one column of ternary logic ≪ one storage element/bit), not zero-folding.
- **`rand0` (0% zeros) is NOT a valid pessimistic bound under `{p,n}`.** With no zeros, `n = ~p` for
  every weight (proven: `n == 1−p` for all 2,048 weights) → only 32 independent functions → it comes
  out *smaller* than real. The honest content-dependent **upper** bound is randmatch (3,180.6 µm² =
  0.18 t), which still fits trivially.
- **allzero → 0 cells** — the flow collapses constant outputs, confirming it measures real logic.

Cell mix (winner `case`): 225 AOI/OAI compound + 251 discrete + 17 other — dense constant-folded
logic, no memory primitives. Consistent with the prior 22-Jul run (3,110 µm²); this fresh sweep is
~13% lower, same verdict.

---

## Step 4 — sparsity exchange rate (H=32, locked QAT recipe, best-of-3 seeds, 10k test)

Sparsity set by the ternarization threshold `thr` (a per-row magnitude prune); each level retrained
with the full recipe (200+100 epochs, KD 0.3/T4), then its W1 synthesized as a `case` ROM.

| Zero % | thr | Test shift | Test fixed | Cells | Area µm² | Tiles@70% |
|--:|--:|--:|--:|--:|--:|--:|
| **40.4** | 1.00 | **91.00%** | 91.84% | 484 | 2,867.8 | 0.228 |
| 47.4 | 1.40 | 90.14% | 91.10% | 445 | 2,653.8 | 0.211 |
| **51.1** | 1.55 | 90.22% | 91.21% | 414 | 2,467.4 | 0.196 |
| **60.9** | 1.90 | 89.28% | 90.67% | 395 | 2,113.3 | 0.168 |
| **72.8** | 2.50 | 86.46% | 87.96% | 313 | 1,672.9 | 0.133 |
| **80.6** | 2.85 | 82.63% | 83.08% | 241 | 1,382.6 | 0.110 |
| 94.5 | 3.50 | 71.24% | 67.90% | 98 | 553.0 | 0.044 |

(40.4% is the shipped anchor — reproduces the 90.84% baseline within seed noise. Bold rows ≈ the
brief's requested 40/50/60/70/80 % targets; 47.4% and 94.5% are extra points bracketing the curve.)

**Exchange rate vs the 40% anchor (accuracy pp lost per tile freed @70% util):**

| 40% → | tiles freed | accuracy lost | rate |
|---|--:|--:|--:|
| 51% | 0.032 t | 0.78 pp | 24 pp/t |
| 61% | 0.060 t | 1.72 pp | 29 pp/t |
| 73% | 0.095 t | 4.54 pp | 48 pp/t |
| 81% | 0.118 t | 8.37 pp | 71 pp/t |
| 95% | 0.184 t | 19.76 pp | 107 pp/t |

The curve is convex-punishing: accuracy holds to ~60% zeros (−1.7 pp) then falls off a cliff past
70%. But because the whole block is only 0.23 t, **the maximum reclaimable area is <0.2 t** — a
rounding error against the 8-tile budget — so even the flat region isn't worth 1.7 pp. **Sparsity
is the wrong lever for W1; spend the accuracy budget elsewhere.**

---

## Step 5 — timing
ROM standalone: **1.61 ns / 7 logic levels** (H32), 1.10 ns / 6 levels (H16). Liberty-based,
pre-P&R (no wire load). Path plan `priority-enc → [reg] → ROM → gating-AND → accumulator → DFF`:
the ROM is small relative to the 12-level accumulator ⇒ **one pipeline register is sufficient**;
no second (prefetch) register needed for timing.

## Step 8 — post-P&R area
Cannot run in this environment (no Docker, no OpenROAD/OpenSTA, no Homebrew formula; oss-cad-suite
ships only FPGA `nextpnr`). P&R's only new information — routability/achievable-util and wire delay —
needs a router, so there is no honest local substitute. **Projection** from measured cell area:
post-place **0.22 t @70% util → 0.28 t @55%** — still ≪ 1 tile, so P&R cannot overturn the verdict.
Feasibility, the labeled projection, and the exact run recipe (OpenLane block-macro `config.json`;
TT GHA harden-trial for the real number) are in **`STEP8_pnr.md`**.

---

## Status against the brief
| Step | State |
|---|---|
| 0 naming + 16h/32h accuracy | ✅ done — keep 32h (independently verified) |
| 1 weights + zero fraction | ✅ 40.6% H32 / 40.8% H16 |
| 2 `rom_gen.py`, 4 styles + controls | ✅ all iverilog-verified vs npz |
| 3 synth sweep + controls + tile denom | ✅ done (independently reproduced to the decimal) |
| 4 sparsity exchange (7 points) | ✅ done — sparsity is not a useful W1 lever |
| 5 timing (ns + levels) | ✅ 1.61 ns / 7 lev → one register |
| 8 OpenLane post-P&R | ⚠ can't run locally — projection + run recipe in `STEP8_pnr.md` |

**Aug-1 gate: answered and independently verified.** 32h W1-as-ROM fits with room to spare, one
pipeline register is enough, 32h is accuracy-justified over 16h, and sparsity buys nothing for W1.

## Deliverables
`rom_gen.py` (ckpt → 4 styles + 4 controls, deterministic) · `sparsity_sweep.py` (Step 4) ·
`run_synth.py` + `synth/*.ys` (Yosys flow) · `rtl/*.v`, `rtl_sparsity/*.v` (generated Verilog) ·
`verify/*` (iverilog equivalence TBs, all PASS) · `raw/*`, `raw_sparsity/*` (unedited stat + timing
logs) · `results.json`, `sparsity_results_all.json` (machine-readable) · `STEP8_pnr.md` ·
`lib/` (self-contained sky130 liberty) · `TOOLCHAIN.txt`.
