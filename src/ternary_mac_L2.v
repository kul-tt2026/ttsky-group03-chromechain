module ternary_mac_L2(input wire clk,
                      input wire rst_n,
                      input wire en,
                      input wire clear,
                      input wire [7:0] neuron,
                      input wire signed [1:0] weight,
                      output reg signed [13:0] accumulator);
    
    reg signed [13:0] acc_next;

    always @(*) begin
        case(weight)
          2'sd1: acc_next = accumulator + {{6{1'b0}},neuron};
          -2'sd1: acc_next = accumulator - {{6{1'b0}},neuron};
          2'sd0: acc_next = accumulator;
          default: acc_next = accumulator;
        endcase
    end

    always@(posedge clk or negedge rst_n) begin
        if (!rst_n)
            accumulator <= 0;
        else if (clear)
            accumulator <= 0;
        else if (en)
            accumulator <= acc_next;
    end

endmodule