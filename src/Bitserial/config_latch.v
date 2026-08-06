// config_latch -- the only reloadable state on the chip. W1/W2/theta/k are all
// synthesized ROM (fixed at tape-out), so these 43 b (T1/T2/T3 + ckpt_en/en_skip/
// page_sel/inv_plane/n_cap/en_vstrobe) are the entire post-silicon-adjustable surface.
//
// Resets to the FROZEN SHIPPED CONFIG (T2=8, T3=12, P1 disarmed), not zero, so the exit
// logic never sees an undefined threshold -- there is no bring-up window where arming
// depends on a blob having loaded. `blob_loaded` is separate provenance-only state
// (has a host actually written since reset); it gates a status pin, not the exit logic.
// blob_done is checked before wr_en, so it wins a same-cycle race with a loader's final
// word write.
//
// One shared address port: a blob load and a readback never overlap, so two ports
// would just cost pins.
`include "ckpt_defs.vh"

module config_latch #(
    parameter NWORDS = `CFG_WORDS,
    parameter ADDR_W = `CFG_ADDR_W   // must match blob_loader's NWORDS/ADDR_W
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  wr_en,
    input  wire [ADDR_W-1:0]     addr,
    input  wire [`CFG_W-1:0]     wr_data,
    input  wire                  blob_done,
    output wire [`CFG_W-1:0]     rd_data,

    output wire [(3*`T_W)-1:0]   t_cfg,      // {T3,T2,T1}, matches checkpoint_ctrl's slicing
    output wire [`PLANES-2:0]    ckpt_en,
    output wire                  en_skip,
    output wire                  page_sel,
    output wire [`PLANES-1:0]    inv_plane,
    output wire [`N_CAP_W-1:0]   n_cap,
    output wire                  en_vstrobe,
    output reg                   blob_loaded
);
    localparam FLAT_W = NWORDS * `CFG_W;

    // T1_DEFAULT expands to an unsized expression; concat below needs every operand sized.
    localparam [`T_W-1:0] T1_RST = `T1_DEFAULT;
    localparam [`T_W-1:0] T2_RST = `T2_DEFAULT;
    localparam [`T_W-1:0] T3_RST = `T3_DEFAULT;

    // Field order here must match the CFG_*_LSB offsets -- checked at elaboration below.
    localparam [FLAT_W-1:0] CFG_RST = {
        {(FLAT_W - `CFG_BITS){1'b0}},
        `CFG_VST_DEFAULT,
        `CFG_NCAP_DEFAULT,
        `CFG_INV_DEFAULT,
        `CFG_PAGE_DEFAULT,
        `CFG_SKIP_DEFAULT,
        `CFG_EN_DEFAULT,
        T3_RST, T2_RST, T1_RST
    };

    reg [FLAT_W-1:0] cfg;

    always @(posedge clk) begin
        if (!rst_n) cfg <= CFG_RST;
        else if (wr_en) cfg[addr*`CFG_W +: `CFG_W] <= wr_data;
    end

    always @(posedge clk) begin
        if (!rst_n)         blob_loaded <= 1'b0;
        else if (blob_done) blob_loaded <= 1'b1;
        else if (wr_en)     blob_loaded <= 1'b0;
    end

    assign rd_data = cfg[addr*`CFG_W +: `CFG_W];

    assign t_cfg      = cfg[`CFG_T1_LSB   +: (3*`T_W)];
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
        // Re-derive every field from CFG_RST through the same offsets the outputs use --
        // catches a concat that's right by width and wrong by order.
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
