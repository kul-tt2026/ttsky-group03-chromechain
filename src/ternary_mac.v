module ternary_mac(input wire clk,
                   input wire rst_n,
                   input wire en,
                   input wire clear,
                   input wire [3:0] pixel,
                   input wire signed [1:0] weight,
                   output reg signed [8:0] accumulator);
    
    reg signed [8:0] acc_next;

    always @(*) begin
        case(weight)
          2'sd1: acc_next = accumulator + {{5{1'b0}},pixel};
          -2'sd1: acc_next = accumulator - {{5{1'b0}},pixel};
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