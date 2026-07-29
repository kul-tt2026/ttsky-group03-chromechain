#!/usr/bin/env python3
"""
8-bit input quantization study for the ternary MNIST MLP.

Parameterizes the VERIFIED 4-bit pipeline along the two axes the study probes:
  QIN  : input pixel quantization max (15 = 4-bit, 255 = 8-bit)
  QMAX : hidden activation clip max  (15 = 4-bit, 31 = 5-bit, 63 = 6-bit)

Design invariant (enforced by the A7 bit-exact gate in stage1.py):
  at QIN=15, QMAX=15, req='pow2', the arithmetic here is IDENTICAL to
  ternary_tapeout.py + enlarged_train.py, and RNG consumption order matches,
  so folds reproduce bit-for-bit.

  - RequantBN init 4.0*(QMAX+1)/16, 3.0*(QMAX+1)/16  -> exactly 4.0, 3.0 at QMAX=15
  - snap midpoint QMAX/2.0                            -> exactly 7.5 at QMAX=15
  - floor_quant clamp to QMAX                         -> exactly 15 at QMAX=15
  - model __init__ draws l1 randn then l2 randn, as in tt.TernaryMLP
"""
import argparse, hashlib, json, math, os, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import ternary_tapeout as tt

CACHE = os.path.join(ROOT, "cache")
EB = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.join(EB, "runs"); os.makedirs(RUNS, exist_ok=True)

N_MNIST = 60000
VAL_SEL, VAL_CONF = 3000, 3000
SPLIT_SEED = 1234
SPE_ORIG = math.ceil(58000 / 512)          # 114
STEPS_P1 = 200 * SPE_ORIG                  # 22800
STEPS_P2 = 100 * SPE_ORIG                  # 11400
WARM = 3 * SPE_ORIG                        # 342
BS = 512
LR1, LR2 = 3e-3, 1e-3

# ---------------------------------------------------------------- data (per QIN)
def preprocess_q(imgs, QIN, chunk=20000):
    """(N,28,28) uint8 -> (N,64) ints 0..QIN.  Identical bins to tt.preprocess;
    only the output scale changes.  np.round = IEEE half-to-even, as in the baseline."""
    b = tt.pool_bins()
    N = imgs.shape[0]
    out = np.empty((N, 64), np.uint8 if QIN <= 255 else np.uint16)
    for s in range(0, N, chunk):
        e = min(N, s + chunk)
        f = imgs[s:e].astype(np.float64) / 255.0
        o = np.empty((e - s, 8, 8), np.float64)
        for i, (r0, r1) in enumerate(b):
            for j, (c0, c1) in enumerate(b):
                o[:, i, j] = f[:, r0:r1, c0:c1].mean(axis=(1, 2))
        out[s:e] = np.clip(np.round(o * float(QIN)), 0, QIN).astype(out.dtype).reshape(-1, 64)
    return out

def enl_path(QIN):     return os.path.join(CACHE, f"enlarged_q{QIN}.npz")
def tlogits_path(QIN): return os.path.join(CACHE, f"enlarged_teacher_logits_q{QIN}.npy")
def teacher_path(QIN): return os.path.join(CACHE, f"teacher_enlarged_q{QIN}.pt")

def build_cache(QIN):
    """Mirror enlarged_train.build_enlarged_cache exactly, at scale QIN."""
    p = enl_path(QIN)
    if os.path.exists(p):
        return
    z = np.load(os.path.join(CACHE, "xnist_guarded.npz"))
    x_raw = z["x"].reshape(-1, 28, 28); y = z["y"].astype(np.int64); series = z["series"]
    keep = series != 4                     # drop HSF-4 survivors -> ironclad guard (Piste 3)
    x_raw, y = x_raw[keep], y[keep]
    print(f"[q{QIN}] preprocessing {x_raw.shape[0]} guarded XNIST "
          f"(dropped {int((~keep).sum())} HSF-4) ...", flush=True)
    x_q = preprocess_q(x_raw, QIN)
    d = tt.get_data()
    mtr = preprocess_q(d["imgs_train"], QIN)
    x_big = np.concatenate([mtr, x_q], 0)
    y_big = np.concatenate([d["y_train"].astype(np.int64), y], 0)
    np.savez_compressed(p, x_train=x_big, y_train=y_big, n_mnist=np.int64(N_MNIST))
    print(f"[q{QIN}] wrote {p}: {x_big.shape}", flush=True)

def load_test(QIN):
    """8-bit test set is preprocessed from the raw idx.gz (imgs_test is not in the cache).
    Touched ONLY by the Stage-3 final evaluation."""
    p = os.path.join(CACHE, f"mnist_test_q{QIN}.npz")
    if not os.path.exists(p):
        tt.download()
        tei = tt.load_idx(os.path.join(tt.DATA, tt.FILES["test_images"]))
        tel = tt.load_idx(os.path.join(tt.DATA, tt.FILES["test_labels"]))
        assert tei.shape == (10000, 28, 28)
        np.savez_compressed(p, x_test=preprocess_q(tei, QIN), y_test=tel)
    z = np.load(p)
    return z["x_test"], z["y_test"]

def load_enlarged(QIN):
    z = np.load(enl_path(QIN))
    return z["x_train"], z["y_train"], int(z["n_mnist"])

def splits(n_total):
    rng = np.random.default_rng(SPLIT_SEED)
    perm = rng.permutation(N_MNIST)
    va = perm[:VAL_SEL + VAL_CONF]
    tr_mnist = perm[VAL_SEL + VAL_CONF:]
    tr = np.concatenate([tr_mnist, np.arange(N_MNIST, n_total)])
    return tr, va[:VAL_SEL], va[VAL_SEL:]

# ---------------------------------------------------------------- teacher (per QIN)
class TeacherQ(nn.Module):
    def __init__(self, QIN):
        super().__init__()
        self.QIN = float(QIN)
        self.net = nn.Sequential(
            nn.Linear(64, 512), nn.BatchNorm1d(512), nn.ReLU(), nn.Dropout(0.1),
            nn.Linear(512, 256), nn.BatchNorm1d(256), nn.ReLU(), nn.Dropout(0.1),
            nn.Linear(256, 10))
    def forward(self, x):
        return self.net(x / self.QIN - 0.5)

def train_teacher(QIN, device="cpu"):
    """Mirrors enlarged_train.train_enlarged_teacher; only the input scale changes."""
    if os.path.exists(tlogits_path(QIN)):
        return
    x, y, _ = load_enlarged(QIN)
    tr, va_sel, _ = splits(x.shape[0])
    xt = torch.from_numpy(x.astype(np.float32)); yt = torch.from_numpy(y)
    torch.manual_seed(7)
    t = TeacherQ(QIN).to(device)
    if os.path.exists(teacher_path(QIN)):
        t.load_state_dict(torch.load(teacher_path(QIN), map_location=device))
    else:
        opt = torch.optim.AdamW(t.parameters(), lr=1e-3, weight_decay=1e-4)
        steps = STEPS_P1; tr_t = torch.from_numpy(tr)
        perm = torch.randperm(len(tr)); pos = 0
        t.train()
        for step in range(steps):
            if pos + BS > len(tr): perm = torch.randperm(len(tr)); pos = 0
            idx = tr_t[perm[pos:pos + BS]]; pos += BS
            tt.cosine_lr(opt, 1e-3, step, steps, WARM)
            loss = F.cross_entropy(t(xt[idx].to(device)), yt[idx].to(device), label_smoothing=0.1)
            opt.zero_grad(set_to_none=True); loss.backward(); opt.step()
            if (step + 1) % 6000 == 0:
                t.eval()
                with torch.no_grad():
                    acc = (t(xt[torch.from_numpy(va_sel)]).argmax(1) == yt[torch.from_numpy(va_sel)]
                           ).float().mean().item()
                print(f"  [q{QIN}] teacher step {step+1}/{steps}: val_sel {acc:.4f}", flush=True)
                t.train()
        torch.save(t.state_dict(), teacher_path(QIN))
    t.eval()
    out = np.empty((x.shape[0], 10), np.float32)
    with torch.no_grad():
        for i in range(0, x.shape[0], 8192):
            out[i:i + 8192] = t(xt[i:i + 8192].to(device)).cpu().numpy()
    np.save(tlogits_path(QIN), out)
    acc = float((out[va_sel].argmax(1) == y[va_sel]).mean())
    print(f"[q{QIN}] teacher val_sel {acc:.4f} -> {tlogits_path(QIN)}", flush=True)

# ---------------------------------------------------------------- model
def floor_quant_ste(z, qmax):
    """h = clip(floor(z+0.5), 0, qmax); STE through clip(z,0,qmax).
    qmax is a scalar, or a per-unit tensor for the learned-clip variant.
    The scalar branch is written to be byte-identical to tt.floor_quant_ste."""
    if torch.is_tensor(qmax):
        zc = torch.minimum(torch.clamp(z, min=0.0), qmax)
        h = torch.minimum(torch.clamp(torch.floor(z + 0.5), min=0.0), qmax)
    else:
        zc = torch.clamp(z, 0, qmax)
        h = torch.clamp(torch.floor(z + 0.5), 0, qmax)
    return zc + (h - zc).detach()

class RequantBN(nn.Module):
    """Phase 1: free per-unit affine (BN) then floor-quant to [0,QMAX] with STE."""
    def __init__(self, H, QMAX):
        super().__init__()
        self.QMAX = QMAX
        self.bn = nn.BatchNorm1d(H)
        nn.init.constant_(self.bn.weight, 4.0 * (QMAX + 1) / 16.0)
        nn.init.constant_(self.bn.bias, 3.0 * (QMAX + 1) / 16.0)
    def forward(self, a1):
        return floor_quant_ste(self.bn(a1), self.QMAX)
    def fold(self):
        w, b = self.bn.weight, self.bn.bias
        mu, var = self.bn.running_mean, self.bn.running_var
        s = torch.sqrt(var + self.bn.eps)
        m = (w / s).detach().cpu().double().numpy()
        c = (b - mu * w / s).detach().cpu().double().numpy()
        return m, c

class RequantPow2(nn.Module):
    """Phase 2: per-unit scale 2^-round(t), STE on log2 param t so units migrate between
    shifts; bias quantized to the shift grid. Bit-exact hardware forward:
        h = clip(floor(a1*2^-k + c + 0.5), 0, U)  ==  clip((a1 + B) >> k, 0, U)
    learn_clip=True additionally learns a per-unit integer upper bound U in [1, QMAX]."""
    def __init__(self, t, c, QMAX, kmin=0, kmax=12, learn_clip=False):
        super().__init__()
        self.t = nn.Parameter(t.float())
        self.c = nn.Parameter(c.float())
        self.QMAX, self.kmin, self.kmax = QMAX, kmin, kmax
        self.learn_clip = learn_clip
        if learn_clip:
            self.u = nn.Parameter(torch.full_like(t.float(), float(QMAX)))
    def _qmax(self):
        if not self.learn_clip:
            return self.QMAX
        uc = self.u.clamp(1.0, float(self.QMAX))
        return uc + (torch.round(uc) - uc).detach()
    def forward(self, a1):
        t = self.t.clamp(self.kmin, self.kmax)
        k = torch.round(t)
        scale_s = torch.pow(2.0, -t)
        scale = scale_s + (torch.pow(2.0, -k) - scale_s).detach()
        step = torch.pow(2.0, -k).detach()
        cq = self.c + (torch.round((self.c + 0.5) / step) * step - 0.5 - self.c).detach()
        return floor_quant_ste(a1 * scale + cq, self._qmax())
    def fold(self):
        k = torch.round(self.t.clamp(self.kmin, self.kmax)).detach().cpu().double().numpy()
        m = 2.0 ** (-k)
        c = self.c.detach().cpu().double().numpy()
        return m, np.round((c + 0.5) / m) * m - 0.5
    def qmax_vec(self, H):
        if not self.learn_clip:
            return np.full(H, self.QMAX, np.int64)
        return np.round(self.u.detach().cpu().double().numpy().clip(1, self.QMAX)).astype(np.int64)

class TernaryMLP(nn.Module):
    """RNG draw order matches tt.TernaryMLP exactly: l1 randn, then l2 randn."""
    def __init__(self, H, QMAX, thr=1.0):
        super().__init__()
        self.QMAX = QMAX
        self.l1 = tt.TernaryLinear(64, H, thr)
        self.rq = RequantBN(H, QMAX)
        self.drop = nn.Identity()
        self.l2 = tt.TernaryLinear(H, 10, thr)
        self.b2 = nn.Parameter(torch.zeros(10))
        self.log_g = nn.Parameter(torch.tensor(math.log(0.125)))
    def forward(self, x):
        h = self.drop(self.rq(self.l1(x)))
        b2 = self.b2 + (torch.round(self.b2) - self.b2).detach()
        return (self.l2(h) + b2) * self.log_g.exp()

def snap_pow2(model, kmin=0, kmax=12, learn_clip=False):
    """Absorb scale sign into W1 rows, init log2 param t from the free scale, rescale bias
    keeping the mid-range (QMAX/2) crossing fixed."""
    m, c = model.rq.fold()
    mid = model.QMAX / 2.0
    sign = np.where(m < 0, -1.0, 1.0)
    mm = np.abs(m).clip(1e-12)
    t = np.clip(-np.log2(mm), float(kmin), float(kmax))
    m2 = 2.0 ** (-np.round(t))
    c2 = mid - m2 * (mid - c) / mm
    dev = model.l1.weight.device
    with torch.no_grad():
        model.l1.weight *= torch.from_numpy(sign).float().unsqueeze(1).to(dev)
    model.rq = RequantPow2(torch.from_numpy(t).float().to(dev),
                           torch.from_numpy(c2).float().to(dev),
                           model.QMAX, kmin, kmax, learn_clip).to(dev)
    return model

# ---------------------------------------------------------------- folds
def fold_shift(model):
    """Fold (a), shippable: h = clip((a1 + bias) >> k, 0, qmax_j)."""
    assert isinstance(model.rq, RequantPow2)
    W1 = model.l1.ternary().detach().cpu().numpy().astype(np.int64)
    W2 = model.l2.ternary().detach().cpu().numpy().astype(np.int64)
    m, c = model.rq.fold()
    k = np.round(-np.log2(m)).astype(np.int64)
    assert np.allclose(m, 2.0 ** (-k.astype(np.float64)))
    bias = np.round((c + 0.5) * (2.0 ** k)).astype(np.int64)
    b2 = np.round(model.b2.detach().cpu().double().numpy()).astype(np.int64)
    return dict(kind="shift", W1=W1, W2=W2, sign=np.ones_like(k), k=k, bias=bias, b2=b2,
                qmax=model.rq.qmax_vec(W1.shape[0]))

def fold_fixed(model, FR=tt.FR_BITS):
    """Fold (b), upper reference: h = clip((a1*A + B) >> FR, 0, qmax_j)."""
    W1 = model.l1.ternary().detach().cpu().numpy().astype(np.int64)
    W2 = model.l2.ternary().detach().cpu().numpy().astype(np.int64)
    m, c = model.rq.fold()
    A = np.round(m * (1 << FR)).astype(np.int64)
    B = np.round((c + 0.5) * (1 << FR)).astype(np.int64)
    b2 = np.round(model.b2.detach().cpu().double().numpy()).astype(np.int64)
    qm = model.rq.qmax_vec(W1.shape[0]) if isinstance(model.rq, RequantPow2) \
         else np.full(W1.shape[0], model.QMAX, np.int64)
    return dict(kind="fixed", W1=W1, W2=W2, A=A, bias=B, FR=np.int64(FR), b2=b2, qmax=qm)

def int_forward(x, f, QIN, diag=None):
    """Pure integer inference. x: (N,64) ints 0..QIN."""
    x = x.astype(np.int64)
    assert x.min() >= 0 and x.max() <= QIN, "input out of declared range"
    for W in (f["W1"], f["W2"]):
        assert np.isin(W, (-1, 0, 1)).all(), "weights must be ternary"
    a1 = x @ f["W1"].T
    if f["kind"] == "shift":
        t = a1 * f["sign"][None, :] + f["bias"][None, :]
        h = t >> f["k"][None, :]
    else:
        t = a1 * f["A"][None, :] + f["bias"][None, :]
        h = t >> int(f["FR"])
    qm = f["qmax"][None, :]
    hc = np.clip(h, 0, qm)
    logits = hc @ f["W2"].T + f["b2"][None, :]
    if diag is not None:
        diag.update(
            a1_min=int(a1.min()), a1_max=int(a1.max()),
            a1_bits=int(math.ceil(math.log2(max(1, max(abs(int(a1.min())), int(a1.max()))) + 1)) + 1),
            preclip_min=int(t.min()), preclip_max=int(t.max()),
            pct_at_zero=float((h <= 0).mean()), pct_at_qmax=float((h >= qm).mean()),
            pct_clipped_low=float((h < 0).mean()), pct_clipped_high=float((h > qm).mean()),
            h_max_used=int(hc.max()),
            a2_min=int(logits.min()), a2_max=int(logits.max()),
            a2_bits=int(math.ceil(math.log2(max(1, max(abs(int(logits.min())), int(logits.max()))) + 1)) + 1),
            bias_absmax=int(np.abs(f["bias"]).max()),
            k_dist=np.bincount(f["k"], minlength=16).tolist() if f["kind"] == "shift" else None,
            qmax_dist=np.bincount(f["qmax"], minlength=int(f["qmax"].max()) + 1).tolist(),
        )
    return logits.argmax(1)

def int_acc(x, y, f, QIN, diag=None):
    return float((int_forward(x, f, QIN, diag) == y.astype(np.int64)).mean())

def fold_hash(f):
    h = hashlib.sha256()
    for k in sorted(f):
        if k == "kind": continue
        h.update(k.encode()); h.update(np.ascontiguousarray(f[k]).tobytes())
    return h.hexdigest()

# ---------------------------------------------------------------- training
def kd_alpha_at(step, total, cfg, phase):
    """Constant alpha, or the B9 curriculum. The curriculum is specified over the 200
    epochs of PHASE 1 (thirds: a0 -> a1 -> a2); phase 2 HOLDS the terminal value rather
    than restarting the schedule."""
    if not cfg.get("curriculum"):
        return cfg["kd"]
    a = cfg["curriculum"]
    if phase != "p1":
        return a[-1]
    p = step / max(1, total)
    return a[0] if p < 1/3 else (a[1] if p < 2/3 else a[2])

def run_steps(model, x, y, tlog, tr_m, tr_x, n_steps, lr, cfg, p_mnist, grad_log=None,
              phase="p1"):
    opt = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=0.0)
    tr_m = torch.from_numpy(tr_m); tr_x = torch.from_numpy(tr_x)
    n_m = min(BS, max(0, round(BS * p_mnist))); n_x = BS - n_m
    if len(tr_x) == 0: n_m, n_x = BS, 0
    T = cfg["T"]
    model.train()
    for step in range(n_steps):
        parts = []
        if n_m: parts.append(tr_m[torch.randint(len(tr_m), (n_m,))])
        if n_x: parts.append(tr_x[torch.randint(len(tr_x), (n_x,))])
        idx = torch.cat(parts)
        xb = x[idx]; yb = y[idx]; tb = tlog[idx]
        tt.cosine_lr(opt, lr, step, n_steps, WARM)
        logits = model(xb)
        ce = F.cross_entropy(logits, yb, label_smoothing=0.05)
        a = kd_alpha_at(step, n_steps, cfg, phase)
        if a > 0:
            kd = F.kl_div(F.log_softmax(logits / T, -1), F.softmax(tb / T, -1),
                          reduction="batchmean") * T * T
            loss = a * kd + (1 - a) * ce
        else:
            loss = ce
        opt.zero_grad(set_to_none=True); loss.backward()
        if grad_log is not None and step % 2000 == 0:
            gn = math.sqrt(sum(float((p.grad ** 2).sum()) for p in model.parameters()
                               if p.grad is not None))
            grad_log.append(round(gn, 5))
        opt.step()
    return model

def train_one(cfg, device="cpu"):
    QIN, QMAX, H, seed = cfg["QIN"], cfg["QMAX"], cfg["H"], cfg["seed"]
    x_np, y_np, _ = load_enlarged(QIN)
    tr, va_sel, va_conf = splits(x_np.shape[0])
    tr_m = tr[tr < N_MNIST]; tr_x = tr[tr >= N_MNIST]
    x = torch.from_numpy(x_np.astype(np.float32)); y = torch.from_numpy(y_np)
    tlog = torch.from_numpy(np.load(tlogits_path(QIN)))

    torch.manual_seed(seed); np.random.seed(seed)
    model = TernaryMLP(H, QMAX, thr=cfg.get("thr", 1.0)).to(device)
    t0 = time.time()
    glog = []
    run_steps(model, x, y, tlog, tr_m, tr_x, STEPS_P1, LR1, cfg, cfg["mix"], glog)

    fb1 = fold_fixed(model)                        # phase-1 free-scale reference
    d_b1 = {}
    acc_b1_sel = int_acc(x_np[va_sel], y_np[va_sel], fb1, QIN, d_b1)
    acc_b1_conf = int_acc(x_np[va_conf], y_np[va_conf], fb1, QIN)

    if cfg["req"] == "pow2":
        snap_pow2(model, cfg.get("kmin", 0), cfg.get("kmax", 12), cfg.get("learn_clip", False))
    elif cfg.get("learn_clip"):
        raise SystemExit("learn_clip requires req='pow2' (it lives on RequantPow2)")
    run_steps(model, x, y, tlog, tr_m, tr_x, STEPS_P2, LR2, cfg, cfg["mix"], glog, phase="p2")

    res = dict(cfg={k: v for k, v in cfg.items()}, secs=0.0, grad_norms=glog,
               acc_b1_sel=acc_b1_sel, acc_b1_conf=acc_b1_conf)

    if cfg["req"] == "pow2":
        fa = fold_shift(model); d_a = {}
        res["acc_a_sel"] = int_acc(x_np[va_sel], y_np[va_sel], fa, QIN, d_a)
        res["acc_a_conf"] = int_acc(x_np[va_conf], y_np[va_conf], fa, QIN)
        res["diag_shift"] = d_a
        res["hash_fold_a"] = fold_hash(fa)
        # fold (b) is the PHASE-1 free-scale network, per the published methodology.
        res["acc_b_sel"], res["acc_b_conf"] = acc_b1_sel, acc_b1_conf
        # fold_fixed of the phase-2 pow2 model: sanity only, never selection.
        fb2 = fold_fixed(model)
        res["acc_b2_sel"] = int_acc(x_np[va_sel], y_np[va_sel], fb2, QIN)
        res["acc_b2_conf"] = int_acc(x_np[va_conf], y_np[va_conf], fb2, QIN)
        res["hash_fold_b"] = fold_hash(fb1)
        model.eval()
        with torch.no_grad():
            pfq = model(x[torch.from_numpy(va_sel)]).argmax(1).numpy()
        res["fq_int_agree"] = float((pfq == int_forward(x_np[va_sel], fa, QIN)).mean())
        folds = dict(a=fa, b=fb1)
    else:
        # free-scale phase 2: the shippable shift fold does not exist; report fixed-point,
        # plus a NAIVE post-hoc pow2 snap (no fine-tune) to price the hardware gap honestly.
        fb2 = fold_fixed(model); d_b = {}
        res["acc_b_sel"] = int_acc(x_np[va_sel], y_np[va_sel], fb2, QIN, d_b)
        res["acc_b_conf"] = int_acc(x_np[va_conf], y_np[va_conf], fb2, QIN)
        res["diag_fixed"] = d_b
        snap_pow2(model, cfg.get("kmin", 0), cfg.get("kmax", 12), False)
        fa = fold_shift(model); d_a = {}
        res["acc_a_sel"] = int_acc(x_np[va_sel], y_np[va_sel], fa, QIN, d_a)
        res["acc_a_conf"] = int_acc(x_np[va_conf], y_np[va_conf], fa, QIN)
        res["acc_a_is_naive_snap"] = True
        res["diag_shift"] = d_a
        # fold (b) reported consistently with the pow2 arms = PHASE-1 free-scale network,
        # so cross-arm fold-(b) comparisons are not confounded by 100 extra epochs.
        res["acc_b2_sel"], res["acc_b2_conf"] = res["acc_b_sel"], res["acc_b_conf"]
        res["acc_b_sel"], res["acc_b_conf"] = acc_b1_sel, acc_b1_conf
        res["hash_fold_a"] = fold_hash(fa); res["hash_fold_b"] = fold_hash(fb2)
        folds = dict(a=fa, b=fb2)

    res["diag_p1"] = d_b1
    res["p1_to_p2_gap_sel"] = res["acc_a_sel"] - acc_b1_sel
    res["secs"] = round(time.time() - t0, 1)
    return res, folds

# ---------------------------------------------------------------- CLI
def cfg_from_args(a):
    cur = None
    if a.curriculum:
        cur = [float(v) for v in a.curriculum.split(",")]
    return dict(name=a.name, QIN=a.qin, QMAX=a.qmax, H=a.H, seed=a.seed, mix=a.mix,
                kd=a.kd, T=a.T, thr=a.thr, req=a.req, kmin=a.kmin, kmax=a.kmax,
                learn_clip=bool(a.learn_clip), curriculum=cur)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stage", choices=["setup", "run"])
    ap.add_argument("--name", default="run")
    ap.add_argument("--qin", type=int, default=15)
    ap.add_argument("--qmax", type=int, default=15)
    ap.add_argument("--H", type=int, default=32)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--mix", type=float, default=1.0)
    ap.add_argument("--kd", type=float, default=0.3)
    ap.add_argument("--T", type=float, default=4.0)
    ap.add_argument("--thr", type=float, default=1.0)
    ap.add_argument("--req", default="pow2", choices=["pow2", "free"])
    ap.add_argument("--kmin", type=int, default=0)
    ap.add_argument("--kmax", type=int, default=12)
    ap.add_argument("--learn_clip", type=int, default=0)
    ap.add_argument("--curriculum", default=None)
    ap.add_argument("--threads", type=int, default=1)
    ap.add_argument("--outdir", default=RUNS)
    a = ap.parse_args()
    torch.set_num_threads(a.threads)          # PISTE 2: pinned, non-negotiable
    if a.stage == "setup":
        build_cache(a.qin); train_teacher(a.qin)
        return
    cfg = cfg_from_args(a)
    res, folds = train_one(cfg)
    os.makedirs(a.outdir, exist_ok=True)
    stem = f"{a.name}_s{a.seed}"
    with open(os.path.join(a.outdir, f"{stem}.json"), "w") as fh:
        json.dump(res, fh)
    for tag, f in folds.items():
        # provenance: a fold is only meaningful against the input scale it was trained for.
        # tt.int_forward would silently mis-evaluate an 8-bit fold, so stamp the scale.
        np.savez(os.path.join(a.outdir, f"{stem}_fold_{tag}.npz"),
                 **{k: v for k, v in f.items() if k != "kind"},
                 _qin=np.int64(cfg["QIN"]), _qmax=np.int64(cfg["QMAX"]),
                 _req=np.str_(cfg["req"]), _kmax=np.int64(cfg["kmax"]))
    print(f"[{stem}] sel_a={res['acc_a_sel']:.4f} conf_a={res['acc_a_conf']:.4f} "
          f"sel_b={res['acc_b_sel']:.4f} conf_b={res['acc_b_conf']:.4f} ({res['secs']}s)",
          flush=True)

if __name__ == "__main__":
    main()
