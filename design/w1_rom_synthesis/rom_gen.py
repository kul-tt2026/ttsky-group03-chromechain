#!/usr/bin/env python3
"""
rom_gen.py -- Chrome Chain v1, W1-as-ROM synthesis trial (Step 2 of the brief).

Checkpoint (npz with int W1 of shape (H,64), values in {-1,0,+1}) -> Verilog.

Emits, deterministically and re-runnably, for the requested hidden size H:

  Coding-style sweep of the REAL trained W1 (Step 2, four styles):
    w1_h{H}_case    -- case(addr) with 64 full-width constant literals
    w1_h{H}_flat    -- flat assign from a packed constant vector, bit-slice indexed
    w1_h{H}_bool    -- per-output-bit SOP after Quine-McCluskey minimisation
    w1_h{H}_annot   -- (* full_case, parallel_case *) / rom_style="logic" annotated case

  Controls (Step 3 "Required controls"):
    w1_h{H}_dff     -- DFF register-file baseline (2*H*64 dfxtp + clk/load/read mux)
    w1_h{H}_randmatch -- random ternary at the SAME zero fraction as real W1
    w1_h{H}_rand0   -- random ternary at 0% zeros (pessimistic upper bound)
    w1_h{H}_allzero -- all-zero W1 (degenerate floor / flow sanity)

Encoding (fixed by the brief -- do NOT substitute sign-magnitude):
    each ternary weight -> {p, n} 2 bits :  0 -> 00 , +1 -> 10 , -1 -> 01
    makes downstream gating free:  inc = p AND x ,  dec = n AND x
Bit layout of wcol (width 2H): hidden unit j occupies wcol[2j+1:2j],
    wcol[2j+1] = p_j , wcol[2j] = n_j.  Address = pixel index i (0..63);
    the emitted word for address i is column W1[:, i].
"""
import sys, os, json, argparse
import numpy as np

# ----------------------------------------------------------------------------
# encoding
# ----------------------------------------------------------------------------
def encode_column(col):
    """col: length-H int array in {-1,0,1}. Return 2H-bit int, unit j at [2j+1:2j]={p,n}."""
    v = 0
    for j, w in enumerate(col):
        p = 1 if w == 1 else 0
        n = 1 if w == -1 else 0
        field = (p << 1) | n           # {p,n}
        v |= field << (2 * j)
    return v

def words_from_W1(W1):
    """W1: (H,64) -> list of 64 ints, one per pixel address, width 2H bits."""
    H = W1.shape[0]
    return [encode_column(W1[:, i]) for i in range(64)], 2 * H

# ----------------------------------------------------------------------------
# Quine-McCluskey (n=6) + greedy prime-implicant cover  -> SOP for one output bit
# ----------------------------------------------------------------------------
def qm_sop(onset, nvars=6):
    """onset: set of ints (minterms) in [0,2^nvars). Returns list of (val,mask) primes
    covering the on-set (mask bit=1 => don't-care)."""
    if not onset:
        return []                       # constant 0
    full = (1 << nvars) - 1
    if len(onset) == (1 << nvars):
        return [(0, full)]              # constant 1  (everything don't-care)

    # implicant = (value, mask). start with minterms, mask=0.
    groups = {(m, 0) for m in onset}
    primes = set()
    while groups:
        used = set()
        nxt = set()
        gl = list(groups)
        # bucket by mask so we only combine same-mask implicants
        by_mask = {}
        for (val, mask) in gl:
            by_mask.setdefault(mask, []).append(val)
        for mask, vals in by_mask.items():
            vset = set(vals)
            for v in vals:
                for b in range(nvars):
                    bit = 1 << b
                    if mask & bit:
                        continue        # already don't-care here
                    w = v ^ bit
                    if w in vset:
                        # combine v and w (v<w to dedupe): new don't-care at b
                        base = v & ~bit
                        nxt.add((base, mask | bit))
                        used.add((v, mask))
                        used.add((w, mask))
        for g in groups:
            if g not in used:
                primes.add(g)
        groups = nxt
    primes = list(primes)

    # greedy cover of the original minterms with prime implicants
    def covers(prime, m):
        val, mask = prime
        return (m & ~mask) == (val & ~mask)
    remaining = set(onset)
    chosen = []
    # essential-ish greedy: repeatedly pick prime covering most remaining minterms
    while remaining:
        best = None; best_cov = -1
        for pr in primes:
            c = sum(1 for m in remaining if covers(pr, m))
            if c > best_cov:
                best_cov = c; best = pr
        chosen.append(best)
        remaining -= {m for m in remaining if covers(best, m)}
        primes.remove(best)
    return chosen

def sop_to_verilog(primes, nvars=6, sig="addr"):
    """primes list of (val,mask) -> Verilog boolean expression string."""
    full = (1 << nvars) - 1
    if not primes:
        return "1'b0"
    if len(primes) == 1 and primes[0][1] == full:
        return "1'b1"
    terms = []
    for (val, mask) in primes:
        lits = []
        for b in range(nvars):
            bit = 1 << b
            if mask & bit:
                continue
            if val & bit:
                lits.append(f"{sig}[{b}]")
            else:
                lits.append(f"~{sig}[{b}]")
        terms.append("(" + " & ".join(lits) + ")" if len(lits) > 1 else lits[0])
    return " | ".join(terms)

# ----------------------------------------------------------------------------
# Verilog emitters
# ----------------------------------------------------------------------------
def hexlit(width, value):
    return f"{width}'h{value:0{(width+3)//4}x}"

def emit_case(name, words, W):
    L = [f"// {name}: style 1 -- case(addr) with 64 constant literals",
         f"module {name}(input wire [5:0] addr, output reg [{W-1}:0] wcol);",
         "  always @(*) begin",
         "    case (addr)"]
    for i, w in enumerate(words):
        L.append(f"      6'd{i}: wcol = {hexlit(W,w)};")
    L += ["      default: wcol = {W}'b0;".replace("{W}", str(W)),
          "    endcase", "  end", "endmodule", ""]
    return "\n".join(L)

def emit_flat(name, words, W):
    # packed constant vector, word 0 in the LSBs, bit-slice by addr*W
    parts = ", ".join(hexlit(W, w) for w in reversed(words))  # word63 ... word0
    L = [f"// {name}: style 2 -- flat assign from packed constant vector, bit-slice indexed",
         f"module {name}(input wire [5:0] addr, output wire [{W-1}:0] wcol);",
         f"  localparam [{64*W-1}:0] MEM = {{ {parts} }};",
         f"  assign wcol = MEM[addr*{W} +: {W}];",
         "endmodule", ""]
    return "\n".join(L)

def emit_bool(name, words, W):
    # per output bit b: on-set = {addr : bit b of word == 1}, minimise, emit assign
    L = [f"// {name}: style 3 -- per-output-bit SOP after Quine-McCluskey minimisation",
         f"module {name}(input wire [5:0] addr, output wire [{W-1}:0] wcol);"]
    for b in range(W):
        onset = {i for i, w in enumerate(words) if (w >> b) & 1}
        expr = sop_to_verilog(qm_sop(onset))
        L.append(f"  assign wcol[{b}] = {expr};")
    L += ["endmodule", ""]
    return "\n".join(L)

def emit_annot(name, words, W):
    L = [f"// {name}: style 4 -- full_case/parallel_case + rom_style annotated case",
         f"module {name}(input wire [5:0] addr, output reg [{W-1}:0] wcol);",
         '  (* rom_style = "logic" *)',
         "  always @(*) begin",
         "    (* full_case, parallel_case *)",
         "    case (addr)"]
    for i, w in enumerate(words):
        L.append(f"      6'd{i}: wcol = {hexlit(W,w)};")
    L += ["    endcase", "  end", "endmodule", ""]
    return "\n".join(L)

def emit_dff(name, words, W):
    # DFF register-file baseline: 64 words x W bits of dfxtp with a load path + read mux.
    # External wdata/load keep the flops from constant-folding away -> honest storage cost.
    L = [f"// {name}: control -- DFF register-file baseline ({64*W} dfxtp + clk/load/read mux)",
         f"module {name}(input wire clk, input wire load,",
         f"    input wire [5:0] waddr, input wire [{W-1}:0] wdata,",
         f"    input wire [5:0] raddr, output wire [{W-1}:0] wcol);",
         f"  reg [{W-1}:0] mem [0:63];",
         "  always @(posedge clk) if (load) mem[waddr] <= wdata;",
         "  assign wcol = mem[raddr];",
         "endmodule", ""]
    return "\n".join(L)

# ----------------------------------------------------------------------------
# control weight generators (deterministic)
# ----------------------------------------------------------------------------
def rand_ternary(H, zero_frac, seed):
    rng = np.random.default_rng(seed)
    W = np.zeros((H, 64), dtype=np.int64)
    for j in range(H):
        for i in range(64):
            u = rng.random()
            if u < zero_frac:
                W[j, i] = 0
            elif u < zero_frac + (1 - zero_frac) / 2:
                W[j, i] = 1
            else:
                W[j, i] = -1
    return W

# ----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--hidden", type=int, required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--seed", type=int, default=1234)
    args = ap.parse_args()

    d = np.load(args.ckpt)
    W1 = d["W1"].astype(np.int64)
    H = W1.shape[0]
    assert H == args.hidden, f"checkpoint H={H} != --hidden {args.hidden}"
    assert set(np.unique(W1)).issubset({-1, 0, 1}), "W1 not ternary"
    zf = float((W1 == 0).mean())

    os.makedirs(args.outdir, exist_ok=True)
    words, W = words_from_W1(W1)
    tag = f"h{H}"

    manifest = {"ckpt": os.path.abspath(args.ckpt), "H": H, "width_bits": W,
                "stored_bits": 64 * W, "zero_frac_real": zf, "seed": args.seed,
                "modules": {}}

    def write(mod, text, kind, storage_bits=64 * W):
        path = os.path.join(args.outdir, mod + ".v")
        with open(path, "w") as f:
            f.write(text)
        manifest["modules"][mod] = {"file": mod + ".v", "kind": kind,
                                    "storage_bits": storage_bits}

    # --- four coding styles on REAL weights
    write(f"w1_{tag}_case",  emit_case (f"w1_{tag}_case",  words, W), "real/style1-case")
    write(f"w1_{tag}_flat",  emit_flat (f"w1_{tag}_flat",  words, W), "real/style2-flat")
    write(f"w1_{tag}_bool",  emit_bool (f"w1_{tag}_bool",  words, W), "real/style3-bool")
    write(f"w1_{tag}_annot", emit_annot(f"w1_{tag}_annot", words, W), "real/style4-annot")

    # --- controls
    write(f"w1_{tag}_dff", emit_dff(f"w1_{tag}_dff", words, W), "control/dff-baseline")

    Wm = rand_ternary(H, zf, args.seed)
    wm, _ = words_from_W1(Wm)
    write(f"w1_{tag}_randmatch", emit_case(f"w1_{tag}_randmatch", wm, W),
          f"control/random-zerofrac={zf:.4f}")

    W0 = rand_ternary(H, 0.0, args.seed + 1)
    w0, _ = words_from_W1(W0)
    write(f"w1_{tag}_rand0", emit_case(f"w1_{tag}_rand0", w0, W), "control/random-0pct-zeros")

    Wz = np.zeros((H, 64), dtype=np.int64)
    wz, _ = words_from_W1(Wz)
    write(f"w1_{tag}_allzero", emit_case(f"w1_{tag}_allzero", wz, W), "control/all-zero-floor")

    with open(os.path.join(args.outdir, f"manifest_{tag}.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"H={H}: width={W}b, stored={64*W}b, zero_frac={zf*100:.2f}%  "
          f"-> {len(manifest['modules'])} modules in {args.outdir}")

if __name__ == "__main__":
    main()
