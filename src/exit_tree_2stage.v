// exit_tree_2stage -- max / runner-up tournament over the 10 class scores in y (the
// out-ACC register in ckpt_block), cut into two pipeline stages. y presented at cycle N
// -> argmax / done / margin valid at N+2.
// T is registered in stage 1 ALONGSIDE y, in the same always block as the stage-1
// survivors, so the stage-2 compare sees the threshold that belonged to this y, not
// whatever the T port carries a cycle later when stage 2 evaluates. Do not bypass or
// re-time rT.
module exit_tree_2stage (
    input  wire         clk,
    input  wire [119:0] y,
    input  wire [9:0]   T,
    output reg  [3:0]   argmax,
    output reg          done,
    output reg  signed [11:0] margin
);
    wire signed [11:0] lm [0:9];
    wire        [3:0]  li [0:9];
    genvar g;
    generate
        for (g = 0; g < 10; g = g + 1) begin : leaf
            assign lm[g] = $signed(y[12*g +: 12]);
            assign li[g] = g[3:0];
        end
    endgenerate
    localparam signed [11:0] NEG = -12'sd2048;

    // ---- stage 1 (combinational): levels 1 and 2, 10 -> 3 survivors
    wire signed [11:0] m1_0,m1_1,m1_2,m1_3,m1_4, s1_0,s1_1,s1_2,s1_3,s1_4;
    wire [3:0] i1_0,i1_1,i1_2,i1_3,i1_4;
    max2_node n1_0 (lm[0],li[0],NEG, lm[1],li[1],NEG, m1_0,i1_0,s1_0);
    max2_node n1_1 (lm[2],li[2],NEG, lm[3],li[3],NEG, m1_1,i1_1,s1_1);
    max2_node n1_2 (lm[4],li[4],NEG, lm[5],li[5],NEG, m1_2,i1_2,s1_2);
    max2_node n1_3 (lm[6],li[6],NEG, lm[7],li[7],NEG, m1_3,i1_3,s1_3);
    max2_node n1_4 (lm[8],li[8],NEG, lm[9],li[9],NEG, m1_4,i1_4,s1_4);
    wire signed [11:0] m2_0,m2_1, s2_0,s2_1;
    wire [3:0] i2_0,i2_1;
    max2_node n2_0 (m1_0,i1_0,s1_0, m1_1,i1_1,s1_1, m2_0,i2_0,s2_0);
    max2_node n2_1 (m1_2,i1_2,s1_2, m1_3,i1_3,s1_3, m2_1,i2_1,s2_1);

    // ---- pipeline registers: 3 x (max, idx, sec) = 84 b, plus rT (10 b)
    reg signed [11:0] rm0,rm1,rm2, rs0,rs1,rs2;
    reg        [3:0]  ri0,ri1,ri2;
    reg        [9:0]  rT;
    // No reset on any register in this module (rm*/ri*/rs*/rT, argmax/done/margin): a
    // deliberate area choice, like the L1 accumulator and the shadow bank. Every check
    // presents a fresh y and T two cycles before its done is read, so nothing stale is
    // ever consumed. Adding resets changes the area and timing being preserved.
    always @(posedge clk) begin
        rm0 <= m2_0; ri0 <= i2_0; rs0 <= s2_0;
        rm1 <= m2_1; ri1 <= i2_1; rs1 <= s2_1;
        rm2 <= m1_4; ri2 <= i1_4; rs2 <= s1_4;
        rT  <= T;
    end

    // ---- stage 2 (combinational): levels 3 and 4, 3 -> 1, then margin/threshold
    wire signed [11:0] m3, s3, m4, s4;
    wire [3:0] i3, i4;
    max2_node n3_0 (rm0,ri0,rs0, rm1,ri1,rs1, m3,i3,s3);
    max2_node n4_0 (m3,i3,s3, rm2,ri2,rs2, m4,i4,s4);
    always @(posedge clk) begin
        argmax <= i4;
        margin <= m4 - s4;
        // >= : a margin exactly equal to T counts as an exit. The default thresholds
        // T2 = 8 and T3 = 12 (T2_DEFAULT / T3_DEFAULT in ckpt_defs.vh) were calibrated
        // under this compare and under max2_node's lowest-index-wins tie-break (>= in
        // max2_node.v); changing either one moves the exit boundary they were fitted to.
        done   <= (m4 - s4) >= $signed({2'b0, rT});
    end
endmodule
