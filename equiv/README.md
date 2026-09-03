# equiv/ -- the gate

Everything on the `clutchfactor` branch has to be shown behaviour-identical to the
baseline that was green on `origin/main` (commit `b5939b8`), except for the commits
that deliberately change behaviour. These scripts are that gate.

| script | what it checks | how |
|---|---|---|
| `get_base.sh [ref]` | materialises `base_src/` from a git ref (default `b5939b8`) | `git checkout <ref> -- src` into a scratch tree |
| `run_diff.sh` | 6a: whole-chip differential simulation | `tb_equiv.v` drives only the TT pins, ~2.09 M cycles, fixed seed; the two per-cycle traces must be byte-identical |
| `formal.sh [base] [cand] [mod...]` | 6b: per-module formal equivalence | yosys `equiv_make` miter + `equiv_simple` + `equiv_induct`; prints PROVEN / UNPROVEN per module |
| `formal_project.sh <mod> <base> <cand> <port...>` | a module that gained output ports | demotes them in the candidate (`delete -output`) and proves every original port identical |
| `formal_wrap.sh <wrapper.v> <top> <base> <cand>` | equivalence through a wrapper (`wrappers/`) | mask an output meant to differ, or tie an input to a constant; `BLACKLIST=` excludes internal nets from matching |
| `diff_explain.py <base.txt> <cand.txt>` | explain a trace mismatch | which DFT view and which `uo_out` bits differ, over which cycles |
| `strip_comments.py <dirA> <dirB>` | comment-only commits | code-only diff; exit 1 if any code differs |
| `synth.sh <src> <log>` | 6c: synthesis parity | flattened yosys synth to sky130_fd_sc_hd, cell count and liberty area; `ABC_D=<ps>` adds an abc delay target |
| `run_lint.sh <src>`, `lint_summary.sh <log>` | 6d: lint parity | `verilator --lint-only -Wall`; the summariser strips paths and line numbers so two logs diff cleanly |

| `model/run_model_check.py [N] [src]` | the arithmetic against a SECOND implementation | generates N images, predicts each with `model/cc_model.py`, runs the same images through the TT pins with `model/tb_model.v`, compares answer and exit_k |

The existing cocotb suite (6e) is `cd test && make` with cocotb 2.0.1 on Python 3.12.

## `model/` -- the only check here that is not self-referential

Everything else in `equiv/` proves the candidate matches `origin/main`. None of it can
tell you `origin/main` is right. `model/cc_model.py` is an independent implementation of
the datapath, written from the ROM contents and the RTL's stated conventions rather than
from its structure: Horner accumulation, the 10-bit truncated requant, the L2 MAC, the
tournament tree and the checkpoint schedule.

```bash
cd equiv/model && ./run_model_check.py 1000            # against ../../src
cd equiv/model && ./run_model_check.py 1000 ../base_src
```

Result on this branch and on `origin/main`: 1000 of 1000 images agree on both the answer
and the exit checkpoint. Injected-fault results, to show the check is not vacuous:

| injected fault | mismatching images, of 200 |
|---|---|
| `max2_node` `>=` to `>`, the tie-break | 1 |
| `l2_mac_x4` W2 pair order swapped | 144 |
| `requant_unit` `t >>> k` to `>>` | 189 |
| `l1_horner_acc`/`_cnt` doubling removed | 129 |
| `ckpt_block` `bias_ext >>> bias_sh` to `>>` | 0, see below |

The last one is not a gap in the model. That mutation is unobservable at the pins by any
means: the difference is a multiple of 1024 and `requant_unit` truncates to 10 bits, so
the differential harness also reports 0 differing cycles over 2,085,356 cycles. The shift
stays arithmetic because it is correct, not because a test forces it.

What this does NOT establish: that the trained network classifies digits well. It checks
that the silicon computes what the weights say it should. The 10,000-image reference gate
in the private repository remains the only check of accuracy.

```bash
cd equiv
./get_base.sh                      # once
./run_diff.sh                      # prints EQUIVALENT or the first differing cycles
./formal.sh                        # all 21 modules
./synth.sh base_src out/a.log; ./synth.sh ../src out/b.log
./run_lint.sh base_src > out/lint_a.log; ./run_lint.sh ../src > out/lint_b.log
```

`wrappers/` holds the wrappers used on this branch: `tt_mask_view2_bit3.v` (P3a proven
with view 2 bit 3 masked; its `.blacklist` names the pre-mask nets) and
`top_fsm_ncap<n>.v` (P3b proven unchanged for every `n_cap` but 1..3).

`synth.sh` needs a sky130_fd_sc_hd liberty file; point `LIB=` at one. The numbers are
only meaningful as a delta between two trees run with the same liberty.

Expected properties of a correct `run_diff.sh` on the baseline: 2,085,356 cycles,
48 distinct `uo_out` values, and every `x` in the trace at DFT view 1 (`cycle % 4 == 1`),
which is the config-readback defect on `main`. An `x` at any other view is a regression.
