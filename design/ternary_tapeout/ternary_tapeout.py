#!/usr/bin/env python3
"""
Ternary-weight MLP on MNIST (8x8 avg-pooled, 4-bit unsigned inputs) for Tiny Tapeout.

Pipeline: download -> preprocess (exact spec) -> float teacher -> QAT phase-1 (free
per-unit requant scale, BN) -> phase-2 (per-unit power-of-two scale, fine-tuned) ->
integer folds -> EXACT-INTEGER eval (pure numpy int64) on the 10k test set.

The reported numbers come only from the integer model. Fake-quant is training-only.

Stages:
  selftest  - verify pooling bins / shift semantics
  data      - download + preprocess + cache
  teacher   - train float teacher(s) for the KD splits
  sweep     - HP ablations at H=32 on a 55k/5k train split (validation only)
  finals    - train final models per H on 58k/2k split, select on val, save artifacts
  report    - load artifacts, run exact-integer eval on the 10k test set ONCE, print table
  all       - data -> teacher -> finals -> report with the locked recipe
"""
import argparse, gzip, json, math, os, struct, sys, time
import numpy as np

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(ROOT, "data"); CACHE = os.path.join(ROOT, "cache")
RUNS = os.path.join(ROOT, "runs"); ART = os.path.join(ROOT, "artifacts")
for d in (DATA, CACHE, RUNS, ART): os.makedirs(d, exist_ok=True)

MIRROR = "https://raw.githubusercontent.com/fgnt/mnist/master/"
FILES = dict(
    train_images="train-images-idx3-ubyte.gz", train_labels="train-labels-idx1-ubyte.gz",
    test_images="t10k-images-idx3-ubyte.gz",  test_labels="t10k-labels-idx1-ubyte.gz")

SPLIT_SEED = 1234          # fixed shuffle for train/val splits (train-side only)
FR_BITS = 16               # fractional bits for fold (b)

# Locked final recipe (chosen on the 55k/5k validation sweep, never on test):
RECIPE = dict(lr=3e-3, bs=512, epochs1=200, epochs2=100, warm=3, kd=0.3, T=4.0,
              thr=1.0, drop=0.0, aug=False, rot=12.0, trans=2.0, scl=0.10,
              seeds=(0, 1, 2, 3, 4))

# ---------------------------------------------------------------- data
def download():
    import urllib.request
    for f in FILES.values():
        p = os.path.join(DATA, f)
        if not os.path.exists(p):
            print("downloading", f); urllib.request.urlretrieve(MIRROR + f, p)

def load_idx(path):
    with gzip.open(path, "rb") as fh:
        data = fh.read()
    magic = struct.unpack(">I", data[:4])[0]
    if magic == 2051:
        n, r, c = struct.unpack(">III", data[4:16])
        return np.frombuffer(data, np.uint8, offset=16).reshape(n, r, c)
    if magic == 2049:
        n = struct.unpack(">I", data[4:8])[0]
        return np.frombuffer(data, np.uint8, offset=8).reshape(n)
    raise ValueError(f"bad idx magic {magic}")

def pool_bins():
    # spec: rows/cols span (floor(i*28/8), ceil((i+1)*28/8)) - variable, slightly overlapping
    return [(math.floor(i * 28 / 8), math.ceil((i + 1) * 28 / 8)) for i in range(8)]

def preprocess(imgs):
    """(N,28,28) uint8 -> (N,64) ints 0..15. x = clip(round(mean_pixel_in_[0,1] * 15), 0, 15).
    Rounding: np.round (IEEE half-to-even)."""
    b = pool_bins()
    f = imgs.astype(np.float64) / 255.0
    out = np.empty((imgs.shape[0], 8, 8), np.float64)
    for i, (r0, r1) in enumerate(b):
        for j, (c0, c1) in enumerate(b):
            out[:, i, j] = f[:, r0:r1, c0:c1].mean(axis=(1, 2))
    return np.clip(np.round(out * 15.0), 0, 15).astype(np.uint8).reshape(-1, 64)

def get_data():
    p = os.path.join(CACHE, "mnist8x8.npz")
    if not os.path.exists(p):
        download()
        tri = load_idx(os.path.join(DATA, FILES["train_images"]))
        trl = load_idx(os.path.join(DATA, FILES["train_labels"]))
        tei = load_idx(os.path.join(DATA, FILES["test_images"]))
        tel = load_idx(os.path.join(DATA, FILES["test_labels"]))
        assert tri.shape == (60000, 28, 28) and tei.shape == (10000, 28, 28)
        np.savez_compressed(p, x_train=preprocess(tri), y_train=trl,
                            x_test=preprocess(tei), y_test=tel, imgs_train=tri)
        print("cached", p)
    z = np.load(p)
    return {k: z[k] for k in z.files}

def split_train(n_val):
    rng = np.random.default_rng(SPLIT_SEED)
    perm = rng.permutation(60000)
    return perm[n_val:], perm[:n_val]

# ---------------------------------------------------------------- torch models
import torch
import torch.nn as nn
import torch.nn.functional as F

def pool_matrix():
    P = np.zeros((8, 28), np.float32)
    for i, (r0, r1) in enumerate(pool_bins()):
        P[i, r0:r1] = 1.0 / (r1 - r0)
    return torch.from_numpy(P)

def augment_pool_quant(imgs, P, rot=12.0, scale=0.10, trans=2.0):
    """imgs (B,28,28) float 0..1 -> (B,64) integer-valued float 0..15 (train-time only)."""
    B = imgs.shape[0]; dev = imgs.device
    th = (torch.rand(B, device=dev) * 2 - 1) * math.radians(rot)
    sc = 1.0 + (torch.rand(B, device=dev) * 2 - 1) * scale
    tx = (torch.rand(B, device=dev) * 2 - 1) * (trans / 14.0)
    ty = (torch.rand(B, device=dev) * 2 - 1) * (trans / 14.0)
    cos, sin = torch.cos(th) * sc, torch.sin(th) * sc
    mat = torch.zeros(B, 2, 3, device=dev)
    mat[:, 0, 0] = cos; mat[:, 0, 1] = -sin; mat[:, 0, 2] = tx
    mat[:, 1, 0] = sin; mat[:, 1, 1] = cos;  mat[:, 1, 2] = ty
    grid = F.affine_grid(mat, (B, 1, 28, 28), align_corners=False)
    out = F.grid_sample(imgs[:, None], grid, mode="bilinear",
                        padding_mode="zeros", align_corners=False)[:, 0]
    pooled = torch.einsum("ir,brc,jc->bij", P, out, P)
    return torch.clamp(torch.round(pooled * 15.0), 0, 15).reshape(B, 64)

def ishift_pool_quant(imgs, P, max_s=1):
    """Integer-pixel random shifts via roll (no interpolation blur), then pool+quant."""
    B = imgs.shape[0]
    dx = torch.randint(-max_s, max_s + 1, (B,), device=imgs.device)
    dy = torch.randint(-max_s, max_s + 1, (B,), device=imgs.device)
    res = imgs.clone()
    for sx in range(-max_s, max_s + 1):
        for sy in range(-max_s, max_s + 1):
            if sx == 0 and sy == 0: continue
            m = (dx == sx) & (dy == sy)
            if m.any(): res[m] = torch.roll(imgs[m], shifts=(sx, sy), dims=(1, 2))
    pooled = torch.einsum("ir,brc,jc->bij", P, res, P)
    return torch.clamp(torch.round(pooled * 15.0), 0, 15).reshape(B, 64)

class TernaryLinear(nn.Module):
    """W_t = clamp(round(W / (thr * absmean_row)), -1, 1); absmean used ONLY as the
    ternarization threshold (folded away), never as an inference multiplier."""
    def __init__(self, in_f, out_f, thr=1.0):
        super().__init__()
        self.weight = nn.Parameter(torch.randn(out_f, in_f) / math.sqrt(in_f))
        self.thr = thr
    def ternary(self):
        a = self.weight.abs().mean(dim=1, keepdim=True).clamp_min(1e-8) * self.thr
        return torch.clamp(torch.round(self.weight / a), -1, 1)
    def forward(self, x):
        w = self.weight + (self.ternary() - self.weight).detach()
        return F.linear(x, w)

def floor_quant_ste(z):
    """h = clip(floor(z + 0.5), 0, 15) — hardware round-half-up semantics; STE gradient
    through clip(z, 0, 15)."""
    zc = torch.clamp(z, 0, 15)
    h = torch.clamp(torch.floor(z + 0.5), 0, 15)
    return zc + (h - zc).detach()

class RequantBN(nn.Module):
    """Phase 1: free per-unit affine (BN) then 4-bit floor-quant with STE."""
    def __init__(self, H):
        super().__init__()
        self.bn = nn.BatchNorm1d(H)
        nn.init.constant_(self.bn.weight, 4.0)
        nn.init.constant_(self.bn.bias, 3.0)
    def forward(self, a1):
        return floor_quant_ste(self.bn(a1))
    def fold(self):
        """h = clip(round(m*a1 + c), 0, 15)"""
        w, b = self.bn.weight, self.bn.bias
        mu, var = self.bn.running_mean, self.bn.running_var
        s = torch.sqrt(var + self.bn.eps)
        m = (w / s).detach().cpu().double().numpy()
        c = (b - mu * w / s).detach().cpu().double().numpy()
        return m, c

class RequantPow2(nn.Module):
    """Phase 2: per-unit scale 2^-round(t) with STE on the log2 param t (units may still
    migrate between shift values while training), bias quantized to the shift grid (STE).
    Forward is bit-exact hardware semantics: h = clip(floor(a1*2^-k + c + 0.5), 0, 15),
    which equals clip((a1 + B) >> k, 0, 15) with B = (c + 0.5)*2^k an integer."""
    def __init__(self, t, c):
        super().__init__()
        self.t = nn.Parameter(t.float())
        self.c = nn.Parameter(c.float())
    def forward(self, a1):
        t = self.t.clamp(0, 12)
        k = torch.round(t)
        scale_s = torch.pow(2.0, -t)                              # smooth gradient path
        scale = scale_s + (torch.pow(2.0, -k) - scale_s).detach()
        step = torch.pow(2.0, -k).detach()                        # bias grid = 2^-k
        cq = self.c + (torch.round((self.c + 0.5) / step) * step - 0.5 - self.c).detach()
        return floor_quant_ste(a1 * scale + cq)
    def fold(self):
        k = torch.round(self.t.clamp(0, 12)).detach().cpu().double().numpy()
        m = 2.0 ** (-k)
        c = self.c.detach().cpu().double().numpy()
        cq = np.round((c + 0.5) / m) * m - 0.5
        return m, cq

class TernaryMLP(nn.Module):
    def __init__(self, H, thr=1.0, drop=0.0):
        super().__init__()
        self.l1 = TernaryLinear(64, H, thr)
        self.rq = RequantBN(H)
        self.drop = nn.Dropout(drop) if drop > 0 else nn.Identity()
        self.l2 = TernaryLinear(H, 10, thr)
        self.b2 = nn.Parameter(torch.zeros(10))
        self.log_g = nn.Parameter(torch.tensor(math.log(0.125)))
    def forward(self, x):                    # x: integer-valued float 0..15
        h = self.drop(self.rq(self.l1(x)))
        b2 = self.b2 + (torch.round(self.b2) - self.b2).detach()   # integer bias, STE
        return (self.l2(h) + b2) * self.log_g.exp()

class Teacher(nn.Module):
    def __init__(self):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(64, 512), nn.BatchNorm1d(512), nn.ReLU(), nn.Dropout(0.1),
            nn.Linear(512, 256), nn.BatchNorm1d(256), nn.ReLU(), nn.Dropout(0.1),
            nn.Linear(256, 10))
    def forward(self, x):
        return self.net(x / 15.0 - 0.5)

# ---------------------------------------------------------------- training
def cosine_lr(opt, base, step, total, warm):
    if step < warm:
        lr = base * (step + 1) / max(1, warm)
    else:
        p = (step - warm) / max(1, total - warm)
        lr = base * 0.5 * (1 + math.cos(math.pi * p))
    for g in opt.param_groups:
        g["lr"] = lr

def fq_val_acc(model, xv, yv):
    model.eval()
    with torch.no_grad():
        return (model(xv).argmax(1) == yv).float().mean().item()

def train_teacher(n_val, epochs=60, lr=1e-3, bs=512, seed=7, device="cpu"):
    p = os.path.join(CACHE, f"teacher_val{n_val}_s{seed}.pt")
    data = get_data()
    tr_idx, va_idx = split_train(n_val)
    xq = torch.from_numpy(data["x_train"].astype(np.float32)).to(device)
    y = torch.from_numpy(data["y_train"].astype(np.int64)).to(device)
    t = Teacher().to(device)
    if os.path.exists(p):
        t.load_state_dict(torch.load(p, map_location=device))
        t.eval()
        acc = fq_val_acc(t, xq[va_idx], y[va_idx])
        print(f"teacher (cached) val{n_val}: {acc:.4f}")
        return t
    torch.manual_seed(seed)
    t = Teacher().to(device)
    imgs = torch.from_numpy(data["imgs_train"]).float().div_(255.0).to(device)
    P = pool_matrix().to(device)
    tr = torch.from_numpy(tr_idx).to(device)
    opt = torch.optim.AdamW(t.parameters(), lr=lr, weight_decay=1e-4)
    spe = math.ceil(len(tr_idx) / bs); total = spe * epochs; step = 0
    for ep in range(epochs):
        t.train()
        perm = torch.randperm(len(tr_idx), device=device)
        for b in range(spe):
            idx = tr[perm[b * bs:(b + 1) * bs]]
            xb = augment_pool_quant(imgs[idx], P)
            cosine_lr(opt, lr, step, total, 2 * spe)
            loss = F.cross_entropy(t(xb), y[idx], label_smoothing=0.1)
            opt.zero_grad(set_to_none=True); loss.backward(); opt.step(); step += 1
        if (ep + 1) % 10 == 0:
            print(f"  teacher ep{ep+1}: val {fq_val_acc(t, xq[va_idx], y[va_idx]):.4f}")
    acc = fq_val_acc(t, xq[va_idx], y[va_idx])
    torch.save(t.state_dict(), p)
    print(f"teacher val{n_val}: {acc:.4f} -> {p}")
    return t

def run_epochs(model, teacher, data, tr_idx, cfg, epochs, lr, device, xv=None, yv=None, tag=""):
    imgs = torch.from_numpy(data["imgs_train"]).float().div_(255.0).to(device)
    xq = torch.from_numpy(data["x_train"].astype(np.float32)).to(device)
    y = torch.from_numpy(data["y_train"].astype(np.int64)).to(device)
    P = pool_matrix().to(device)
    tr = torch.from_numpy(tr_idx).to(device)
    bs = cfg["bs"]
    opt = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=0.0)
    spe = math.ceil(len(tr_idx) / bs); total = spe * epochs; step = 0
    if teacher is not None:
        teacher.eval()
    for ep in range(epochs):
        model.train()
        perm = torch.randperm(len(tr_idx), device=device)
        for b in range(spe):
            idx = tr[perm[b * bs:(b + 1) * bs]]
            if cfg["aug"] == "ishift":
                xb = ishift_pool_quant(imgs[idx], P, max_s=int(cfg.get("ish", 1)))
            elif cfg["aug"]:
                xb = augment_pool_quant(imgs[idx], P, rot=cfg["rot"], scale=cfg["scl"],
                                        trans=cfg["trans"])
            else:
                xb = xq[idx]
            yb = y[idx]
            cosine_lr(opt, lr, step, total, cfg["warm"] * spe)
            logits = model(xb)
            ce = F.cross_entropy(logits, yb, label_smoothing=0.05)
            if cfg["kd"] > 0 and teacher is not None:
                with torch.no_grad():
                    tl = teacher(xb)
                T = cfg["T"]
                kd = F.kl_div(F.log_softmax(logits / T, -1), F.softmax(tl / T, -1),
                              reduction="batchmean") * T * T
                loss = cfg["kd"] * kd + (1 - cfg["kd"]) * ce
            else:
                loss = ce
            opt.zero_grad(set_to_none=True); loss.backward(); opt.step(); step += 1
        if xv is not None and (ep + 1) % 20 == 0:
            print(f"  {tag} ep{ep+1}/{epochs}: fq-val {fq_val_acc(model, xv, yv):.4f}", flush=True)
    return model

def snap_pow2(model):
    """Switch to power-of-two requant: absorb scale sign into W1 latent rows, init the
    log2 param t from the free scale (fractional, so STE can settle to the best shift),
    and rescale the bias keeping the z=7.5 (mid-range) crossing fixed."""
    m, c = model.rq.fold()
    sign = np.where(m < 0, -1.0, 1.0)
    mm = np.abs(m).clip(1e-12)
    t = np.clip(-np.log2(mm), 0.0, 12.0)
    m2 = 2.0 ** (-np.round(t))
    c2 = 7.5 - m2 * (7.5 - c) / mm
    dev = model.l1.weight.device
    with torch.no_grad():
        model.l1.weight *= torch.from_numpy(sign).float().unsqueeze(1).to(dev)
    model.rq = RequantPow2(torch.from_numpy(t).float().to(dev),
                           torch.from_numpy(c2).float().to(dev)).to(dev)
    return model

# ---------------------------------------------------------------- folds + integer eval
def fold_shift(model):
    """Fold (a), shippable: h = clip((a1*sign + bias) >> k, 0, 15).
    +0.5 round-to-nearest baked into bias (hardware shift floors)."""
    assert isinstance(model.rq, RequantPow2)
    W1 = model.l1.ternary().detach().cpu().numpy().astype(np.int64)
    W2 = model.l2.ternary().detach().cpu().numpy().astype(np.int64)
    m, c = model.rq.fold()                       # m = 2^-k exact, c on the shift grid
    k = np.round(-np.log2(m)).astype(np.int64)
    assert np.allclose(m, 2.0 ** (-k.astype(np.float64)))
    bias = np.round((c + 0.5) * (2.0 ** k)).astype(np.int64)
    b2 = np.round(model.b2.detach().cpu().double().numpy()).astype(np.int64)
    return dict(kind="shift", W1=W1, W2=W2, sign=np.ones_like(k), k=k, bias=bias, b2=b2)

def fold_fixed(model, FR=FR_BITS):
    """Fold (b), upper reference: h = clip((a1*A + B) >> FR, 0, 15)."""
    W1 = model.l1.ternary().detach().cpu().numpy().astype(np.int64)
    W2 = model.l2.ternary().detach().cpu().numpy().astype(np.int64)
    m, c = model.rq.fold()
    A = np.round(m * (1 << FR)).astype(np.int64)
    B = np.round((c + 0.5) * (1 << FR)).astype(np.int64)
    b2 = np.round(model.b2.detach().cpu().double().numpy()).astype(np.int64)
    return dict(kind="fixed", W1=W1, W2=W2, A=A, bias=B, FR=np.int64(FR), b2=b2)

def int_forward(x, f):
    """Pure integer inference. x: (N,64) ints 0..15."""
    x = x.astype(np.int64)
    assert x.min() >= 0 and x.max() <= 15
    for W in (f["W1"], f["W2"]):
        assert np.isin(W, (-1, 0, 1)).all(), "weights must be ternary"
    a1 = x @ f["W1"].T                                   # int64, |a1| <= 960
    if f["kind"] == "shift":
        t = a1 * f["sign"][None, :] + f["bias"][None, :]
        h = np.clip(t >> f["k"][None, :], 0, 15)         # arithmetic shift floors
    else:
        t = a1 * f["A"][None, :] + f["bias"][None, :]
        h = np.clip(t >> int(f["FR"]), 0, 15)
    assert h.min() >= 0 and h.max() <= 15
    logits = h @ f["W2"].T + f["b2"][None, :]
    return logits.argmax(1)                              # tie-break: lowest class index

def int_acc(x, y, f):
    return float((int_forward(x, f) == y.astype(np.int64)).mean())

# ---------------------------------------------------------------- experiments
def student_run(H, seed, cfg, data, teacher, tr_idx, va_idx, device, tag=""):
    torch.manual_seed(seed); np.random.seed(seed)
    xv = torch.from_numpy(data["x_train"][va_idx].astype(np.float32)).to(device)
    yv = torch.from_numpy(data["y_train"][va_idx].astype(np.int64)).to(device)
    model = TernaryMLP(H, thr=cfg["thr"], drop=cfg["drop"]).to(device)
    t0 = time.time()
    run_epochs(model, teacher, data, tr_idx, cfg, cfg["epochs1"], cfg["lr"],
               device, xv, yv, tag=f"{tag}p1")
    fb = fold_fixed(model)
    xva = data["x_train"][va_idx]; yva = data["y_train"][va_idx]
    acc_b = int_acc(xva, yva, fb)
    snap_pow2(model)
    run_epochs(model, teacher, data, tr_idx, cfg, cfg["epochs2"], cfg["lr"] / 3,
               device, xv, yv, tag=f"{tag}p2")
    fa = fold_shift(model)
    acc_a = int_acc(xva, yva, fa)
    fb2 = fold_fixed(model)          # fold(b) of the pow2 model, sanity only
    acc_b2 = int_acc(xva, yva, fb2)
    # fake-quant vs integer agreement (sanity, not selection)
    model.eval()
    with torch.no_grad():
        pfq = model(xv).argmax(1).cpu().numpy()
    agree = float((pfq == int_forward(xva, fa)).mean())
    dt = time.time() - t0
    print(f"[{tag}] H={H} seed={seed}  val int: fold_b(P1)={acc_b:.4f}  "
          f"fold_a(P2)={acc_a:.4f}  fold_b(P2)={acc_b2:.4f}  fq/int agree={agree:.4f}  ({dt:.0f}s)",
          flush=True)
    return dict(model=model, fold_a=fa, fold_b=fb, acc_a=acc_a, acc_b=acc_b)

def stage_sweep(device):
    data = get_data()
    tr_idx, va_idx = split_train(5000)
    teacher = train_teacher(5000, device=device)
    base = dict(RECIPE)
    variants = [
        ("base",   {}),
        ("no_kd",  {"kd": 0.0}),
        ("no_aug", {"aug": False}),
        ("thr1.4", {"thr": 1.4}),
        ("drop05", {"drop": 0.05}),
        ("base_s1", {"_seed": 1}),
    ]
    results = {}
    for name, over in variants:
        cfg = dict(base); seed = over.pop("_seed", 0); cfg.update(over)
        r = student_run(32, seed, cfg, data, teacher, tr_idx, va_idx, device, tag=name + " ")
        results[name] = dict(acc_a=r["acc_a"], acc_b=r["acc_b"])
        with open(os.path.join(RUNS, "sweep.json"), "w") as fh:
            json.dump(results, fh, indent=2)
    print(json.dumps(results, indent=2))

def stage_finals(device, only_H=None):
    data = get_data()
    n_val = 2000
    tr_idx, va_idx = split_train(n_val)
    teacher = train_teacher(n_val, device=device)
    summary = {}
    for H in (16, 32, 64):
        if only_H is not None and H != only_H:
            continue
        best = None
        for seed in RECIPE["seeds"]:
            r = student_run(H, seed, RECIPE, data, teacher, tr_idx, va_idx,
                            device, tag=f"H{H}s{seed} ")
            if best is None or (r["acc_a"], r["acc_b"]) > (best["acc_a"], best["acc_b"]):
                best = r; best["seed"] = seed
        fa, fb = best["fold_a"], best["fold_b"]
        np.savez(os.path.join(ART, f"H{H}_fold_a_shift.npz"),
                 **{k: v for k, v in fa.items() if k != "kind"})
        np.savez(os.path.join(ART, f"H{H}_fold_b_fixed.npz"),
                 **{k: v for k, v in fb.items() if k != "kind"})
        summary[f"H{H}"] = dict(seed=int(best["seed"]),
                                val_acc_shift=best["acc_a"], val_acc_fixed=best["acc_b"])
        with open(os.path.join(ART, f"selection_H{H}.json"), "w") as fh:
            json.dump(summary[f"H{H}"], fh, indent=2)
    print(json.dumps(summary, indent=2))

def load_fold(path, kind):
    z = np.load(path)
    d = {k: z[k] for k in z.files}; d["kind"] = kind
    return d

def stage_report():
    data = get_data()
    xt, yt = data["x_test"], data["y_test"]
    assert xt.shape == (10000, 64)
    base = {16: 0.804, 32: 0.854, 64: 0.895}
    print("\nEXACT-INTEGER accuracy, full 10,000-image MNIST test set")
    print(f"{'H':>4} {'fold(a) shift-only':>20} {'fold(b) fixed-point':>20} {'baseline(a)':>12}")
    table = {}
    for H in (16, 32, 64):
        fa = load_fold(os.path.join(ART, f"H{H}_fold_a_shift.npz"), "shift")
        fb = load_fold(os.path.join(ART, f"H{H}_fold_b_fixed.npz"), "fixed")
        aa, ab = int_acc(xt, yt, fa), int_acc(xt, yt, fb)
        table[f"H{H}"] = dict(shift=aa, fixed=ab)
        print(f"{H:>4} {aa*100:>19.2f}% {ab*100:>19.2f}% {base[H]*100:>11.1f}%")
    with open(os.path.join(ART, "test_results.json"), "w") as fh:
        json.dump(table, fh, indent=2)

def stage_selftest():
    b = pool_bins()
    print("pooling bins:", b)
    assert b == [(0, 4), (3, 7), (7, 11), (10, 14), (14, 18), (17, 21), (21, 25), (24, 28)], b
    assert np.right_shift(np.int64(-5), 1) == -3, "shift must floor"
    assert (np.array([-5], np.int64) >> 1)[0] == -3
    d = get_data()
    print("x_train", d["x_train"].shape, d["x_train"].dtype,
          "min", d["x_train"].min(), "max", d["x_train"].max())
    print("x_test ", d["x_test"].shape, "label counts", np.bincount(d["y_test"]))
    print("selftest OK")

def stage_probe(args, device):
    """One-off validation run (55k/5k split) with recipe overrides — HP search only."""
    data = get_data()
    tr_idx, va_idx = split_train(5000)
    teacher = train_teacher(5000, device=device)
    cfg = dict(RECIPE)
    for f in ("kd", "T", "thr", "drop", "rot", "trans", "scl", "lr"):
        v = getattr(args, f)
        if v is not None: cfg[f] = v
    for f in ("epochs1", "epochs2"):
        v = getattr(args, f)
        if v is not None: cfg[f] = v
    if args.noaug: cfg["aug"] = False
    if args.ishift is not None: cfg["aug"] = "ishift"; cfg["ish"] = args.ishift
    if args.H is None or args.name is None:
        raise SystemExit("probe needs --H and --name")
    r = student_run(args.H, args.seed, cfg, data, teacher, tr_idx, va_idx,
                    device, tag=args.name + " ")
    print(json.dumps({args.name: dict(acc_a=r["acc_a"], acc_b=r["acc_b"])}))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stage", choices=["selftest", "data", "teacher", "sweep",
                                      "probe", "finals", "report", "all"])
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--name"); ap.add_argument("--H", type=int)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--noaug", action="store_true")
    ap.add_argument("--ishift", type=int, default=None)
    ap.add_argument("--epochs1", type=int, default=None)
    ap.add_argument("--epochs2", type=int, default=None)
    for f in ("kd", "T", "thr", "drop", "rot", "trans", "scl", "lr"):
        ap.add_argument(f"--{f}", type=float, default=None)
    args = ap.parse_args()
    torch.set_num_threads(args.threads)
    if args.stage == "selftest": stage_selftest()
    elif args.stage == "data": get_data()
    elif args.stage == "teacher":
        train_teacher(5000, device=args.device); train_teacher(2000, device=args.device)
    elif args.stage == "sweep": stage_sweep(args.device)
    elif args.stage == "probe": stage_probe(args, args.device)
    elif args.stage == "finals": stage_finals(args.device, only_H=args.H)
    elif args.stage == "report": stage_report()
    elif args.stage == "all":
        get_data(); train_teacher(2000, device=args.device)
        stage_finals(args.device); stage_report()

if __name__ == "__main__":
    main()
