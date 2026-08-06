// ckpt_block -- Fase-1 integration: 13 verified modules, one datapath, +120 flops of
// new logic (the out-ACC register; l2_mac_x4 is combinational so the accumulator it
// feeds back into exists nowhere else).
//
// BOUNDARY SKEW: the A1 snapshot below reads acc_next (D side), not acc_live (Q side).
// plane_end fires DURING a plane's last accumulate cycle, so acc_live at that edge is
// one pixel short of the plane boundary. Invisible under dense (1/10000 images has a
// nonzero final pixel), wrong in 69.5% of zero-skip planes. Do not change this wire.
//
// W1 ROM is a port (w1_addr out / w1_row in), not an instance: w1_h32_case.v holds a
// DIFFERENT weight fold than requant_rom_x4/l2_weight_rom_x4 (both FINAL4_s12_fold_a),
// instantiating it makes L1 and L2 compute different networks. rom_addr is shared by
// both ROMs as P*rd_grp + lane -- lane i must see addr % P == i or it returns silently
// wrong data.
//
// No FSM here: img_start/swap/scan_start are inputs (top_fsm.v). K10: inv_plane wires
// through but stays 0 on page 1 -- inverting needs a row-sum correction that doesn't
// exist yet (bitplane_buffer.v).
`include "ckpt_defs.vh"

`ifdef SYNTHESIS
`ifndef SKY130_FD_SC_HD__DLCLKP_1_DECLARED
`define SKY130_FD_SC_HD__DLCLKP_1_DECLARED
(* blackbox *)
(* keep *)
module sky130_fd_sc_hd__dlclkp_1 (
    input  CLK,
    input  GATE,
    output GCLK
);
endmodule
`endif
`endif

module ckpt_block #(
    parameter ACC_CNT       = `ACC_CNT_DEFAULT,
    parameter W             = `ACC_W,
    parameter SHADOW_CG     = 1,
    parameter OACC_CG       = `OACC_CG_DEFAULT,
    parameter EN_SKIP_FUSED = 0,
    parameter CFG_NWORDS    = `CFG_WORDS,
    parameter CFG_ADDRW     = `CFG_ADDR_W,
    parameter MODE1_ONLY    = 0   // synthesis probe only: ties ckpt_en=0 to price mode 3's cost
) (
    input  wire                          clk,
    input  wire                          rst_n,

    input  wire                          img_start,
    input  wire                          swap,
    input  wire                          scan_start,

    input  wire                          ld_en,
    input  wire [`LD_W-1:0]              ld_data,
    input  wire                          ld_vstrobe,
    output wire                          ld_ready,
    output wire                          ld_done,
    output wire [1:0]                    ld_idx,

    output wire [`PIX_W-1:0]             w1_addr,
    input  wire [(2*`NHID)-1:0]          w1_row,

    input  wire                          cfg_wr_en,
    input  wire [CFG_ADDRW-1:0]          cfg_addr,
    input  wire [`CFG_W-1:0]             cfg_wr_data,
    input  wire                          cfg_blob_done,
    output wire [`CFG_W-1:0]             cfg_rd_data,
    output wire                          blob_loaded,
    output wire                          page_sel,
    output wire [`N_CAP_W-1:0]           n_cap,

    output wire                          plane_start,
    output wire                          plane_end,
    output wire                          scan_busy,
    output wire [`LEN_W-1:0]             plane_len,
    output wire                          plane_valid,
    output wire [1:0]                    plane_idx,
    output wire                          fill_full,

    output wire                          y_valid,
    output wire                          dec_valid,
    output wire                          exit_strobe,
    output wire [2:0]                    exit_k,
    output wire [2:0]                    chk_idx,
    output wire                          ckpt_busy,
    output wire [3:0]                    answer,
    output wire [2:0]                    exit_k_held,
    output wire                          ans_valid,

    output wire [`OACC_BUS-1:0]          y,
    output wire [3:0]                    tree_argmax,
    output wire                          tree_done,
    output wire signed [`OACC_W-1:0]     tree_margin,

    output wire                          sched_err,
    output wire                          scan_err,
    output wire                          frame_err
);
    wire [(3*`T_W)-1:0] t_cfg;
    wire [`PLANES-2:0]  ckpt_en_cfg;
    wire                en_skip, en_vstrobe;
    wire [`PLANES-1:0]  inv_plane;

    config_latch #(.NWORDS(CFG_NWORDS), .ADDR_W(CFG_ADDRW)) cfg (
        .clk(clk), .rst_n(rst_n),
        .wr_en(cfg_wr_en), .addr(cfg_addr), .wr_data(cfg_wr_data),
        .blob_done(cfg_blob_done), .rd_data(cfg_rd_data),
        .t_cfg(t_cfg), .ckpt_en(ckpt_en_cfg), .en_skip(en_skip), .page_sel(page_sel),
        .inv_plane(inv_plane), .n_cap(n_cap), .en_vstrobe(en_vstrobe),
        .blob_loaded(blob_loaded)
    );

    // The mode switch: mode 3 is ckpt_en from the blob, mode 1 is the same net at 0.
    // Both drain through the same requant/l2_mac_x4/exit_tree_2stage below.
    wire [`PLANES-2:0] ckpt_en = (MODE1_ONLY != 0) ? {(`PLANES-1){1'b0}} : ckpt_en_cfg;

    wire [`NPIX-1:0] plane;
    wire [`PC_W-1:0] pop;
    wire             pix_act;

    bitplane_buffer bpb (
        .clk(clk), .rst_n(rst_n), .img_start(img_start),
        .ld_en(ld_en), .ld_data(ld_data), .ld_vstrobe(ld_vstrobe),
        .ld_ready(ld_ready), .ld_done(ld_done), .ld_idx(ld_idx),
        .inv_plane(inv_plane), .en_vstrobe(en_vstrobe),
        .swap(swap), .plane(plane), .plane_valid(plane_valid),
        .plane_idx(plane_idx), .fill_full(fill_full), .frame_err(frame_err)
    );

    popcount pc (.bits(plane), .count(pop));

    active_pixel_scan #(.EN_SKIP_FUSED(EN_SKIP_FUSED)) scan (
        .clk(clk), .rst_n(rst_n), .en_skip(en_skip), .start(scan_start),
        .plane(plane), .plane_valid(plane_valid), .pop(pop),
        .pix_idx(w1_addr), .pix_act(pix_act), .plane_start(plane_start),
        .plane_end(plane_end), .busy(scan_busy), .plane_len(plane_len),
        .scan_err(scan_err)
    );

    wire [(`NHID*W)-1:0] acc_live, acc_next;

    generate
    if (ACC_CNT) begin : g_cnt
        l1_horner_cnt #(.W(W)) l1 (
            .clk(clk), .img_start(img_start), .plane_start(plane_start),
            .act(pix_act), .w_col(w1_row),
            .acc_live(acc_live), .acc_next(acc_next)
        );
    end else begin : g_add
        l1_horner_acc #(.W(W)) l1 (
            .clk(clk), .img_start(img_start), .plane_start(plane_start),
            .act(pix_act), .w_col(w1_row),
            .acc_live(acc_live), .acc_next(acc_next)
        );
    end
    endgenerate

    wire                         capture, sgn, oacc_sel_init, oacc_en;
    wire [2:0]                   rd_grp;
    wire [(`P*`CKPT_ADDR_W)-1:0] rom_addr;
    wire [1:0]                   bias_sh;
    wire [`OACC_BUS-1:0]         oacc_init;
    wire [`T_W-1:0]              t_sel;

    checkpoint_ctrl ctrl (
        .clk(clk), .rst_n(rst_n), .img_start(img_start), .plane_end(plane_end),
        .ckpt_en(ckpt_en), .t_cfg(t_cfg),
        .tree_done(tree_done), .tree_argmax(tree_argmax),
        .capture(capture), .rd_grp(rd_grp), .rom_addr(rom_addr),
        .sgn(sgn), .bias_sh(bias_sh),
        .oacc_init(oacc_init), .oacc_sel_init(oacc_sel_init), .oacc_en(oacc_en),
        .y_valid(y_valid), .t_sel(t_sel),
        .dec_valid(dec_valid), .exit_strobe(exit_strobe), .exit_k(exit_k),
        .chk_idx(chk_idx), .busy(ckpt_busy), .answer(answer),
        .exit_k_held(exit_k_held), .ans_valid(ans_valid), .sched_err(sched_err)
    );

    // acc_NEXT, not acc_live -- see BOUNDARY SKEW above.
    wire [(`P*W)-1:0] a1_out;
    generate
        if (SHADOW_CG != 0) begin : shadow_cg
            l1_acc_shadow_cg #(.W(W)) bank (
                .clk(clk), .capture(capture), .acc_live(acc_next),
                .rd_grp(rd_grp), .a1_out(a1_out)
            );
        end else begin : shadow_en
            l1_acc_shadow #(.W(W)) bank (
                .clk(clk), .capture(capture), .acc_live(acc_next),
                .rd_grp(rd_grp), .a1_out(a1_out)
            );
        end
    endgenerate

    wire [(`P*`THETAK_ROW_W)-1:0] thetak;
    wire [(`P*`W2_ROW_W)-1:0]     w2col;
    requant_rom_x4   rq  (.addr(rom_addr), .wcol(thetak));
    l2_weight_rom_x4 w2r (.addr(rom_addr), .wcol(w2col));

    wire [(`P*`H_W)-1:0] h;
    genvar u;
    generate
        for (u = 0; u < `P; u = u + 1) begin : lane
            wire signed [`CKPT_BIAS_W-1:0] bias_raw =
                thetak[`THETAK_ROW_W*u +: `CKPT_BIAS_W];
            wire [`K_W-1:0] kq =
                thetak[`THETAK_ROW_W*u + `CKPT_BIAS_W +: `K_W];
            wire signed [W-1:0] a1_raw = a1_out[W*u +: W];

            // Arithmetic shift -- matches numpy floor semantics; 24/32 FINAL4 biases
            // are negative, so a logical shift here is silently wrong, not obviously.
            wire signed [`BIAS_W-1:0] bias_ext = $signed(bias_raw);
            wire signed [`BIAS_W-1:0] bias_shf = bias_ext >>> bias_sh;
            wire signed [`BIAS_W-1:0] a1_ext   = $signed(a1_raw);

            requant_unit ru (
                .a1   (a1_ext),
                .sgn  (sgn),   // checkpoint_ctrl ties this 0; fold's sign is +1 for all 32 units
                .bias (bias_shf),
                .k    (kq),
                .h    (h[`H_W*u +: `H_W])
            );
        end
    endgenerate

    // The only new sequential logic in this file: l2_mac_x4 is combinational, so this
    // register IS the out-ACC accumulator (NCLASS x OACC_W = 120 b).
    reg  [`OACC_BUS-1:0] oacc;
    wire [`OACC_BUS-1:0] acc_in = oacc_sel_init ? oacc_init : oacc;
    wire [`OACC_BUS-1:0] acc_out;

    l2_mac_x4 mac (.h_in(h), .w_in(w2col), .acc_in(acc_in), .acc_out(acc_out));

    generate
        if (OACC_CG != 0) begin : oacc_gated
            wire ogclk;
`ifdef SYNTHESIS
            sky130_fd_sc_hd__dlclkp_1 ocg (.CLK(clk), .GATE(oacc_en), .GCLK(ogclk));
`else
            reg ogate;
            always @(*)
                if (!clk) ogate = oacc_en;
            assign ogclk = clk & ogate;
`endif
            always @(posedge ogclk) oacc <= acc_out;
        end else begin : oacc_enabled
            always @(posedge clk)
                if (oacc_en) oacc <= acc_out;
        end
    endgenerate

    assign y = oacc;

    // T is registered by checkpoint_ctrl alongside y -- t_sel must be right on the
    // y_valid cycle, two cycles before done (TREE_LAT), not on the done cycle itself.
    exit_tree_2stage tree (
        .clk(clk), .y(oacc), .T(t_sel),
        .argmax(tree_argmax), .done(tree_done), .margin(tree_margin)
    );

`ifndef SYNTHESIS
    initial begin
        if (`OACC_BUS != 120) begin
            $display("ckpt_block: FAIL `OACC_BUS = %0d, l2_mac_x4 is fixed at 120", `OACC_BUS);
            $finish;
        end
        if (`P != 4) begin
            $display("ckpt_block: FAIL `P = %0d, the x4 ROMs and l2_mac_x4 are fixed at 4", `P);
            $finish;
        end
        if (W > `BIAS_W) begin
            $display("ckpt_block: FAIL W = %0d does not fit requant_unit's %0d b ports", W, `BIAS_W);
            $finish;
        end
    end
`endif
endmodule
