// blob_loader -- host write path into config_latch, the only reloadable state on chip.
// Blob is `CFG_WORDS x `CFG_W (6x8=48b since v1.1, 16x8=128b in v1); `CFG_W=8 matches
// TT's 8b ui_in, so one word is one host cycle, no serialiser needed.
//
// Protocol: cfg_mode held high for the whole load (its rising edge resets the word
// counter -- a host that loses count restarts by dropping/raising it, no abort command
// to get wrong). cfg_stb pulses once per word; the word goes to the counter's address,
// so host and loader can never disagree on address. After the NWORDS'th strobe,
// blob_done pulses once (config_latch's K12 gate). A counter instead of host-supplied
// addresses: a wrong address would write a threshold into the enable field silently;
// a counter can only be at the wrong COUNT, which words_seen reports. Overrun (strobes
// past NWORDS) sets blob_err and is dropped, not wrapped -- wrapping would silently
// overwrite T1 with whatever word 17 held.
//
// NWORDS IS A CONTRACT WITH config_latch, not a loader-only parameter: this module owns
// the word counter and the write address, so if the latch shrinks and this doesn't, the
// address wraps modulo 2^ADDR_W and the chip comes up with T1=T2=T3=0 (always-true exit)
// from a load that reports no error. cc_top drives both from one pair
// (CFG_NWORDS/CFG_ADDRW); the elaboration check below makes a mismatch loud.
`include "ckpt_defs.vh"

module blob_loader #(
    parameter NWORDS = `CFG_WORDS,
    parameter ADDR_W = `CFG_ADDR_W
) (
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire                      cfg_mode,
    input  wire                      cfg_stb,
    input  wire [`CFG_W-1:0]         cfg_din,

    output reg                       cfg_wr_en,
    output reg  [ADDR_W-1:0]         cfg_addr,
    output reg  [`CFG_W-1:0]         cfg_wr_data,
    output reg                       cfg_blob_done,

    output wire                      loading,
    output wire [ADDR_W:0]           words_seen,
    output reg                       blob_err
);

    reg [ADDR_W:0] cnt;
    reg            mode_q;

    wire mode_rise = cfg_mode && !mode_q;
    wire last_word = (cnt == NWORDS - 1);
    wire in_range  = (cnt < NWORDS);
    wire take      = cfg_mode && cfg_stb && in_range;
    wire overrun   = cfg_mode && cfg_stb && !in_range;

    assign loading    = cfg_mode && in_range;
    assign words_seen = cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            cnt           <= 0;
            mode_q        <= 1'b0;
            cfg_wr_en     <= 1'b0;
            cfg_addr      <= 0;
            cfg_wr_data   <= 0;
            cfg_blob_done <= 1'b0;
            blob_err      <= 1'b0;
        end else begin
            mode_q <= cfg_mode;

            // Rising edge of cfg_mode restarts the load and clears the error, so a
            // retry is a clean retry -- the only reset path a host needs.
            if (mode_rise) begin
                cnt      <= 0;
                blob_err <= 1'b0;
            end else if (take) begin
                cnt <= cnt + 1'b1;
            end

            cfg_wr_en   <= take;
            cfg_addr    <= cnt[ADDR_W-1:0];
            cfg_wr_data <= cfg_din;

            cfg_blob_done <= take && last_word;

            if (overrun) blob_err <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((1 << ADDR_W) < NWORDS) begin
            $display("blob_loader: FAIL ADDR_W=%0d cannot address NWORDS=%0d",
                     ADDR_W, NWORDS);
            $finish;
        end
        if (NWORDS * `CFG_W <= `CFG_BITS) begin
            $display("blob_loader: FAIL NWORDS=%0d carries %0d b, need > CFG_BITS=%0d",
                     NWORDS, NWORDS * `CFG_W, `CFG_BITS);
            $finish;
        end
    end
`endif
endmodule
