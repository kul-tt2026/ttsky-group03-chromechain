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

The existing cocotb suite (6e) is `cd test && make` with cocotb 2.0.1 on Python 3.12.

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
