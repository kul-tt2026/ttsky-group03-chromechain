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
