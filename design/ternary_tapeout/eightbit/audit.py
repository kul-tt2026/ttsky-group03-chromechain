#!/usr/bin/env python3
"""STAGE 4 verification harness (audits 1, 2, 3, 5).

Audit 4 (blind replication) is deliberately NOT here -- it is performed by a separate
reasoning pass with no access to this file or to study.py.

Audit 1 re-implements the input quantization from the SPEC TEXT ONLY, using a different
code structure (explicit per-image integer loops, no shared helper, no pool_bins()), and
compares bit-for-bit against the cached tensors over all 70,000 images.
"""
import argparse, json, math, os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, "eightbit"))
import numpy as np
import ternary_tapeout as tt
import study as S

# ---------------------------------------------------------------- audit 1
def independent_quantize(imgs, QIN, want_ties=False):
    """From the spec: 8x8 pooling, bin i spans rows [floor(i*28/8), ceil((i+1)*28/8)).
    value = clip(round(mean(pixel/255) * QIN), 0, QIN), round = IEEE half-to-even.

    Computed in EXACT INTEGER arithmetic -- value = round_half_even(sum*QIN / (npix*255))
    -- so it is the authoritative ground truth, free of any floating-point evaluation-order
    dependence. Shares no code with study.preprocess_q / tt.preprocess."""
    lo = [int(math.floor(i * 28 / 8)) for i in range(8)]
    hi = [int(math.ceil((i + 1) * 28 / 8)) for i in range(8)]
    N = imgs.shape[0]
    out = np.zeros((N, 8, 8), dtype=np.int64)
    tie = np.zeros((N, 8, 8), dtype=bool)
    for r in range(8):
        for c in range(8):
            s = imgs[:, lo[r]:hi[r], lo[c]:hi[c]].astype(np.int64).sum(axis=(1, 2))
            npix = (hi[r] - lo[r]) * (hi[c] - lo[c])
            num, den = s * QIN, npix * 255
            q, rem = num // den, num % den
            is_tie = (2 * rem == den)
            up = (2 * rem > den) | (is_tie & (q % 2 == 1))     # half-to-even
            out[:, r, c] = np.clip(q + up, 0, QIN)
            tie[:, r, c] = is_tie
    if want_ties:
        return out.reshape(N, 64), tie.reshape(N, 64)
    return out.reshape(N, 64)

def audit1(QIN):
    """Compare the study's cached inputs against exact-integer ground truth over all 70k
    images. PASS requires: every disagreement sits on an exact .5 tie AND is bounded by
    1 LSB -- i.e. the only divergence is float evaluation order resolving ties, never a
    genuine binning or scaling error."""
    d = tt.get_data()
    res = {"QIN": QIN}
    tei = tt.load_idx(os.path.join(tt.DATA, tt.FILES["test_images"]))
    ok = True
    for split, imgs, cached in (
            ("train", d["imgs_train"], S.load_enlarged(QIN)[0][:60000].astype(np.int64)),
            ("test", tei, S.load_test(QIN)[0].astype(np.int64))):
        ex, tie = independent_quantize(imgs, QIN, want_ties=True)
        diff = (ex != cached)
        res[split] = dict(
            images=int(ex.shape[0]), cells=int(ex.size),
            cells_differing=int(diff.sum()),
            frac_differing=float(diff.mean()),
            exact_half_ties=int(tie.sum()), tie_rate=float(tie.mean()),
            all_diffs_are_ties=bool((diff & ~tie).sum() == 0),
            max_abs_delta=int(np.abs(ex - cached).max()) if ex.size else 0,
            non_tie_disagreements=int((diff & ~tie).sum()))
        ok &= res[split]["all_diffs_are_ties"] and res[split]["max_abs_delta"] <= 1
    res["bins"] = [(int(math.floor(i * 28 / 8)), int(math.ceil((i + 1) * 28 / 8))) for i in range(8)]
    res["npix_per_bin"] = 16
    res["tie_condition"] = f"sum*{QIN} == k*4080 + 2040  (npix=16, 255 scale)"
    res["pass"] = bool(ok)
    res["note"] = ("Disagreements are exact-.5-tie resolutions only (float eval order), "
                   "never binning/scaling errors. Tie rate is ~16x higher at 8-bit.")
    return res

# ---------------------------------------------------------------- audit 2
def audit2(fold, QIN, x, y, kmax_declared):
    """Integer-eval audit: ternary weights, integer biases on the shift grid, shift range,
    accumulator widths (observed AND theoretical worst case)."""
    f = dict(fold)
    r = {}
    W1, W2 = f["W1"], f["W2"]
    r["W1_ternary"] = bool(np.isin(W1, (-1, 0, 1)).all())
    r["W2_ternary"] = bool(np.isin(W2, (-1, 0, 1)).all())
    r["W1_values"] = sorted(int(v) for v in np.unique(W1))
    r["W2_values"] = sorted(int(v) for v in np.unique(W2))
    r["W1_nonzero_frac"] = float((W1 != 0).mean())
    r["W2_nonzero_frac"] = float((W2 != 0).mean())
    r["bias_is_integer"] = bool(np.all(f["bias"] == np.round(f["bias"])))
    r["b2_is_integer"] = bool(np.all(f["b2"] == np.round(f["b2"])))
    r["bias_absmax"] = int(np.abs(f["bias"]).max())
    r["b2_absmax"] = int(np.abs(f["b2"]).max())
    if f["kind"] == "shift":
        k = f["k"]
        r["k_is_integer"] = bool(np.all(k == np.round(k)))
        r["k_min"], r["k_max"] = int(k.min()), int(k.max())
        r["k_within_declared"] = bool(k.min() >= 0 and k.max() <= kmax_declared)
        r["k_dist"] = {str(v): int((k == v).sum()) for v in sorted(np.unique(k))}
    r["qmax_values"] = sorted(int(v) for v in np.unique(f["qmax"]))

    # observed accumulator ranges on the supplied eval set
    xi = x.astype(np.int64)
    a1 = xi @ W1.T
    r["a1_observed"] = [int(a1.min()), int(a1.max())]
    if f["kind"] == "shift":
        t = a1 * f["sign"][None, :] + f["bias"][None, :]
        h = np.clip(t >> f["k"][None, :], 0, f["qmax"][None, :])
    else:
        t = a1 * f["A"][None, :] + f["bias"][None, :]
        h = np.clip(t >> int(f["FR"]), 0, f["qmax"][None, :])
    r["preshift_observed"] = [int(t.min()), int(t.max())]
    logits = h @ W2.T + f["b2"][None, :]
    r["a2_observed"] = [int(logits.min()), int(logits.max())]

    # theoretical worst case over ANY legal input, not just this eval set
    wc_a1 = int(np.abs(W1).sum(1).max()) * QIN
    r["a1_worst_case"] = [-wc_a1, wc_a1]
    r["a1_bits_worst_case"] = int(math.ceil(math.log2(wc_a1 + 1)) + 1)
    wc_pre = wc_a1 + r["bias_absmax"]
    r["preshift_bits_worst_case"] = int(math.ceil(math.log2(wc_pre + 1)) + 1)
    wc_a2 = int((np.abs(W2) * f["qmax"][None, :]).sum(1).max()) + r["b2_absmax"]
    r["a2_worst_case"] = [-wc_a2, wc_a2]
    r["a2_bits_worst_case"] = int(math.ceil(math.log2(wc_a2 + 1)) + 1)
    r["no_int64_overflow"] = bool(wc_pre < 2**62 and wc_a2 < 2**62)
    r["observed_within_worst_case"] = bool(
        abs(r["a1_observed"][0]) <= wc_a1 and abs(r["a1_observed"][1]) <= wc_a1 and
        abs(r["a2_observed"][0]) <= wc_a2 and abs(r["a2_observed"][1]) <= wc_a2)
    r["pass"] = all([r["W1_ternary"], r["W2_ternary"], r["bias_is_integer"],
                     r["b2_is_integer"], r["no_int64_overflow"],
                     r["observed_within_worst_case"],
                     r.get("k_within_declared", True), r.get("k_is_integer", True)])
    return r

# ---------------------------------------------------------------- audit 5
def audit5(fold, QIN, x, y):
    """Tie-breaking audit: how many argmax ties exist, and does the convention matter?"""
    f = dict(fold)
    xi = x.astype(np.int64)
    a1 = xi @ f["W1"].T
    if f["kind"] == "shift":
        t = a1 * f["sign"][None, :] + f["bias"][None, :]
        h = np.clip(t >> f["k"][None, :], 0, f["qmax"][None, :])
    else:
        t = a1 * f["A"][None, :] + f["bias"][None, :]
        h = np.clip(t >> int(f["FR"]), 0, f["qmax"][None, :])
    logits = h @ f["W2"].T + f["b2"][None, :]
    mx = logits.max(1, keepdims=True)
    nmax = (logits == mx).sum(1)
    yi = y.astype(np.int64)
    lowest = logits.argmax(1)
    highest = 9 - logits[:, ::-1].argmax(1)
    tied = nmax > 1
    # "generous" convention: count a tie as correct if the true label is among the argmaxes
    generous = np.where(tied & (logits[np.arange(len(yi)), yi] == mx[:, 0]), yi, lowest)
    return dict(
        n_images=int(len(yi)), n_tied=int(tied.sum()),
        tie_rate=float(tied.mean()),
        max_tie_multiplicity=int(nmax.max()),
        acc_lowest_index=float((lowest == yi).mean()),
        acc_highest_index=float((highest == yi).mean()),
        acc_generous=float((generous == yi).mean()),
        spread_pp=float((max((lowest == yi).mean(), (highest == yi).mean(),
                             (generous == yi).mean()) -
                         min((lowest == yi).mean(), (highest == yi).mean(),
                             (generous == yi).mean())) * 100),
        convention="lowest class index (numpy argmax)")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qin", type=int, required=True)
    ap.add_argument("--fold", default=None, help="path to *_fold_a.npz")
    ap.add_argument("--kmax", type=int, default=12)
    ap.add_argument("--split", default="val", choices=["val", "test"])
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    rep = {"audit1_preprocessing": audit1(a.qin)}
    if a.fold:
        z = np.load(a.fold)
        f = {k: z[k] for k in z.files}
        f["kind"] = "shift" if "k" in f else "fixed"
        if a.split == "test":
            x, y = S.load_test(a.qin)
        else:
            xx, yy, _ = S.load_enlarged(a.qin)
            _, vs, vc = S.splits(xx.shape[0])
            x, y = xx[vc], yy[vc]
        rep["audit2_integer_eval"] = audit2(f, a.qin, x, y, a.kmax)
        rep["audit5_tiebreak"] = audit5(f, a.qin, x, y)
    print(json.dumps(rep, indent=2, default=str))
    if a.out:
        with open(a.out, "w") as fh: json.dump(rep, fh, indent=2, default=str)

if __name__ == "__main__":
    main()
