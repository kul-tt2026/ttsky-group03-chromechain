// checkpoint_ctrl -- decides when each conformal-exit check runs and sequences the shared
// checkpoint datapath through it. One check is `GAMMA = 11 cycles: 8 read cycles (4 hidden
// units requantised and L2-accumulated per cycle), 1 to present y, 2 in the exit tree. The
// L1 datapath never stalls: the shadow bank snapshots the accumulator at each boundary.
`include "ckpt_defs.vh"

module checkpoint_ctrl (
    input  wire                          clk,
    input  wire                          rst,          // synchronous, active high

    // ---- from top_fsm (img_start) and active_pixel_scan (plane_end). Neither is ever
    // back-pressured: the datapath does not stall for a check; the shadow bank snapshots it.
    input  wire                          img_start,    // 1-cycle pulse before plane 1
    input  wire                          plane_end,    // pulse DURING the last
                                                       // accumulate cycle of a plane

    // ---- from config_latch
    input  wire [`PLANES-2:0]            ckpt_en,      // arm bits: bit0=P1, bit1=P2, bit2=P3
    input  wire [(3*`T_W)-1:0]           t_cfg,        // {T3,T2,T1}, `T_W each

    // ---- from exit_tree_2stage
    input  wire                          tree_done,
    input  wire [3:0]                    tree_argmax,

    // ---- to l1_acc_shadow / l1_acc_shadow_cg
    output wire                          capture,
    output wire [2:0]                    rd_grp,

    // ---- to l2_weight_rom_x4 and requant_rom_x4 (shared address bus)
    output wire [(`P*`CKPT_ADDR_W)-1:0]  rom_addr,

    // ---- to the `P requant_unit lanes
    output wire                          sgn,          // negate flag; tied 0 here
    output wire [1:0]                    bias_sh,      // bias >>> amount, `PLANES - k

    // ---- to the out-ACC register in front of exit_tree_2stage
    output wire [`OACC_BUS-1:0]          oacc_init,    // b2, the L2 bias preload
    output wire                          oacc_sel_init,// select oacc_init, not feedback
    output wire                          oacc_en,

    // ---- to exit_tree_2stage
    output wire                          y_valid,      // y presented, t_sel valid
    output wire [`T_W-1:0]               t_sel,

    // ---- decision
    output wire                          dec_valid,    // decide cycle: chk_cnt == DEC_CYC
    output wire                          exit_strobe,
    output wire [2:0]                    exit_k,       // 0 = final answer, else 1..3
    output wire [2:0]                    chk_idx,      // in-flight check, 1..`PLANES
    output wire                          busy,
    output reg  [3:0]                    answer,
    output reg  [2:0]                    exit_k_held,  // registered companion to answer;
                                                       // wired in cc_top, not consumed
    output reg                           ans_valid,    // 1-cycle pulse with answer
    output reg                           sched_err     // sticky; must never fire
);
    // Derived from ckpt_defs.vh. Sized to match the state registers so they compare
    // without a part-select.
    localparam [3:0] RD_CYC  = `NHID / `P;                        // 8  read cycles
    localparam [3:0] Y_CYC   = (`NHID / `P) + 1;                  // 9  y presented
    localparam [3:0] DEC_CYC = (`NHID / `P) + 1 + `TREE_LAT;      // 11 done/argmax valid
    // FINAL_K is `PLANES, not N_cap: the final check always waits for the fourth plane
    // boundary. top_fsm's plane cap must never stop the frame short of it, or the final
    // check never starts and busy stays high with no alarm.
    localparam [2:0] FINAL_K = `PLANES;                           // 4  = the final answer

    // ------------------------------------------------------------------ state
    reg [2:0] plane_cnt;      // planes completed so far, 0..`PLANES
    reg       chk_busy;
    reg [3:0] chk_cnt;        // 1..DEC_CYC within the in-flight check
    reg [2:0] chk_k;          // which checkpoint it belongs to, 1..FINAL_K
    reg       pend_valid;     // a snapshot is captured and waiting for the unit
    reg [2:0] pend_k;
    reg       fin_pend;       // last plane is done; the final check still owes a start
    reg       resolved;       // this image has already produced its answer

    // ------------------------------------------------------- boundary arbitration
    wire [2:0] k_next   = plane_cnt + 3'd1;      // the boundary being crossed, 1..4
    wire       is_fin_b = (k_next == FINAL_K);
    wire       armed_here = (k_next == 3'd1) ? ckpt_en[0] :
                            (k_next == 3'd2) ? ckpt_en[1] :
                            (k_next == 3'd3) ? ckpt_en[2] : 1'b0;

    wire dec_now   = chk_busy && (chk_cnt == DEC_CYC);
    // The final answer is taken unconditionally; armed checkpoints exit only on
    // tree_done. t_sel is 0 at the final, and margin = max - 2nd_max >= 0 by
    // construction, so exit_tree_2stage's done = (margin >= T) is always true there
    // anyway; the explicit chk_k test makes the final independent of the tree.
    wire take_exit = dec_now && ((chk_k == FINAL_K) ? 1'b1 : tree_done);

    // Free *this* cycle: idle, or the in-flight check resolves now. In the latter case
    // the new check starts on the decide cycle of the one it replaces.
    wire unit_free = (!chk_busy) || dec_now;

    // A boundary that wants a check. Suppressed once the image has answered -- the
    // datapath may still be running planes, but nothing further is scheduled.
    wire boundary_check = plane_end && !resolved && !take_exit && (is_fin_b || armed_here);

    wire start_pend = unit_free && !take_exit &&  pend_valid;
    wire start_bnd  = unit_free && !take_exit && !pend_valid &&  boundary_check;
    wire start_fin  = unit_free && !take_exit && !pend_valid && !boundary_check && fin_pend;
    wire start_now  = start_pend | start_bnd | start_fin;
    wire [2:0] start_k = start_pend ? pend_k :
                         start_bnd  ? k_next : FINAL_K;

    // ------------------------------------------------------------------ outputs
    wire rd_active = chk_busy && (chk_cnt >= 4'd1) && (chk_cnt <= RD_CYC);

    assign rd_grp = rd_active ? (chk_cnt[2:0] - 3'd1) : 3'd0;

    // Lane i is handed addr == `P*rd_grp + i, so addr % `P == i on every cycle. Both x4
    // ROMs use a grouped decode that reads only the top 3 bits of each 5-bit address
    // field, which is valid only under this guarantee: a violation returns wrong data,
    // not an error.
    genvar gi;
    generate
        for (gi = 0; gi < `P; gi = gi + 1) begin : lane_addr
            // unit index = `P*rd_grp + gi, so lane gi always sees addr % `P == gi.
            assign rom_addr[`CKPT_ADDR_W*gi +: `CKPT_ADDR_W] = (rd_grp * `P) + gi;
        end
    endgenerate

    // Capture at the boundary for an armed checkpoint (the L1 ACC moves on immediately
    // -- that is the overlap). For the final, capture at the START of the final check
    // instead: the ACC is frozen after the last plane, so a late snapshot is still the
    // right value, and it keeps a short-plane image from clobbering a live P3 read.
    assign capture = (boundary_check && !is_fin_b)
                  || (start_now && (start_k == FINAL_K));

    // Requant negate flag, deliberately tied 0. requant_unit computes
    // (sgn ? -a1 : a1) + bias; the fold's sign is +1 for all 32 hidden units, so
    // nothing is negated, and wiring this live would negate every activation.
    assign sgn = 1'b0;                                   // negate flag, tied 0

    // Bias shift amount, `PLANES - chk_k: P1 -> 3, P2 -> 2, P3 -> 1, final -> 0.
    // ckpt_block applies it as an ARITHMETIC right shift (>>>) on the sign-extended
    // `CKPT_BIAS_W ROM bias. 8 of the 32 bias values are negative, so a logical shift
    // compiles and makes every checkpoint margin on those units wrong.
    wire [2:0] bias_sh_full = FINAL_K - chk_k;
    assign bias_sh = bias_sh_full[1:0];

    // b2 (L2 bias) preload for the out-ACC, class 9 in the MSB slot down to class 0 in
    // the LSB slot, matching l2_mac_x4's acc_in packing of `OACC_W bits per class. The
    // out-ACC loads it on the first read cycle of every check (oacc_sel_init) in place
    // of a zero start.
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

    // A function of chk_k, so held for the whole check and stable on the y_valid cycle
    // two cycles ahead of done; exit_tree_2stage registers it alongside y. T = 0 at
    // the final makes the margin >= T compare always true.
    assign t_sel = (chk_k == 3'd1) ? t_cfg[0*`T_W +: `T_W] :
                   (chk_k == 3'd2) ? t_cfg[1*`T_W +: `T_W] :
                   (chk_k == 3'd3) ? t_cfg[2*`T_W +: `T_W] : {`T_W{1'b0}};

    assign dec_valid   = dec_now;
    assign exit_strobe = take_exit;
    assign exit_k      = (chk_k == FINAL_K) ? 3'd0 : chk_k;
    assign chk_idx     = chk_k;
    assign busy        = chk_busy;

    // ------------------------------------------------------------------ sequential
    always @(posedge clk) begin
        if (rst) begin
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

            // A boundary the unit cannot serve yet. Non-final boundaries must snapshot
            // now (capture above) and queue; the final one only records that it is owed.
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

            // A capture landing on a read cycle other than the last one destroys the
            // in-flight check's snapshot. Unreachable for the default {P2,P3} arm config
            // (`CFG_EN_DEFAULT) because a plane is at least `ZS_FILL = `NHID/`P cycles
            // long (asserted below); loud, not silent, if another arm config breaks it.
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
