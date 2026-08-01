// l1_horner_acc -- the L1 ternary MAC + Horner accumulator (build-l1, stage 3).
//
// The core of the chip: 256 of every inference's cycles run through this block, and it
// is the source of the `acc_live` that l1_acc_shadow / l1_acc_shadow_cg capture.
//
// ---------------------------------------------------------------- what it computes
// checkpoint_sim/engine.py:4-21 is the exact reference. 4 bit planes, MSB-first,
// plane-major: plane p carries input bit (3-p). Within a plane, one pixel per cycle;
// at each plane boundary ACC <- 2*ACC. After k planes:
//     ACC_j == sum_i W1[j,i] * (x_i >> (`PLANES-k))
// W1 is ternary, so there is no multiplier anywhere -- each lane is an add/sub of 1,
// gated by (input bit AND weight-is-nonzero).
//
// THE x2 AND THE FIRST PIXEL SHARE A CYCLE. engine.build_records() line 156 is
//     acc_traj[:, p] = 2 * prev + np.cumsum(delta, 1)
// so position 0 of plane p is 2*prev + delta_0, NOT 2*prev on its own cycle. That is
// what `plane_start` means here: "this cycle is the first pixel of a plane, so double
// the running value before adding this pixel's contribution". Splitting the doubling
// into its own cycle would be 4 extra cycles per inference AND would not match the
// reference trajectory the frozen thresholds were calibrated against.
//
// Zero-skip is where that ordering is easiest to get wrong. A plane whose popcount is
// 0 still runs `ZS_FILL = 8 cycles with act == 0 throughout -- and the x2 still has to
// happen, on the first of those 8. It does: `plane_start` is asserted there and the
// delta is simply 0. Nothing about this module distinguishes the two orderings; the
// pixel sequence, the plane lengths and the act bits all come from the sequencer
// (build-input). Both orderings are verified against engine.py anyway -- see
// checkpoint_sim/dump_l1_vectors.py and ckpt_tb/tb_l1_horner_acc.v.
//
// ---------------------------------------------------------------- W1 ROM bit order
// `w_col` is ONE W1 ROM row, i.e. exactly the 64-bit `wcol` output of
// w1_rom_synthesis/rtl/w1_h32_case.v (`module w1_h32_case(input [5:0] addr, output reg
// [63:0] wcol)`), addressed by pixel index. Packing, per rom_gen.py encode_column():
//     w_col[2*j + 1] = p_j   -> W1[j,i] == +1
//     w_col[2*j    ] = n_j   -> W1[j,i] == -1
//     neither set            -> W1[j,i] == 0
//
// This is the OPPOSITE order from l2_mac_x4.v's W2 packing, where bit 2*c is p and bit
// 2*c+1 is n. rom_gen.py:58-63 says the divergence is deliberate ("the two ROMs feed
// different consumers ... their bit orders are not required to match"). Do not copy
// l2_mac_x4's indexing into this file.
//
// Confirmed, not assumed: decoding the 64 checked-in literals of w1_h32_case.v with
// p=w_col[2j+1] / n=w_col[2j] reproduces its source W1 exactly (64/64 addresses,
// 32x64 trits); decoding with l2_mac_x4's order does not. NOTE that w1_h32_case.v's
// source is ternary_tapeout/artifacts/H32_fold_a_shift.npz (w1_rom_synthesis
// results.md:7), which is NOT the FINAL4_s12_fold_a.npz that engine.py and every
// ckpt_rtl ROM use -- the two W1 matrices differ. That is a ROM-content question, not
// a MAC question: this module takes the row as a port and is weight-agnostic, and its
// verification drives it from engine.py's own FINAL4 W1 so the trajectory check is
// against the shipped network.
//
// The ROM is a PORT, not an instance, for two reasons: it is already priced on its own
// in w1_rom_synthesis/results.md (instantiating it here would double-count it against
// the option-C budget), and one ROM row is shared by all 32 lanes -- there is exactly
// one address per cycle, driven by the sequencer.
//
// ---------------------------------------------------------------- width
// `ACC_W = 12 from ckpt_defs.vh; nothing is re-declared here. The parameter exists so
// run_synth.py can price the DESIGN_LEDGER Aug-1 W=11 floor via PARAM_OVERRIDES,
// exactly as l1_acc_shadow does.
//
// Sizing is an ARITHMETIC bound, not an observation: the largest W1 row L1 norm is 46
// and the input is 4 b (max 15), so |ACC| <= 15*46 = 690 for ANY input, in-distribution
// or not. The Horner intermediates rise monotonically 46 -> 138 -> 322 -> 690
// ((2^k - 1) * 46), so no partial value overflows on the way to the final one either.
// 12 b signed (+-2047) fits with ~3x headroom. 11 b (+-1023) also fits, but leaves only
// row-norm <= 68 of headroom for the not-yet-frozen page-2 weights. 9 b is KILLED: it
// wraps and silently voids the conformal guarantee.
// (The tight attainable maximum is smaller than the bound -- no row's 46 nonzeros are
// all one sign, so the true worst case is 15*max_j max(#+1_j, #-1_j) = 480 for FINAL4
// and 450 for the ROM's fold. 690 is the sound bound and is what the width is sized on.)
//
// ---------------------------------------------------------------- no reset, no enable
// Both omissions are deliberate and both are worth real area on a 384-flop bank.
//
// NO FLOP RESET. `img_start` clears through the DATAPATH (it forces the accumulator's
// feedback term to 0) instead of through a reset pin. 384 resettable flops would be
// sky130_fd_sc_hd__dfrtp_1 at 25.0240 um^2 each; plain dfxtp_1 is 20.0192 um^2. That is
// 5.0048 um^2 x 384 = 1,921.8 um^2 = 0.107 t @100% / 0.153 t @70% saved, for a mux
// input the datapath needs anyway. Cost: the bank is X in simulation until the first
// `img_start`, which is the first cycle of every image regardless.
//
// NO `en` PIN. Holding the accumulator is already free: act == 0 and plane_start == 0
// give base == q and delta == 0, i.e. q <= q. A per-flop load enable would map the bank
// to sky130_fd_sc_hd__edfxtp_1 (30.0288 um^2) and cost 384 x 10.0096 = 3,843.7 um^2 --
// the exact trap l1_acc_shadow.v hit and l1_acc_shadow_cg.v exists to A/B. If a future
// caller wants the bank's CLOCK stopped rather than its data held (a power lever, not a
// correctness one), that is the l1_acc_shadow_cg pattern: one dlclkp_1 in front of this
// module's clk, not 384 enables inside it.
//
// A pure clear with no accumulate is still available: img_start = 1 with act = 0.
`include "ckpt_defs.vh"

module l1_horner_acc #(parameter W = `ACC_W) (
    input  wire                 clk,
    input  wire                 img_start,    // first cycle of an image: base <- 0
    input  wire                 plane_start,  // first pixel cycle of a plane: base <- 2*ACC
    input  wire                 act,          // this cycle's input bit, x_i >> (`PLANES-1-p)
    input  wire [2*`NHID-1:0]   w_col,        // one W1 ROM row: unit j = {p,n} at [2j+1:2j]
    output wire [`NHID*W-1:0]   acc_live      // 32 x W signed, unit 31 (MSB) .. unit 0 (LSB)
);
    genvar j;
    generate
        for (j = 0; j < `NHID; j = j + 1) begin : lane
            reg signed [W-1:0] q;

            // gated add/sub. p and n are never both set by rom_gen.encode_column(), so
            // the priority below is unreachable on real ROM content -- it is here only
            // so a malformed row has one defined answer instead of two.
            wire inc = act & w_col[2*j + 1];        // p -> +1
            wire dec = act & w_col[2*j];            // n -> -1

            // Horner: img_start dominates plane_start (both are asserted on the first
            // cycle of plane 0, where 2*ACC and 0 must both mean 0).
            wire signed [W-1:0] base  = img_start   ? {W{1'b0}}
                                      : plane_start ? {q[W-2:0], 1'b0}   // 2*ACC
                                                    : q;
            wire signed [W-1:0] delta = inc ? { {(W-1){1'b0}}, 1'b1 }    // +1
                                      : dec ? {W{1'b1}}                  // -1
                                            : {W{1'b0}};                 //  0

            always @(posedge clk)
                q <= base + delta;

            assign acc_live[j*W +: W] = q;
        end
    endgenerate
endmodule
