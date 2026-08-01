// config_latch -- the theta/T/config latch. THE ONLY RELOADABLE STATE ON THE CHIP.
//
// WHY THIS IS THE WHOLE RELOAD STORY. Option C (RATIFIED Jul 27, DESIGN_LEDGER:38)
// puts W1, W2, theta and k in synthesized ROM. ROM contents cannot change after
// tape-out, so everything a new blob is allowed to move lives in this module: the
// three conformal thresholds plus a handful of config bits. That is what makes the
// "reload = 128 b instead of 5,286 b" claim (~66 us, not 543 us) true.
//
// FIELD LIST -- DESIGN_LEDGER Aug-1 item 5, offsets frozen in ckpt_defs.vh:
//
//   [ 29:  0]  T1,T2,T3     3 x `T_W  conformal exit thresholds
//   [ 32: 30]  ckpt_en      K7        per-checkpoint arm bits, bit0=P1 bit1=P2 bit2=P3
//   [ 33: 33]  en_skip                zero-skip enable
//   [ 34: 34]  page_sel               ROM page select (1 = digits, 2 = thermal)
//   [ 38: 35]  inv_plane    K10       per-plane input inversion
//   [ 41: 39]  n_cap                  plane cap
//   [ 42: 42]  en_vstrobe   K11       per-plane valid-strobe enable
//   [127: 43]  spare                  page-2 (thermal) fields, not frozen until ~Aug 5
//
// 43 b of payload in a 128 b window. The spare bits are NOT free -- they are writable
// and readable, so they cost real flops -- but they are the blob contract, and page-2
// content is still open. config_latch_min (NWORDS=6) prices the payload alone; see
// l2_synthesis/results.md.
//
// T PACKING IS NOT ARBITRARY. checkpoint_ctrl.v:238-240 slices its t_cfg port as
// t_cfg[(k-1)*`T_W +: `T_W] for checkpoint k, i.e. {T3,T2,T1}. The offsets above match
// that exactly, so `t_cfg` below is a bare slice of the storage vector with zero decode
// logic between the latch and the threshold mux.
//
// K12 -- RESET ARCHITECTURE (docs/cc_v1_review_findings.md:55). The v1 review's
// power-up hazard was: config bits live in unresettable latches, so at power-up
// en_term/en_anytime are X and the chip may self-terminate off garbage or drive
// outputs from unloaded weights -- "dead on arrival, actually just unloaded". Both
// halves of its fix are here:
//   1. Storage is synchronous-reset DFFs, and the reset value is the FROZEN CONFIG
//      (T2=8, T3=12, P1 disarmed) rather than zero. So the config is never X, and a
//      chip that is reset and never loaded runs the shipped page-1 configuration.
//      This is stronger than gating a valid-but-unknown config: there is no window in
//      which the exit logic sees an undefined threshold.
//   2. `blob_loaded` is a separate reset-able DFF reporting whether a blob has been
//      written since reset. cc_top gates the DONE pin with it (build-top). It clears
//      on any write -- a reload in flight is not a coherent config -- and sets on
//      `blob_done`. blob_done wins a same-cycle race with wr_en, so a loader may raise
//      it coincident with its final word write; that word still lands at that posedge.
//
// Arming is deliberately NOT gated by blob_loaded. Gating it would make the reset
// defaults inert and reintroduce a "chip does nothing and no one knows why" bring-up
// mode; the defaults being valid is what closes the hazard.
//
// ONE ADDRESS PORT, not two. March C- reads and writes the same address within an
// element operation, and a blob load and a readback never overlap, so a shared `addr`
// is sufficient for both -- and cheaper in decode and in TT pin budget -- than
// separate read and write addresses.
//
// Widths and field offsets come from ckpt_rtl/ckpt_defs.vh. Nothing is re-declared
// here, and no default below is a literal: they are the `*_DEFAULT macros, so the
// Aug-10 T3 recalibration is a one-line change in one file.
`include "ckpt_defs.vh"

module config_latch #(
    parameter NWORDS = `CFG_WORDS,      // 16 -> the 128 b blob contract
    parameter ADDR_W = `CFG_ADDR_W      // 4; set to 3 alongside NWORDS=6 for the
) (                                     //    payload-only area variant
    input  wire                  clk,
    input  wire                  rst,        // synchronous, active high

    // ---- host/loader port. One shared address; write is `wr_en`, read is always on.
    input  wire                  wr_en,
    input  wire [ADDR_W-1:0]     addr,
    input  wire [`CFG_W-1:0]     wr_data,
    input  wire                  blob_done,  // loader: blob fully written
    output wire [`CFG_W-1:0]     rd_data,    // combinational readback (march + scan-out)

    // ---- decoded fields
    output wire [(3*`T_W)-1:0]   t_cfg,      // {T3,T2,T1} -- checkpoint_ctrl's port
    output wire [`PLANES-2:0]    ckpt_en,    // K7
    output wire                  en_skip,
    output wire                  page_sel,
    output wire [`PLANES-1:0]    inv_plane,  // K10
    output wire [`N_CAP_W-1:0]   n_cap,
    output wire                  en_vstrobe, // K11
    output reg                   blob_loaded // K12
);
    localparam FLAT_W = NWORDS * `CFG_W;

    // Sized so the concatenation below is well-formed. `T1_DEFAULT expands to
    // (1 << `T_W) - 1, an unsized expression that must not go into a concat raw.
    localparam [`T_W-1:0] T1_RST = `T1_DEFAULT;   // 1023: P1 disarmed by threshold too
    localparam [`T_W-1:0] T2_RST = `T2_DEFAULT;   // 8
    localparam [`T_W-1:0] T3_RST = `T3_DEFAULT;   // 12

    // Reset image. Field order here must match the `CFG_*_LSB offsets; the elaboration
    // check below re-derives every field from CFG_RST and compares against the macros,
    // so a mis-ordered concat is a loud failure, not a silently wrong default.
    localparam [FLAT_W-1:0] CFG_RST = {
        {(FLAT_W - `CFG_BITS){1'b0}},   // [127:43] spare
        `CFG_VST_DEFAULT,               // [42]     K11
        `CFG_NCAP_DEFAULT,              // [41:39]  N_cap
        `CFG_INV_DEFAULT,               // [38:35]  K10
        `CFG_PAGE_DEFAULT,              // [34]     page_sel
        `CFG_SKIP_DEFAULT,              // [33]     en_skip
        `CFG_EN_DEFAULT,                // [32:30]  K7
        T3_RST, T2_RST, T1_RST          // [29:0]
    };

    reg [FLAT_W-1:0] cfg;

    always @(posedge clk) begin
        if (rst) cfg <= CFG_RST;
        else if (wr_en) cfg[addr*`CFG_W +: `CFG_W] <= wr_data;
    end

    always @(posedge clk) begin
        if (rst)            blob_loaded <= 1'b0;
        else if (blob_done) blob_loaded <= 1'b1;
        else if (wr_en)     blob_loaded <= 1'b0;
    end

    assign rd_data = cfg[addr*`CFG_W +: `CFG_W];

    assign t_cfg      = cfg[`CFG_T1_LSB   +: (3*`T_W)];   // {T3,T2,T1}, zero decode
    assign ckpt_en    = cfg[`CFG_EN_LSB   +: (`PLANES-1)];
    assign en_skip    = cfg[`CFG_SKIP_LSB];
    assign page_sel   = cfg[`CFG_PAGE_LSB];
    assign inv_plane  = cfg[`CFG_INV_LSB  +: `PLANES];
    assign n_cap      = cfg[`CFG_NCAP_LSB +: `N_CAP_W];
    assign en_vstrobe = cfg[`CFG_VST_LSB];

`ifndef SYNTHESIS
    initial begin
        if (FLAT_W <= `CFG_BITS) begin
            $display("config_latch: FAIL NWORDS=%0d gives %0d b, need > CFG_BITS=%0d",
                     NWORDS, FLAT_W, `CFG_BITS);
            $finish;
        end
        if ((1 << ADDR_W) < NWORDS) begin
            $display("config_latch: FAIL ADDR_W=%0d cannot address NWORDS=%0d",
                     ADDR_W, NWORDS);
            $finish;
        end
        // The reset image is the frozen config, read back through the same offsets the
        // field outputs use. Catches a concat that is right by width and wrong by order.
        if (CFG_RST[`CFG_T1_LSB   +: `T_W]       !== T1_RST            ||
            CFG_RST[`CFG_T2_LSB   +: `T_W]       !== T2_RST            ||
            CFG_RST[`CFG_T3_LSB   +: `T_W]       !== T3_RST            ||
            CFG_RST[`CFG_EN_LSB   +: (`PLANES-1)]!== `CFG_EN_DEFAULT   ||
            CFG_RST[`CFG_SKIP_LSB]               !== `CFG_SKIP_DEFAULT ||
            CFG_RST[`CFG_PAGE_LSB]               !== `CFG_PAGE_DEFAULT ||
            CFG_RST[`CFG_INV_LSB  +: `PLANES]    !== `CFG_INV_DEFAULT  ||
            CFG_RST[`CFG_NCAP_LSB +: `N_CAP_W]   !== `CFG_NCAP_DEFAULT ||
            CFG_RST[`CFG_VST_LSB]                !== `CFG_VST_DEFAULT) begin
            $display("config_latch: FAIL CFG_RST field order does not match CFG_*_LSB");
            $finish;
        end
    end
`endif
endmodule
