// bitplane_buffer -- double buffer: the host fills one half while the datapath scans
// the other. K10 per-plane inversion is sampled at FILL time, not at swap. ld_ready must
// include `swap` so the fill half is free on the swap cycle itself -- a host driving one
// beat per cycle then refills in exactly 8, meeting the shortest plane with zero margin.
`include "ckpt_defs.vh"

module bitplane_buffer #(parameter LD_W = `LD_W) (
    input  wire                 clk,
    input  wire                 rst,          // synchronous, active high
    input  wire                 img_start,    // 1-cycle pulse: next plane loaded is 0

    // ---- host fill port (wired straight from the pins; never back-pressured mid-plane)
    input  wire                 ld_en,
    input  wire [LD_W-1:0]      ld_data,      // LD_W pixels, bit 0 = lowest pixel index
    input  wire                 ld_vstrobe,   // K11: host marks a plane's LAST beat
    output wire                 ld_ready,     // the fill half can take a beat this cycle
    output wire                 ld_done,      // K11: pulse, one per COMPLETE plane
    output wire [1:0]           ld_idx,       // which plane that pulse belongs to

    // ---- from the config latch (config_latch.v)
    input  wire [`PLANES-1:0]   inv_plane,    // K10
    input  wire                 en_vstrobe,   // K11 arm

    // ---- consume side: popcount + active_pixel_scan
    input  wire                 swap,         // promote fill -> active
    output wire [`NPIX-1:0]     plane,        // K10 applied
    output wire                 plane_valid,  // the active half holds a COMPLETE plane
    output wire [1:0]           plane_idx,
    output wire                 fill_full,    // a complete plane is waiting to swap
    output reg                  frame_err     // sticky; must never fire
);
    localparam BEATS = `NPIX / LD_W;          // 8 = `ZS_FILL
    localparam BCW   = $clog2(BEATS);         // 3
    localparam PIW   = $clog2(`PLANES);       // 2

    // 2 x `NPIX = 128 b of buffer state: one half being filled, one half being scanned.
    reg [`NPIX-1:0] act_buf, fil_buf;
    reg             act_v,   fil_v;           // holds a COMPLETE plane
    reg             act_inv, fil_inv;         // K10 bit, travelling with its plane
    reg [PIW-1:0]   act_idx, fil_idx;
    reg [BCW-1:0]   beat;                     // 0 whenever fil_v is set

    wire last_beat = (beat == BEATS - 1);
    // A swap frees the fill half on the SAME cycle, so the host loses no beat to the
    // handover. This is what lets an 8-beat fill hide entirely under an 8-cycle plane.
    // Without the `swap` term a beat on the swap cycle is refused and flagged as an
    // overrun, and a streaming host needs 9 cycles per plane against a floor of 8.
    wire fil_free  = !fil_v || swap;
    wire fill_wr   = ld_en && fil_free;

    assign ld_ready    = fil_free;
    assign ld_done     = fill_wr && last_beat;
    assign ld_idx      = fil_idx;
    assign fill_full   = fil_v;

    assign plane       = act_buf ^ {`NPIX{act_inv}};   // K10
    assign plane_valid = act_v;                        // K11
    assign plane_idx   = act_idx;

    always @(posedge clk) begin
        if (rst) begin
            beat <= {BCW{1'b0}};
            fil_v <= 1'b0;      act_v <= 1'b0;
            fil_inv <= 1'b0;    act_inv <= 1'b0;
            fil_idx <= {PIW{1'b0}};
            act_idx <= {PIW{1'b0}};
            frame_err <= 1'b0;
        end else if (img_start) begin
            // A partially filled half here is a torn plane: the frame restarted
            // mid-plane. A COMPLETE unconsumed plane is not flagged: img_start clears
            // fil_v and act_v below, so a plane loaded before img_start is silently
            // discarded.
            if (beat != {BCW{1'b0}}) frame_err <= 1'b1;
            // A beat presented on the img_start cycle is DROPPED (the fill write below
            // is in the else branch). Silently losing it would shift every subsequent
            // beat by one and tear the plane, so it is flagged: the host owes one idle
            // cycle at img_start.
            if (ld_en) frame_err <= 1'b1;
            beat <= {BCW{1'b0}};
            fil_v <= 1'b0;      act_v <= 1'b0;
            fil_idx <= {PIW{1'b0}};
            act_idx <= {PIW{1'b0}};
        end else begin
            // ORDER MATTERS, and it is the nonblocking last-write-wins rule doing the
            // work: `swap` is written first and the fill write second, so a beat
            // arriving on the swap cycle lands at position 0 of the just-freed half and
            // its `beat <= 1` overrides swap's `beat <= 0`. Do not reorder these and do
            // not merge them into an if/else: either change drops one beat per swap.
            if (swap) begin
                act_buf <= fil_buf;
                act_v   <= fil_v;
                act_inv <= fil_inv;
                act_idx <= fil_idx;
                fil_idx <= fil_idx + {{(PIW-1){1'b0}}, 1'b1};
                fil_v   <= 1'b0;
                beat    <= {BCW{1'b0}};
                if (!fil_v) frame_err <= 1'b1;              // underrun: torn plane out
            end
            if (fill_wr) begin
                fil_buf[beat*LD_W +: LD_W] <= ld_data;
                beat <= last_beat ? {BCW{1'b0}} : beat + {{(BCW-1){1'b0}}, 1'b1};
                if (last_beat) begin
                    fil_v   <= 1'b1;
                    fil_inv <= inv_plane[fil_idx];         // K10 sampled with its plane
                end
            end
            if (ld_en && !fil_free) frame_err <= 1'b1;      // overrun: beat dropped

            // K11. Armed, the host's plane boundary must be exactly this module's: a
            // strobe on a non-final beat, a final beat without one, or a strobe with no
            // accepted beat, is a slip.
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
        // The zero-skip plane-length floor IS this fill time. If they ever diverge,
        // active_pixel_scan's max(popcount, `ZS_FILL) stops describing the hardware.
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
