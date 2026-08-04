// top_fsm -- load | L1 | check | resume. Fase 3.
//
// ckpt_block.v's "NOT IN SCOPE" states the contract this implements: assert `swap`
// during a plane's `plane_end` cycle and `scan_start` on the next cycle, and planes cost
// exactly their own lengths with no per-plane bubble. ckpt_tb/tb_ckpt_block.v's host FSM
// is the reference this is promoted from -- the sequencing below is deliberately
// identical to it, because that sequencer is what the Fase-1 gate proved cycle-exact
// against engine.py's boundary_cycles(overlap=True). Changing its shape here would
// invalidate a passing gate.
//
// WHAT THIS ADDS OVER THE TESTBENCH SEQUENCER, and it is the whole point of Fase 3:
//
//   1. EARLY STOP. tb_modes reports "turning an early decision into an early STOP is the
//      top FSM's job -- Fase 3 -- and is not measured here." Until now every image ran
//      all `PLANES planes and the exit only decided EARLIER, it did not finish earlier.
//      `exit_strobe` here latches `stopped`, which withholds every further `swap`. That
//      is what converts a decision cycle into a cycle the chip does not spend, and it is
//      what makes the mean-cycle numbers in docs/cc_verilog_roadmap_review.md real
//      silicon behaviour rather than a property of the model.
//
//   2. RESUME WITH ACCUMULATORS INTACT. There is no explicit resume state, and that is
//      the design: on "not done" the FSM simply issues the next swap/scan_start pair and
//      l1_horner_acc is never told to clear. `img_start` is the ONLY thing that zeroes
//      the accumulator base. That is what makes the exit anytime rather than restart --
//      a restart would re-scan planes 1..k and the whole cycle saving would vanish.
//
//   3. N_cap. `plane_cap` is min(n_cap, `PLANES). n_cap comes from the config latch, so
//      the host can cap precision per image (the C2 forced-exit ablation needs this).
//      Clamped rather than trusted: a blob with n_cap = 7 must not make the FSM launch
//      seven planes into a four-plane buffer.
//
//   4. K12. No plane is launched until `blob_loaded`. A chip that runs with an unloaded
//      latch would classify with T = whatever reset left, which is a silently wrong
//      answer rather than a visible stall.
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

    // n_cap is `N_CAP_W = 3 b, so it can carry 5..7 which no buffer can serve. Clamp and
    // report rather than trust -- see header note 3.
    localparam [2:0] PLANE_MAX = `PLANES;   // a macro literal cannot be bit-selected
    wire [2:0] cap_raw   = n_cap[2:0];
    wire       cap_bad   = (cap_raw == 3'd0) || (cap_raw > PLANE_MAX);
    wire [2:0] plane_cap = cap_bad ? PLANE_MAX : cap_raw;

    // Identical in shape to tb_ckpt_block.v's host FSM, with `stopped` and `plane_cap`
    // replacing its unconditional `pstarted < `PLANES`.
    // `!exit_strobe` as well as `!stopped`: `stopped` is registered, so without the
    // combinational term a swap in the very cycle the decision resolves would still be
    // granted and one more plane would launch for nothing. Under zero-skip that is not
    // hypothetical -- planes are ~10 cycles and `GAMMA is 11, so a swap lands in that
    // window often.
    wire more_planes = (pstarted < plane_cap) && !stopped && !exit_strobe;
    // `!img_start` is load-bearing and cost an hour to find. bitplane_buffer handles
    // img_start in an else-if chain that PRE-EMPTS swap, so a swap coinciding with
    // img_start is swallowed -- but scan_start_r would still fire the next cycle and the
    // scanner would start on a plane that was never promoted (act_v = 0), tripping
    // active_pixel_scan's `start && !plane_valid` alarm. It only happens when the
    // previous image left fill_full high, i.e. after an early exit, which is why it is
    // data-dependent and why no Fase-1 test could have seen it: ckpt_block has no FSM.
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
                // names the plane on that plane's own t = 0 cycle (the TB's comment).
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
