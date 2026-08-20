// l1_acc_shadow_cg -- the clock-gated A1 snapshot bank.
//
// Same ports, same function, same result as l1_acc_shadow. The ONLY difference is how
// the enable is built: instead of 32*W flops each carrying an enable pin (edfxtp_1,
// 30.0288 um2), this uses plain flops (dfxtp_1, 20.0192) and stops the CLOCK with one
// integrated clock gate (dlclkp_1, 17.5168).
//
// Its spec is l1_acc_shadow, not engine.py. The two must be bit-identical every cycle;
// l2_synthesis/tb/tb_l1_acc_shadow_cg_equiv.v compiles both and compares them.
`include "ckpt_defs.vh"

// ---------------------------------------------------------------- PDK cell stub
// Guarded: ckpt_block.v declares the identical stub, and run_synth.py reads both files
// in one yosys invocation -- an unguarded second declaration is a hard error.
`ifdef SYNTHESIS
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
    // The real cell. Pin names are fixed by the PDK; yosys prices it by name.
    sky130_fd_sc_hd__dlclkp_1 cg (
        .CLK  (clk),
        .GATE (capture),
        .GCLK (gclk)
    );
`else
    // ---- YOURS (1) ----------------------------------------------------------------
    // Behavioural model of the cell, for iverilog only. The liberty says
    //     state_function : "(CLK * M0)"
    // where M0 is an internal TRANSPARENT LATCH on GATE:
    //     while CLK is LOW  -> M0 follows GATE
    //     while CLK is HIGH -> M0 HOLDS
    // The hold is the whole point: without it, a change on `capture` during the high
    // phase would chop gclk and clock the bank at a moment nobody intended.
    //
    reg gate_latched;
    // verilator lint_off LATCH
    always @(*)
        if (!clk) gate_latched = capture;
    // verilator lint_on LATCH

    assign gclk = clk & gate_latched;

`endif

    // ---- YOURS (2) --------------------------------------------------------------------
    // The bank. Identical to l1_acc_shadow except there is no `if (capture)` -- the
    // clock itself decides.
    reg [32*W-1:0] chain;
    always @(posedge gclk) chain <= acc_live;

    assign a1_out = chain[rd_grp*(4*W) +: 4*W];

endmodule
