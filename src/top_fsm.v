// top_fsm -- image framing: start -> swap -> scan_start, once per plane, up to n_cap.
// Owns busy, done and cap_err. A swap must be suppressed in any cycle where img_start
// is asserted -- bitplane_buffer handles img_start in an else-if chain that pre-empts it.
`include "ckpt_defs.vh"

module top_fsm (
    input  wire                  clk,
    input  wire                  rst,          // synchronous, active high

    // ---- host
    input  wire                  start,        // 1-cycle pulse: begin an image
    input  wire                  blob_loaded,  // K12, from config_latch
    input  wire [`N_CAP_W-1:0]   n_cap,

    // ---- status in, from ckpt_block
    input  wire                  fill_full,
    input  wire                  scan_busy,
    input  wire                  plane_end,
    input  wire                  exit_strobe,
    input  wire                  ans_valid,

    // ---- framing out, to ckpt_block
    output reg                   img_start,
    output wire                  swap,
    output wire                  scan_start,

    // ---- status out
    output wire                  busy,
    output reg                   done,         // 1-cycle pulse when the answer is valid
    output wire [2:0]            planes_run,
    output reg                   cap_err       // sticky: n_cap out of range in the blob
);

    reg       running;
    reg       priming;
    reg       scan_start_r;
    reg [2:0] pstarted;
    reg       stopped;

    // n_cap is `N_CAP_W = 3 b, so it can carry 0 or 5..7, which no buffer can serve.
    // Clamp to `PLANES and report rather than trust. Values 1..3 pass the clamp, but
    // checkpoint_ctrl hardcodes FINAL_K = `PLANES, so with fewer than 4 planes the final
    // check never fires and the chip hangs with no alarm.
    localparam [2:0] PLANE_MAX = `PLANES;   // a macro literal cannot be bit-selected
    wire [2:0] cap_raw   = n_cap[2:0];
    wire       cap_bad   = (cap_raw == 3'd0) || (cap_raw > PLANE_MAX);
    wire [2:0] plane_cap = cap_bad ? PLANE_MAX : cap_raw;

    // `!exit_strobe` as well as `!stopped`: `stopped` is registered, so without the
    // combinational term a swap in the very cycle the decision resolves would still be
    // granted and one more plane would launch for nothing. Under zero-skip that is not
    // hypothetical: a plane can be as short as `ZS_FILL = 8 cycles while a check takes
    // `GAMMA = 11, so decisions resolve while the next plane is in flight.
    wire more_planes = (pstarted < plane_cap) && !stopped && !exit_strobe;
    // `!img_start` is load-bearing. bitplane_buffer handles img_start in an else-if
    // chain that PRE-EMPTS swap, so a swap coinciding with img_start is swallowed -- but
    // scan_start_r would still fire the next cycle and the scanner would start on a
    // plane that was never promoted (act_v = 0), tripping active_pixel_scan's
    // `start && !plane_valid` alarm. It happens whenever fill_full is still high on
    // the img_start cycle: a plane an early exit left unconsumed, or one loaded before
    // START (bitplane_buffer clears fil_v in its img_start branch), so it is
    // data-dependent.
    wire want_swap   = running && !img_start &&
                       ((priming && fill_full) ||
                        (scan_busy && plane_end && more_planes));

    assign swap       = want_swap;
    assign scan_start = scan_start_r;
    assign busy       = running;
    assign planes_run = pstarted;

    always @(posedge clk) begin
        if (rst) begin
            running      <= 1'b0;
            priming      <= 1'b0;
            scan_start_r <= 1'b0;
            pstarted     <= 3'd0;
            stopped      <= 1'b0;
            img_start    <= 1'b0;
            done         <= 1'b0;
            cap_err      <= 1'b0;
        end else begin
            // K12: an image may only start once the blob is in.
            img_start <= start && blob_loaded && !running;
            done      <= ans_valid;

            if (start && blob_loaded && !running) begin
                running  <= 1'b1;
                priming  <= 1'b1;
                pstarted <= 3'd0;
                stopped  <= 1'b0;
                if (cap_bad) cap_err <= 1'b1;
            end else begin
                if (want_swap) priming <= 1'b0;
                // incremented with the SWAP, not with the start, so `pstarted` already
                // names the plane on that plane's own t = 0 cycle.
                if (want_swap) pstarted <= pstarted + 3'd1;
                // The exit fired: withhold every further swap. The check already in
                // flight still completes and still produces ans_valid.
                if (exit_strobe) stopped <= 1'b1;
                if (ans_valid)   running <= 1'b0;
            end

            scan_start_r <= want_swap;
        end
    end

endmodule
