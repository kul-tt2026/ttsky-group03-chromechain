// cc_top -- chip level: ckpt_block + top_fsm + blob_loader + the W1 ROM.
// Instantiates w1_rom_final4, the only W1 ROM in the repo (ckpt_block takes it as a port).
// CFG_NWORDS/CFG_ADDRW drive the latch AND the loader from one parameter pair.
`include "ckpt_defs.vh"

// ---------------------------------------------------------------- AREA PARAMETERS
// W, OACC_CG, ACC_CNT, CFG_NWORDS and CFG_ADDRW default to the ckpt_defs.vh values
// (ACC_W = 10, OACC_CG_DEFAULT = 1, ACC_CNT_DEFAULT = 1, CFG_WORDS = 6, CFG_ADDR_W = 3);
// SHADOW_CG and EN_SKIP_FUSED are literal defaults here. All are module parameters,
// overridable at instantiation, and are passed down to ckpt_block (the CFG pair to
// blob_loader as well).
//
// CFG_NWORDS/CFG_ADDRW drive config_latch AND blob_loader from one pair. They are not two
// independent knobs: the loader owns the word counter and the address, and neither
// module's elaboration check sees the other's parameters. A 6-word (48 b) latch behind a
// 16-word loader aliases blob words 8..15 onto latch addresses 0..7, so the tail of the
// blob overwrites the thresholds in words 0..3 and blob_err never rises -- the loader saw
// no overrun. See blob_loader.v's header.
module cc_top #(
    parameter W             = `ACC_W,             // L1 accumulator width (10)
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
    input  wire                   start,        // 1-cycle pulse: begin an image. Ignored
                                                // until blob_loaded and while an image runs
    output wire                   busy,
    output wire                   done,         // 1-cycle pulse: `answer` is valid

    // ---- pixel fill port: `LD_W = 8 b per beat into bitplane_buffer's fill half
    input  wire                   ld_en,
    input  wire [`LD_W-1:0]       ld_data,
    input  wire                   ld_vstrobe,   // host marks a plane's last beat. Ignored
                                                // unless the blob's en_vstrobe bit is set;
                                                // then a strobe on any beat but the last,
                                                // a last beat without one, or a strobe
                                                // outside a fill write, sets frame_err
    output wire                   ld_ready,
    output wire                   ld_done,
    output wire [1:0]             ld_idx,

    // ---- config blob port
    input  wire                   cfg_mode,     // held high for the whole load
    input  wire                   cfg_stb,      // one pulse per word
    input  wire [`CFG_W-1:0]      cfg_din,
    output wire [`CFG_W-1:0]      cfg_rd_data,  // the latch word at the loader's write
                                                // address (uo_out view 1, dft_sel = 1, in
                                                // the TT wrapper). Mid-load it shows the
                                                // word about to be overwritten; the address
                                                // parks at 6 after a complete load, outside
                                                // the 48 b latch, so the view is undefined
                                                // until the next load. No host read address.
    output wire                   blob_loaded,  // set on the blob's last word, cleared by
                                                // the next config write; top_fsm ignores
                                                // `start` until it is high

    // ---- result
    output wire [3:0]             answer,
    output wire [2:0]             exit_k,       // 0 = ran to the end, else the checkpoint
    output wire                   ans_valid,    // ckpt_block's pulse; `done` is its
                                                // registered copy one cycle later

    // ---- sticky alarms. Every one is a loud version of a silently-wrong-answer class.
    output wire                   sched_err,    // checkpoint scheduling violated
    output wire                   scan_err,     // pixel sequencer violated its contract
    output wire                   frame_err,    // plane framing violated
    output wire                   blob_err,     // config load overran
    output wire                   cap_err       // n_cap 0 or 5..7 in the blob (clamped to
                                                // 4). 1..3 pass the clamp and hang the
                                                // chip with no alarm: see top_fsm.v
);

    // ---- ckpt_block <-> the rest
    wire [`PIX_W-1:0]      w1_addr;
    wire [(2*`NHID)-1:0]   w1_row;

    wire                   cfg_wr_en, cfg_blob_done;
    wire [CFG_ADDRW-1:0]   cfg_addr;
    wire [`CFG_W-1:0]      cfg_wr_data;

    wire                   page_sel;     // decoded from the blob; drives nothing --
                                         // only one W1 page is instantiated
    wire [`N_CAP_W-1:0]    n_cap;

    wire                   img_start, swap, scan_start;
    wire                   plane_start, plane_end, scan_busy, plane_valid, fill_full;
    wire [`LEN_W-1:0]      plane_len;
    wire [1:0]             plane_idx;

    wire                   y_valid, dec_valid, exit_strobe, ckpt_busy;
    wire [2:0]             chk_idx, exit_k_held;   // exit_k_held is unused: the pins
                                                    // show the live exit_k, which holds
                                                    // because chk_k is never cleared
    wire [3:0]             blk_answer;
    wire                   blk_ans_valid;
    wire [`OACC_BUS-1:0]   y;
    wire [3:0]             tree_argmax;
    wire                   tree_done;
    wire signed [`OACC_W-1:0] tree_margin;

    // ---- W1 ROM (w1_rom_final4): one page, 64 rows x 64 b, unit j = {p,n} at
    // [2j+1:2j] with p (+1) the high bit. page_sel is not consulted.
    w1_rom_final4 u_w1 (.addr(w1_addr), .wcol(w1_row));

    // ---- config blob. loading/words_seen have no chip-level consumer.
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
