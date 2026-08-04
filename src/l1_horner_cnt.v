// l1_horner_cnt -- l1_horner_acc's accumulator written as an up/down COUNTER instead of
// an adder. Functionally identical; the only difference is how the +-1 update is
// expressed, and therefore what yosys builds.
//
// WHY. The ternary weight makes the per-cycle update exactly +1, -1 or 0. l1_horner_acc
// writes that as `base + delta` with delta a W-bit signed constant, so synthesis has no
// choice but to build a general W-bit adder: 2,985 cells, 16,458 um2 of combinational
// logic for 32 lanes -- 514 um2 per lane for what is arithmetically an increment. That
// block is 1.92 t, the largest in the chip, and it is the first place to look when the
// question is whether the design fits 3x2.
//
// THE FORM. A conditional increment/decrement is a carry chain, not an adder:
//     c[0]   = inc | dec                     start the chain only when something happens
//     n[i]   = q[i] ^ c[i]                   flip on carry
//     c[i+1] = c[i] & (q[i] ^ dec)           propagate while 1 (inc) or while 0 (dec)
// Two gates per bit rather than a full-adder cell per bit. Same result, and `dec` is the
// only thing that distinguishes counting up from counting down.
//
// Everything else is copied unchanged from l1_horner_acc: the same gated add/sub decode,
// the same img_start-dominates-plane_start ordering for the Horner x2, and the same
// acc_next output that the A1 shadow samples from the D side (ckpt_block's BOUNDARY SKEW).
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

            wire inc = act & w_col[2*j + 1];        // p -> +1
            wire dec = act & w_col[2*j];            // n -> -1

            wire signed [W-1:0] base = img_start   ? {W{1'b0}}
                                     : plane_start ? {q[W-2:0], 1'b0}   // 2*ACC
                                                   : q;

            // `dn` and not plain `dec`: l1_horner_acc writes `inc ? +1 : dec ? -1 : 0`,
            // so +1 WINS when a malformed ROM row sets p and n together. Using `dec`
            // directly would count down there instead -- unreachable on real content
            // (rom_gen.encode_column never sets both) but a real divergence, and the
            // random equivalence check finds it in the first handful of cycles.
            wire dn = dec & ~inc;

            // carry chain: c[0] starts only if this cycle counts at all
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
