module gewicht_rom_L2_wide(
    input  wire [4:0] neuron_index,      // 0..31, which hidden unit
    output reg  [19:0] w2_all            // 10 classes x 2b signed weight, class c at [2c+1:2c]
);
    always @(*) begin
        case (neuron_index)
            5'd0: w2_all = {2'sd1, 2'sd0, -2'sd1, 2'sd0, -2'sd1, 2'sd0, 2'sd0, 2'sd1, -2'sd1, 2'sd0};
            5'd1: w2_all = {2'sd1, -2'sd1, 2'sd1, 2'sd1, -2'sd1, -2'sd1, 2'sd0, -2'sd1, -2'sd1, 2'sd0};
            5'd2: w2_all = {-2'sd1, -2'sd1, 2'sd0, 2'sd0, 2'sd0, 2'sd0, 2'sd1, -2'sd1, 2'sd1, 2'sd0};
            5'd3: w2_all = {-2'sd1, 2'sd0, 2'sd1, 2'sd0, 2'sd0, -2'sd1, -2'sd1, 2'sd1, 2'sd1, -2'sd1};
            5'd4: w2_all = {-2'sd1, 2'sd0, 2'sd0, -2'sd1, -2'sd1, -2'sd1, 2'sd1, 2'sd1, -2'sd1, -2'sd1};
            5'd5: w2_all = {-2'sd1, -2'sd1, -2'sd1, 2'sd0, 2'sd1, -2'sd1, 2'sd1, 2'sd0, 2'sd0, 2'sd0};
            5'd6: w2_all = {2'sd0, -2'sd1, 2'sd1, -2'sd1, 2'sd1, -2'sd1, 2'sd0, 2'sd0, -2'sd1, -2'sd1};
            5'd7: w2_all = {-2'sd1, -2'sd1, 2'sd1, -2'sd1, 2'sd1, 2'sd1, -2'sd1, 2'sd0, 2'sd1, 2'sd1};
            5'd8: w2_all = {2'sd0, -2'sd1, 2'sd1, -2'sd1, 2'sd1, -2'sd1, -2'sd1, -2'sd1, 2'sd1, 2'sd0};
            5'd9: w2_all = {-2'sd1, 2'sd0, 2'sd0, -2'sd1, -2'sd1, -2'sd1, -2'sd1, -2'sd1, -2'sd1, 2'sd1};
            5'd10: w2_all = {2'sd0, 2'sd0, 2'sd1, -2'sd1, -2'sd1, -2'sd1, 2'sd1, 2'sd1, 2'sd1, 2'sd0};
            5'd11: w2_all = {2'sd1, -2'sd1, -2'sd1, -2'sd1, 2'sd1, 2'sd0, 2'sd1, 2'sd0, 2'sd0, -2'sd1};
            5'd12: w2_all = {2'sd0, 2'sd1, 2'sd0, -2'sd1, 2'sd0, 2'sd0, 2'sd1, -2'sd1, -2'sd1, -2'sd1};
            5'd13: w2_all = {2'sd0, 2'sd1, -2'sd1, 2'sd0, 2'sd0, -2'sd1, 2'sd0, 2'sd0, -2'sd1, 2'sd0};
            5'd14: w2_all = {-2'sd1, -2'sd1, 2'sd1, 2'sd0, -2'sd1, 2'sd1, 2'sd1, 2'sd0, 2'sd1, 2'sd0};
            5'd15: w2_all = {-2'sd1, 2'sd1, 2'sd0, -2'sd1, 2'sd0, 2'sd0, -2'sd1, 2'sd1, 2'sd0, -2'sd1};
            5'd16: w2_all = {-2'sd1, 2'sd0, -2'sd1, 2'sd0, 2'sd1, -2'sd1, 2'sd1, -2'sd1, 2'sd0, 2'sd0};
            5'd17: w2_all = {2'sd1, 2'sd0, -2'sd1, -2'sd1, -2'sd1, 2'sd1, 2'sd0, -2'sd1, 2'sd1, -2'sd1};
            5'd18: w2_all = {2'sd0, 2'sd0, -2'sd1, -2'sd1, 2'sd1, 2'sd1, 2'sd1, -2'sd1, 2'sd0, -2'sd1};
            5'd19: w2_all = {2'sd1, -2'sd1, 2'sd1, -2'sd1, -2'sd1, 2'sd0, -2'sd1, -2'sd1, -2'sd1, -2'sd1};
            5'd20: w2_all = {-2'sd1, -2'sd1, -2'sd1, 2'sd0, 2'sd0, 2'sd0, -2'sd1, 2'sd1, -2'sd1, 2'sd0};
            5'd21: w2_all = {2'sd0, -2'sd1, -2'sd1, -2'sd1, -2'sd1, 2'sd0, -2'sd1, 2'sd0, -2'sd1, 2'sd1};
            5'd22: w2_all = {-2'sd1, 2'sd1, 2'sd0, 2'sd1, 2'sd0, 2'sd1, -2'sd1, 2'sd0, 2'sd0, 2'sd0};
            5'd23: w2_all = {2'sd0, 2'sd1, -2'sd1, 2'sd0, 2'sd0, 2'sd0, -2'sd1, -2'sd1, 2'sd0, -2'sd1};
            5'd24: w2_all = {2'sd1, 2'sd0, 2'sd0, 2'sd1, 2'sd1, -2'sd1, -2'sd1, -2'sd1, -2'sd1, 2'sd0};
            5'd25: w2_all = {-2'sd1, -2'sd1, 2'sd0, -2'sd1, -2'sd1, 2'sd0, -2'sd1, 2'sd1, -2'sd1, 2'sd1};
            5'd26: w2_all = {2'sd0, 2'sd0, -2'sd1, 2'sd0, -2'sd1, 2'sd0, -2'sd1, 2'sd1, 2'sd1, 2'sd0};
            5'd27: w2_all = {2'sd0, -2'sd1, 2'sd0, -2'sd1, 2'sd0, 2'sd1, -2'sd1, 2'sd1, -2'sd1, 2'sd0};
            5'd28: w2_all = {2'sd0, -2'sd1, -2'sd1, 2'sd1, 2'sd0, 2'sd1, -2'sd1, 2'sd0, 2'sd1, -2'sd1};
            5'd29: w2_all = {2'sd0, -2'sd1, 2'sd0, 2'sd1, 2'sd1, -2'sd1, -2'sd1, -2'sd1, -2'sd1, 2'sd0};
            5'd30: w2_all = {-2'sd1, -2'sd1, 2'sd1, 2'sd1, 2'sd0, 2'sd0, 2'sd1, -2'sd1, -2'sd1, 2'sd0};
            5'd31: w2_all = {2'sd0, 2'sd1, -2'sd1, 2'sd1, -2'sd1, 2'sd0, -2'sd1, -2'sd1, 2'sd0, 2'sd1};
            default: w2_all = 20'sd0;
        endcase
    end
endmodule