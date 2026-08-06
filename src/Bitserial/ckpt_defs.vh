// Chrome Chain — one place for every width. Include this; never re-declare a width.
//
// The point: the ACC_W 11-vs-12 b decision (DESIGN_LEDGER Aug-1 blocking item 2) must
// be a one-line change here, not a sweep through six files. Same for the page-2
// content questions that are still open.
//
// Every number below cites its evidence. Do not change one without updating the cite.

`ifndef CKPT_DEFS_VH
`define CKPT_DEFS_VH

// ---------------------------------------------------------------- WHICH BUILD IS THIS
// The defaults below describe **v1.1**: v1 with four area levers and bit-identical
// behaviour. Verified over the full 10,000-image test set, both plane orderings, both
// modes, every engine.py aggregate reproduced -- l2_synthesis/results.md, "v1.1 -- the
// four area levers". 5.547 t@70% wrapped, against v1's 6.238 t.
//
//   lever 1  `ACC_W       12 -> 11      L1 accumulator width
//   lever 2  `OACC_CG_DEF  0 ->  1      out-ACC behind one dlclkp_1
//   lever 3  `CFG_WORDS   16 ->  6      config latch 128 -> 48 b, AND the blob that
//            `CFG_ADDR_W   4 ->  3      fills it -- these two move together or the load
//                                       silently zeroes the thresholds (blob_loader.v)
//   lever 4  `ACC_CNT_DEF  0 ->  1      l1_horner_cnt, the carry-chain accumulator
//
// V1 IS NOT GONE, and it is not a second copy of the source either -- that is the failure
// mode docs/cc_v11_plan.md records (two copies of l1_horner_acc drifted and the
// submission's source list stopped elaborating). It is THIS source with five values:
//
//   simulation  iverilog -DCC_W=12 -DCC_OACC_CG=0 -DCC_ACC_CNT=0 \
//                        -DCC_CFG_NWORDS=16 -DCC_CFG_ADDRW=4
//   synthesis   run_synth.py labels `cc_top_v1` and `tt_um_v1`
//   frozen bits kul-tt2026/ttsky-group03-chromechain, branch bitserial-datapath
//
// verify.py runs BOTH builds over the full test set, so v1 cannot rot unnoticed.
//
// WHAT IT COSTS -- both were page-2 questions, and page 2 is DEAD (2026-08-03, one page,
// digit-only), so both are settled and neither is a risk any more:
//   - The blob contract is 48 b / 6 host words, not 128 b / 16. The 43 b payload fits;
//     the 85 b page-2 reserve is spent, and there is no page 2 to want it back.
//     RATIFIED, DESIGN_LEDGER blocking item 5. A blob is six ui_in writes, ~25 us.
//   - `ACC_W = 11 holds +-1023 against the page-1 bound of 690, a 33% margin, and
//     dump_{a1,l1}_vectors.py re-assert that fit on every regeneration. The <=68 row-norm
//     caveat that made this guarantee-load-bearing was page-2's. RATIFIED, item 2.
//
// So v1.1 is not a candidate any more, it is the design. v1 stays buildable and gated
// because a frozen build nobody runs stops elaborating -- not because it is coming back.
//
// If the submission's src/ is ever regenerated from this repo, CHECK THIS LINE FIRST.
`define CC_BUILD "v1.1"

// ---------------------------------------------------------------- network shape
`define NPIX    64          // 8x8 input, one pixel per cycle (dense)
`define NHID    32          // 32h ratified; 16h and 64h both closed (DESIGN_LEDGER §3)
`define NCLASS  10
`define PLANES  4           // 4-bit input, MSB-first, plane-major Horner

// ---------------------------------------------------------------- datapath widths
// a1 worst case +-690 -> 11 b signed floor; 9 b is KILLED (wraps at +-719 on OOD
// inputs and silently voids the conformal guarantee). figures/datapath.dot labels the
// bank "32 x 12 b ACC (DFF, 384 b)" and is now one build behind;
// ternary_tapeout/eightbit/audit_final.json is the range source.
//
// v1.1 LEVER 1: this is the ledger floor, taken. 11 b signed holds +-1023 against the
// page-1 bound of 690, and checkpoint_sim/dump_{a1,l1}_vectors.py assert that fit at THIS
// width every time the golden vectors are regenerated -- so the margin is re-checked by
// the gate, not argued. v1 was 12. Worth -0.234 t@70% at chip level, and it is the lever
// the ledger calls guarantee-load-bearing: see "WHICH BUILD IS THIS" above.
`define ACC_W   11          // L1 hidden accumulator (Horner). Was 12 in v1.
`define OACC_W  12          // L2 out-ACC; a2 worst case +-408 -> 10 b needed
`define H_W     4           // hidden activation, unsigned [0,15] (QMAX=15)
`define K_W     2           // requant shift; FINAL4 k in {0,1,2}, bincount [2,28,2]
`define BIAS_W  12          // act_unit port width; FINAL4 bias range -12..29 fits 6 b
`define T_W     10          // threshold field; observed margins m1<=12 m2<=28 m3<=61

// derived
`define ACC_BUS   (`NHID   * `ACC_W)      // 384 b at ACC_W=12 -- the A1 snapshot size
`define OACC_BUS  (`NCLASS * `OACC_W)     // 120 b
`define W2_ROW_W  (`NCLASS * 2)           // 20 b: {p,n} ternary pair per class

// ---------------------------------------------------------------- checkpoint config
`define P          4        // L2 units per cycle (lever B1). P=4 is the measured knee.
`define GAMMA     11        // check latency: 8 (act||L2 at P=4) + 2 (tree) + 1
`define ZS_FILL    8        // zero-skip plane length = max(popcount, ZS_FILL)
`define TREE_LAT   2        // term_tree_p2: y at cycle N -> done at N+2

// ---------------------------------------------------------------- input side (1 + 6)
// Index and count widths for the bitplane buffer / zero-skip sequencer. `PC_W and
// `LEN_W are both 7 because popcount and plane length range over 0..`NPIX and
// `ZS_FILL..`NPIX respectively -- `NPIX+1 = 65 codes, which 6 b cannot hold.
`define PIX_W   6           // pixel index / W1 ROM address, log2(`NPIX)
`define PC_W    7           // popcount, 0..`NPIX
`define LEN_W   7           // plane length, `ZS_FILL..`NPIX

// `LD_W is the plane-buffer FILL PORT width, and it is what makes `ZS_FILL true:
// filling one `NPIX-bit plane takes `NPIX/`LD_W = 8 cycles, so a plane can never be
// consumed faster than 8 cycles no matter how sparse it is -- which is exactly the
// "8 = plane-buffer fill bound" in engine.py's plane_costs docstring and the
// "vulbodem van de plane-buffer" in docs/cc_datapath_walkthrough.md stage 2.
// CAUTION: the sources state the 8-CYCLE bound, never the port width; `LD_W = 8 is
// this RTL's reading of it. bitplane_buffer.v checks `NPIX/`LD_W == `ZS_FILL at
// elaboration, so if stage 0's host interface ever fixes a different width the
// mismatch is a loud failure and not a silently wrong plane length. Changing it also
// moves `ZS_FILL, which checkpoint_ctrl.v requires to equal `NHID/`P for its
// single-shadow-bank bound -- two independent 8s that must stay equal.
`define LD_W    8           // plane-buffer fill port, bits/cycle

// Frozen thresholds, checkpoint_sim/out/frozen_thresholds.json "P2P3|B1B2A1|1e-3".
// Identical across gamma in {11,43} x overlap in {0,1}, so a late gamma change does
// not move them. Compare is >=T; T=0 is an always-true exit (margin >= 0 always).
`define T2_DEFAULT  8
`define T3_DEFAULT 12
`define T1_DEFAULT (1 << `T_W) - 1   // P1 disarmed: 0.28% exits even when free (MILP D1)

// Per-checkpoint bias shift: bias >>> (PLANES - k_planes). Arithmetic shift; matches
// numpy's floor semantics in engine.py:true_score_at. Getting this wrong makes every
// checkpoint margin wrong and the frozen thresholds meaningless.
`define BIAS_SH_P2  2
`define BIAS_SH_P3  1
`define BIAS_SH_FIN 0

// ---------------------------------------------------------------- P2: W2 / theta-k ROM
// CKPT_BIAS_W is the ROM-STORED bias width -- a different number from BIAS_W above,
// which is act_unit's 12b datapath PORT width. FINAL4_s12_fold_a.npz "bias" measured
// range is -12..29 (docs/cc_verilog_build_prompts.md P2), which fits signed 6 b
// (range -32..31); 6 b is much smaller than docs/cc_32h_area_cookbook.md's cited
// "504 b of bias" figure, which does not divide evenly across NHID=32 units
// (504/32=15.75) and was conservative/imprecise, not a target to match.
`define CKPT_BIAS_W  6
`define CKPT_ADDR_W  5             // 32-word ROM address width, 2^5 = 32 = NHID
`define THETAK_ROW_W (`CKPT_BIAS_W + `K_W)  // 8 b/word: bias(6) + k(2), reuses K_W above

// ------------------------------------------------- config latch / blob contract
// DESIGN_LEDGER Aug-1 item 5 ("freeze the blob/ROM contract"). These offsets ARE the
// contract: the loader, config_latch and any host-side blob packer must all agree, so
// they live here rather than inside config_latch.v.
//
// Option C ROMs W1, W2, theta and k, so the latch holds ONLY T + config. Word width 8 b
// because TT's ui_in is 8 b, so a word write is one host cycle.
//
// v1.1 LEVER 3: 6 words = 48 b, the 43 b payload with 5 b of slack and NO page-2 spare.
// v1 was 16 words = 128 b, of which 85 b were reserve for thermal fields that do not
// exist. Worth -0.292 t@70% at chip level -- the single biggest lever -- and it is the
// one that changes something a HOST can see: the blob is 6 words, not 16.
//
// THESE TWO MOVE TOGETHER WITH blob_loader's NWORDS/ADDR_W, always. The loader owns the
// word counter and the address, so a 48 b latch behind a 16-word loader wraps words 8..15
// back onto 0..5, zeroes every threshold and does NOT raise blob_err -- a silently wrong
// chip from a load that reports success. cc_top drives both from one parameter pair
// (CFG_NWORDS/CFG_ADDRW); see blob_loader.v's "NWORDS IS A CONTRACT".
`define CFG_W        8             // latch word width
`define CFG_WORDS    6             // 6 x 8 = 48 b. Was 16 (128 b) in v1.
`define CFG_ADDR_W   3             // 2^3 = 8 >= CFG_WORDS. Was 4 in v1.
`define N_CAP_W      3             // N_cap holds 0..`PLANES, so 3 b

// ------------------------------------------------- build choices that are not widths
// Levers 2 and 4. Both are pure codings -- same behaviour, different cells -- so they
// have no width to live in, but they belong in the same one place as the rest of the
// build identity rather than in a module's parameter list.
//   OACC_CG  0 = 120 edfxtp_1 enable flops, 1 = 120 dfxtp_1 behind one dlclkp_1.
//            The gate costs a second manually-instantiated clock-gate domain, which
//            becomes a CTS and hold-time review point in P&R. -0.124 t@70%.
//   ACC_CNT  0 = l1_horner_acc (adder), 1 = l1_horner_cnt (carry chain). Proven
//            equivalent over 200,000 random cycles. -0.155 t@70% alone; it costs
//            2.1 MHz at `ACC_W = 12 and is free at 11, so never take it without lever 1.
`define OACC_CG_DEFAULT  1         // was 0 in v1
`define ACC_CNT_DEFAULT  1         // was 0 in v1

// Field offsets into the flat latch vector. T occupies [29:0] in exactly the order
// checkpoint_ctrl.v's t_cfg port expects ({T3,T2,T1}, `T_W each), so t_cfg is a
// zero-logic slice, not a re-pack.
`define CFG_T1_LSB    0            // `T_W
`define CFG_T2_LSB   10            // `T_W
`define CFG_T3_LSB   20            // `T_W
`define CFG_EN_LSB   30            // K7 per-checkpoint arm bits, `PLANES-1 = 3 b
`define CFG_SKIP_LSB 33            // en_skip, 1 b
`define CFG_PAGE_LSB 34            // page_sel, 1 b
`define CFG_INV_LSB  35            // K10 per-plane inversion, `PLANES = 4 b
`define CFG_NCAP_LSB 39            // N_cap, `N_CAP_W = 3 b
`define CFG_VST_LSB  42            // K11 per-plane valid-strobe enable, 1 b
`define CFG_BITS     43            // payload bits in use; [127:43] spare

// Reset defaults for the non-threshold fields. The T defaults are T{1,2,3}_DEFAULT
// above (frozen_thresholds.json "P2P3|B1B2A1|1e-3"). These four are NOT set by that
// key -- boundary margins are ordering-invariant, so the frozen T fields say nothing
// about en_skip (cc_checkpoint_study.md:34) -- and en_skip fused-vs-config is still an
// Aug-10 ledger item. All four are therefore chosen for safe bring-up, not for the
// headline number, and the blob overrides them:
//   en_skip = 0   dense ordering: unconditional 64 cycles/plane, always correct, and
//                 the same ordering as the mode-1 baseline.
//   page    = 0   page 1 (MNIST digits, FINAL4) is the only frozen page.
//   inv     = 0   K10 is for page-2 offset-binary thermal (v1 review S1-8: default 0).
//   n_cap   = `PLANES  no cap.
//   en_vst  = 0   K11 off until the host is known to drive strobes; a chip that stalls
//                 on a missing strobe at first bring-up is the worse failure.
`define CFG_EN_DEFAULT    3'b110   // K7: bit0=P1 (disarmed), bit1=P2, bit2=P3
`define CFG_SKIP_DEFAULT  1'b0
`define CFG_PAGE_DEFAULT  1'b0
`define CFG_INV_DEFAULT   4'b0000
`define CFG_NCAP_DEFAULT  3'd4     // == `PLANES
`define CFG_VST_DEFAULT   1'b0

`endif
