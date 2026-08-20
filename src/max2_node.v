module max2_node(
    input wire signed [11:0] a_max, input wire [3:0] a_idx, input wire signed [11:0] a_sec,
    input wire signed [11:0] b_max, input wire [3:0] b_idx, input wire signed [11:0] b_sec,
    output wire signed [11:0] LeMax, output wire [3:0] LeIdx, output wire signed [11:0] LeSec
);
    wire a_wins = (a_max >= b_max);
    assign LeMax = a_wins ? a_max : b_max;
    assign LeIdx = a_wins ? a_idx : b_idx;
    wire signed [11:0] lose_max = a_wins ? b_max : a_max;
    wire signed [11:0] win_sec  = a_wins ? a_sec : b_sec;
    assign LeSec = (lose_max >= win_sec) ? lose_max : win_sec;
endmodule
