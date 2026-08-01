// bitplane_buffer -- stage 1: the 2 x `NPIX b bit-plane double buffer.
//
// One bit plane is `NPIX bits, one bit per pixel. The four planes are consumed
// MSB-first: plane p carries input bit (`PLANES-1-p). This module holds two of them,
// so plane p+1 loads from the host while plane p is being consumed by
// popcount + active_pixel_scan.
//
// THE SINGLE-BUFFER VARIANT IS KILLED and is not re-litigated here: DESIGN_LEDGER §3
// "Single plane buffer (drop the second 64 b half)" -- saves ~0.15 t, nearly doubles
// plane time under zero-skip, makes the host interface brittle (Jul-26 conversation).
// The neighbouring kill, "Streaming 1 b/cycle from the RP2040 without the double
// buffer", is the same finding from the host side: zero-skip needs the WHOLE plane
// resident before it can pick the lowest set bit, so there is no streaming variant
// that keeps the ordering.
//
// ---------------------------------------------------------------- why `ZS_FILL is 8
// This module is the reason the zero-skip plane length has a floor at all. Filling one
// plane takes `NPIX/`LD_W = 64/8 = 8 beats, so however sparse a plane is, the NEXT one
// cannot be ready sooner than 8 cycles -- which is exactly engine.py plane_costs()'s
//
//     plane length = max(popcount, 8)      "8 = plane-buffer fill bound"
//
// The `NPIX/`LD_W == `ZS_FILL identity is checked at elaboration below rather than
// left as a comment, because it is the structural justification for the whole Aug-10
// property run: if the fill port width ever changes, the floor in
// active_pixel_scan.v's length rule has to move with it or the RTL and the golden
// model quietly disagree. (See ckpt_defs.vh's `LD_W note: the repo's sources state the
// 8-CYCLE bound, never the port width -- 8 b/cycle is this RTL's reading of it.)
//
// Timing consequence, verified end-to-end in ckpt_tb/tb_input_stage.v: with `swap`
// asserted on a plane's last cycle, the freed half accepts its first beat on that same
// cycle (`fil_free` includes `swap`), so a host that drives one beat per cycle
// finishes the next plane in exactly 8 cycles -- meeting, with zero margin, the
// shortest possible plane. `fill_full` is asserted at every swap in that TB, which is
// the hardware statement that the double buffer sustains max(popcount, 8).
//
// ---------------------------------------------------------------- K10 and K11
// K10 -- per-plane inversion (DESIGN_LEDGER Aug-1 item 6, feature freeze K10: "4
// config b + XOR", "thermal is offset-binary -> dense MSB plane; restores zero-skip on
// page 2"). `inv_plane[p]` is XORed into the plane as it is PRESENTED, so popcount and
// the scan both see the corrected plane and the length shortens -- which is the entire
// point. The bit is sampled when its plane finishes loading and travels with it
// through the buffer, so a config write cannot retro-invert a plane already in flight.
//   SCOPE, stated plainly: inverting the bits fed to the MAC changes the arithmetic.
//   sum_i W1[j,i]*(1-b_i) = rowsum_j - sum_i W1[j,i]*b_i, so a consumer of an inverted
//   plane owes a negated accumulate plus a precomputed row-sum offset. That correction
//   is stage 3's (build-l1), not stage 1's, and it does not arise on page 1: FINAL4
//   uses `CFG_INV_DEFAULT = 4'b0000 and every number in this repo is measured at
//   inv = 0. K10 is wired and verified here; page 2 must not be taped out on it until
//   the L1 side of the correction exists.
//
// K11 -- per-plane valid strobe (DESIGN_LEDGER §3: "replaces the rolling checksum ...
// a slip that exits at checkpoint k is undetectable by any end-of-stream check
// anyway"). Two halves, both cheap:
//   in   `ld_vstrobe` is the host's claim "this beat ends a plane". When armed by
//        `en_vstrobe` it is compared against this module's own beat counter; any
//        disagreement in either direction is a frame slip and sets `frame_err`.
//   out  `ld_done` pulses once per COMPLETE plane with `ld_idx`, so the host can check
//        the same boundary from its side.
// `en_vstrobe` defaults to 0 (ckpt_defs.vh `CFG_VST_DEFAULT) so first bring-up cannot
// be blocked by a host that does not drive the strobe yet.
//
// `frame_err` is sticky and clears only on `rst`, following checkpoint_ctrl.v's
// `sched_err`: a torn or missing plane must be loud, never a silently wrong answer.
//
// Widths come from ckpt_rtl/ckpt_defs.vh. Nothing is re-declared here.
`include "ckpt_defs.vh"

module bitplane_buffer #(parameter LD_W = `LD_W) (
    input  wire                 clk,
    input  wire                 rst,          // synchronous, active high
    input  wire                 img_start,    // 1-cycle pulse: next plane loaded is 0

    // ---- host fill port (stage 0 drives this; it is never back-pressured mid-plane)
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

    // 2 x `NPIX = 128 b -- the whole of stage 1's state (gate_calibration.md's
    // "1 input staging ... 128 DFF").
    reg [`NPIX-1:0] act_buf, fil_buf;
    reg             act_v,   fil_v;           // holds a COMPLETE plane
    reg             act_inv, fil_inv;         // K10 bit, travelling with its plane
    reg [PIW-1:0]   act_idx, fil_idx;
    reg [BCW-1:0]   beat;                     // 0 whenever fil_v is set

    wire last_beat = (beat == BEATS - 1);
    // A swap frees the fill half on the SAME cycle, so the host loses no beat to the
    // handover. This is what lets an 8-beat fill hide entirely under an 8-cycle plane.
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
            // mid-plane. A COMPLETE unconsumed plane is not flagged -- a host that
            // pipelines the next image's plane 0 early is discarding its own data
            // knowingly, and blocking that would forbid back-to-back frames.
            if (beat != {BCW{1'b0}}) frame_err <= 1'b1;
            // A beat presented on the img_start cycle is DROPPED (the fill write below
            // is in the else branch). Silently losing it would shift every subsequent
            // beat by one and tear the plane, so it is flagged: the host owes one idle
            // cycle at img_start. Costing a cycle here is free -- the 8-beat prologue
            // of plane 0 has no plane to overlap with anyway.
            if (ld_en) frame_err <= 1'b1;
            beat <= {BCW{1'b0}};
            fil_v <= 1'b0;      act_v <= 1'b0;
            fil_idx <= {PIW{1'b0}};
            act_idx <= {PIW{1'b0}};
        end else begin
            // ORDER MATTERS, and it is the nonblocking last-write-wins rule doing the
            // work: `swap` is written first and the fill write second, so a beat
            // arriving on the swap cycle lands at position 0 of the just-freed half and
            // its `beat <= 1` overrides swap's `beat <= 0`. Do not reorder these.
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

            // K11. Armed, the host's plane boundary must be exactly this module's:
            // a strobe on a non-final beat, or a final beat without one, is a slip.
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
