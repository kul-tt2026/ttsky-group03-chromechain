// l2_mac_x4 -- L2 ternary MAC, purely combinational. For each of the 10 classes c:
//   acc_out[c] = acc_in[c] + Σ over the 4 lanes u of  trit(u,c) × h[u]
// Instantiated once, in ckpt_block (mac): h_in from the four requant_unit lanes, w_in
// from l2_weight_rom_x4, acc_in the out-ACC register (or its once-per-check preload).
module l2_mac_x4 (
    input wire  [15:0] h_in, //4x4b unsigned activation
    input wire  [79:0] w_in, //4x20b W2 trits, unit u at [20u +: 20]; bit order: see decode
    input wire  [119:0] acc_in,   //10x12 b signed out-ACC
    output wire [119:0] acc_out 
);
    genvar c;
    generate
        for (c = 0; c < 10; c = c + 1) begin : cls
            // W2 trit for (unit u, class c) is the bit pair w_in[20*u + 2*c +: 2]:
            //   bit 20u+2c   (LOW bit)  set -> +h[u]
            //   bit 20u+2c+1 (HIGH bit) set -> -h[u]
            //   neither set             -> 0   (both set decodes as +h[u]: +1 is tested first)
            // This is the OPPOSITE bit order from W1: l1_horner_acc takes +1 from
            // w_col[2j+1] (high bit) and -1 from w_col[2j] (low bit). The generated ROM
            // contents (l2_weight_rom_x4 here, w1_rom_final4 for W1) encode these exact
            // conventions, so swapping the two selects below negates every W2 weight and
            // nothing reports it -- the design still compiles and runs.
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
