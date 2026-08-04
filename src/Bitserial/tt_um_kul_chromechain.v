// tt_um_kul_chromechain -- the Tiny Tapeout wrapper. Pin mapping only: one cc_top
// instance, no logic beyond the output mux. Everything that decides anything lives
// below in cc_top.
//
// ui_in[7:0]   THE DATA BUS. Pixel beats (LD_W=8, one plane = 8 beats) and config
//              words (CFG_W=8, one blob = CFG_WORDS words) share it -- never live at
//              once: config loads only while cfg_mode is high and no image is running.
// uio[7:0]     CONTROL IN, all inputs (uio_oe tied 0, no direction hazard):
//                [0] ld_en  [1] ld_vstrobe  [2] cfg_mode  [3] cfg_stb  [4] start
//                [6:5] dft_sel (readout view select)  [7] reserved, drive 0
// uo_out[7:0]  STATUS OUT, four views on dft_sel. View 0 is the operating view; the
//              other three are a DFT readout that costs nothing but the mux:
//                0  {err_any, busy, ld_ready, done, answer[3:0]}
//                1  cfg_rd_data[7:0]              -- config march test / scan-out
//                2  {blob_loaded, ld_done, ld_idx[1:0], 1'b0, exit_k[2:0]}
//                3  {3'b0, cap_err, blob_err, frame_err, scan_err, sched_err}
// The five sticky alarms in view 3 are each the loud version of a bug class that would
// otherwise be a silently wrong answer -- on returned silicon, the difference between
// "it classifies badly" and "frame_err is set" is a debug week vs a debug hour.
//
// page_sel is not on a pin -- it's a config-latch field, set by writing the blob.
// ena is ignored by design -- TT holds it high whenever the design is powered.
`default_nettype none
`include "ckpt_defs.vh"

module tt_um_kul_chromechain (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    wire       ld_en      = uio_in[0];
    wire       ld_vstrobe = uio_in[1];
    wire       cfg_mode   = uio_in[2];
    wire       cfg_stb    = uio_in[3];
    wire       start      = uio_in[4];
    wire [1:0] dft_sel    = uio_in[6:5];

    wire        busy, done, ld_ready, ld_done, blob_loaded, ans_valid;
    wire [1:0]  ld_idx;
    wire [7:0]  cfg_rd_data;
    wire [3:0]  answer;
    wire [2:0]  exit_k;
    wire        sched_err, scan_err, frame_err, blob_err, cap_err;

    cc_top u_cc (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done),
        .ld_en(ld_en), .ld_data(ui_in), .ld_vstrobe(ld_vstrobe),
        .ld_ready(ld_ready), .ld_done(ld_done), .ld_idx(ld_idx),
        .cfg_mode(cfg_mode), .cfg_stb(cfg_stb), .cfg_din(ui_in),
        .cfg_rd_data(cfg_rd_data), .blob_loaded(blob_loaded),
        .answer(answer), .exit_k(exit_k), .ans_valid(ans_valid),
        .sched_err(sched_err), .scan_err(scan_err), .frame_err(frame_err),
        .blob_err(blob_err), .cap_err(cap_err)
    );

    wire err_any = sched_err | scan_err | frame_err | blob_err | cap_err;

    reg [7:0] uo_r;
    always @(*) begin
        case (dft_sel)
            2'd0:    uo_r = {err_any, busy, ld_ready, done, answer};
            2'd1:    uo_r = cfg_rd_data;
            2'd2:    uo_r = {blob_loaded, ld_done, ld_idx, 1'b0, exit_k};
            default: uo_r = {3'b000, cap_err, blob_err, frame_err, scan_err, sched_err};
        endcase
    end
    assign uo_out  = uo_r;

    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;

    wire _unused = &{ena, ans_valid, uio_in[7], 1'b0};

endmodule
