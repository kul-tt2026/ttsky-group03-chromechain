/*
module rekwantisatie_rom (input wire [4:0] neuron_index,
                          output reg signed [5:0] bias,
                          output reg [1:0] k);
    always @(*) begin
        case (neuron_index)
           5'd0: begin bias = -6'sd12; k = 2'd1; end
           ...
        endcase
    end
endmodule
*/