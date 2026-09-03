#!/usr/bin/env python3
"""An independent behavioural model of Chrome Chain, written from the RTL's stated
conventions and the ROM contents, not from the RTL's structure.

Its purpose is to check the datapath arithmetic against a second implementation.
Everything else in equiv/ proves the candidate matches origin/main; this is the only
check here that can disagree with BOTH of them, which is what makes it worth having.

Scope and limits, stated plainly:
  - Dense pixel ordering only (en_skip = 0, the reset default). Zero-skip accumulates
    the same pixels, but shortens planes below the 11-cycle check latency, so the
    checkpoint SCHEDULE can differ; that scheduling is deliberately not modelled.
  - It models what the weights say the chip should compute. It says nothing about
    whether the trained network classifies digits well.

Conventions taken from the RTL (file:line as of this branch):
  w1_rom_final4.v      addr = pixel index; unit j is {p,n} at wcol[2j+1:2j], p = HIGH
  l2_mac_x4.v:23-26    class c of unit u: bit 20u+2c = +h (LOW), bit 20u+2c+1 = -h
  l1_horner_acc.v:22   base = img_start ? 0 : plane_start ? q<<1 : q, all in ACC_W bits
  requant_unit.v:8-10  t = a1 + bias in 10 b (TRUNCATED from 12), t >>> k, clamp 0..15
  ckpt_block.v:257-259 bias sign-extended to 12 b, then >>> (PLANES - checkpoint)
  checkpoint_ctrl.v    b2 preload, bias_sh = 4 - k, final check uses T = 0
  max2_node.v:6        a_wins = a_max >= b_max, so a tie keeps the LOWER index
  exit_tree_2stage.v   done = (max - runner_up) >= T
"""
import re, sys, os, random

SRC = os.path.join(os.path.dirname(__file__), '..', '..', 'src')

# ---------------------------------------------------------------- fixed-width helpers
def sgn(v, w):
    """interpret the low w bits of v as two's complement"""
    v &= (1 << w) - 1
    return v - (1 << w) if v & (1 << (w - 1)) else v

def asr(v, s):
    """arithmetic right shift; Python's >> already floors on negatives"""
    return v >> s

# ---------------------------------------------------------------- ROM decoding
def load_w1():
    """64 words x 64 b. Returns w1[pixel][unit] in {-1,0,+1}."""
    txt = open(os.path.join(SRC, 'w1_rom_final4.v')).read()
    words = {int(a): int(h, 16) for a, h in
             re.findall(r"6'd(\d+)\s*:\s*wcol\s*=\s*64'h([0-9a-fA-F]+)", txt)}
    assert len(words) == 64, f'w1: {len(words)} words'
    w1 = []
    for p in range(64):
        row, w = words[p], []
        for j in range(32):
            pos = (row >> (2 * j + 1)) & 1      # p is the HIGH bit of the pair
            neg = (row >> (2 * j)) & 1
            w.append(1 if pos else (-1 if neg else 0))
        w1.append(w)
    return w1

def _grouped_rom(path, bits, pat):
    """The x4 ROMs: port i, case entry g holds unit 4g+i."""
    txt = open(os.path.join(SRC, path)).read()
    out = {}
    for port, (lo, body) in enumerate(_ports(txt)):
        for g, h in re.findall(pat, body):
            out[4 * int(g) + port] = int(h, 16)
    assert len(out) == 32, f'{path}: {len(out)} words'
    return out

def _ports(txt):
    """each always block's case table, in port order"""
    return [(m.start(), m.group(1)) for m in
            re.finditer(r"case \(addr\[\d+:\d+\]\)(.*?)endcase", txt, re.S)]

def load_w2():
    """32 words x 20 b. Returns w2[unit][class] in {-1,0,+1}."""
    words = _grouped_rom('l2_weight_rom_x4.v', 20,
                         r"3'd(\d+)\s*:\s*wcol\[\d+:\d+\]\s*=\s*20'h([0-9a-fA-F]+)")
    w2 = []
    for u in range(32):
        row, w = words[u], []
        for c in range(10):
            pos = (row >> (2 * c)) & 1          # +h is the LOW bit: opposite of W1
            neg = (row >> (2 * c + 1)) & 1
            w.append(1 if pos else (-1 if neg else 0))
        w2.append(w)
    return w2

def load_thetak():
    """32 words x 8 b: [7:6] = k, [5:0] = signed bias."""
    words = _grouped_rom('requant_rom_x4.v', 8,
                         r"3'd(\d+)\s*:\s*wcol\[\d+:\d+\]\s*=\s*8'h([0-9a-fA-F]+)")
    return [(sgn(words[u] & 0x3F, 6), (words[u] >> 6) & 3) for u in range(32)]

def load_b2():
    """b2[class], read from checkpoint_ctrl's oacc_init concat (class 9 first)."""
    txt = open(os.path.join(SRC, 'checkpoint_ctrl.v')).read()
    blk = txt[txt.index('assign oacc_init'):]
    blk = blk[:blk.index(';')]
    vals = [sgn(int(h, 16), 12) for h in re.findall(r"'sh([0-9a-fA-F]+)", blk)]
    assert len(vals) == 10, f'b2: {len(vals)}'
    return vals[::-1]                            # concat is class 9 .. class 0

# ---------------------------------------------------------------- the datapath
ACC_W, OACC_W = 10, 12
PLANES, NHID, NCLASS = 4, 32, 10

def l1_accumulate(planes, w1):
    """Horner fold. Yields the 32-unit accumulator after each plane boundary."""
    acc = [0] * NHID
    for plane in planes:
        acc = [sgn((a << 1), ACC_W) for a in acc]         # plane_start: q<<1 in ACC_W b
        for t in range(64):                                # dense: pixel t, act=plane[t]
            if (plane >> t) & 1:
                row = w1[t]
                for j in range(NHID):
                    d = row[j]
                    if d:
                        acc[j] = sgn(acc[j] + d, ACC_W)
        yield list(acc)

def requant(a1, bias, k, bias_sh):
    """requant_unit.v with ckpt_block's bias pre-shift. The 10 b t is a truncation."""
    bias_shf = asr(sgn(bias, OACC_W), bias_sh)             # 12 b signed, arithmetic
    t = sgn(sgn(a1, OACC_W) + bias_shf, ACC_W)             # 12 b add, TRUNCATED to 10 b
    s = asr(t, k)
    return 0 if s <= 0 else (15 if s >= 15 else s & 0xF)

def l2_scores(h, w2, b2):
    acc = list(b2)
    for u in range(NHID):
        if h[u]:
            row = w2[u]
            for c in range(NCLASS):
                if row[c]:
                    acc[c] = sgn(acc[c] + row[c] * h[u], OACC_W)
    return acc

def _max2(a, b):
    """max2_node.v: a wins ties, LeSec = max(loser's max, winner's sec)"""
    (am, ai, asec), (bm, bi, bsec) = a, b
    a_wins = am >= bm
    lm, ws = (bm, asec) if a_wins else (am, bsec)
    return ((am, ai, asec) if a_wins else (bm, bi, bsec))[0:2] + (max(lm, ws),)

def exit_tree(y):
    """exit_tree_2stage.v's exact tournament, node for node."""
    NEG = -2048
    leaf = [(y[g], g, NEG) for g in range(10)]
    m1 = [_max2(leaf[2 * i], leaf[2 * i + 1]) for i in range(5)]
    m2_0 = _max2(m1[0], m1[1])
    m2_1 = _max2(m1[2], m1[3])
    m3 = _max2(m2_0, m2_1)
    m4 = _max2(m3, m1[4])
    return m4[1], m4[0] - m4[2]                            # argmax, margin

def classify(planes, w1, w2, thetak, b2, t_cfg=(1023, 8, 12), ckpt_en=0b110):
    """Returns (answer, exit_k). exit_k 0 means the final check decided."""
    for k, a1 in enumerate(l1_accumulate(planes, w1), start=1):
        final = (k == PLANES)
        armed = final or ((ckpt_en >> (k - 1)) & 1)
        if not armed:
            continue
        h = [requant(a1[u], thetak[u][0], thetak[u][1], PLANES - k) for u in range(NHID)]
        argmax, margin = exit_tree(l2_scores(h, w2, b2))
        T = 0 if final else t_cfg[k - 1]
        if final or margin >= T:
            return argmax, (0 if final else k)
    raise AssertionError('no checkpoint fired')

def load_all():
    return load_w1(), load_w2(), load_thetak(), load_b2()

def planes_from_pixels(pix):
    """pix[64] of 4-bit values -> four planes, MSB plane first"""
    return [sum(((pix[n] >> (3 - k)) & 1) << n for n in range(64)) for k in range(4)]

if __name__ == '__main__':
    w1, w2, tk, b2 = load_all()
    print(f'W1 64x32 ternary, W2 32x10 ternary, theta/k 32, b2 {b2}')
    known = [
        ('IMG_EARLY', (0xd1d788a381de9003, 0xdb5f10b68d3b801a,
                       0x9c8b8839f91d02f2, 0xf6cec2ede4afc2c9), (5, 2)),
        ('IMG_FULL',  (0xF0F00F0FAA551234, 0x0123456789ABCDEF,
                       0xFFFF0000FFFF0000, 0x8001400220041008), (5, 0)),
    ]
    bad = 0
    for name, planes, expect in known:
        got = classify(list(planes), w1, w2, tk, b2)
        ok = got == expect
        bad += not ok
        print(f'  {name:10s} model {got}  RTL-measured {expect}  {"OK" if ok else "MISMATCH"}')
    sys.exit(bad)
