// checkpoint_ctrl -- lever A1: the conformal-exit checkpoint scheduler.
//
// The L1 datapath never stalls. At an armed plane boundary this FSM snapshots the L1
// accumulator into l1_acc_shadow(_cg) and walks it through requant -> L2 -> exit tree
// over the next GAMMA=11 cycles WHILE the datapath keeps accumulating the next plane.
// That overlap is A1's entire value: mode 3's no-exit cost is NPIX*PLANES + GAMMA =
// 267 cycles, identical to same-die mode 1.
//
// Scheduling rule: check_start(k) = max(end_of_plane(k), prev_check_end). One
// checkpoint unit, so check k+1 waits for check k. Reference: engine.py's
// boundary_cycles(overlap=True) -- cycle-exact and index-exact, NOT bit-exact (this
// module changes WHEN a check starts, never what it computes).
//
// Cycle map of one check, S = start cycle: S capture=1; S+1..S+8 rd_grp 0..7 (4 units/
// cycle through requant+l2_mac_x4); S+9 y_valid (t_sel must be correct THIS cycle, I4);
// S+11 dec_valid (I5: y at N -> done N+2). 8+1+2=11=GAMMA, checked at elaboration.
//
// ONE shadow bank suffices for the frozen {P2,P3} config because: a check only reads
// the shadow for its first 8 cycles, and ZS_FILL == RD_CYC == 8 by construction (both
// trace to bitplane_buffer's fill-port width) -- the next plane boundary structurally
// cannot arrive before the shadow frees. The final snapshot is deliberately DEFERRED to
// when the final check starts (the ACC is frozen after the last plane, so a late
// snapshot is still correct) -- a naive end-of-plane-4 capture would clobber an
// in-flight P3 check 23.4% of the time. This bound is pairwise-adjacent only; a config
// arming 3 consecutive checkpoints could break it -- not silently: sched_err goes
// sticky on any capture that would clobber a live read.
//
// Controller only -- instantiates no datapath, so "A1 total = l1_acc_shadow_cg +
// checkpoint_ctrl" is an honest accounting (everything else is shared with mode 1).
//
// INVARIANTS (each a silent-wrong-answer risk, not a compile error):
//   I1  sgn tied 0 -- fold's sign is +1 for all units; sgn=1 in requant_unit negates.
//   I2  bias_sh = PLANES - k_planes (2 at P2, 1 at P3, 0 at final), ARITHMETIC shift.
//   I3  oacc_init = b2, not zero -- l2_mac_x4 is a pure accumulator.
//   I4  t_sel valid on the y_valid cycle, 2 cycles before done.
//   I5  y at cycle N -> argmax/done/margin at N+2 (DEC_CYC).
//   I6  >=T compare and lowest-index tie-break live in exit_tree_2stage, not here.
//   I8  grouped ROM decode requires addr%P==lane; rom_addr is built as P*rd_grp+lane.
`include "ckpt_defs.vh"

module checkpoint_ctrl (
    input  wire                          clk,
    input  wire                          rst_n,

    input  wire                          img_start,
    input  wire                          plane_end,

    input  wire [`PLANES-2:0]            ckpt_en,
    input  wire [(3*`T_W)-1:0]           t_cfg,

    input  wire                          tree_done,
    input  wire [3:0]                    tree_argmax,

    output wire                          capture,
    output wire [2:0]                    rd_grp,

    output wire [(`P*`CKPT_ADDR_W)-1:0]  rom_addr,

    output wire                          sgn,
    output wire [1:0]                    bias_sh,

    output wire [`OACC_BUS-1:0]          oacc_init,
    output wire                          oacc_sel_init,
    output wire                          oacc_en,

    output wire                          y_valid,
    output wire [`T_W-1:0]               t_sel,

    output wire                          dec_valid,
    output wire                          exit_strobe,
    output wire [2:0]                    exit_k,
    output wire [2:0]                    chk_idx,
    output wire                          busy,
    output reg  [3:0]                    answer,
    output reg  [2:0]                    exit_k_held,
    output reg                           ans_valid,
    output reg                           sched_err
);
    localparam [3:0] RD_CYC  = `NHID / `P;
    localparam [3:0] Y_CYC   = (`NHID / `P) + 1;
    localparam [3:0] DEC_CYC = (`NHID / `P) + 1 + `TREE_LAT;
    localparam [2:0] FINAL_K = `PLANES;

    reg [2:0] plane_cnt;
    reg       chk_busy;
    reg [3:0] chk_cnt;
    reg [2:0] chk_k;
    reg       pend_valid;
    reg [2:0] pend_k;
    reg       fin_pend;
    reg       resolved;

    wire [2:0] k_next   = plane_cnt + 3'd1;
    wire       is_fin_b = (k_next == FINAL_K);
    wire       armed_here = (k_next == 3'd1) ? ckpt_en[0] :
                            (k_next == 3'd2) ? ckpt_en[1] :
                            (k_next == 3'd3) ? ckpt_en[2] : 1'b0;

    wire dec_now   = chk_busy && (chk_cnt == DEC_CYC);
    // t_sel is 0 at the final (always-true compare), so this agrees with tree_done by
    // construction; the explicit chk_k test is belt and braces, not a second policy.
    wire take_exit = dec_now && ((chk_k == FINAL_K) ? 1'b1 : tree_done);

    // Free this cycle: idle, or the in-flight check resolves now -- start = prev_check_end.
    wire unit_free = (!chk_busy) || dec_now;

    wire boundary_check = plane_end && !resolved && !take_exit && (is_fin_b || armed_here);

    wire start_pend = unit_free && !take_exit &&  pend_valid;
    wire start_bnd  = unit_free && !take_exit && !pend_valid &&  boundary_check;
    wire start_fin  = unit_free && !take_exit && !pend_valid && !boundary_check && fin_pend;
    wire start_now  = start_pend | start_bnd | start_fin;
    wire [2:0] start_k = start_pend ? pend_k :
                         start_bnd  ? k_next : FINAL_K;

    wire rd_active = chk_busy && (chk_cnt >= 4'd1) && (chk_cnt <= RD_CYC);

    assign rd_grp = rd_active ? (chk_cnt[2:0] - 3'd1) : 3'd0;

    genvar gi;
    generate
        for (gi = 0; gi < `P; gi = gi + 1) begin : lane_addr
            // I8: lane gi always sees addr % `P == gi.
            assign rom_addr[`CKPT_ADDR_W*gi +: `CKPT_ADDR_W] = (rd_grp * `P) + gi;
        end
    endgenerate

    // Immediate capture for an armed non-final boundary (ACC moves on right away);
    // deferred to the final check's start for the last plane -- see header.
    assign capture = (boundary_check && !is_fin_b)
                  || (start_now && (start_k == FINAL_K));

    assign sgn = 1'b0;   // I1

    wire [2:0] bias_sh_full = FINAL_K - chk_k;   // I2
    assign bias_sh = bias_sh_full[1:0];

    // I3: b2 from FINAL4_s12_fold_a.npz, class 9 (MSB) down to class 0.
    assign oacc_init = { `OACC_W'sh001,   // b2[9] =  1
                         `OACC_W'sh003,   // b2[8] =  3
                         `OACC_W'shffe,   // b2[7] = -2
                         `OACC_W'sh000,   // b2[6] =  0
                         `OACC_W'shfff,   // b2[5] = -1
                         `OACC_W'shfff,   // b2[4] = -1
                         `OACC_W'sh000,   // b2[3] =  0
                         `OACC_W'sh000,   // b2[2] =  0
                         `OACC_W'shffe,   // b2[1] = -2
                         `OACC_W'sh000 }; // b2[0] =  0
    assign oacc_sel_init = chk_busy && (chk_cnt == 4'd1);
    assign oacc_en       = rd_active;

    assign y_valid = chk_busy && (chk_cnt == Y_CYC);

    assign t_sel = (chk_k == 3'd1) ? t_cfg[0*`T_W +: `T_W] :
                   (chk_k == 3'd2) ? t_cfg[1*`T_W +: `T_W] :
                   (chk_k == 3'd3) ? t_cfg[2*`T_W +: `T_W] : {`T_W{1'b0}};

    assign dec_valid   = dec_now;
    assign exit_strobe = take_exit;
    assign exit_k      = (chk_k == FINAL_K) ? 3'd0 : chk_k;
    assign chk_idx     = chk_k;
    assign busy        = chk_busy;

    always @(posedge clk) begin
        if (!rst_n) begin
            plane_cnt  <= 3'd0;
            chk_busy   <= 1'b0;
            chk_cnt    <= 4'd0;
            chk_k      <= 3'd0;
            pend_valid <= 1'b0;
            pend_k     <= 3'd0;
            fin_pend   <= 1'b0;
            resolved   <= 1'b0;
            exit_k_held <= 3'd0;
            answer     <= 4'd0;
            ans_valid  <= 1'b0;
            sched_err  <= 1'b0;
        end else if (img_start) begin
            // Starting an image while a check is still in flight would drop it.
            if (chk_busy || pend_valid || fin_pend) sched_err <= 1'b1;
            plane_cnt  <= 3'd0;
            chk_busy   <= 1'b0;
            chk_cnt    <= 4'd0;
            pend_valid <= 1'b0;
            fin_pend   <= 1'b0;
            resolved   <= 1'b0;
            ans_valid  <= 1'b0;
        end else begin
            ans_valid <= 1'b0;

            if (plane_end) plane_cnt <= plane_cnt + 3'd1;

            if (boundary_check && !start_bnd) begin
                if (is_fin_b) begin
                    fin_pend <= 1'b1;
                end else begin
                    if (pend_valid) sched_err <= 1'b1;   // one pending slot only
                    pend_valid <= 1'b1;
                    pend_k     <= k_next;
                end
            end

            if (start_now) begin
                chk_busy <= 1'b1;
                chk_cnt  <= 4'd1;
                chk_k    <= start_k;
                if (start_pend) pend_valid <= 1'b0;
                if (start_fin)  fin_pend   <= 1'b0;
            end else if (dec_now) begin
                chk_busy <= 1'b0;
                chk_cnt  <= 4'd0;
            end else if (chk_busy) begin
                chk_cnt  <= chk_cnt + 4'd1;
            end

            if (take_exit) begin
                resolved   <= 1'b1;
                pend_valid <= 1'b0;
                fin_pend   <= 1'b0;
                exit_k_held <= (chk_k == FINAL_K) ? 3'd0 : chk_k;
                answer     <= tree_argmax;
                ans_valid  <= 1'b1;
            end

            // A capture on a read cycle other than the last would destroy the in-flight
            // check's snapshot -- unreachable for the frozen {P2,P3} config, loud if not.
            if (capture && rd_active && (chk_cnt != RD_CYC)) sched_err <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((`NHID / `P) + 1 + `TREE_LAT != `GAMMA) begin
            $display("checkpoint_ctrl: FAIL GAMMA mismatch: NHID/P + 1 + TREE_LAT = %0d, GAMMA = %0d",
                     (`NHID / `P) + 1 + `TREE_LAT, `GAMMA);
            $finish;
        end
        if ((`NHID / `P) != `ZS_FILL) begin
            $display("checkpoint_ctrl: FAIL single-shadow bound broken: NHID/P = %0d, ZS_FILL = %0d",
                     (`NHID / `P), `ZS_FILL);
            $finish;
        end
    end
`endif
endmodule
