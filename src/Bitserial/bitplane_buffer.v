// bitplane_buffer -- stage 1: 2 x `NPIX b double buffer. Plane p+1 loads from the host
// while plane p is consumed by popcount + active_pixel_scan. Single-buffer was killed
// (DESIGN_LEDGER §3): zero-skip needs the whole plane resident to pick the lowest set
// bit, so there is no streaming variant that preserves ordering.
//
// This module is WHY `ZS_FILL = 8: filling one plane takes `NPIX/LD_W = 8 beats no
// matter how sparse it is, so the next plane is never ready sooner. Checked at
// elaboration below, not just asserted in a comment.
//
// K10: inv_plane[p] is XORed into the plane as presented and sampled once, when its
// plane finishes loading, so a config write can't retro-invert a plane in flight.
// Inverting bits changes the arithmetic (needs a row-sum correction that doesn't exist
// yet) -- stays 0 on page 1.
// K11: if en_vstrobe, the host's claimed plane boundary (ld_vstrobe) must match this
// module's own beat counter in both directions or frame_err fires. Off by default so
// early bring-up isn't blocked by a host that doesn't drive it yet.
`include "ckpt_defs.vh"

module bitplane_buffer #(parameter LD_W = `LD_W) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 img_start,

    input  wire                 ld_en,
    input  wire [LD_W-1:0]      ld_data,
    input  wire                 ld_vstrobe,
    output wire                 ld_ready,
    output wire                 ld_done,
    output wire [1:0]           ld_idx,

    input  wire [`PLANES-1:0]   inv_plane,
    input  wire                 en_vstrobe,

    input  wire                 swap,
    output wire [`NPIX-1:0]     plane,
    output wire                 plane_valid,
    output wire [1:0]           plane_idx,
    output wire                 fill_full,
    output reg                  frame_err
);
    localparam BEATS = `NPIX / LD_W;
    localparam BCW   = $clog2(BEATS);
    localparam PIW   = $clog2(`PLANES);

    reg [`NPIX-1:0] act_buf, fil_buf;
    reg             act_v,   fil_v;
    reg             act_inv, fil_inv;
    reg [PIW-1:0]   act_idx, fil_idx;
    reg [BCW-1:0]   beat;

    wire last_beat = (beat == BEATS - 1);
    // fil_free includes swap: the fill half frees on the SAME cycle it's promoted, so
    // an 8-beat fill can hide entirely inside an 8-cycle plane with zero slack.
    wire fil_free  = !fil_v || swap;
    wire fill_wr   = ld_en && fil_free;

    assign ld_ready    = fil_free;
    assign ld_done     = fill_wr && last_beat;
    assign ld_idx      = fil_idx;
    assign fill_full   = fil_v;

    assign plane       = act_buf ^ {`NPIX{act_inv}};
    assign plane_valid = act_v;
    assign plane_idx   = act_idx;

    always @(posedge clk) begin
        if (!rst_n) begin
            beat <= {BCW{1'b0}};
            fil_v <= 1'b0;      act_v <= 1'b0;
            fil_inv <= 1'b0;    act_inv <= 1'b0;
            fil_idx <= {PIW{1'b0}};
            act_idx <= {PIW{1'b0}};
            frame_err <= 1'b0;
        end else if (img_start) begin
            // Partial fill in progress = torn plane (flagged). A COMPLETE unconsumed
            // plane is not flagged -- a host pipelining next image's plane 0 early is
            // discarding its own data on purpose.
            if (beat != {BCW{1'b0}}) frame_err <= 1'b1;
            // A beat on the img_start cycle itself is dropped (fill write is in the
            // else branch) -- flagged rather than silently shifting every later beat.
            if (ld_en) frame_err <= 1'b1;
            beat <= {BCW{1'b0}};
            fil_v <= 1'b0;      act_v <= 1'b0;
            fil_idx <= {PIW{1'b0}};
            act_idx <= {PIW{1'b0}};
        end else begin
            // ORDER MATTERS: swap's beat<=0 is written first, fill_wr's beat<=1
            // second, so nonblocking last-write-wins makes a beat landing on the same
            // cycle as a swap correctly land at position 0 of the freed half. Do not
            // reorder these two if-blocks.
            if (swap) begin
                act_buf <= fil_buf;
                act_v   <= fil_v;
                act_inv <= fil_inv;
                act_idx <= fil_idx;
                fil_idx <= fil_idx + {{(PIW-1){1'b0}}, 1'b1};
                fil_v   <= 1'b0;
                beat    <= {BCW{1'b0}};
                if (!fil_v) frame_err <= 1'b1;   // underrun: torn plane going out
            end
            if (fill_wr) begin
                fil_buf[beat*LD_W +: LD_W] <= ld_data;
                beat <= last_beat ? {BCW{1'b0}} : beat + {{(BCW-1){1'b0}}, 1'b1};
                if (last_beat) begin
                    fil_v   <= 1'b1;
                    fil_inv <= inv_plane[fil_idx];
                end
            end
            if (ld_en && !fil_free) frame_err <= 1'b1;   // overrun: beat dropped

            if (en_vstrobe && fill_wr && (ld_vstrobe != last_beat)) frame_err <= 1'b1;
            if (en_vstrobe && ld_vstrobe && !fill_wr)              frame_err <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (`NPIX % LD_W != 0) begin
            $display("bitplane_buffer: FAIL LD_W = %0d does not divide `NPIX = %0d",
                     LD_W, `NPIX);
            $finish;
        end
        if ((`NPIX / LD_W) != `ZS_FILL) begin
            $display("bitplane_buffer: FAIL fill bound broken: `NPIX/LD_W = %0d, `ZS_FILL = %0d",
                     (`NPIX / LD_W), `ZS_FILL);
            $finish;
        end
        if (BEATS < 2) begin
            $display("bitplane_buffer: FAIL BEATS = %0d needs a multi-beat fill", BEATS);
            $finish;
        end
    end
`endif
endmodule
