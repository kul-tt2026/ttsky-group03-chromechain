`include "ckpt_defs.vh"

// cc_top -- the chip below the TT pin wrapper: W1 ROM + config blob loader +
// top_fsm sequencer + ckpt_block datapath, wired together, no logic of its own.
// Instantiates w1_rom_final4, NOT w1_h32_case.v (different fold, all 64/64 words
// differ) -- verify against rom_gen.py's encode_column() before ever changing this.
// Page 2 not wired: page_sel exists but there is no second ROM/mux yet.

module cc_top #(
    parameter W             = `ACC_W,
    parameter SHADOW_CG     = 1,
    parameter OACC_CG       = `OACC_CG_DEFAULT,
    parameter EN_SKIP_FUSED = 0,
    parameter ACC_CNT       = `ACC_CNT_DEFAULT,
    parameter CFG_NWORDS    = `CFG_WORDS,   // one knob with blob_loader's ADDR_W --
    parameter CFG_ADDRW     = `CFG_ADDR_W   //   drifting them apart wraps addresses silently
) (
    input  wire               clk,
    input  wire                rst_n,

    input  wire                start,
    output wire                busy,
    output wire                done,

    input  wire                ld_en,
    input  wire [`LD_W-1:0]    ld_data,
    input  wire                ld_vstrobe,
    output wire                ld_ready,
    output wire                ld_done,
    output wire [1:0]          ld_idx,

    input  wire                cfg_mode,
    input  wire                cfg_stb,
    input  wire [`CFG_W-1:0]   cfg_din,
    output wire [`CFG_W-1:0]   cfg_rd_data,
    output wire                blob_loaded,

    output wire [3:0]          answer,
    output wire [2:0]          exit_k,
    output wire                ans_valid,

    output wire                sched_err,
    output wire                scan_err,
    output wire                frame_err,
    output wire                blob_err,
    output wire                cap_err
);

    wire [`PIX_W-1:0]      w1_addr;
    wire [(2*`NHID)-1:0]   w1_row;

    wire                   cfg_wr_en, cfg_blob_done;
    wire [CFG_ADDRW-1:0]   cfg_addr;
    wire [`CFG_W-1:0]      cfg_wr_data;

    wire                   page_sel;
    wire [`N_CAP_W-1:0]    n_cap;

    wire                   img_start, swap, scan_start;
    wire                   plane_start, plane_end, scan_busy, plane_valid, fill_full;
    wire [`LEN_W-1:0]      plane_len;
    wire [1:0]             plane_idx;

    wire                   y_valid, dec_valid, exit_strobe, ckpt_busy;
    wire [2:0]             chk_idx, exit_k_held;
    wire [3:0]             blk_answer;
    wire                   blk_ans_valid;
    wire [`OACC_BUS-1:0]   y;
    wire [3:0]             tree_argmax;
    wire                   tree_done;
    wire signed [`OACC_W-1:0] tree_margin;

    w1_rom_final4 u_w1 (.addr(w1_addr), .wcol(w1_row));
    // page 2: wire [63:0] row_p1, row_p2; two ROM instances; assign w1_row = page_sel ? row_p2 : row_p1;

    blob_loader #(.NWORDS(CFG_NWORDS), .ADDR_W(CFG_ADDRW)) u_blob (
        .clk(clk), .rst_n(rst_n),
        .cfg_mode(cfg_mode), .cfg_stb(cfg_stb), .cfg_din(cfg_din),
        .cfg_wr_en(cfg_wr_en), .cfg_addr(cfg_addr), .cfg_wr_data(cfg_wr_data),
        .cfg_blob_done(cfg_blob_done),
        .loading(), .words_seen(), .blob_err(blob_err)
    );

    top_fsm u_fsm (
        .clk(clk), .rst_n(rst_n),
        .start(start), .blob_loaded(blob_loaded), .n_cap(n_cap),
        .fill_full(fill_full), .scan_busy(scan_busy), .plane_end(plane_end),
        .exit_strobe(exit_strobe), .ans_valid(blk_ans_valid),
        .img_start(img_start), .swap(swap), .scan_start(scan_start),
        .busy(busy), .done(done), .planes_run(), .cap_err(cap_err)
    );

    ckpt_block #(
        .W(W), .SHADOW_CG(SHADOW_CG), .OACC_CG(OACC_CG),
        .EN_SKIP_FUSED(EN_SKIP_FUSED), .MODE1_ONLY(0), .ACC_CNT(ACC_CNT),
        .CFG_NWORDS(CFG_NWORDS), .CFG_ADDRW(CFG_ADDRW)
    ) u_blk (
        .clk(clk), .rst_n(rst_n),
        .img_start(img_start), .swap(swap), .scan_start(scan_start),
        .ld_en(ld_en), .ld_data(ld_data), .ld_vstrobe(ld_vstrobe),
        .ld_ready(ld_ready), .ld_done(ld_done), .ld_idx(ld_idx),
        .w1_addr(w1_addr), .w1_row(w1_row),
        .cfg_wr_en(cfg_wr_en), .cfg_addr(cfg_addr), .cfg_wr_data(cfg_wr_data),
        .cfg_blob_done(cfg_blob_done), .cfg_rd_data(cfg_rd_data),
        .blob_loaded(blob_loaded), .page_sel(page_sel), .n_cap(n_cap),
        .plane_start(plane_start), .plane_end(plane_end), .scan_busy(scan_busy),
        .plane_len(plane_len), .plane_valid(plane_valid), .plane_idx(plane_idx),
        .fill_full(fill_full),
        .y_valid(y_valid), .dec_valid(dec_valid), .exit_strobe(exit_strobe),
        .exit_k(exit_k), .chk_idx(chk_idx), .ckpt_busy(ckpt_busy),
        .answer(blk_answer), .exit_k_held(exit_k_held), .ans_valid(blk_ans_valid),
        .y(y), .tree_argmax(tree_argmax), .tree_done(tree_done),
        .tree_margin(tree_margin),
        .sched_err(sched_err), .scan_err(scan_err), .frame_err(frame_err)
    );

    assign answer    = blk_answer;
    assign ans_valid = blk_ans_valid;

endmodule
