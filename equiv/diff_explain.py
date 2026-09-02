#!/usr/bin/env python3
"""Explain a differential-trace mismatch: which DFT view and which uo_out bits differ,
and in which cycle ranges. Used to show that a deliberate behaviour change (P3) is
confined to exactly the bits it was meant to change.
   usage: diff_explain.py <base.txt> <cand.txt>
"""
import sys
from collections import Counter, defaultdict

def load(p):
    with open(p) as f:
        for line in f:
            cyc, uo, uio, oe = line.split()
            yield int(cyc), uo, uio, oe

def bits(a, b):
    """bit positions (7..0) where the two hex/x strings differ"""
    out = []
    for i in range(8):
        ca, cb = a, b
        # x-aware compare per nibble character
    va, vb = [], []
    for s in (a, b):
        v = []
        for ch in s:
            if ch in 'xX': v += [None] * 4
            else: v += [(int(ch, 16) >> k) & 1 for k in (3, 2, 1, 0)]
        (va if s is a else vb).append(v)
    va, vb = va[0], vb[0]
    return [7 - i for i in range(8) if va[i] != vb[i]]

def main(pa, pb):
    per_view = Counter(); per_bit = Counter(); ranges = defaultdict(list); n = 0
    first = None; last = None
    for (ca, a, ua, oa), (cb, b, ub, ob) in zip(load(pa), load(pb)):
        assert ca == cb
        if a == b and ua == ub and oa == ob:
            continue
        n += 1
        view = ca % 4
        per_view[view] += 1
        for bt in bits(a, b): per_bit[(view, bt)] += 1
        if ua != ub or oa != ob: per_bit[('uio', 0)] += 1
        if first is None: first = ca
        if last is not None and ca - last > 16:
            ranges[view].append((first, last)); first = ca
        last = ca
    if first is not None: ranges[None].append((first, last))
    print(f"differing cycles: {n}")
    for v in sorted(per_view): print(f"  view {v}: {per_view[v]} cycles")
    print("differing bits (view, uo_out bit): count")
    for k in sorted(per_bit, key=str): print(f"  {k}: {per_bit[k]}")
    if n:
        print(f"first differing cycle: {min(r[0] for rs in ranges.values() for r in rs)}")
        print(f"last differing cycle:  {last}")
    return 0 if n == 0 else 1

if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
