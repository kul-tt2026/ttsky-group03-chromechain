module shift_kwantisatie(input signed [8:0] accumulator,
                         input signed [5:0] bias,
                         input wire [1:0] k,
                         output wire [3:0] h);
    
    wire signed[8:0] som;
    reg signed [8:0] shifted;

    assign som = accumulator + {{3{1'b0}},bias};

    always@(*) begin
        case(k)
           2'd0: shifted = som;
           2'd1: shifted = som >>> 1;
           2'd2: shifted = som >>> 2;
           2'd3: shifted = som >>> 3;
        endcase
    end

    assign h = shifted[8] ? 4'd0 : (|shifted[8:4]) ? 4'd15 : shifted[3:0];

endmodule