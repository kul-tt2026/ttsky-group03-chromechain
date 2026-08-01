// active_pixel_scan -- stage 6: the zero-skip sequencer.
//
// This is the module the frontrunner's headline number rests on. Zero-skip's 41.4 mean
// cycles instead of 256 is entirely the claim that
//
//     cycles per plane == max(popcount, `ZS_FILL)
//
// holds in real hardware, and until now that had only ever been checked in Python
// (DESIGN_LEDGER §2 schedules the property run for Aug 10; docs/cc_datapath_walkthrough.md
// stage 2 calls it "het minst geverifieerde getal in de hele studie"). Everything below
// exists to make that sentence structurally true rather than incidentally true.
//
// ---------------------------------------------------------------- the reference
// checkpoint_sim/engine.py is the semantics, in two places that must both be matched:
//
//   plane_costs(x, "zskip")     np.maximum(popcount, 8)
//   build_records(...)          order = np.argsort(1 - b, axis=1, kind="stable")
//
// The stable argsort of (1 - b) is exactly "active pixels first, in ASCENDING index
// order, then the inactive ones" -- i.e. an ascending priority encoder. That ordering
// is not a timing detail: the ACC trajectory build-l1 accumulates, and therefore every
// mid-plane checkpoint margin the frozen T2/T3 were calibrated against, is a function
// of it. Emitting the same SET of pixels in a different order gives the same
// plane-boundary ACC and a different trajectory, so a mismatch here breaks
// bit-exactness downstream, not merely latency.
//
//   cycle t of a plane, 0 <= t < len:
//     zero-skip   pix_idx = the (t+1)-th lowest set bit;  pix_act = (t < popcount)
//     dense       pix_idx = t;                            pix_act = plane[t]
//
// The IDLE TAIL is the t >= popcount cycles of a zero-skip plane whose popcount is
// below `ZS_FILL: the plane still occupies max(popcount, 8) cycles, `pix_act` is low
// throughout, and nothing accumulates. engine.py's loop does the same thing by running
// `for t in range(L)` while only `t < len(order)` positions carry a bit. A plane whose
// popcount is 0 is the extreme case and still costs 8 cycles -- and still needs its
// Horner x2, which is why `plane_start` is emitted on the first of those 8 regardless
// of whether any pixel is active (see l1_horner_acc.v's header on the shared x2 cycle).
//
// ---------------------------------------------------------------- cycle contract
//   `start` is a 1-cycle pulse and IS cycle t = 0: the first pixel is presented
//   combinationally out of `plane` on that same cycle, not the cycle after. That is
//   what makes planes contiguous -- `plane_end` fires on t = len-1 and the next
//   `start` may be the very next cycle, so an image costs exactly the sum of its plane
//   lengths with no per-plane bubble. A design that registered the plane first would
//   cost `PLANES extra cycles per image and would not reproduce engine.py's totals.
//   Since len >= `ZS_FILL = 8 > 1, `plane_end` can never coincide with `start`.
//
//   `plane` and `pop` must be stable for the whole plane. They are: `plane` is
//   bitplane_buffer's registered active half, and the swap that changes it happens on
//   the PREVIOUS plane's last cycle, which reads from `rem`, not from `plane`.
//
//   Consumers: pix_idx -> the W1 ROM address, pix_act -> l1_horner_acc.act,
//   plane_start -> l1_horner_acc.plane_start, plane_end -> checkpoint_ctrl.plane_end
//   ("pulse DURING the last accumulate cycle of a plane").
//
// ---------------------------------------------------------------- one register, two modes
// `rem` is the scan residue and is shared by both orderings:
//   zero-skip   rem <= rem & ~lsb    clear the bit just emitted (priority-encoder residue)
//   dense       rem <= rem >> 1      plain shift register; pix_act is its bit 0
// The dense path is a shift specifically so it does NOT need a 64:1 index mux on
// `plane`; the cost of supporting both is the 64-bit next-state mux, and that cost is
// measured -- see EN_SKIP_FUSED below.
//
// gate_calibration.md's spec row for stage 6 says "(reuses mask)", i.e. the v1 spec
// assumed the scan would destroy the plane buffer in place and carry no state of its
// own. This does not: `rem` is 64 flops here (~1,281 um^2 raw, ~0.10 t @70%). Consuming
// bitplane_buffer's active half destructively would recover them, at the cost of
// coupling the two modules and making the active plane unreadable after cycle 0. It is
// declined as an area lever, not overlooked; the measured delta is in results.md.
//
// ---------------------------------------------------------------- EN_SKIP_FUSED
// Two open ledger items about `en_skip` point in OPPOSITE directions, and this
// parameter exists so both are priced instead of argued:
//
//   1  fuse zero-skip ON.  DESIGN_LEDGER §4: "en_skip: fused always-on vs config bit",
//      to be "settled by the `cycles == max(popcount, fill)` property run".
//   2  fuse zero-skip OFF. reports/gate_calibration.md §7 lists "Fuse zero-skip closed
//      (`en_skip`=0)" as a pressure valve recovering "~0.2 t (the ~290 c)" at the cost
//      of "the input-sparsity latency win". Fusing dense deletes the residue scan; the
//      popcount module then has no consumer either, so the valve's real value is this
//      delta PLUS all of popcount.
//
// Setting the parameter ties `skip` to a constant and lets yosys delete the unreachable
// half, so run_synth.py can price each through PARAM_OVERRIDES exactly the way
// l1_acc_shadow_w11 prices the ACC-width floor -- no forked file to drift.
//
// Default 0 (config bit), and the property run is what justifies it: the dense ordering
// is load-bearing, because mode 1 -- the fixed-precision control arm of the same-die
// A/B that IS the experiment (flagship C8) -- is the dense 256-cycle path. Measured
// numbers for all three settings are in l2_synthesis/results.md.
//
// ---------------------------------------------------------------- loud, not silent
// `scan_err` is sticky and follows checkpoint_ctrl.v's `sched_err` idiom. Two of its
// four causes are self-checks of the property itself:
//   - at `plane_end`, any residue left in `rem` means the plane was too SHORT for its
//     own popcount, i.e. the length rule is broken. In silicon, not just in the TB.
//   - every cycle, the popcount path (`t < pop`) and the mask path (`|rem`) must agree
//     on whether an active pixel remains. They are independent derivations of the same
//     fact; disagreement means `pop` does not describe `plane`.
//
// Widths come from ckpt_rtl/ckpt_defs.vh. Nothing is re-declared here.
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

    // 0 = config bit (default), 1 = fused zero-skip, 2 = fused dense. See the header.
    wire skip = (EN_SKIP_FUSED == 1) ? 1'b1 :
                (EN_SKIP_FUSED == 2) ? 1'b0 : en_skip;

    reg  [`NPIX-1:0]  rem;        // scan residue (zero-skip) / shift register (dense)
    reg  [`LEN_W-1:0] t_q;        // index of the NEXT cycle in this plane
    reg  [`LEN_W-1:0] len_q;
    reg  [`PC_W-1:0]  pop_q;
    reg               busy_q;

    // THE LENGTH RULE. This one line is the Aug-10 property.
    wire [`LEN_W-1:0] pop_x   = {{(`LEN_W-`PC_W){1'b0}}, pop};
    wire [`LEN_W-1:0] len_new = skip ? ((pop_x > FILL) ? pop_x : FILL) : FULL;

    // On the start cycle everything comes from the inputs; afterwards from state. This
    // mux is what removes the per-plane bubble.
    wire              run   = busy_q || start;
    wire [`NPIX-1:0]  cur   = start ? plane          : rem;
    wire [`LEN_W-1:0] len_c = start ? len_new        : len_q;
    wire [`LEN_W-1:0] t_c   = start ? {`LEN_W{1'b0}} : t_q;
    wire [`PC_W-1:0]  pop_c = start ? pop            : pop_q;

    // Lowest set bit, one-hot. cur & -cur; yosys maps the negate's carry chain, which
    // is the same prefix-AND an explicit "no set bit below i" network would build.
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
            // The property, self-checked: the plane ran out of cycles before it ran out
            // of active pixels. Unreachable while len >= pop.
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
