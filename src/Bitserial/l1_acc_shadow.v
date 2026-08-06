// l1_acc_shadow -- A1 snapshot bank: storage + read path only, no scheduling.
// `capture` latches all 32 hidden-ACC words atomically; `rd_grp` combinationally
// selects which 4-word group drives the requant lanes.
//
// Storage flops synthesize to enable-DFF (edfxtp_1, 30.03 um2/flop), not plain DFF
// (20.02 um2), because this bank must HOLD on every low-capture cycle. Unavoidable:
// a discrete mux+DFF pair (31.28 um2) costs MORE than the integrated enable cell, so
// this is already area-optimal -- l1_acc_shadow_cg.v is the alternative that beats it
// with a different mechanism (gating the clock, not the data).
`include "ckpt_defs.vh"

module l1_acc_shadow #(parameter W = `ACC_W) (
    input  wire clk,
    input  wire capture,
    input  wire [32*W-1:0] acc_live,
    input  wire [2:0] rd_grp,
    output wire [4*W-1:0] a1_out
);
    reg [32*W-1:0] snap;
    always @(posedge clk) if (capture) snap <= acc_live;

    assign a1_out = snap[rd_grp*(4*W) +: 4*W];
endmodule
