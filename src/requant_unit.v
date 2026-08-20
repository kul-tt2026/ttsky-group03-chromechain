module requant_unit (
    input  wire signed [11:0] a1,
    input  wire               sgn,
    input  wire signed [11:0] bias,
    input  wire [1:0]         k,
    output wire [3:0]         h
);
    wire signed [9:0] t  = (sgn ? -$signed(a1) : $signed(a1)) + $signed(bias);
    wire signed [9:0] shift = t >>> k;
    assign h = (shift <= 0) ? 4'd0 : (shift >= 15) ? 4'd15 : shift[3:0];
endmodule
