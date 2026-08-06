// l1_acc_shadow_cg -- A1 snapshot bank, clock-gated variant. Same interface and
// behaviour as l1_acc_shadow.v: one integrated clock gate (dlclkp_1, 17.52 um2)
// feeding plain flops (dfxtp_1, 20.02 um2/flop), instead of 384 per-flop enables
// (edfxtp_1, 30.03 um2/flop). Kept ALONGSIDE l1_acc_shadow.v as an A/B, not a
// replacement -- proof of equivalence is l2_synthesis/tb/tb_l1_acc_shadow_cg_equiv.v,
// which drives both modules from identical stimulus incl. capture-during-read and
// capture-held-low, and checks a1_out matches every cycle. Trust the area delta only
// if that testbench passes.
//
// yosys implicitly defines `SYNTHESIS` on every read, so it always instantiates the
// REAL dlclkp_1 cell (the blackbox stub below only gives `hierarchy` something to
// resolve against; `stat -liberty` prices the real cell by name). iverilog never
// defines it, so simulation uses a behavioural model transcribed directly from the
// liberty's own statetable: M0 (internal latch) transparent to GATE while CLK is low,
// holds while CLK is high; GCLK = CLK & M0.
//
// `capture` must be stable while CLK is high for the real cell (setup/hold on GATE) --
// true here because capture is itself synchronously driven by checkpoint_ctrl, but
// that's argued, not proven; post-P&R STA has to confirm it.
`include "ckpt_defs.vh"

`ifdef SYNTHESIS
// Guarded: ckpt_block.v declares the identical stub and run_synth.py reads both files
// in one yosys invocation -- an unguarded second declaration is a hard error.
`ifndef SKY130_FD_SC_HD__DLCLKP_1_DECLARED
`define SKY130_FD_SC_HD__DLCLKP_1_DECLARED
(* blackbox *)
(* keep *)
module sky130_fd_sc_hd__dlclkp_1 (
    input  CLK,
    input  GATE,
    output GCLK
);
endmodule
`endif
`endif

module l1_acc_shadow_cg #(parameter W = `ACC_W) (
    input  wire clk,
    input  wire capture,
    input  wire [32*W-1:0] acc_live,
    input  wire [2:0] rd_grp,
    output wire [4*W-1:0] a1_out
);
    wire gclk;

`ifdef SYNTHESIS
    sky130_fd_sc_hd__dlclkp_1 cg (
        .CLK  (clk),
        .GATE (capture),
        .GCLK (gclk)
    );
`else
    reg gate_latched;
    always @(*)
        if (!clk) gate_latched = capture;
    assign gclk = clk & gate_latched;
`endif

    reg [32*W-1:0] snap;
    always @(posedge gclk) snap <= acc_live;

    assign a1_out = snap[rd_grp*(4*W) +: 4*W];
endmodule
