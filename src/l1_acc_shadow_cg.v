// l1_acc_shadow_cg -- clock-gated A1 snapshot bank. Same ports, function and result as
// l1_acc_shadow, but the capture enable is one integrated clock gate
// (sky130_fd_sc_hd__dlclkp_1) on the clock instead of an enable pin on every flop.
// ckpt_block selects it with SHADOW_CG=1 (the default); the two must match bit for bit.
`include "ckpt_defs.vh"

// ---------------------------------------------------------------- PDK cell stub
// Guarded: ckpt_block.v declares the identical stub under the same macro, and both files
// are in info.yaml's source_files, so synthesis reads them in one yosys invocation -- an
// unguarded second declaration is a hard error. The stub is blackbox + keep so that yosys
// leaves the instance alone and `stat -liberty` can cost it by cell name.
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
    // ---- behavioural model (any build without SYNTHESIS defined) ----------------------
    // Behavioural model of the cell, for simulation and lint. The liberty describes it as
    //     state_function : "(CLK * M0)"
    // where M0 is an internal TRANSPARENT LATCH on GATE:
    //     while CLK is LOW  -> M0 follows GATE
    //     while CLK is HIGH -> M0 HOLDS
    // The hold is the whole point: without it, a change on `capture` during the high
    // phase would chop gclk and clock the bank at a moment nobody intended. A plain
    // `clk & capture` is therefore NOT an equivalent model of this cell.
    //
    reg gate_latched;
    // verilator lint_off LATCH
    always @(*)
        if (!clk) gate_latched = capture;
    // verilator lint_on LATCH

    assign gclk = clk & gate_latched;

`endif

    // ---- the bank ---------------------------------------------------------------------
    // 32*W plain flops, loaded from acc_live on every gclk edge; a1_out reads back four
    // units (4*W bits) selected by rd_grp. Identical to l1_acc_shadow except there is no
    // `if (capture)` -- the gated clock itself decides. No reset, same as l1_acc_shadow
    // (a deliberate area choice): the contents are undefined until the first capture.
    reg [32*W-1:0] chain;
    always @(posedge gclk) chain <= acc_live;

    assign a1_out = chain[rd_grp*(4*W) +: 4*W];

endmodule
