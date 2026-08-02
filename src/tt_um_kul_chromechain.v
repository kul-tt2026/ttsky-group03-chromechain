// tt_um_kul_chromechain -- the Tiny Tapeout wrapper. Fase 4.
//
// Pin mapping and nothing else: one cc_top instance, no logic beyond the output mux and
// the active-low reset inversion. Everything that decides anything lives below.
//
// ---------------------------------------------------------------- the port list
// DESIGN_LEDGER Aug-1 item 7 lists the signals the chip owes -- DONE, argmax, valid
// strobe, page-select, DFT readout, config-load -- and records that the port list was
// "never costed". This is that costing. TT gives 8 dedicated inputs, 8 dedicated
// outputs and 8 bidirectionals, and the design needs more than 16 wires, so `ui_in`
// carries the only wide datapath and `uo_out` is muxed.
//
//   ui_in[7:0]   THE DATA BUS. Pixel beats (`LD_W = 8, one plane = 8 beats) and config
//                words (`CFG_W = 8, one blob = 16 words) share it. They are never live
//                at once: config loads while `cfg_mode` is high and no image is running,
//                which is exactly what tb_cc_top's K12 phase proves is enforced.
//
//   uio[7:0]     CONTROL IN. uio_oe is tied 0 -- every bidirectional is an input, so the
//                chip never drives them and there is no direction hazard to get wrong.
//                  [0] ld_en       [1] ld_vstrobe (K11)
//                  [2] cfg_mode    [3] cfg_stb
//                  [4] start
//                  [6:5] dft_sel   the readout view selector, below
//                  [7] reserved, drive 0
//
//   uo_out[7:0]  STATUS OUT, four views on `dft_sel`. View 0 is the operating view; the
//                other three are the DFT readout the ledger asks for, and they cost
//                nothing but the mux because every source already exists.
//                  0  {err_any, busy, ld_ready, done, answer[3:0]}
//                  1  cfg_rd_data[7:0]              -- config march test / scan-out
//                  2  {blob_loaded, ld_done, ld_idx[1:0], 1'b0, exit_k[2:0]}
//                  3  {3'b0, cap_err, blob_err, frame_err, scan_err, sched_err}
//
// View 3 is worth the pin. The five alarms are sticky and each is the loud version of a
// bug class that would otherwise be a silently wrong answer -- a scheduling violation, a
// torn plane, a scanner contract breach, a config overrun, an out-of-range N_cap. On
// returned silicon the difference between "it classifies badly" and "frame_err is set"
// is the difference between a debug week and a debug hour.
//
// `page_sel` is NOT on a pin: it is a config-latch field, so the host sets it by writing
// the blob rather than by holding a wire. It is observable through view 1.
//
// `ena` is ignored by design -- TT holds it high whenever the design is powered.
`default_nettype none
`include "ckpt_defs.vh"

module tt_um_kul_chromechain (
    input  wire [7:0] ui_in,    // dedicated inputs  -- the data bus
    output wire [7:0] uo_out,   // dedicated outputs -- muxed status
    input  wire [7:0] uio_in,   // IOs: input path   -- control
    output wire [7:0] uio_out,  // IOs: output path  -- unused, tied 0
    output wire [7:0] uio_oe,   // IOs: enable       -- all inputs
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ---- control decode
    wire       ld_en      = uio_in[0];
    wire       ld_vstrobe = uio_in[1];
    wire       cfg_mode   = uio_in[2];
    wire       cfg_stb    = uio_in[3];
    wire       start      = uio_in[4];
    wire [1:0] dft_sel    = uio_in[6:5];

    // ---- chip
    wire        busy, done, ld_ready, ld_done, blob_loaded, ans_valid;
    wire [1:0]  ld_idx;
    wire [7:0]  cfg_rd_data;
    wire [3:0]  answer;
    wire [2:0]  exit_k;
    wire        sched_err, scan_err, frame_err, blob_err, cap_err;

    cc_top u_cc (
        .clk(clk), .rst(~rst_n),
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

    // ---- output mux. Every pin is assigned in every view.
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

    // Bidirectionals are inputs only: nothing to drive, nothing to enable.
    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;

    // ans_valid is `done` one layer down; both are exposed (done on a pin, ans_valid
    // through the same wire) so listing it here keeps the linter quiet about neither
    // being unused nor duplicated.
    wire _unused = &{ena, ans_valid, uio_in[7], 1'b0};

endmodule
