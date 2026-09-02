# clutchfactor -- submission candidate for Chrome Chain (TTSKY26c)

Branch `clutchfactor` in `~/Documents/Projects/ttsky-clutchfactor`, cut from `origin/main`
at `b5939b8` (the green run: DRC 0, LVS 0, antenna 0, hold slack positive at every
corner). **Nothing has been pushed.** `main` and the three other worktrees are untouched.

## One screen

**What changed.** Every false statement in the comments, `info.yaml` and the datasheet
is corrected (P0, P0b, P0c). The decision archaeology in the RTL comments is replaced by
plain descriptions of what the code does and what breaks if it changes; every trap
warning from the brief is kept and several are sharpened (P1). `CLOCK_PERIOD` in
`src/config.json` now matches the declared 10 MHz (P2). Two safety fixes: the
post-DONE scanner drain is visible on DFT view 2 bit 3 (P3a), and an `N_cap` of 1..3 is
clamped and reported instead of hanging the chip silently (P3b). The cocotb suite grows
from 2 tests that never ran an image to 8 that run real images through the pins (P4).
CI no longer hardens a design whose RTL tests fail, and no longer passes when the test
produced no results file (P5). A P6 lint tidy was tried, measured and dropped (see
below). The gate that proves all of this lives in `equiv/`.

**What the gate says.** Every commit through P2 is bit-identical to `origin/main` on
every pin, every cycle, over the 2,085,356-cycle differential harness, and all 21
modules are formally proven equivalent. P3a differs on exactly one bit of one view and
nowhere else; with that bit masked the whole chip is formally proven identical. P3b
differs only inside the harness's `N_cap` 1..3 sweep, and `top_fsm` is formally proven
identical for every other `N_cap` value; outside that window the whole branch differs
from `main` on view 2 bit 3 and nothing else (25,654 cycles, 0 exceptions). Synthesis
area is unchanged through P2 and 0.2% smaller after P3; the lint warning set is
unchanged.

**What I would ship.** Everything on the branch. If one commit has to go, drop P3b
(`git revert 1ea14dc`): it is the only commit that changes what a host could observe
from a legal blob, and it is the last RTL change before the tests, so it reverts clean.

## The gate (`equiv/`)

| script | what it proves | how |
|---|---|---|
| `run_diff.sh` | 6a, whole chip | `tb_equiv.v` drives only the TT pins, fixed seed, 2,085,356 cycles; the two per-cycle traces must be byte-identical |
| `diff_explain.py` | for a deliberate change: which view and which bits differ, over which cycles | |
| `formal.sh` | 6b, per module | yosys `equiv_make` + `equiv_simple` + `equiv_induct -seq 4`; PROVEN means every matched net and output is proven |
| `formal_project.sh` | a module that gained an output port | demote the port (`delete -output`), prove every original port identical |
| `formal_wrap.sh` | equivalence through a wrapper | mask an output that is meant to differ, or tie an input to a constant |
| `synth.sh` | 6c | flattened yosys synth to sky130_fd_sc_hd, cell count and area (low-power cells excluded) |
| `run_lint.sh`, `lint_summary.sh` | 6d | `verilator --lint-only -Wall`, compared as (class, file, message) sets |
| `strip_comments.py` | comment-only commits | code-only diff; proves a comment change touched no code |

Baseline, measured locally on `b5939b8` (`get_base.sh` materialises it):

| measure | value |
|---|---|
| differential trace | 2,085,356 cycles, 48 distinct `uo_out` values, every `x` at DFT view 1 (521,262 cycles): the config-readback defect |
| formal, identical trees | 21/21 PROVEN |
| yosys synth (0.67, tt_025C_1v80 liberty) | 8,214 cells, 67,444.68 um2; sequential 24,843.83 um2: 1049 dfxtp_1, 128 edfxtp_1, 2 dlclkp_1 |
| verilator lint | 31 warnings: 3 PINCONNECTEMPTY, 19 UNUSEDSIGNAL, 1 VARHIDDEN, 4 WIDTHEXPAND, 4 WIDTHTRUNC |
| cocotb | 2/2 (cocotb 2.0.1 needs Python 3.12; it refuses to build on 3.14) |
| elaboration assertions | 18 in 7 files (the brief says 17): popcount 2, active_pixel_scan 3, blob_loader 2, config_latch 3, checkpoint_ctrl 2, bitplane_buffer 3, ckpt_block 3 |

Mutation evidence that the gate has teeth, re-measured here:

| injected fault | differential | formal |
|---|---|---|
| `max2_node` `>=` to `>` (trap 5) | 2,416 cycles, view 0 bits 0..2 | UNPROVEN, 53 nets |
| `requant_unit` `t >>> k` to `>>` (trap 4 as the brief states it) | 744,443 cycles | UNPROVEN |
| `ckpt_block` `bias_ext >>> bias_sh` to `>>` | **0 cycles** (see findings) | UNPROVEN, 10,036 nets |
| `blob_loader` `cnt_eff` removed | old suite 2/2 pass; new restart test fails on `blob_err` | -- |

## Commit series and evidence

Each commit was gated before it went on the branch. "code identical" is
`strip_comments.py` against the previous commit; "EQUIVALENT" is `run_diff.sh` against
`origin/main`; formal counts are against `origin/main` unless stated.

| commit | change | evidence |
|---|---|---|
| `cb0fe5f` `3a61319` `1d659ce` `c08c935` | the `equiv/` gate | validated on identical trees; catches the injected faults above |
| `d9ef466` **P0** | every false statement in section 3 of the brief, prose only | code identical; EQUIVALENT; formal 21/21; lint set unchanged; cocotb 2/2 |
| `1e21a6d` **P0b** | elaboration guard `W > 10` for `requant_unit`'s 10 b intermediate, inside `ifndef SYNTHESIS` | formal 21/21; EQUIVALENT; fires at `ACC_W = 11` ("FAIL W = 11 exceeds requant_unit's 10 b intermediate t") |
| `719a553` **P0c** | corrections the audit found (datasheet "4 classes per cycle", `exit_k` 0 not 4, 320 flops not 384, `ACC_CNT` ships at 1, spare bits `[47:43]`, `term_tree_p2`) | code identical; EQUIVALENT; formal 21/21 |
| `1e092ab` **P1** | comments: archaeology out, plain descriptions in, trap warnings kept; README rewritten; info.yaml loses a paragraph about another branch | code identical; EQUIVALENT; formal 21/21; synth 8,214 / 67,444.68 (identical); lint set unchanged; cocotb 2/2 |
| `a6f7cc2` **P2** | `CLOCK_PERIOD` 20 -> 100 ns | no RTL; see the P2 section |
| `a63bf43` **P3a** | `scan_busy` on DFT view 2 bit 3 | DIFFERS: 25,750 cycles, all at view 2 bit 3, nothing else; formal 20/21 (wrapper UNPROVEN by design); `cc_top` PROVEN with the new port demoted; whole chip PROVEN through `tt_mask_view2_bit3.v`; synth 8,230 / 67,332.08; lint unchanged; new drain test passes (50 cycles) |
| `1ea14dc` **P3b** | clamp and report every `N_cap` that is not 4 | DIFFERS vs P3a: 1,072 cycles, all inside the `N_cap` 1..3 sweep (cycles 21566..23350, 0 outside); formal 18/21 (`top_fsm`, `cc_top`, wrapper UNPROVEN by design); `top_fsm` PROVEN with `n_cap` tied to 0, 4, 5, 6, 7 and UNPROVEN for 1, 2, 3; synth 8,151 / 67,303.30; new `N_cap` test passes |
| `2df100a` **P4** | eight cocotb tests | 8/8 on the branch; the restart test fails with `cnt_eff` removed |
| `fe42391` **P5** | gds needs test; results.xml must exist and hold a testcase | YAML parses; job graph test -> gds -> {precheck, gl_test, viewer} |
| `3343aa5` **P4b** | datasheet describes the suite | docs only |
| (none) **P6** | tried: `cc_top` naming its unconsumed observation outputs in a `_unused_ok` reduction | EQUIVALENT vs P3b, formal 21/21, lint 31 -> 14, cocotb 8/8, **but** synth 8,155 / 67,790.02 vs 8,151 / 67,303.30: abc re-mapped around the extra RTLIL cell (flop counts identical, combinational cells reshuffled, +0.7% area). Zero functional value against a measurable, if noisy, growth: **dropped**, not on the branch |

### P0, P0b, P0c: corrections

Prose only, number never changed. The stale figures were `ACC_W` "11" or "12" and the
"690" bound (the reachable L1 range is -480..+420, decoded from `w1_rom_final4`; 10 b
signed holds it with 32 to spare); "24 of 32 bias values negative" (8); `ACC_BUS`
"384 b" (320); spare latch bits "[127:43]" ([47:43]); the four levers "default to v1"
(v1.1); five references to headings that do not exist; the datasheet's bring-up order
(START must precede the image), its "all zeros after reset" (0x20), its "L2 evaluates 4
classes per cycle" (4 hidden units, all 10 classes), its "exit_k 1 or 2 rather than 4"
(0 on a full run), and its view-1 description (undefined after a load); `info.yaml`'s
tile reasoning (now the real post-P&R numbers, tiles unchanged) and its "config loads
only while no image is running, enforced by K12" (nothing gates a config write on busy;
K12 is the opposite interlock). The three dead signals (`exit_k_held`, `page_sel`,
`ans_valid`) are remarked as such. P0b strengthens the one guard the brief singled out.

### P1: comments

Removed: area deltas, citations of files not in this repository (`run_synth.py`,
`tb_cc_top.v`, `w1_rom_synthesis/`, `l2_synthesis/results.md`, `DESIGN_LEDGER`,
`checkpoint_sim/`, `engine.py`, `verify.py`, `rom_gen.py`, `*.npz`, `docs/cc_*.md`),
ledger and ratification notes, dated notes, the v1 vs v1.1 lever narrative, the
commented-out page-2 ROM mux, and the non-existent macro names. Comment lines went from
582 to 578: several files gained lines because trap warnings were made explicit where
they used to be a bare tag ("I1", "I8").

Kept: all ten traps, each with a warning at its site that says what breaks. Also the
two `verilator lint_off/on` pragma pairs (functional comments) and the three GENERATED
notices. New statements were allowed only where verified against the code: the L2
accumulator range -255..+150 (decoded from `l2_weight_rom_x4`: at most 10 +1 and 17 -1
weights per class, b2 preload included), the exact `frame_err` conditions for the K11
strobe, when a wrong `acc_live` wiring would actually be observable (dense: only when
pixel 63 is set; zero-skip: whenever popcount >= 8), that `blob_done` must win over
`wr_en` on every complete load, and that nothing gates a config write on busy.

The rewrite was done per file by agents working from an audit map, mechanically checked
(code-only diff empty, pragma counts equal), then reviewed; where reviewers were lost to
the usage limit I reviewed the file myself. Every file was read in full before the
commit.

### P2: `CLOCK_PERIOD`

`src/config.json` asked for 20 ns while `info.yaml` declares 10 MHz and the critical
path is about 27 ns. Before, on the green run: setup slack -5.80 ns at ss_100C_1v60,
TNS -1461 ns, 2,281 violating paths, 1,208 timing-repair buffers (~10,600 um2, 7% of the
core), hold slack +0.10 ns. After: **not measurable here.** The buffers come from
OpenROAD's timing repair, not from yosys: the local yosys mapping is identical at an abc
delay target of 20 and of 100 ns (8,214 cells either way), so section 6c cannot see this
change. The expected effect is zero setup violations at 100 ns (4x margin on the 27 ns
path) and most of the 1,208 buffers gone; hold repair is independent of the period and
should stay positive. Read the actual numbers from the gds workflow run after the push
(`runs/wokwi/reports/` in the artifact: `synth_stat`, the STA summary, and the
resizer's buffer count) and record them here before deciding on `main`.

### P3a: the drain, made visible

`active_pixel_scan` has no abort, so after an early exit the plane it is on runs to its
end, up to 52 cycles after `busy` falls; a START inside that window scans the next
image's first plane before it is loaded (`scan_err`). `cc_top` now exports `scan_busy`
and the wrapper muxes it into view 2 bit 3, which was a hardwired 0. No pin or pinout
change. The differential shows 25,750 differing cycles, every one at view 2 bit 3, over
the whole trace (first at cycle 62, last at 2,082,322); no `x` moved. The whole chip is
formally proven identical through a wrapper that forces that bit to 0
(`equiv/wrappers/tt_mask_view2_bit3.v`, with the pre-mask nets blacklisted). The cell
count moved by +16 because that mux input is now a real net and abc re-mapped around it.

### P3b: `N_cap`

`checkpoint_ctrl` waits for the fourth plane boundary unconditionally, so on `main` an
`N_cap` of 1..3 stopped the frame short of it: busy high forever, no DONE, no alarm.
The fix extends the existing clamp-and-report policy (which `main` already applies to 0
and 5..7) to those values: one condition in `top_fsm.v`, `cap_bad = cap_raw != PLANE_MAX`.
A blob with `N_cap` 2 now raises `cap_err` and `ERR` at START and the chip runs four
planes. If the host then feeds only two, it sees the same underrun alarms it would see
today with `N_cap` 0. That is what the 1,072 differing cycles are: `ERR` and `cap_err`
(431 cycles), then busy, answer, `exit_k`, `scan_busy`, `scan_err` and `frame_err` as
the clamped chip proceeds; all inside cycles 21566..23350, the harness's `N_cap` 1..3
entries. `top_fsm` is formally identical to `main` for `n_cap` tied to 0, 4, 5, 6 or 7.

### P4, P5, P6

P4's expected values were measured on the `b5939b8` RTL with the harness's host
protocol, so they pin the shipped behaviour rather than a model; there are no golden
vectors in this repository. The host drives and samples on the falling edge and a
watcher catches the one-cycle DONE pulse, which for a checkpoint-2 exit lands while
plane 4's last beat is still going in. P5 is two mechanisms: `workflow_call` on
`test.yaml` with `needs: test` on the gds job, and a results-file existence check.
P6 was the only restructuring attempted: a `wire _unused_ok = &{...}` in `cc_top`
naming the fourteen sub-block outputs it leaves unconsumed, and named wires on the three
empty output pins. It proved equivalent and cut 17 lint warnings, but the local yosys
mapping grew by 4 cells and 487 um2 because abc's heuristics are sensitive to netlist
order. The brief's rule is that growth is a regression, the change buys nothing in
silicon, and the deadline is tomorrow, so it is not on the branch. Every other
restructuring candidate is in the deferred list below with what it would need.

## Found and NOT changed

- **Plumbing `plane_cap` into `checkpoint_ctrl`** (the "correct" `N_cap` fix). The
  thresholds T2 = 8 and T3 = 12 were calibrated for a 4-plane final; a real 2-plane
  final needs a bias shift of 2 at the final check and a decision the calibration never
  covered. That needs the private golden vectors to validate. Deferred.
- **The pixel scanner's missing abort** (the 52-cycle drain itself). An abort changes
  `active_pixel_scan`, `top_fsm`'s swap logic and the `!img_start` trap. P3a makes the
  drain pollable instead. Deferred.
- **Dead ports and signals**: `exit_k_held`, `page_sel`, `blob_loader`'s `loading` and
  `words_seen`, `top_fsm`'s `planes_run`, the wrapper-level `ans_valid`. Synthesis
  already removes them (no flop of theirs survives in the netlist), so removing them
  from the source buys tidiness only, at the cost of port changes in four modules two
  days from tape-out, each needing a projected proof. They are now remarked in the
  comments. Deferred.
- **The lint tidy (P6)**: see above. Dropped after measurement; the recipe and its
  numbers are here so it can be retried after the shuttle with a fresh synth
  comparison.
- **`BIAS_SH_P2/P3/FIN` and `ACC_BUS` in `ckpt_defs.vh`** are defined and read by
  nothing; `CC_BUILD` likewise. Annotated, left.
- **The reset-less registers** (trap 8). Not touched, as instructed.
- **DFT view 1 after a load** is undefined because there is no host read address.
  Documented truthfully in P0 rather than fixed: a fix needs a pin or a blob field.
- **VARHIDDEN in `config_latch`** (the instance `cfg` hides the reg `cfg`). Renaming the
  instance breaks the name-based formal matching this gate relies on. Left.
- **The remaining lint warnings** (14): `requant_unit`'s WIDTHTRUNC is the intentional
  truncation from section 3; the others are benign width notes on sized localparams and
  the grouped ROM decode's ignored address bits. Left.
- **`fpga.yaml`** never runs (`branches: none`). It is the Tiny Tapeout template's
  choice. Left.
- **`tiles: "4x2"`**. Not touched; only the reasoning in `info.yaml` was corrected.
- **A pre-existing uncommitted change** in `~/Documents/Projects/ttsky-bsgds/test/test.py`
  (modified 2026-08-06, long before this work). Not touched.

## Findings that were not in the brief

- **The `ckpt_block` bias shift is currently unobservable at the pins.** `bias_ext` is
  12 b and `bias_sh` is 0, 1 or 2; a logical shift differs from the arithmetic one by
  2^(12-s), a multiple of 1024 for s <= 2, and `requant_unit` truncates the sum to 10 b.
  The mutant gives 0 differing cycles; the formal gate still reports it. Trap 4 stays as
  written: the shift is correct and its invisibility is an accident of widths.
- The trap the brief states, `requant_unit`'s own `t >>> k`, is fully observable
  (744,443 cycles), matching the brief.
- `ACC_W` 10, the ROM ranges (-12..29, 8 negative, k bincount [2,28,2]) and the W1
  counts (28 and 32) all reproduce from an independent decode.
- 18 elaboration assertions on `main`, not 17.
- The datasheet's "L2 evaluates 4 classes per cycle" was wrong in a way that mattered to
  a reader: it is 4 hidden units per cycle, all 10 class scores updated each cycle.
- `test/README.md` pointed at a gate-level netlist path that the root Makefile does not
  produce; fixed in P4.

## Stated plainly: what is not proven

- **P2's netlist effect** is asserted from the brief's numbers and reasoning, not
  measured: no OpenLane here. CI must confirm it.
- **P3a's wrapper** is UNPROVEN by `formal.sh` because it is meant to differ; the
  masked-wrapper proof is the substitute and it is a full proof.
- **P3b's `cc_top` and wrapper** have no formal statement for `n_cap` in 1..3. The
  evidence there is the one-line code diff, the confined differential, and the cocotb
  test. `top_fsm` alone is proven for every other value.
- **Formal "PROVEN"** here means yosys `equiv_status -assert` passed after
  `equiv_simple` and `equiv_induct -seq 4` over name-matched nets. It is a proof of
  equivalence between the two RTL trees as yosys elaborates them with `-DSYNTHESIS`;
  it is not a proof against a specification, which this repository does not contain.
- **The cocotb expected values** are the shipped behaviour of `b5939b8`, not truth.

## Recommended push order (for a human to run)

Nothing here has been pushed. Every workflow is `on: push` without a branch filter, so
the first push of the branch rebuilds the GDS and redeploys the viewer for that branch.

```bash
cd ~/Documents/Projects/ttsky-clutchfactor
git log --oneline origin/main..HEAD          # 16 commits, read them all
git diff origin/main --stat
cd equiv && ./get_base.sh && ./run_diff.sh && ./formal.sh; cd ..   # ~5 min, reproduces the gate
```

1. Push the branch, not `main`: `git push origin clutchfactor`. Wait for the gds, test
   and docs workflows. Confirm: test 8/8, precheck green, gl_test green, DRC/LVS/antenna
   0, hold slack still positive, and read the P2 numbers (setup slack, buffer count) from
   the gds artifact into the P2 section above.
2. If anything is off, the commits revert independently from P2 onward:
   `git revert 1ea14dc` (P3b), `git revert a63bf43` (P3a), `git revert a6f7cc2` (P2).
   P4's two P3 tests must go with their commits (`git revert 2df100a` or edit them out).
3. When green: `git push origin clutchfactor:main` (fast-forward; `main` is the branch's
   base), or open a PR from `clutchfactor` if a review trail is wanted.
4. Only `main`'s GDS is what the shuttle takes; do not tag or submit from the branch.

Deadline: Friday 2026-09-04.
