// Chrome Chain -- one place for every width and build constant. Include this; never
// re-declare a width elsewhere. Datapath widths, checkpoint thresholds, config-latch
// field offsets and the two build-coding switches all live here, so a change is one
// edit in one file rather than a sweep through the modules that include it.

`ifndef CKPT_DEFS_VH
`define CKPT_DEFS_VH

// ---------------------------------------------------------------- WHICH BUILD IS THIS
// The defaults below are the shipped build: `ACC_W 10, `OACC_CG_DEFAULT 1,
// `ACC_CNT_DEFAULT 1, `CFG_WORDS 6, `CFG_ADDR_W 3. Each is also a cc_top parameter
// (W, OACC_CG, ACC_CNT, CFG_NWORDS, CFG_ADDRW) that defaults to the value here, so an
// alternative build is an instantiation override; there is no `define or -D switch.
//
// CC_BUILD is a build-identity string; no module in src/ reads it.
`define CC_BUILD "v1.1"

// ---------------------------------------------------------------- network shape
`define NPIX    64          // 8x8 input, one pixel per cycle (dense)
`define NHID    32          // hidden units
`define NCLASS  10
`define PLANES  4           // 4-bit input, MSB-first, plane-major Horner

// ---------------------------------------------------------------- datapath widths
// a1 reachable range is -480..+420 (w1_rom_final4 decoded: at most 28 +1 and 32 -1
// weights in any hidden unit, unsigned 4 b pixels), so 10 b signed (-512..+511) holds
// it with 32 to spare; 9 b (-256..+255) would wrap. requant_unit.v adds the shifted
// bias to a1 in a 10 b intermediate (its ports are `BIAS_W = 12 b; the narrower sum is
// intentional): worst case -480 + (-12) = -492 against a floor of -512, 20 counts of
// headroom. ckpt_block.v fails elaboration if its W (= `ACC_W) exceeds `BIAS_W or that
// 10 b intermediate.
//
// a2 (the L2 out-ACC) reaches -255..+150 with the b2 preload included (l2_weight_rom_x4
// decoded: at most 10 +1 and 17 -1 weights in any class, h in 0..15; b2 is -2..3,
// checkpoint_ctrl.v). `OACC_W = 12 is fixed by l2_mac_x4's 120 b acc bus and
// exit_tree_2stage's 12 b margin; ckpt_block.v checks `OACC_BUS == 120 at elaboration.
`define ACC_W   10          // L1 hidden accumulator (Horner), signed
`define OACC_W  12          // L2 out-ACC, signed; a2 reachable -255..+150
`define H_W     4           // hidden activation, unsigned [0,15] (QMAX=15)
`define K_W     2           // requant shift; k in {0,1,2}, bincount [2,28,2]
`define BIAS_W  12          // requant_unit a1/bias port width; ROM bias -12..29 fits 6 b
`define T_W     10          // threshold field; 1023 exceeds any reachable margin (<= 405)

// derived
// W2_ROW_W packs class c as bit 2c = +1 (p) and bit 2c+1 = -1 (n): p is the LOW bit,
// the opposite of W1's [2j+1:2j] order where p is the HIGH bit. Both ROMs encode this.
`define ACC_BUS   (`NHID   * `ACC_W)      // 320 b at ACC_W=10, the A1 snapshot size; unused
`define OACC_BUS  (`NCLASS * `OACC_W)     // 120 b
`define W2_ROW_W  (`NCLASS * 2)           // 20 b: {p,n} ternary pair per class

// ---------------------------------------------------------------- checkpoint config
// checkpoint_ctrl.v checks `NHID/`P + 1 + `TREE_LAT == `GAMMA and `NHID/`P == `ZS_FILL
// at elaboration; ckpt_block.v checks `P == 4.
`define P          4        // L2 units per cycle; the x4 ROMs and l2_mac_x4 are fixed at 4
`define GAMMA     11        // check latency: 8 (act||L2 at P=4) + 2 (tree) + 1
`define ZS_FILL    8        // zero-skip plane length = max(popcount, ZS_FILL)
`define TREE_LAT   2        // exit_tree_2stage: y at cycle N -> done at N+2

// ---------------------------------------------------------------- input side (1 + 6)
// Index and count widths for the bitplane buffer / zero-skip sequencer. `PC_W and
// `LEN_W are both 7 because popcount and plane length range over 0..`NPIX and
// `ZS_FILL..`NPIX respectively -- `NPIX+1 = 65 codes, which 6 b cannot hold.
`define PIX_W   6           // pixel index / W1 ROM address, log2(`NPIX)
`define PC_W    7           // popcount, 0..`NPIX
`define LEN_W   7           // plane length, `ZS_FILL..`NPIX

// `LD_W is the plane-buffer FILL PORT width, and it is what makes `ZS_FILL true:
// filling one `NPIX-bit plane takes `NPIX/`LD_W = 8 cycles, so a plane can never be
// consumed faster than 8 cycles no matter how sparse it is. bitplane_buffer.v checks
// `NPIX/`LD_W == `ZS_FILL at elaboration, so a host fill port of a different width is
// a loud failure and not a silently wrong plane length. Changing it also moves
// `ZS_FILL, which checkpoint_ctrl.v requires to equal `NHID/`P for its
// single-shadow-bank bound -- two independent 8s that must stay equal.
`define LD_W    8           // plane-buffer fill port, bits/cycle

// Checkpoint thresholds: reset defaults for the T fields; the blob overrides them. The
// compare is margin >= T (exit_tree_2stage.v) and max2_node.v resolves a tie to the
// lowest index; T2 = 8 and T3 = 12 were calibrated under exactly those two conventions,
// so changing either one invalidates them. T = 0 is an always-true exit (margin >= 0).
// `T1_DEFAULT expands to an unsized expression: size it before use in a concat, as
// config_latch.v does.
`define T2_DEFAULT  8
`define T3_DEFAULT 12
`define T1_DEFAULT (1 << `T_W) - 1   // P1 disarmed: maximum threshold, never exits

// Per-checkpoint bias shift: bias >>> (`PLANES - k_planes). This MUST be an arithmetic
// shift on the sign-extended ROM value (8 of the 32 bias values are negative); a
// logical shift compiles and makes every checkpoint margin wrong, so the thresholds
// above no longer mean anything. ckpt_block.v applies it; checkpoint_ctrl.v computes
// the amount as FINAL_K - chk_k on its bias_sh port, and no module reads these three.
`define BIAS_SH_P2  2
`define BIAS_SH_P3  1
`define BIAS_SH_FIN 0

// ---------------------------------------------------------------- P2: W2 / theta-k ROM
// CKPT_BIAS_W is the ROM-STORED bias width, a different number from BIAS_W above, which
// is requant_unit's 12 b datapath PORT width. The ROM bias range is -12..29, which fits
// signed 6 b (-32..31); ckpt_block.v sign-extends it to `BIAS_W before the shift.
`define CKPT_BIAS_W  6
`define CKPT_ADDR_W  5             // 32-word ROM address width, 2^5 = 32 = NHID
`define THETAK_ROW_W (`CKPT_BIAS_W + `K_W)  // 8 b/word: bias(6) + k(2), reuses K_W above

// ------------------------------------------------- config latch / blob contract
// These offsets ARE the contract: the loader, config_latch and any host-side blob packer
// must all agree, so they live here rather than inside config_latch.v.
//
// W1, W2, theta and k are ROMs, so the latch holds ONLY T + config. Word width is 8 b
// because TT's ui_in is 8 b, so a word write is one host cycle.
//
// 6 words = 48 b: the 43 b payload plus 5 b of slack at [47:43]. A blob is six ui_in
// writes.
//
// THESE TWO MOVE TOGETHER WITH blob_loader's NWORDS/ADDR_W, always. The loader owns the
// word counter and the address, so a 48 b latch behind a 16-word loader wraps words 8..15
// back onto 0..5, zeroes every threshold and does NOT raise blob_err -- a silently wrong
// chip from a load that reports success. cc_top drives both from one parameter pair
// (CFG_NWORDS/CFG_ADDRW); blob_loader.v and config_latch.v each check at elaboration
// that (1 << ADDR_W) >= NWORDS and NWORDS * `CFG_W > `CFG_BITS.
`define CFG_W        8             // latch word width, = TT ui_in width
`define CFG_WORDS    6             // 6 x 8 = 48 b
`define CFG_ADDR_W   3             // 2^3 = 8 >= CFG_WORDS
`define N_CAP_W      3             // N_cap holds 0..`PLANES, so 3 b

// ------------------------------------------------- build choices that are not widths
// OACC_CG and ACC_CNT select alternative codings with identical behaviour -- the same
// result every cycle, different cells -- so they have no width to live in, but they are
// build identity and belong here with the rest of it rather than in a module's
// parameter list. cc_top and ckpt_block take them as parameters defaulting to these.
//   OACC_CG  0 = 120 edfxtp_1 enable flops, 1 = 120 dfxtp_1 behind one dlclkp_1.
//            The gate adds a second manually-instantiated clock-gate domain (the first
//            is the shadow bank's, SHADOW_CG), a CTS and hold-time review point in P&R.
//   ACC_CNT  0 = l1_horner_acc (adder), 1 = l1_horner_cnt (carry chain).
`define OACC_CG_DEFAULT  1
`define ACC_CNT_DEFAULT  1

// Field offsets into the flat latch vector. T occupies [29:0] in exactly the order
// checkpoint_ctrl.v's t_cfg port expects ({T3,T2,T1}, `T_W each), so t_cfg is a
// zero-logic slice, not a re-pack.
`define CFG_T1_LSB    0            // `T_W
`define CFG_T2_LSB   10            // `T_W
`define CFG_T3_LSB   20            // `T_W
`define CFG_EN_LSB   30            // K7 per-checkpoint arm bits, `PLANES-1 = 3 b
`define CFG_SKIP_LSB 33            // en_skip, 1 b
`define CFG_PAGE_LSB 34            // page_sel, 1 b; latched, drives no logic
`define CFG_INV_LSB  35            // K10 per-plane inversion, `PLANES = 4 b
`define CFG_NCAP_LSB 39            // N_cap, `N_CAP_W = 3 b
`define CFG_VST_LSB  42            // K11 per-plane valid-strobe enable, 1 b
`define CFG_BITS     43            // payload bits in use; [47:43] spare

// Reset defaults for the non-threshold fields. The T defaults are T{1,2,3}_DEFAULT
// above. These four are chosen for safe bring-up, and the blob overrides them:
//   en_skip = 0   dense ordering: unconditional 64 cycles/plane, always correct.
//   page    = 0   page_sel is latched but drives no logic.
//   inv     = 0   K10 per-plane inversion off.
//   n_cap   = `PLANES  no cap.
//   en_vst  = 0   K11 off until the host is known to drive strobes; when armed, a
//                 strobe that does not coincide with the last beat of a fill (early,
//                 missing on the last beat, or outside a fill write) sets the sticky
//                 frame_err (bitplane_buffer.v).
`define CFG_EN_DEFAULT    3'b110   // K7: bit0=P1 (disarmed), bit1=P2, bit2=P3
`define CFG_SKIP_DEFAULT  1'b0
`define CFG_PAGE_DEFAULT  1'b0
`define CFG_INV_DEFAULT   4'b0000
`define CFG_NCAP_DEFAULT  3'd4     // == `PLANES
`define CFG_VST_DEFAULT   1'b0

`endif
