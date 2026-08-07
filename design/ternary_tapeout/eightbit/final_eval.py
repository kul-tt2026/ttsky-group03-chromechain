#!/usr/bin/env python3
"""STAGE 3 selection + the ONE-TIME test evaluation.

Selection (Piste 1, two-stage val): rank seeds on the 3k SELECTION split, take the top-K,
re-rank those on the 3k CONFIRMATION split, winner = best. The 10k test set is read only
after the winner is fixed.

Audit-3 enforcement: the test evaluation writes an append-only ledger. Every test read is
recorded with the fold hash it evaluated. A second evaluation of a DIFFERENT fold is
refused unless --i-am-redoing-a-failed-audit is passed, which is itself logged. This makes
"test touched exactly once" a mechanical property, not a promise.
"""
import argparse, glob, hashlib, json, os, sys, time
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT); sys.path.insert(0, os.path.join(ROOT, "eightbit"))
import numpy as np
import study as S

EB = os.path.join(ROOT, "eightbit")
LEDGER = os.path.join(EB, "TEST_LEDGER.jsonl")

def select(outdir, name, topk=4):
    runs = []
    for f in sorted(glob.glob(os.path.join(outdir, f"{name}_s*.json"))):
        if "_fold_" in os.path.basename(f):
            continue
        r = json.load(open(f))
        if r.get("cfg", {}).get("name") == name:
            runs.append(r)
    if not runs:
        raise SystemExit(f"no runs for {name} in {outdir}")
    runs.sort(key=lambda r: r["acc_a_sel"], reverse=True)
    top = sorted(runs[:topk], key=lambda r: r["acc_a_conf"], reverse=True)
    win = top[0]
    return win, runs

def ledger_append(rec):
    with open(LEDGER, "a") as fh:
        fh.write(json.dumps(rec, default=str) + "\n")

def ledger_read():
    if not os.path.exists(LEDGER):
        return []
    return [json.loads(l) for l in open(LEDGER) if l.strip()]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--qin", type=int, required=True)
    ap.add_argument("--topk", type=int, default=4)
    ap.add_argument("--label", default="final")
    ap.add_argument("--i-am-redoing-a-failed-audit", action="store_true")
    a = ap.parse_args()
    outdir = a.outdir if os.path.isabs(a.outdir) else os.path.join(EB, a.outdir)

    win, runs = select(outdir, a.name, a.topk)
    seed = win["cfg"]["seed"]
    print(f"=== selection for {a.name} over {len(runs)} seeds (two-stage val) ===")
    for r in runs:
        mark = " <-- WINNER" if r["cfg"]["seed"] == seed else ""
        print(f"  s{r['cfg']['seed']:>2}: sel_a {r['acc_a_sel']:.4f}  conf_a {r['acc_a_conf']:.4f}"
              f"  sel_b {r['acc_b_sel']:.4f}  conf_b {r['acc_b_conf']:.4f}{mark}")
    print(f"  -> top{a.topk} on sel, re-ranked on conf: seed {seed}")

    fa_p = os.path.join(outdir, f"{a.name}_s{seed}_fold_a.npz")
    fb_p = os.path.join(outdir, f"{a.name}_s{seed}_fold_b.npz")
    za = np.load(fa_p); fa = {k: za[k] for k in za.files}; fa["kind"] = "shift"
    zb = np.load(fb_p); fb = {k: zb[k] for k in zb.files}
    fb["kind"] = "fixed" if "A" in fb else "shift"
    ha, hb = S.fold_hash(fa), S.fold_hash(fb)

    prior = ledger_read()
    prior_other = [p for p in prior if p.get("fold_a_hash") != ha]
    if prior_other and not a.i_am_redoing_a_failed_audit:
        print("\n!! REFUSED: the test set has already been evaluated on a DIFFERENT fold:")
        for p in prior_other:
            print(f"   {p['ts']}  label={p['label']}  fold_a={p['fold_a_hash'][:16]}  "
                  f"test_shift={p.get('test_shift')}")
        print("   Evaluating a second, differently-selected model would make the test set a "
              "selection surface.\n   Pass --i-am-redoing-a-failed-audit only if an audit "
              "failed and the run is being redone.")
        sys.exit(2)
    repeat = [p for p in prior if p.get("fold_a_hash") == ha]
    if repeat:
        print(f"\n(note: this exact fold was already evaluated at {repeat[0]['ts']}; "
              f"re-reporting the identical number, not a new test read)")

    xt, yt = S.load_test(a.qin)
    d_a, d_b = {}, {}
    test_shift = S.int_acc(xt, yt, fa, a.qin, d_a)
    test_fixed = S.int_acc(xt, yt, fb, a.qin, d_b)

    rec = dict(ts=time.strftime("%Y-%m-%dT%H:%M:%S"), label=a.label, name=a.name,
               qin=a.qin, seed=seed, n_seeds=len(runs),
               fold_a_hash=ha, fold_b_hash=hb,
               val_sel_shift=win["acc_a_sel"], val_conf_shift=win["acc_a_conf"],
               val_sel_fixed=win["acc_b_sel"], val_conf_fixed=win["acc_b_conf"],
               test_shift=test_shift, test_fixed=test_fixed,
               test_n=int(len(yt)), diag_shift=d_a,
               forced=bool(a.i_am_redoing_a_failed_audit))
    ledger_append(rec)
    with open(os.path.join(outdir, f"FINAL_{a.name}.json"), "w") as fh:
        json.dump(rec, fh, indent=2, default=str)
    print(f"\n=== FINAL exact-integer test (10,000 images), read ONCE ===")
    print(f"  config      : {a.name}  QIN={a.qin}  seed={seed}")
    print(f"  val  shift  : {win['acc_a_sel']*100:.2f}% (sel)  {win['acc_a_conf']*100:.2f}% (conf)")
    print(f"  TEST shift  : {test_shift*100:.2f}%")
    print(f"  TEST fixed  : {test_fixed*100:.2f}%")
    print(f"  ledger      : {LEDGER}")

if __name__ == "__main__":
    main()
