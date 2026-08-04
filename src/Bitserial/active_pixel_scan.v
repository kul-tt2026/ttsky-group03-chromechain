// active_pixel_scan -- stage 6, the zero-skip sequencer. The headline zero-skip cycle
// count rests entirely on `cycles per plane == max(popcount, `ZS_FILL)` holding in real
// hardware -- this module makes that structurally true, self-checked every cycle
// (see scan_err below), not just checked once in Python (checkpoint_sim/engine.py).
//
// Order matters, not just count: engine.py's pixel order is a stable ascending argsort
// (active pixels first, lowest index first) because the L1 accumulator's TRAJECTORY,
// not just its sum, is what the frozen T2/T3 checkpoint thresholds were calibrated
// against. Wrong order = wrong trajectory = broken bit-exactness even with matching
// cycle counts.
//
// `start` IS cycle t=0 (first pixel out combinationally the same cycle) -- that is what
// makes planes contiguous with zero per-plane bubble.
//
// `rem` is one register serving both orderings: zero-skip clears the emitted bit
// (priority-encoder residue), dense shifts right (avoids a 64:1 index mux). Declined as
// an area lever to instead destructively consume bitplane_buffer's active half (~0.10 t
// saved) -- that would couple the two modules and make the plane unreadable after
// cycle 0.
//
// EN_SKIP_FUSED: 0 = config bit (default), 1 = fuse zero-skip on, 2 = fuse dense on --
// ties `skip` to a constant so synthesis deletes the unreachable half. Default stays 0
// because dense IS mode 1, the control arm of the same-die A/B this chip exists to run.
`include "ckpt_defs.vh"

module active_pixel_scan #(parameter EN_SKIP_FUSED = 0) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 en_skip,
    input  wire                 start,

    input  wire [`NPIX-1:0]     plane,
    input  wire                 plane_valid,
    input  wire [`PC_W-1:0]     pop,

    output wire [`PIX_W-1:0]    pix_idx,
    output wire                 pix_act,
    output wire                 plane_start,

    output wire                 plane_end,
    output wire                 busy,
    output wire [`LEN_W-1:0]    plane_len,
    output reg                  scan_err
);
    localparam [`LEN_W-1:0] FILL = `ZS_FILL;
    localparam [`LEN_W-1:0] FULL = `NPIX;

    wire skip = (EN_SKIP_FUSED == 1) ? 1'b1 :
                (EN_SKIP_FUSED == 2) ? 1'b0 : en_skip;

    reg  [`NPIX-1:0]  rem;
    reg  [`LEN_W-1:0] t_q;
    reg  [`LEN_W-1:0] len_q;
    reg  [`PC_W-1:0]  pop_q;
    reg               busy_q;

    // THE LENGTH RULE. This one line is the Aug-10 property.
    wire [`LEN_W-1:0] pop_x   = {{(`LEN_W-`PC_W){1'b0}}, pop};
    wire [`LEN_W-1:0] len_new = skip ? ((pop_x > FILL) ? pop_x : FILL) : FULL;

    // start: everything from inputs. continuing: from state. This mux removes the bubble.
    wire              run   = busy_q || start;
    wire [`NPIX-1:0]  cur   = start ? plane          : rem;
    wire [`LEN_W-1:0] len_c = start ? len_new        : len_q;
    wire [`LEN_W-1:0] t_c   = start ? {`LEN_W{1'b0}} : t_q;
    wire [`PC_W-1:0]  pop_c = start ? pop            : pop_q;

    // Lowest set bit, one-hot (two's-complement isolate).
    wire [`NPIX-1:0] lsb = cur & (~cur + {{(`NPIX-1){1'b0}}, 1'b1});

    // One-hot -> binary priority encoder.
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
        if (!rst_n) begin
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

            if (start && !plane_valid) scan_err <= 1'b1;   // scanning an unfinished plane
            if (start && busy_q)       scan_err <= 1'b1;   // start while not idle
            if (plane_end && (|nxt))   scan_err <= 1'b1;   // length rule violated: residue left
            if (run && skip && (pix_act != any_left)) scan_err <= 1'b1;   // popcount vs residue disagree
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
        if (`ZS_FILL < 2) begin
            $display("active_pixel_scan: FAIL `ZS_FILL = %0d breaks the start/end overlap rule",
                     `ZS_FILL);
            $finish;
        end
    end
`endif
endmodule
