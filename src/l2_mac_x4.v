//acc_out[c] = acc_in[c] + Σ over the 4 lanes u of  trit(u,c) × h[u]
module l2_mac_x4 (
    input wire  [15:0] h_in, //4x4b unsigned activation
    input wire  [79:0] w_in, //4x20b W2 trits ({p,n} per class)
    input wire  [119:0] acc_in,   //10x12 b signed out-ACC
    output wire [119:0] acc_out 
);
    genvar c;
    generate
        for (c = 0; c < 10; c = c + 1) begin : cls
            wire signed [7:0] a0 = w_in[20*0 + 2*c]     ? $signed({4'b0, h_in[4*0 +: 4]})
                                  : w_in[20*0 + 2*c + 1] ? -$signed({4'b0, h_in[4*0 +: 4]})
                                  : 8'sd0;
            wire signed [7:0] a1 = w_in[20*1 + 2*c]     ? $signed({4'b0, h_in[4*1 +: 4]})
                                  : w_in[20*1 + 2*c + 1] ? -$signed({4'b0, h_in[4*1 +: 4]})
                                  : 8'sd0;
            wire signed [7:0] a2 = w_in[20*2 + 2*c]     ? $signed({4'b0, h_in[4*2 +: 4]})
                                  : w_in[20*2 + 2*c + 1] ? -$signed({4'b0, h_in[4*2 +: 4]})
                                  : 8'sd0;
            wire signed [7:0] a3 = w_in[20*3 + 2*c]     ? $signed({4'b0, h_in[4*3 +: 4]})
                                  : w_in[20*3 + 2*c + 1] ? -$signed({4'b0, h_in[4*3 +: 4]})
                                  : 8'sd0;
            wire signed [7:0] s = a0 + a1 + a2 + a3;
            assign acc_out[12*c +: 12] = $signed(acc_in[12*c +: 12]) + $signed(s);
        end
    endgenerate
endmodule
