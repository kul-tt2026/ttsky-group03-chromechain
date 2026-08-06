// One activation / requant unit. B1 needs P copies of this.
module requant_unit (
    input  wire signed [11:0] a1,
    input  wire               sgn,
    input  wire signed [11:0] bias,
    input  wire [1:0]         k,
    output wire [3:0]         h
);
    wire signed [12:0] t  = (sgn ? -$signed(a1) : $signed(a1)) + $signed(bias);
    wire signed [12:0] sh = t >>> k;
    assign h = (sh <= 0) ? 4'd0 : (sh >= 15) ? 4'd15 : sh[3:0];
endmodule
