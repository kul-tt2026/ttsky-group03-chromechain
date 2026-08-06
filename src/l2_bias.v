module bias_rom_L2(input wire [3:0] class_idx,
                   output reg signed [2:0] bias);
    always@(*) begin
        case(class_idx)
            4'd0: bias = 3'sd1;
            4'd1: bias = 3'sd3;
            4'd2: bias = -3'sd2;
            4'd3: bias = 3'sd0;
            4'd4: bias = -3'sd1;
            4'd5: bias = -3'sd1;
            4'd6: bias = 3'sd0;
            4'd7: bias = 3'sd0;
            4'd8: bias = -3'sd2;
            4'd9: bias = 3'sd0;
            default: bias = 3'sd0;
        endcase        
    end


endmodule