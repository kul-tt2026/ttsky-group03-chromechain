// l1_horner_acc -- the L1 ternary MAC + Horner accumulator. 256 of every inference's
// cycles run through this: 32 lanes, each a gated add/sub of 1 (no multiplier -- W1 is
// ternary), doubling at each plane boundary (engine.py's Horner scheme).
//
// The x2 and the first pixel of a plane share ONE cycle: base = 2*ACC, then +delta_0,
// not two separate cycles -- splitting them costs 4 extra cycles/image and breaks the
// trajectory the frozen thresholds were calibrated against. An empty zero-skip plane
// still needs this pulse on its first of 8 idle cycles even though delta stays 0.
//
// w_col bit order: p = w_col[2j+1], n = w_col[2j] -- OPPOSITE of l2_mac_x4's W2
// packing. Confirmed against the checked-in ROM literals, not assumed; do not copy
// l2_mac_x4's indexing here. ROM stays a port: it's priced standalone and one row is
// shared by all 32 lanes.
//
// Width: |ACC| <= 15*46 = 690 for ANY input (proven bound: max row L1-norm 46, 4b
// input), Horner intermediates rise monotonically so nothing overflows mid-way either.
// 11 b is the taken floor (fits 690 with margin); 9 b is KILLED -- wraps and silently
// voids the conformal guarantee.
//
// No reset: img_start clears through the datapath (base <- 0) instead of a reset pin
// -- ~0.153 t@70% saved across 384 flops. No enable: holding is already free
// (act=0, plane_start=0 gives base=q, delta=0) -- a real load-enable would cost
// ~3.8k um^2 more, the exact trap l1_acc_shadow.v hit.
//
// acc_next is the SAME D-side nets as acc_live, re-tapped -- zero extra cells. It
// exists because plane_end fires DURING a plane's last accumulate cycle, so acc_live
// (Q side) at that edge is still one pixel short of the boundary; a shadow bank wired
// to acc_live snapshots wrong. Delaying capture a cycle isn't a fix either -- breaks
// GAMMA cycle-exactness. Taking acc_next keeps the schedule and gets the right value.
// Silent in dense (last pixel active in 1/40000 planes), wrong in 69.5% of zero-skip
// planes -- test both orderings.
`include "ckpt_defs.vh"

module l1_horner_acc #(parameter W = `ACC_W) (
    input  wire                 clk,
    input  wire                 img_start,
    input  wire                 plane_start,
    input  wire                 act,
    input  wire [2*`NHID-1:0]   w_col,
    output wire [`NHID*W-1:0]   acc_live,
    output wire [`NHID*W-1:0]   acc_next
);
    genvar j;
    generate
        for (j = 0; j < `NHID; j = j + 1) begin : lane
            reg signed [W-1:0] q;

            // p and n are never both set by real ROM content; this priority only gives
            // a malformed row one defined answer instead of two.
            wire inc = act & w_col[2*j + 1];
            wire dec = act & w_col[2*j];

            wire signed [W-1:0] base  = img_start   ? {W{1'b0}}
                                      : plane_start ? {q[W-2:0], 1'b0}
                                                    : q;
            wire signed [W-1:0] delta = inc ? { {(W-1){1'b0}}, 1'b1 }
                                      : dec ? {W{1'b1}}
                                            : {W{1'b0}};

            wire signed [W-1:0] nxt = base + delta;

            always @(posedge clk)
                q <= nxt;

            assign acc_live[j*W +: W] = q;
            assign acc_next[j*W +: W] = nxt;
        end
    endgenerate
endmodule
