// ckpt_block -- the integration: fourteen modules wired into one datapath. It owns
// exactly one register, the OACC_BUS-wide out-ACC. Almost every trap in the design lives
// on one of its nets, and a wrong wire here compiles clean and computes a plausible
// wrong answer.
//   THE ONE TO GET RIGHT: the A1 snapshot is fed from l1_horner_acc's acc_NEXT (its D
//   side), not acc_live. plane_end is asserted during the plane's last accumulate cycle,
//   so at that edge the flop output is still one pixel short. Invisible under dense
//   ordering, wrong in 69.5% of zero-skip planes.
//   The W1 ROM is a PORT here, not an instance -- cc_top owns it.
`include "ckpt_defs.vh"

`ifdef SYNTHESIS
// Also declared by l1_acc_shadow_cg.v; both files may be read in one invocation, so the
// declaration is guarded rather than duplicated. See that file's header for why a
// blackbox stub of the real cell is what `stat -liberty` needs.
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
    parameter ACC_CNT = `ACC_CNT_DEFAULT,   // 1 = carry-chain accumulator (l1_horner_cnt)
    // L1 accumulator width. `ACC_W = 12; W = 11 is the DESIGN_LEDGER Aug-1 floor, priced
    // through run_synth.py's PARAM_OVERRIDES exactly as l1_horner_acc/l1_acc_shadow are.
    parameter W             = `ACC_W,
    // 1 = l1_acc_shadow_cg (one integrated clock gate), 0 = l1_acc_shadow (384 enables).
    parameter SHADOW_CG     = 1,
    // out-ACC storage: 0 = 120 load-enable flops (edfxtp_1), 1 = 120 plain flops behind
    // one dlclkp_1. v1 was 0 -- the coding ckpt_tb/tb_checkpoint_ctrl.v had been verifying
    // since Jul 30. v1.1 takes the gate; both codings stay in verify.py's gate and both
    // are measured, see l2_synthesis/results.md.
    parameter OACC_CG       = `OACC_CG_DEFAULT,
    // passed straight to active_pixel_scan: 0 = config bit, 1 = fused zero-skip,
    // 2 = fused dense.
    parameter EN_SKIP_FUSED = 0,
    // config_latch geometry, PASSED THROUGH so a build can reach it from a testbench.
    // Defaults follow ckpt_defs.vh: 6 words / 48 b since v1.1, 16 / 128 b in v1.
    // run_synth.py used to reach this with `chparam -set NWORDS 6 config_latch`, which
    // works for a synthesis probe and is unreachable from iverilog -- and an area number
    // for a configuration nobody simulated is worthless (tb_cc_top.v's own words). The
    // loader that fills this latch is parameterised in lockstep one level up; see
    // blob_loader.v's "NWORDS IS A CONTRACT".
    parameter CFG_NWORDS = `CFG_WORDS,
    parameter CFG_ADDRW  = `CFG_ADDR_W,
    // SYNTHESIS PROBE, NEVER A SHIPPING BUILD. 1 ties `ckpt_en` to 0 at elaboration, so
    // yosys deletes everything that exists only to serve mode 3 -- the arming decode, the
    // threshold mux, the pending-check slot, exit_tree_2stage's rT compare. The delta
    // against the default build is therefore the silicon COST of the conformal exit
    // mechanism, which is the number the flagship same-die A/B owes alongside its cycle
    // saving. It is a probe and not a candidate: a die built this way has no mode 3, so it
    // has no A/B, and the flagship claim (DESIGN_LEDGER.md:39) needs BOTH arms on ONE die.
    // Note what it does NOT delete, which is the point of the gamma-matched framing: the
    // requant lanes, l2_mac_x4 and exit_tree_2stage all survive, because mode 1 needs them
    // too. See l2_synthesis/results.md "What the exit mechanism costs".
    parameter MODE1_ONLY = 0
) (
    input  wire                          clk,
    input  wire                          rst,          // synchronous, active high

    // ---- image framing. Fase 3's FSM drives these; see NOT IN SCOPE above.
    input  wire                          img_start,    // 1-cycle pulse before plane 1
    input  wire                          swap,         // promote fill -> active
    input  wire                          scan_start,   // 1-cycle pulse, IS cycle t = 0

    // ---- host fill port (stage 0)
    input  wire                          ld_en,
    input  wire [`LD_W-1:0]              ld_data,
    input  wire                          ld_vstrobe,   // K11
    output wire                          ld_ready,
    output wire                          ld_done,
    output wire [1:0]                    ld_idx,

    // ---- W1 ROM, external. See "W1 ROM: A PORT".
    output wire [`PIX_W-1:0]             w1_addr,
    input  wire [(2*`NHID)-1:0]          w1_row,       // unit j = {p,n} at [2j+1:2j]

    // ---- config-latch host port (the only reloadable state on the chip)
    input  wire                          cfg_wr_en,
    input  wire [CFG_ADDRW-1:0]          cfg_addr,
    input  wire [`CFG_W-1:0]             cfg_wr_data,
    input  wire                          cfg_blob_done,
    output wire [`CFG_W-1:0]             cfg_rd_data,
    output wire                          blob_loaded,  // K12
    output wire                          page_sel,
    output wire [`N_CAP_W-1:0]           n_cap,

    // ---- datapath status, to the top FSM
    output wire                          plane_start,
    output wire                          plane_end,
    output wire                          scan_busy,
    output wire [`LEN_W-1:0]             plane_len,
    output wire                          plane_valid,
    output wire [1:0]                    plane_idx,
    output wire                          fill_full,

    // ---- decision
    output wire                          y_valid,
    output wire                          dec_valid,
    output wire                          exit_strobe,
    output wire [2:0]                    exit_k,       // 0 = final answer, else 1..3
    output wire [2:0]                    chk_idx,
    output wire                          ckpt_busy,
    output wire [3:0]                    answer,
    output wire [2:0]                    exit_k_held,
    output wire                          ans_valid,

    // ---- the score vector and the tree's raw outputs (the Fase-1 gate observes these)
    output wire [`OACC_BUS-1:0]          y,            // out-ACC, class 9 (MSB) .. 0
    output wire [3:0]                    tree_argmax,
    output wire                          tree_done,
    output wire signed [`OACC_W-1:0]     tree_margin,

    // ---- sticky alarms. All three must stay low; each is a loud version of a bug
    // class that would otherwise be a silently wrong answer.
    output wire                          sched_err,
    output wire                          scan_err,
    output wire                          frame_err
);
    // ------------------------------------------------------------------ config latch
    wire [(3*`T_W)-1:0] t_cfg;
    wire [`PLANES-2:0]  ckpt_en_cfg;
    wire                en_skip, en_vstrobe;
    wire [`PLANES-1:0]  inv_plane;

    config_latch #(.NWORDS(CFG_NWORDS), .ADDR_W(CFG_ADDRW)) cfg (
        .clk(clk), .rst(rst),
        .wr_en(cfg_wr_en), .addr(cfg_addr), .wr_data(cfg_wr_data),
        .blob_done(cfg_blob_done), .rd_data(cfg_rd_data),
        .t_cfg(t_cfg), .ckpt_en(ckpt_en_cfg), .en_skip(en_skip), .page_sel(page_sel),
        .inv_plane(inv_plane), .n_cap(n_cap), .en_vstrobe(en_vstrobe),
        .blob_loaded(blob_loaded)
    );

    // THE MODE SWITCH, and it is one net. Mode 3 is `ckpt_en` from the blob; mode 1 is the
    // same net at 0. There is no mode-dependent datapath anywhere below this line -- both
    // modes drain through the single requant / l2_mac_x4 / exit_tree_2stage instances,
    // which is what makes gamma a property of the die rather than of the mode and the
    // same-die A/B honest. MODE1_ONLY only lets synthesis PRICE the difference; it is not
    // how the mode is selected at run time.
    wire [`PLANES-2:0] ckpt_en = (MODE1_ONLY != 0) ? {(`PLANES-1){1'b0}} : ckpt_en_cfg;

    // ------------------------------------------------------------------ input side
    wire [`NPIX-1:0] plane;
    wire [`PC_W-1:0] pop;
    wire             pix_act;

    bitplane_buffer bpb (
        .clk(clk), .rst(rst), .img_start(img_start),
        .ld_en(ld_en), .ld_data(ld_data), .ld_vstrobe(ld_vstrobe),
        .ld_ready(ld_ready), .ld_done(ld_done), .ld_idx(ld_idx),
        .inv_plane(inv_plane), .en_vstrobe(en_vstrobe),
        .swap(swap), .plane(plane), .plane_valid(plane_valid),
        .plane_idx(plane_idx), .fill_full(fill_full), .frame_err(frame_err)
    );

    popcount pc (.bits(plane), .count(pop));

    active_pixel_scan #(.EN_SKIP_FUSED(EN_SKIP_FUSED)) scan (
        .clk(clk), .rst(rst), .en_skip(en_skip), .start(scan_start),
        .plane(plane), .plane_valid(plane_valid), .pop(pop),
        .pix_idx(w1_addr), .pix_act(pix_act), .plane_start(plane_start),
        .plane_end(plane_end), .busy(scan_busy), .plane_len(plane_len),
        .scan_err(scan_err)
    );

    // ------------------------------------------------------------------ L1
    wire [(`NHID*W)-1:0] acc_live, acc_next;

    // ACC_CNT picks the accumulator FORM, not its behaviour: l1_horner_cnt is proven
    // equivalent to l1_horner_acc over 200,000 random cycles and differs only in writing
    // the +-1 update as a carry chain instead of an adder (-0.149 t standalone). Default
    // 0 keeps the shipping build bit-identical; the parameter exists so the saving can be
    // measured AT CHIP LEVEL, because l1_horner_cnt is 1.3 ns slower standalone and the
    // accumulator sits at the tail of the chip's critical path -- so the area win might
    // cost fmax, and that has to be measured rather than assumed.
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

    // ------------------------------------------------------------------ controller
    wire                         capture, sgn, oacc_sel_init, oacc_en;
    wire [2:0]                   rd_grp;
    wire [(`P*`CKPT_ADDR_W)-1:0] rom_addr;
    wire [1:0]                   bias_sh;
    wire [`OACC_BUS-1:0]         oacc_init;
    wire [`T_W-1:0]              t_sel;

    checkpoint_ctrl ctrl (
        .clk(clk), .rst(rst), .img_start(img_start), .plane_end(plane_end),
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

    // ------------------------------------------------------- A1 snapshot bank
    // acc_NEXT, not acc_live -- see BOUNDARY SKEW in the header. This one net is the
    // difference between a bit-exact block and one that is quietly a pixel behind.
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

    // ------------------------------------------------------------------ ROMs (I8)
    // One shared address bus for both ROMs. checkpoint_ctrl builds it as
    // `P*rd_grp + lane, so lane i always sees addr % `P == i -- which is what the
    // GROUPED decode requires and what it returns wrong data (not an error) without.
    wire [(`P*`THETAK_ROW_W)-1:0] thetak;
    wire [(`P*`W2_ROW_W)-1:0]     w2col;
    requant_rom_x4   rq  (.addr(rom_addr), .wcol(thetak));
    l2_weight_rom_x4 w2r (.addr(rom_addr), .wcol(w2col));

    // ------------------------------------------------------------ requant lanes
    wire [(`P*`H_W)-1:0] h;
    genvar u;
    generate
        for (u = 0; u < `P; u = u + 1) begin : lane
            // ROM word: [`CKPT_BIAS_W+`K_W-1 : `CKPT_BIAS_W] = k,
            //           [`CKPT_BIAS_W-1 : 0]                 = bias, two's complement.
            wire signed [`CKPT_BIAS_W-1:0] bias_raw =
                thetak[`THETAK_ROW_W*u +: `CKPT_BIAS_W];
            wire [`K_W-1:0] kq =
                thetak[`THETAK_ROW_W*u + `CKPT_BIAS_W +: `K_W];
            wire signed [W-1:0] a1_raw = a1_out[W*u +: W];

            // I2. Both widen by SIGN extension (signed-to-signed assignment) and the
            // shift is ARITHMETIC, matching numpy's floor semantics in
            // engine.py:true_score_at -- `s = PLANES - k_planes; bias >> s`. 24 of the
            // 32 FINAL4 bias values are negative, so a logical shift here is not a
            // subtle error, but it is a silent one: it compiles and every checkpoint
            // margin comes out wrong, which makes the frozen T2/T3 meaningless.
            wire signed [`BIAS_W-1:0] bias_ext = $signed(bias_raw);
            wire signed [`BIAS_W-1:0] bias_shf = bias_ext >>> bias_sh;
            wire signed [`BIAS_W-1:0] a1_ext   = $signed(a1_raw);

            requant_unit ru (
                .a1   (a1_ext),
                .sgn  (sgn),          // I1: checkpoint_ctrl ties this 0. The fold's
                                      // `sign` is +1 for all 32 units, and this port is
                                      // a NEGATE flag -- 1 would negate every activation.
                .bias (bias_shf),
                .k    (kq),
                .h    (h[`H_W*u +: `H_W])
            );
        end
    endgenerate

    // ------------------------------------------------------ L2 MAC + the out-ACC
    // THE ONLY NEW LOGIC IN THIS FILE. l2_mac_x4 is combinational, so this register is
    // the accumulator: `NCLASS x `OACC_W = 120 b.
    //
    // I3: acc_in is oacc_init (= b2, from checkpoint_ctrl) on the first read cycle of
    // every check and the feedback on the other seven. Preloading zero instead of b2
    // moves every class score by up to 3 -- well inside the T2 = 8 / T3 = 12 thresholds,
    // so it changes exit decisions rather than obviously breaking.
    reg  [`OACC_BUS-1:0] oacc;
    wire [`OACC_BUS-1:0] acc_in = oacc_sel_init ? oacc_init : oacc;
    wire [`OACC_BUS-1:0] acc_out;

    l2_mac_x4 mac (.h_in(h), .w_in(w2col), .acc_in(acc_in), .acc_out(acc_out));

    generate
        if (OACC_CG != 0) begin : oacc_gated
            // The l1_acc_shadow_cg pattern: one dlclkp_1 in front of 120 plain flops
            // instead of 120 enable pins. `oacc_en` is driven synchronously by
            // checkpoint_ctrl (it is a function of chk_cnt), so it is stable while CLK
            // is high -- the real cell's setup/hold requirement on GATE. The `else
            // branch is the same liberty statetable transcription l1_acc_shadow_cg.v
            // carries; see that file for the full derivation.
            wire ogclk;
`ifdef SYNTHESIS
            sky130_fd_sc_hd__dlclkp_1 ocg (.CLK(clk), .GATE(oacc_en), .GCLK(ogclk));
`else
            // INTENTIONAL LATCH -- it is the whole point of the model: the dlclkp_1
            // cell's internal M0, transparent to GATE while CLK is low and holding
            // while CLK is high. Verilator's LATCH check is an ERROR in librelane's
            // lint step (Checker.LintErrors), so silence it around exactly the lines
            // that mean it rather than globally in config.json. NOT `always_latch`:
            // that is a SystemVerilog keyword, and a tool-dialect mismatch is what
            // took this repo's CI down once already.
            reg ogate;
            /* verilator lint_off LATCH */
            always @(*)
                if (!clk) ogate = oacc_en;
            /* verilator lint_on LATCH */
            assign ogclk = clk & ogate;
`endif
            always @(posedge ogclk) oacc <= acc_out;
        end else begin : oacc_enabled
            always @(posedge clk)
                if (oacc_en) oacc <= acc_out;
        end
    endgenerate

    assign y = oacc;

    // ------------------------------------------------------------------ exit tree
    // I4: T is registered in stage 1 alongside y, so t_sel has to be right on the
    // y_valid cycle -- two cycles before done, not on the done cycle. checkpoint_ctrl
    // holds t_sel constant for the whole check, so it is valid on every cycle of it.
    // I5: y at cycle N -> argmax/done/margin at N+2 (`TREE_LAT).
    // I6: the >=T compare and the lowest-index tie-break live inside this module and
    //     are NOT re-implemented here. T2 = 8 and T3 = 12 were calibrated under exactly
    //     those two conventions.
    exit_tree_2stage tree (
        .clk(clk), .y(oacc), .T(t_sel),
        .argmax(tree_argmax), .done(tree_done), .margin(tree_margin)
    );

`ifndef SYNTHESIS
    initial begin
        // The out-ACC has to hold a `OACC_W-wide class score, and l2_mac_x4's ports are
        // hard-coded to 10 x 12 b. A ckpt_defs.vh edit that moves either must be a loud
        // failure here, not a truncation inside a port connection.
        if (`OACC_BUS != 120) begin
            $display("ckpt_block: FAIL `OACC_BUS = %0d, l2_mac_x4 is fixed at 120",
                     `OACC_BUS);
            $finish;
        end
        if (`P != 4) begin
            $display("ckpt_block: FAIL `P = %0d, the x4 ROMs and l2_mac_x4 are fixed at 4",
                     `P);
            $finish;
        end
        // requant_unit's a1/bias ports are 12 b; a wider ACC would be truncated by the
        // signed assignment above without a warning.
        if (W > `BIAS_W) begin
            $display("ckpt_block: FAIL W = %0d does not fit requant_unit's %0d b ports",
                     W, `BIAS_W);
            $finish;
        end
    end
`endif
endmodule
