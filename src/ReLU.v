module ReLU(input wire signed [8:0] in,
            output wire [7:0] out);
    
    assign out = in[8] ? 8'd0 : in[7:0];
endmodule