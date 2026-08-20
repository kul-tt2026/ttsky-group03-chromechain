`include "ckpt_defs.vh"

module l1_acc_shadow #(parameter W = `ACC_W) (
    input  wire clk,
    input  wire capture,
    input  wire [32*W-1:0] acc_live,
    input  wire [2:0] rd_grp,
    output wire [4*W-1:0] a1_out
);

    reg [32*W-1:0] chain;
    always @(posedge clk) if (capture) chain <= acc_live;

    assign a1_out = chain[rd_grp*(4*W) +: 4*W];
endmodule
