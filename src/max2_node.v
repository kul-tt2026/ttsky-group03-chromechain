// One max/max2 tournament merge node. Shared by exit_tree and exit_tree_2stage.
module max2_node (
    input  wire signed [11:0] a_max, input wire [3:0] a_idx, input wire signed [11:0] a_sec,
    input  wire signed [11:0] b_max, input wire [3:0] b_idx, input wire signed [11:0] b_sec,
    output wire signed [11:0] o_max, output wire [3:0] o_idx, output wire signed [11:0] o_sec
);
    wire a_wins = (a_max >= b_max);              // tie -> lower-index subtree
    assign o_max = a_wins ? a_max : b_max;
    assign o_idx = a_wins ? a_idx : b_idx;
    wire signed [11:0] lose_max = a_wins ? b_max : a_max;
    wire signed [11:0] win_sec  = a_wins ? a_sec : b_sec;
    assign o_sec = (lose_max >= win_sec) ? lose_max : win_sec;
endmodule
