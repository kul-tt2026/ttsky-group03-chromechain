// Wrapper for formal_wrap.sh: top_fsm with n_cap tied to 7, to prove P3b changes
// nothing for this n_cap value (or, for 1..3, to show exactly where it differs).
`include "ckpt_defs.vh"
module top_fsm_ncap7 (
    input  wire clk, input wire rst, input wire start, input wire blob_loaded,
    input  wire fill_full, input wire scan_busy, input wire plane_end,
    input  wire exit_strobe, input wire ans_valid,
    output wire img_start, output wire swap, output wire scan_start,
    output wire busy, output wire done, output wire [2:0] planes_run, output wire cap_err);
    top_fsm u (.clk(clk), .rst(rst), .start(start), .blob_loaded(blob_loaded),
        .n_cap(3'd7), .fill_full(fill_full), .scan_busy(scan_busy), .plane_end(plane_end),
        .exit_strobe(exit_strobe), .ans_valid(ans_valid), .img_start(img_start), .swap(swap),
        .scan_start(scan_start), .busy(busy), .done(done), .planes_run(planes_run),
        .cap_err(cap_err));
endmodule
