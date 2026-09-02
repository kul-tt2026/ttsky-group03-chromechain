// config_latch -- the only reloadable state on the chip. A byte-addressable register
// file whose RESET IMAGE is the frozen shipped config, not zero. Field offsets are
// frozen in ckpt_defs.vh; t_cfg is a zero-logic slice, never a re-pack.
`include "ckpt_defs.vh"

module config_latch #(
    parameter NWORDS = `CFG_WORDS,      // 6 -> 48 b; 16 was v1's 128 b window
    parameter ADDR_W = `CFG_ADDR_W      // 3; 4 alongside NWORDS=16. blob_loader's
) (                                     //    NWORDS/ADDR_W must match -- see its header
    input  wire                  clk,
    input  wire                  rst,        // synchronous, active high

    // ---- host/loader port. One shared address; write is `wr_en`, read is always on.
    input  wire                  wr_en,
    input  wire [ADDR_W-1:0]     addr,
    input  wire [`CFG_W-1:0]     wr_data,
    input  wire                  blob_done,  // loader: blob fully written
    output wire [`CFG_W-1:0]     rd_data,    // the word at `addr`, combinational

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
        {(FLAT_W - `CFG_BITS){1'b0}},   // [47:43]  spare
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
