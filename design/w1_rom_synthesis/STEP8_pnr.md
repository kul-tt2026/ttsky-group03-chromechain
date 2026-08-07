# Step 8 — post-P&R area (OpenLane): feasibility, projection, and how to get the real number

## Can it run in this environment? No.

A real place-and-route pass needs a P&R engine + physical views. Checked:

| Requirement | Status here |
|---|---|
| OpenROAD / OpenSTA | **absent** — oss-cad-suite ships only FPGA `nextpnr` |
| Docker / Podman (for TT/OpenLane container) | **absent** |
| Homebrew formula for OpenROAD/OpenLane | **none exists** |
| sky130 cell LEF + tech LEF | present (`pdk/sky130_fd_sc_hd_merged.lef`, 441 macros; `.tlef`) |

So the physical abstracts are on disk, but there is **no router to consume them**, and no
container runtime to run the TT/OpenLane flow natively on this macOS-arm64 box. Installing
OpenROAD natively on macOS-arm64 is unreliable (no prebuilt bottle; source build is heavy).

**What P&R would add that synthesis did not:** achievable placement utilization / routability,
and wire-load-inclusive timing. Neither can be produced without a router — there is no honest
*local* substitute, so the number below is labeled a **projection**, not a measurement.

## Projection (labeled estimate — not measured)

Measured synthesized cell area of the winning `w1_h32_case`: **2,718.9 µm² = 0.151 tiles**
(cell area / 17,954.72 µm² tile, 100% util). P&R inflates this by placement whitespace to a
target density plus filler/tap/decap; routing metal sits over the cells and adds negligible
footprint at this size.

| Target placement util | Projected die area | Tiles |
|---|--:|--:|
| 70% (TT planning bar) | 3,884 µm² | **0.216 t** |
| 60% (typical small-block achieved) | 4,531 µm² | **0.252 t** |
| 55% (conservative) | 4,943 µm² | **0.275 t** |

Equivalently the cookbook's +10–20% P&R margin on cell area gives ~0.17–0.18 t. **Every
scenario is a small fraction of one tile.** P&R cannot overturn the gate verdict: the W1 ROM
is ≤ ~0.28 t post-place under any realistic assumption, vs the 8-tile budget.

**What would convert this to a measurement:** one OpenLane run on the winning netlist (below).

## How to get the real number (two routes)

**Route A — block macro harden (measures this block directly).** On a machine with OpenLane 2
(`pip install openlane`, needs a container backend or nix) or classic OpenLane + sky130 PDK
(`volare enable`), run the winner as a macro:

```json
// config.json  (OpenLane 2, block-level hardening of the winning ROM)
{
  "DESIGN_NAME": "w1_h32_case",
  "VERILOG_FILES": ["dir::rtl/w1_h32_case.v"],
  "CLOCK_PORT": null,                     // purely combinational ROM
  "PL_TARGET_DENSITY_PCT": 60,
  "FP_SIZING": "absolute",
  "DIE_AREA": "0 0 90 60",                // µm; ~0.30 t, gives P&R headroom
  "PDK": "sky130A",
  "STD_CELL_LIBRARY": "sky130_fd_sc_hd"
}
```
Read the post-`grid_placement`/`global_routing` area and `openroad` STA report; compare to
the 0.216–0.275 t projection above.

**Route B — TT harden-trial (the cookbook's do-before-Aug-1 #2, measures the real chip).**
The authoritative TT tile/util/timing number comes from the Tiny Tapeout GitHub Actions
OpenLane flow. The meaningful harden-trial is **W1-ROM + datapath together** (not the ROM in
isolation — a 64-bit-wide output does not fit the 8-pin TT interface without serialization,
which would measure the mux, not the ROM). That is a full-design task beyond this block-level
experiment's scope; wire it when the datapath RTL lands (currently absent per the feature-freeze
notes). The winning `case` RTL here drops straight into that design.

**Bottom line:** the local verdict stands unchanged; the post-P&R figure is a ≤ 0.28-tile
refinement, and the real measurement is one OpenLane run away on a P&R-capable host.
