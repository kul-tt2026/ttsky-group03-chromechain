// cc_top -- chip level: ckpt_block + top_fsm + blob_loader + the W1 ROM.
// Instantiates w1_rom_final4 (the FINAL4 fold), never w1_rom_synthesis's area-study ROM.
// CFG_NWORDS/CFG_ADDRW drive the latch AND the loader from one parameter pair.
`include "ckpt_defs.vh"

// ---------------------------------------------------------------- THE v1.1 LEVERS
// Four area levers, all of them parameters and all of them defaulting to v1. W and
// OACC_CG were already here; ACC_CNT and the config-latch geometry are added so a
// TESTBENCH can reach them, not only `chparam`. run_synth.py could always poke a nested
// parameter (`chparam -set NWORDS 6 config_latch`), but iverilog cannot -- so lever 3 and
// lever 4 were priced on configurations no simulation had ever run. tb_cc_top.v says it
// itself: "an area number for a configuration nobody simulated is worthless".
//
// CFG_NWORDS/CFG_ADDRW drive config_latch AND blob_loader from one pair. They are not two
// independent knobs: the loader owns the word counter and the address, so a 48 b latch
// behind a 16-word loader wraps words 8..15 onto 0..5 and zeroes the thresholds without
// raising blob_err. See blob_loader.v's "NWORDS IS A CONTRACT".
// Every default comes from ckpt_defs.vh, so "which build is this" is one question with one
// answer in one file. v1 is this module with W=12, OACC_CG=0, ACC_CNT=0, CFG_NWORDS=16,
// CFG_ADDRW=4 -- see ckpt_defs.vh's "WHICH BUILD IS THIS".
module cc_top #(
    parameter W             = `ACC_W,
    parameter SHADOW_CG     = 1,
    parameter OACC_CG       = `OACC_CG_DEFAULT,
    parameter EN_SKIP_FUSED = 0,
    parameter ACC_CNT       = `ACC_CNT_DEFAULT,   // 1 = l1_horner_cnt (carry chain)
    parameter CFG_NWORDS    = `CFG_WORDS,         // latch geometry AND the blob contract;
    parameter CFG_ADDRW     = `CFG_ADDR_W         //   they are one knob, never two
) (
    input  wire                   clk,
    input  wire                   rst,          // synchronous, active high

    // ---- image framing
    input  wire                   start,        // 1-cycle pulse: begin an image
    output wire                   busy,
    output wire                   done,         // 1-cycle pulse: `answer` is valid

    // ---- pixel fill port (stage 0/1), `LD_W = 8 b per beat
    input  wire                   ld_en,
    input  wire [`LD_W-1:0]       ld_data,
    input  wire                   ld_vstrobe,   // K11
    output wire                   ld_ready,
    output wire                   ld_done,
    output wire [1:0]             ld_idx,

    // ---- config blob port
    input  wire                   cfg_mode,     // held high for the whole load
    input  wire                   cfg_stb,      // one pulse per word
    input  wire [`CFG_W-1:0]      cfg_din,
    output wire [`CFG_W-1:0]      cfg_rd_data,  // readback: march test + DFT scan-out
    output wire                   blob_loaded,  // K12

    // ---- result
    output wire [3:0]             answer,
    output wire [2:0]             exit_k,       // 0 = ran to the end, else the checkpoint
    output wire                   ans_valid,

    // ---- sticky alarms. Every one is a loud version of a silently-wrong-answer class.
    output wire                   sched_err,    // checkpoint scheduling violated
    output wire                   scan_err,     // pixel sequencer violated its contract
    output wire                   frame_err,    // plane framing violated
    output wire                   blob_err,     // config load overran
    output wire                   cap_err       // n_cap out of range in the blob
);

    // ---- ckpt_block <-> the rest
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

    // ---- W1 ROM. One page; see W1 ROM in the header for why this file and not the
    // other, and where page 2 would attach.
    w1_rom_final4 u_w1 (.addr(w1_addr), .wcol(w1_row));
    // PAGE-2 MUX POINT:
    //   wire [63:0] row_p1, row_p2;
    //   w1_rom_final4  u_w1_p1 (.addr(w1_addr), .wcol(row_p1));
    //   w1_rom_thermal u_w1_p2 (.addr(w1_addr), .wcol(row_p2));
    //   assign w1_row = page_sel ? row_p2 : row_p1;

    // ---- config blob
    blob_loader #(.NWORDS(CFG_NWORDS), .ADDR_W(CFG_ADDRW)) u_blob (
        .clk(clk), .rst(rst),
        .cfg_mode(cfg_mode), .cfg_stb(cfg_stb), .cfg_din(cfg_din),
        .cfg_wr_en(cfg_wr_en), .cfg_addr(cfg_addr), .cfg_wr_data(cfg_wr_data),
        .cfg_blob_done(cfg_blob_done),
        .loading(), .words_seen(), .blob_err(blob_err)
    );

    // ---- sequencer
    top_fsm u_fsm (
        .clk(clk), .rst(rst),
        .start(start), .blob_loaded(blob_loaded), .n_cap(n_cap),
        .fill_full(fill_full), .scan_busy(scan_busy), .plane_end(plane_end),
        .exit_strobe(exit_strobe), .ans_valid(blk_ans_valid),
        .img_start(img_start), .swap(swap), .scan_start(scan_start),
        .busy(busy), .done(done), .planes_run(), .cap_err(cap_err)
    );

    // ---- the datapath
    ckpt_block #(
        .W(W), .SHADOW_CG(SHADOW_CG), .OACC_CG(OACC_CG),
        .EN_SKIP_FUSED(EN_SKIP_FUSED), .MODE1_ONLY(0), .ACC_CNT(ACC_CNT),
        .CFG_NWORDS(CFG_NWORDS), .CFG_ADDRW(CFG_ADDRW)
    ) u_blk (
        .clk(clk), .rst(rst),
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
