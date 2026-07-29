# Chrome Chain — design reference

The trained weights the chip implements, and the measurements behind the ROM decision.
19 files. Everything here is either an input to the RTL or evidence for a number quoted in it.

Accuracy figures are **bit-exact integer simulation** on the full 10,000-image MNIST test set —
not silicon. Area figures are **post-synthesis cell area** (yosys + sky130), pre-place-and-route.

## The network

64 → 32 → 10, ternary weights `{-1, 0, +1}`, 4-bit inputs, 4-bit hidden activations.
Hidden requant is a per-unit arithmetic shift: `h = clip((a1 + bias) >> k, 0, 15)`.

## Weights — `ternary_tapeout/eightbit/`

| File | What |
|---|---|
| `stage3/FINAL4_s12_fold_a.npz` | **The weights the chip implements** (shift-only) — 92.56 % |
| `stage3/FINAL4_s12_fold_b.npz` | Fixed-point requant reference — 92.69 % |
| `LOCKED_RECIPE.json` | Training recipe + the hardware envelope below |
| `audit_final.json` | Preprocessing, integer-forward and tie-break audits |
| `TEST_LEDGER.jsonl` | Every read of the test set (one entry) |

Selection: 32 seeds ranked on a 3k validation split, top 4 re-ranked on a second disjoint 3k
split, test set touched once. Knowledge distillation was removed — it cost 1.47 pp on this
lineage (p = 9.5e-9 over 20 paired seeds).

## Hardware envelope

From `audit_final.json`. Worst case is over all legal inputs, not just the MNIST test set.

| Signal | Observed (MNIST) | Input worst case | Bits (signed) |
|---|---|---|---|
| `a1` — layer-1 accumulator | −130 … 95 | **±690** | **11** |
| `a2` — layer-2 accumulator | −92 … 84 | ±408 | 10 |
| `bias` | — | 29 | 6 |
| `k` — per-unit shift | 0 … 2 | — | 2 |

Layer 1 sums 64 terms of `pixel(0…15) × ±1`, so the bound for *any* ternary weight set is
±960 → 11 signed bits. Sizing to the observed range wraps silently on inputs outside the
MNIST distribution.

## W1 as ROM — `w1_rom_synthesis/`

Layer-1 weights synthesize as constant logic rather than a storage array:

| | Cells | Area | Tiles @100 % util |
|---|--:|--:|--:|
| `case` ROM (winner) | 493 | 2,718.9 µm² | 0.151 |
| DFF register-file equivalent | 7,498 | 155,555.4 µm² | 8.664 |

**57× smaller than the DFF equivalent.** Four coding styles were compared; `case`, `flat` and
`annot` tie exactly, hand-minimised boolean SOP is 6.8 % worse. Timing 7 logic levels / 1.61 ns
standalone. Sparsity is not a useful lever here — the whole block is 0.15 t, so the maximum
reclaimable area is under 0.2 t. Full verdict in `results.md`; P&R projection and the OpenLane
recipe in `STEP8_pnr.md`.

`rtl/w1_h32_case.v` is the winning ROM, verified bit-exact against the `.npz` on all 64
addresses (`verify/tb_w1_h32_case.v`). `rtl/w1_h16_case.v` is the 16-hidden fallback.
`rom_gen.py` regenerates either from a checkpoint.

## Reproducing

```bash
cd design/ternary_tapeout
python3.12 -m venv .venv && .venv/bin/python -m pip install torch numpy
.venv/bin/python ternary_tapeout.py all      # downloads MNIST, retrains, prints the table
```

Training is only reproducible with `torch.set_num_threads(1)` — multi-threaded CPU torch
varies by ±0.4 pp per seed.

Re-running synthesis needs yosys and the sky130 liberty
(`sky130_fd_sc_hd__tt_025C_1v80.lib`, from the sky130 PDK or oss-cad-suite); point `run_synth.py`
at your local copy. The measured results are already in `results.json` / `results.md`.

## Not in this repo

Kept locally to stay reviewable: the per-seed outputs of the 32-seed farm (~1,150 weight
snapshots), the training logs, the superseded H16/H32/H64 artifacts, the non-winning ROM
coding styles and sparsity sweep, and the raw yosys logs. The summary numbers those produced
are all quoted above and in `results.md`. Ask if you need the raw set.
