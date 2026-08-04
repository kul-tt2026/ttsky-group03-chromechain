// l1_horner_cnt -- l1_horner_acc's accumulator as an up/down counter instead of an
// adder. Same values in, same values out; only how the +-1 update is built differs.
//
// l1_horner_acc writes the update as base + delta, forcing synthesis to build a
// general W-bit adder per lane for a value that's always +1/-1/0 -- 2,985 cells,
// 16,458 um2 across 32 lanes, the largest block in the chip. A conditional
// increment/decrement is a carry chain instead: two gates per bit, not a full adder.
// Everything else is copied unchanged: the gated add/sub decode, the
// img_start-dominates-plane_start Horner ordering, the acc_next D-side output
// (ckpt_block's BOUNDARY SKEW).
`include "ckpt_defs.vh"

module l1_horner_cnt #(parameter W = `ACC_W) (
    input  wire                 clk,
    input  wire                 img_start,
    input  wire                 plane_start,
    input  wire                 act,
    input  wire [2*`NHID-1:0]   w_col,
    output wire [`NHID*W-1:0]   acc_live,
    output wire [`NHID*W-1:0]   acc_next
);

    genvar j, b;
    generate
        for (j = 0; j < `NHID; j = j + 1) begin : lane
            reg signed [W-1:0] q;

            wire inc = act & w_col[2*j + 1];
            wire dec = act & w_col[2*j];

            wire signed [W-1:0] base = img_start   ? {W{1'b0}}
                                     : plane_start ? {q[W-2:0], 1'b0}
                                                   : q;

            // dn, not plain dec: l1_horner_acc's inc ? +1 : dec ? -1 : 0 means +1 wins
            // if a malformed ROM row ever sets p and n together. Using dec directly
            // would count down there instead -- unreachable on real ROM content, but a
            // real divergence the equivalence check catches in the first few cycles.
            wire dn = dec & ~inc;

            wire [W:0] c;
            wire [W-1:0] nxt_w;
            assign c[0] = inc | dn;
            for (b = 0; b < W; b = b + 1) begin : bit
                assign nxt_w[b] = base[b] ^ c[b];
                assign c[b+1]   = c[b] & (base[b] ^ dn);
            end

            wire signed [W-1:0] nxt = nxt_w;

            always @(posedge clk)
                q <= nxt;

            assign acc_live[j*W +: W] = q;
            assign acc_next[j*W +: W] = nxt;
        end
    endgenerate

endmodule
