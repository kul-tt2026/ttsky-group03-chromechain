#!/usr/bin/env python3
"""
run_synth.py -- Step 3/5 synthesis sweep for the W1-ROM trial.

For each generated module: run Yosys standalone, map to sky130_fd_sc_hd tt_025C_1v80,
capture raw `stat -liberty` (cell count, area, cell mix) and the ABC delay estimate.
Writes one .ys and one raw log per module, and a results.json summary.

Flow matches the prior cookbook for comparability:
  read_verilog; hierarchy -top; synth -flatten; dfflibmap -liberty; abc -liberty;
  opt_clean; stat -liberty
"""
import os, re, json, subprocess, sys

WORK = os.path.dirname(os.path.abspath(__file__))
YOSYS = "/private/tmp/claude-501/-Users-florispenninckx-Documents-LALZ/6852375a-0595-468d-b39a-e93d3c83a061/scratchpad/area32h/synth/oss-cad-suite/bin/yosys"
LIB = os.path.join(WORK, "lib", "sky130_fd_sc_hd__tt_025C_1v80.lib")
RTL = os.path.join(WORK, "rtl")
SYN = os.path.join(WORK, "synth")
RAW = os.path.join(WORK, "raw")
TILE_UM2 = 161.00 * 111.52   # TT tt-support-tools tile_sizes.yaml, 1x1 tile = 17954.72 um^2

os.makedirs(SYN, exist_ok=True); os.makedirs(RAW, exist_ok=True)

def area_script(mod):
    # cookbook-comparable area flow. paths quoted (workspace path has a space).
    return f"""read_verilog "{RTL}/{mod}.v"
hierarchy -top {mod}
synth -top {mod} -flatten
dfflibmap -liberty "{LIB}"
abc -liberty "{LIB}"
opt_clean
tee -o "{RAW}/{mod}.stat" stat -liberty "{LIB}"
"""

def timing_script(mod):
    # separate stime pass -> Delay (ps) + logic levels (lev), does not disturb area run
    return f"""read_verilog "{RTL}/{mod}.v"
hierarchy -top {mod}
synth -top {mod} -flatten
dfflibmap -liberty "{LIB}"
abc -liberty "{LIB}" -script "+strash;dch;map;topo;stime;ps"
"""

def parse_stat(text):
    cells = None; area = None; seq_area = 0.0
    # cell count line looks like:  "      493 2.72E+03 cells"
    m = re.search(r"^\s*(\d+)\s+[\d.eE+]+\s+cells\s*$", text, re.M)
    if m: cells = int(m.group(1))
    m = re.search(r"Chip area for module.*?:\s+([0-9.]+)", text)
    if m: area = float(m.group(1))
    # degenerate floor: outputs are pure constants -> yosys emits no cells and no
    # "Chip area" line. That is a valid measured 0 (all-zero W1 sanity control).
    if area is None and re.search(r"===\s+\S+\s+===", text) and "port bits" in text:
        cells = 0 if cells is None else cells
        area = 0.0
    ms = re.search(r"used for sequential elements:\s+([0-9.]+)", text)
    if ms: seq_area = float(ms.group(1))
    mix = {}
    seq_cells = 0
    for cm in re.finditer(r"^\s+(\d+)\s+[\d.eE+]+\s+(sky130_fd_sc_hd__\S+)\s*$", text, re.M):
        cnt = int(cm.group(1)); name = cm.group(2); mix[name] = cnt
        if ("__df" in name) or ("__dl" in name) or ("sdf" in name) or ("__edf" in name):
            seq_cells += cnt
    return cells, area, seq_cells, seq_area, mix

def parse_timing(log):
    ds = re.findall(r"Delay\s*=\s*([0-9.]+)\s*ps", log)
    lv = re.findall(r"lev\s*=\s*(\d+)", log)
    return (float(ds[-1]) if ds else None), (int(lv[-1]) if lv else None)

def run(mod, seq=False):
    ysf = os.path.join(SYN, mod + ".ys")
    open(ysf, "w").write(area_script(mod))
    p = subprocess.run([YOSYS, "-q", "-s", ysf], capture_output=True, text=True)
    open(os.path.join(RAW, mod + ".log"), "w").write(p.stdout + "\n" + p.stderr)
    statp = os.path.join(RAW, mod + ".stat")
    stat = open(statp).read() if os.path.exists(statp) else (p.stdout + p.stderr)
    cells, area, seqc, seq_area, mix = parse_stat(stat)

    tysf = os.path.join(SYN, mod + "_timing.ys")
    open(tysf, "w").write(timing_script(mod))
    tp = subprocess.run([YOSYS, "-s", tysf], capture_output=True, text=True)  # no -q: keep abc stime output
    open(os.path.join(RAW, mod + "_timing.log"), "w").write(tp.stdout + "\n" + tp.stderr)
    delay_ps, levels = parse_timing(tp.stdout + tp.stderr)

    tiles = area / TILE_UM2 if area else None
    return {"module": mod, "cells": cells, "area_um2": area,
            "seq_cells": seqc, "seq_area_um2": seq_area,
            "tiles_100util": round(tiles, 4) if tiles else None,
            "tiles_at_70util": round(tiles / 0.70, 4) if tiles else None,
            "abc_delay_ps": delay_ps, "abc_levels": levels,
            "cell_mix": mix, "rc": p.returncode}

def main():
    mods = sys.argv[1:]
    if not mods:
        # default: everything in rtl/
        mods = sorted(f[:-2] for f in os.listdir(RTL) if f.endswith(".v"))
    results = {}
    for mod in mods:
        seq = mod.endswith("_dff")
        r = run(mod, seq=seq)
        results[mod] = r
        a = f"{r['area_um2']:.1f}" if r['area_um2'] else "ERR"
        c = r['cells'] if r['cells'] is not None else "ERR"
        d = f"{r['abc_delay_ps']:.0f}ps" if r['abc_delay_ps'] else "?"
        print(f"{mod:22s} cells={str(c):>5}  area={a:>9} um2  "
              f"tiles@70%={r['tiles_at_70util']}  delay={d}")
    json.dump(results, open(os.path.join(WORK, "results.json"), "w"), indent=2)
    print(f"\ntile_um2 = {TILE_UM2:.2f}  -> results.json written")

if __name__ == "__main__":
    main()
