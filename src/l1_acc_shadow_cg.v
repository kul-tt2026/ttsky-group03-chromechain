// A1 snapshot bank, clock-gated variant: same interface and behaviour as
// l1_acc_shadow.v, but `capture` drives ONE integrated clock gate
// (sky130_fd_sc_hd__dlclkp_1, 17.5168 um^2) feeding a bank of plain flops,
// instead of 384 individual per-flop load enables. l1_acc_shadow.v's enable
// flops synthesize to sky130_fd_sc_hd__edfxtp_1 (30.0288 um^2/flop) because
// `capture` is a per-flop enable pin there; a plain sky130_fd_sc_hd__dfxtp_1
// is 20.0192 um^2/flop (exit_scan's own 39-flop reference). This file is the
// probe for whether one gate beats 384 enables -- an A/B, kept ALONGSIDE
// l1_acc_shadow.v, not a replacement for it.
//
// SIM/SYNTH PATH -- read this before touching either branch below:
//   yosys (run_synth.py) predefines `SYNTHESIS` on every `read_verilog`
//   (its own -h: "implicit -D SYNTHESIS"; confirmed empirically, not just
//   read off the help text) so it always takes the `ifdef SYNTHESIS branch:
//   the REAL sky130_fd_sc_hd__dlclkp_1 is instantiated. yosys cannot see
//   inside a physical cell, so a (* blackbox *) stub with the same three
//   ports is declared below purely so `hierarchy` has something to resolve
//   the instance against; `stat -liberty` then prices the instance by name
//   straight out of the liberty (17.5168 um^2), same as any other tech cell
//   -- the stub contributes zero logic of its own.
//
//   iverilog (verify.py) never defines `SYNTHESIS`, so it always takes the
//   `else branch: a behavioural model of the SAME latch, transcribed
//   directly from the liberty's own description of this cell, not a
//   hand-waved shortcut --
//     statetable ("CLK GATE","M0"): "L L : - : L, L H : - : H, H - : - : N"
//       i.e. M0 (the internal latch) is TRANSPARENT to GATE while CLK is
//       LOW, and HOLDS while CLK is HIGH, regardless of GATE.
//     state_function on GCLK: "(CLK*M0)"  ->  GCLK = CLK & M0.
//   (both read straight from cell ("sky130_fd_sc_hd__dlclkp_1") in
//   w1_rom_synthesis/lib/sky130_fd_sc_hd__tt_025C_1v80.lib.)
//
// Neither of those two paragraphs is proof by itself -- the proof is
// l2_synthesis/tb/tb_l1_acc_shadow_cg_equiv.v, which drives this module and
// l1_acc_shadow.v from IDENTICAL stimulus and checks a1_out matches every
// cycle, including a capture asserted in the same cycle as a read and
// capture held low for many cycles. If that TB does not pass, the two
// models do not provably match and this file should not be trusted for an
// area claim regardless of what either branch above says in isolation.
//
// `capture` must be stable while CLK is high for the real cell (liberty
// setup_rising/hold_rising checks on GATE vs CLK) -- true here because
// `capture` is itself driven synchronously by the caller (build-ctrl) and
// only changes shortly after a posedge, the same requirement any
// registered enable already has. STA on the real cell still has to confirm
// it, pre-P&R timing is not that proof either -- see the report's risk list.
`include "ckpt_defs.vh"

`ifdef SYNTHESIS
// GUARDED because ckpt_rtl/ckpt_block.v declares the identical stub for its own
// out-ACC clock gate, and run_synth.py reads both files in one yosys invocation.
// Whichever is read first wins; a second, unguarded declaration is a re-definition
// error, not a silent override.
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
    input  wire capture,                  // gates the single clock gate this cycle
    input  wire [32*W-1:0] acc_live,      // live hidden ACC, 32 x W signed
    input  wire [2:0] rd_grp,             // which group of 4 units to read
    output wire [4*W-1:0] a1_out          // 4 units -> the requant_unit lanes
);
    wire gclk;

`ifdef SYNTHESIS
    sky130_fd_sc_hd__dlclkp_1 cg (
        .CLK  (clk),
        .GATE (capture),
        .GCLK (gclk)
    );
`else
    // INTENTIONAL LATCH -- this is the M0 transcription described in the header:
    // transparent to GATE while CLK is low, holding while CLK is high. Verilator's
    // LATCH check is an ERROR in librelane's lint step (Checker.LintErrors), so it is
    // silenced around exactly these lines rather than globally in config.json. NOT
    // `always_latch`: that is a SystemVerilog keyword, and a tool-dialect mismatch is
    // what took this repo's CI down once already.
    reg gate_latched;
    /* verilator lint_off LATCH */
    always @(*)
        if (!clk) gate_latched = capture;
    /* verilator lint_on LATCH */
    assign gclk = clk & gate_latched;
`endif

    reg [32*W-1:0] snap;
    always @(posedge gclk) snap <= acc_live;

    assign a1_out = snap[rd_grp*(4*W) +: 4*W];
endmodule
