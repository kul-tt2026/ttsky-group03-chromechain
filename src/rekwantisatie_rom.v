module rekwantisatie_rom (input wire [4:0] neuron_index,
                          output reg signed [5:0] bias,
                          output reg [1:0] k);
    always @(*) begin
        case (neuron_index)
            5'd0:  begin bias = 6'sd6;   k = 2'd1; end
            5'd1:  begin bias = -6'sd1;  k = 2'd1; end
            5'd2:  begin bias = 6'sd10;  k = 2'd1; end
            5'd3:  begin bias = 6'sd19;  k = 2'd2; end
            5'd4:  begin bias = -6'sd10; k = 2'd1; end
            5'd5:  begin bias = 6'sd12;  k = 2'd1; end
            5'd6:  begin bias = 6'sd2;   k = 2'd1; end
            5'd7:  begin bias = 6'sd0;   k = 2'd1; end
            5'd8:  begin bias = 6'sd15;  k = 2'd1; end
            5'd9:  begin bias = 6'sd9;   k = 2'd1; end
            5'd10: begin bias = 6'sd11;  k = 2'd1; end
            5'd11: begin bias = -6'sd10; k = 2'd1; end
            5'd12: begin bias = -6'sd8;  k = 2'd1; end
            5'd13: begin bias = 6'sd8;   k = 2'd1; end
            5'd14: begin bias = 6'sd10;  k = 2'd1; end
            5'd15: begin bias = 6'sd10;  k = 2'd1; end
            5'd16: begin bias = 6'sd13;  k = 2'd1; end
            5'd17: begin bias = 6'sd11;  k = 2'd1; end
            5'd18: begin bias = 6'sd10;  k = 2'd1; end
            5'd19: begin bias = 6'sd7;   k = 2'd0; end
            5'd20: begin bias = 6'sd13;  k = 2'd1; end
            5'd21: begin bias = -6'sd4;  k = 2'd1; end
            5'd22: begin bias = -6'sd2;  k = 2'd1; end
            5'd23: begin bias = -6'sd3;  k = 2'd1; end
            5'd24: begin bias = 6'sd7;   k = 2'd1; end
            5'd25: begin bias = 6'sd5;   k = 2'd1; end
            5'd26: begin bias = 6'sd4;   k = 2'd0; end
            5'd27: begin bias = 6'sd6;   k = 2'd1; end
            5'd28: begin bias = 6'sd29;  k = 2'd2; end
            5'd29: begin bias = 6'sd1;   k = 2'd1; end
            5'd30: begin bias = 6'sd7;   k = 2'd1; end
            5'd31: begin bias = -6'sd12; k = 2'd1; end
        endcase
    end
endmodule
