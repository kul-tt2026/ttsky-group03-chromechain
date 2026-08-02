// A1 snapshot bank: storage + read path ONLY. No scheduling, no FSM, no overlap
// logic -- that is build-ctrl's job (docs/cc_verilog_build_prompts.md build-ctrl). `capture`
// latches all 32 hidden-ACC words atomically; `rd_grp` combinationally selects
// which 4-word group drives the requant_unit lanes.
//
// Measured (docs/cc_verilog_roadmap_review.md probe-area): the storage flops map
// to sky130_fd_sc_hd__edfxtp_1 (enable DFF, 30.0288 um^2), not the plain
// sky130_fd_sc_hd__dfxtp_1 (20.0192 um^2) that exit_scan's raw-DFF reference
// figure is built from -- 1.5x per bit, because this bank must HOLD its value
// on every cycle `capture` is low, unlike an always-updating scan register.
// That is unavoidable: mux2_1 (11.26 um^2) + dfxtp_1 (20.02 um^2) = 31.28 um^2
// is not cheaper than the integrated edfxtp_1 cell, so dfflibmap's choice is
// already area-optimal.
//
// A shift-by-4/2/1 log-depth select network was built and measured as an
// alternative read path to this indexed part-select; both synthesize to an
// identical netlist (yosys already balances the part-select into the same
// tree), so this is the simpler of two equal-cost codings, not a preference.
`include "ckpt_defs.vh"

module l1_acc_shadow #(parameter W = `ACC_W) (
    input  wire clk,
    input  wire capture,                  // latch all 32 units this cycle
    input  wire [32*W-1:0] acc_live,      // live hidden ACC, 32 x W signed
    input  wire [2:0] rd_grp,             // which group of 4 units to read
    output wire [4*W-1:0] a1_out          // 4 units -> the requant_unit lanes
);
    reg [32*W-1:0] snap;
    always @(posedge clk) if (capture) snap <= acc_live;

    assign a1_out = snap[rd_grp*(4*W) +: 4*W];
endmodule
