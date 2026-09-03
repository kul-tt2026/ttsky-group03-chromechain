#!/usr/bin/env python3
"""Cross-check the RTL against the independent model in cc_model.py.

Generates images, predicts each with the model, runs the same images through the DUT's
TT pins with tb_model.v, and compares (answer, exit_k). A mismatch means the RTL and a
second implementation of the same weights disagree, which no other check in equiv/ can
detect: the differential and formal gates only prove the candidate matches origin/main.

  usage: ./run_model_check.py [N] [src_dir]
"""
import os, random, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cc_model as M

HERE = os.path.dirname(os.path.abspath(__file__))
SRCS = """tt_um_kul_chromechain cc_top top_fsm blob_loader w1_rom_final4 ckpt_block
bitplane_buffer popcount active_pixel_scan l1_horner_acc l1_horner_cnt l1_acc_shadow
l1_acc_shadow_cg checkpoint_ctrl requant_rom_x4 l2_weight_rom_x4 config_latch
requant_unit l2_mac_x4 max2_node exit_tree_2stage""".split()

def make_images(n, rng):
    """A deliberate mix: uniform random stresses the accumulator hardest, sparse and
    structured images look more like the digits the chip is for."""
    imgs = []
    for i in range(n):
        kind = i % 4
        if kind == 0:                                   # uniform random 4-bit pixels
            pix = [rng.randrange(16) for _ in range(64)]
        elif kind == 1:                                 # sparse, a few bright pixels
            pix = [0] * 64
            for _ in range(rng.randrange(3, 14)):
                pix[rng.randrange(64)] = rng.randrange(8, 16)
        elif kind == 2:                                 # strokes, digit-like
            pix = [0] * 64
            for _ in range(rng.randrange(2, 5)):
                r, c, ln = rng.randrange(8), rng.randrange(8), rng.randrange(2, 6)
                for d in range(ln):
                    rr, cc = (r + d, c) if rng.random() < .5 else (r, c + d)
                    if rr < 8 and cc < 8:
                        pix[8 * rr + cc] = rng.randrange(9, 16)
        else:                                           # extremes: saturated / empty-ish
            pix = [rng.choice([0, 0, 15]) for _ in range(64)]
        imgs.append(M.planes_from_pixels(pix))
    return imgs

def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    src = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, '..', '..', 'src')
    src = os.path.abspath(src)

    rng = random.Random(20260903)                       # fixed: reruns are comparable
    imgs = make_images(n, rng)

    w1, w2, tk, b2 = M.load_all()
    expect = [M.classify(list(p), w1, w2, tk, b2) for p in imgs]

    # keep the path short: the testbench reads it into a fixed-width reg
    base = os.environ.get('CC_TMP', '/tmp')
    tmp = tempfile.mkdtemp(prefix='ccm_', dir=base)
    imgf = os.path.join(tmp, 'images.txt')
    with open(imgf, 'w') as f:
        for p in imgs:
            f.write(' '.join(f'{x:016x}' for x in p) + '\n')

    vvp = os.path.join(tmp, 'm.vvp')
    cmd = ['iverilog', '-g2005', '-I', src, '-o', vvp, '-s', 'tb_model',
           os.path.join(HERE, 'tb_model.v')] + [os.path.join(src, m + '.v') for m in SRCS]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        print(r.stderr); return 2
    r = subprocess.run(['vvp', vvp, f'+imgs={imgf}'], capture_output=True, text=True)

    got = {}
    for line in r.stdout.splitlines():
        if line.startswith('RESULT '):
            _, i, a, k = line.split()
            got[int(i)] = (int(a), int(k))
    if len(got) != n:
        print(f'FAIL: RTL produced {len(got)} results for {n} images')
        print(r.stdout[-2000:]); return 2

    bad = [(i, expect[i], got[i]) for i in range(n) if expect[i] != got[i]]
    ex = sum(1 for e in expect if e[1] != 0)
    print(f'{n} images, dense ordering, default blob')
    print(f'  model early exits: {ex} ({100*ex/n:.0f}%), final-plane answers: {n-ex}')
    print(f'  answer distribution (model): '
          + ', '.join(f'{d}:{sum(1 for e in expect if e[0]==d)}' for d in range(10)))
    if bad:
        print(f'  MISMATCHES: {len(bad)} of {n}')
        for i, e, g in bad[:10]:
            print(f'    image {i}: model {e}  RTL {g}  planes '
                  + ' '.join(f'{x:016x}' for x in imgs[i]))
        return 1
    print(f'  MATCH: all {n} images agree on answer and exit_k')
    return 0

if __name__ == '__main__':
    sys.exit(main())
