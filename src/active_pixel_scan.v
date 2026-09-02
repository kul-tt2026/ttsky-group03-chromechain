// active_pixel_scan -- emits the pixel sequence and the plane length of one bit-plane.
//   plane_len = en_skip ? max(popcount, `ZS_FILL) : `NPIX.  No abort: a started plane
//   runs its full length even after an early exit, so `busy` here can stay high for up to
//   52 cycles after the chip's busy falls (the post-DONE drain). `start` IS cycle t=0 (the
//   first pixel is combinational from `plane`); plane_end fires DURING the last accumulate
//   cycle, NOT after it -- which is why the A1 snapshot MUST be taken from acc_next, not
//   acc_live (ckpt_block.v).
`include "ckpt_defs.vh"

module active_pixel_scan #(parameter EN_SKIP_FUSED = 0) (
    input  wire                 clk,
    input  wire                 rst,          // synchronous, active high
    input  wire                 en_skip,      // config_latch.en_skip; 0 = dense
    input  wire                 start,        // 1-cycle pulse, and IS cycle t = 0

    // ---- from bitplane_buffer (+ popcount on the same plane)
    input  wire [`NPIX-1:0]     plane,        // K10 already applied
    input  wire                 plane_valid,  // K11
    input  wire [`PC_W-1:0]     pop,

    // ---- to the W1 ROM and l1_horner_acc
    output wire [`PIX_W-1:0]    pix_idx,
    output wire                 pix_act,      // -> l1_horner_acc.act
    output wire                 plane_start,  // -> l1_horner_acc.plane_start (the x2)

    // ---- to checkpoint_ctrl / the top FSM
    output wire                 plane_end,    // DURING the last cycle of the plane
    output wire                 busy,
    output wire [`LEN_W-1:0]    plane_len,    // max(pop, `ZS_FILL) or `NPIX
    output reg                  scan_err      // sticky; must never fire
);
    localparam [`LEN_W-1:0] FILL = `ZS_FILL;
    localparam [`LEN_W-1:0] FULL = `NPIX;

    // 0 = config bit (default), 1 = fused zero-skip, 2 = fused dense.
    wire skip = (EN_SKIP_FUSED == 1) ? 1'b1 :
                (EN_SKIP_FUSED == 2) ? 1'b0 : en_skip;

    reg  [`NPIX-1:0]  rem;        // scan residue (zero-skip) / shift register (dense)
    reg  [`LEN_W-1:0] t_q;        // index of the NEXT cycle in this plane
    reg  [`LEN_W-1:0] len_q;
    reg  [`PC_W-1:0]  pop_q;
    reg               busy_q;

    // Plane length: skip ? max(pop, `ZS_FILL) : `NPIX. This guarantees len >= pop, which
    // the plane_end && |nxt self-check below relies on. `ZS_FILL is the minimum plane
    // length in zero-skip mode; ckpt_defs.vh explains where its value comes from.
    wire [`LEN_W-1:0] pop_x   = {{(`LEN_W-`PC_W){1'b0}}, pop};
    wire [`LEN_W-1:0] len_new = skip ? ((pop_x > FILL) ? pop_x : FILL) : FULL;

    // On the start cycle everything comes from the inputs; afterwards from state. This
    // mux is what removes the per-plane bubble.
    wire              run   = busy_q || start;
    wire [`NPIX-1:0]  cur   = start ? plane          : rem;
    wire [`LEN_W-1:0] len_c = start ? len_new        : len_q;
    wire [`LEN_W-1:0] t_c   = start ? {`LEN_W{1'b0}} : t_q;
    wire [`PC_W-1:0]  pop_c = start ? pop            : pop_q;

    // Lowest set bit, one-hot: cur & -cur (all-zero when cur is zero).
    wire [`NPIX-1:0] lsb = cur & (~cur + {{(`NPIX-1){1'b0}}, 1'b1});

    // One-hot -> binary: bit b of the index is set iff the hot bit's index has bit b.
    wire [`PIX_W-1:0] enc_idx;
    genvar b, i;
    generate
        for (b = 0; b < `PIX_W; b = b + 1) begin : enc
            wire [`NPIX-1:0] sel;
            for (i = 0; i < `NPIX; i = i + 1) begin : msk
                assign sel[i] = (((i >> b) & 1) != 0) ? lsb[i] : 1'b0;
            end
            assign enc_idx[b] = |sel;
        end
    endgenerate

    wire any_left = |cur;
    wire [`NPIX-1:0] nxt = skip ? (cur & ~lsb) : {1'b0, cur[`NPIX-1:1]};

    assign pix_idx     = skip ? enc_idx : t_c[`PIX_W-1:0];
    assign pix_act     = run && (skip ? (t_c < {{(`LEN_W-`PC_W){1'b0}}, pop_c}) : cur[0]);
    assign plane_start = run && (t_c == {`LEN_W{1'b0}});
    assign plane_end   = run && (t_c == len_c - {{(`LEN_W-1){1'b0}}, 1'b1});
    assign busy        = run;
    assign plane_len   = len_c;

    always @(posedge clk) begin
        if (rst) begin
            rem <= {`NPIX{1'b0}};
            t_q <= {`LEN_W{1'b0}};
            len_q <= {`LEN_W{1'b0}};
            pop_q <= {`PC_W{1'b0}};
            busy_q <= 1'b0;
            scan_err <= 1'b0;
        end else begin
            busy_q <= run && !plane_end;
            if (run) begin
                rem   <= nxt;
                t_q   <= t_c + {{(`LEN_W-1){1'b0}}, 1'b1};
                len_q <= len_c;
                pop_q <= pop_c;
            end

            // K11: scanning a plane the buffer never finished loading.
            if (start && !plane_valid) scan_err <= 1'b1;
            // Contract: `start` only when idle. On the last cycle of a plane the next
            // start belongs to the FOLLOWING cycle, so this is never tight.
            if (start && busy_q)       scan_err <= 1'b1;
            // Self-check of the length rule: the plane ran out of cycles before it ran
            // out of active pixels. Unreachable while len >= pop.
            if (plane_end && (|nxt))   scan_err <= 1'b1;
            // The two independent derivations of "an active pixel remains" -- the
            // popcount compare and the residue -- must agree on every cycle.
            if (run && skip && (pix_act != any_left)) scan_err <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (`LEN_W < `PC_W) begin
            $display("active_pixel_scan: FAIL `LEN_W = %0d cannot hold `PC_W = %0d",
                     `LEN_W, `PC_W);
            $finish;
        end
        if ((1 << `PIX_W) != `NPIX) begin
            $display("active_pixel_scan: FAIL `PIX_W = %0d does not address `NPIX = %0d",
                     `PIX_W, `NPIX);
            $finish;
        end
        // The no-bubble contract above assumes a plane is never one cycle long.
        if (`ZS_FILL < 2) begin
            $display("active_pixel_scan: FAIL `ZS_FILL = %0d breaks the start/end overlap rule",
                     `ZS_FILL);
            $finish;
        end
    end
`endif
endmodule
