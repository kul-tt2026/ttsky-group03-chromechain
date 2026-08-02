// blob_loader -- the host write path into config_latch. Fase 3.
//
// config_latch has wr_en / addr / wr_data / blob_done and, until this file, NOTHING
// drove them: the only reloadable state on the chip had no way to be loaded. The
// blob is `CFG_WORDS x `CFG_W = 16 x 8 = 128 b (ckpt_defs.vh's "config latch / blob
// contract"), and `CFG_W is 8 because TT's ui_in is 8 b wide, so one word is one host
// cycle and the loader needs no serialiser.
//
// PROTOCOL, deliberately the simplest thing that cannot desynchronise:
//   cfg_mode  held high for the whole load. Its rising edge resets the word counter,
//             so a host that loses count restarts by dropping and raising it -- there
//             is no "abort" command to get wrong.
//   cfg_stb   one pulse per word. The word goes to the address the counter names, so
//             the host never sends an address and the two can never disagree.
//   after the `CFG_WORDS'th strobe the loader raises blob_done for one cycle, which is
//   config_latch's K12 gate: blob_loaded goes high and the datapath is allowed to run.
//
// WHY A COUNTER AND NOT HOST-SUPPLIED ADDRESSES: a host-supplied address needs 4 of the
// 8 data bits or a second transfer, and a wrong address writes a threshold into the
// enable field -- a silently wrong chip rather than a failed load. A counter cannot
// address the wrong word; it can only be at the wrong count, which `words_seen` reports.
//
// OVERRUN is reported, not silently wrapped: strobes past `CFG_WORDS set blob_err and
// are dropped. Wrapping would let a host that sends 17 words overwrite T1 with whatever
// word 17 held, and the chip would come up with a threshold nobody chose.
`include "ckpt_defs.vh"

module blob_loader (
    input  wire                      clk,
    input  wire                      rst,        // synchronous, active high

    // ---- host side (from the TT pins)
    input  wire                      cfg_mode,   // held high for the whole load
    input  wire                      cfg_stb,    // one pulse per word
    input  wire [`CFG_W-1:0]         cfg_din,    // the word, ui_in

    // ---- config_latch side
    output reg                       cfg_wr_en,
    output reg  [`CFG_ADDR_W-1:0]    cfg_addr,
    output reg  [`CFG_W-1:0]         cfg_wr_data,
    output reg                       cfg_blob_done,

    // ---- status
    output wire                      loading,
    output wire [`CFG_ADDR_W:0]      words_seen, // 0..`CFG_WORDS, so one bit wider
    output reg                       blob_err    // sticky: strobe past the last word
);

    reg [`CFG_ADDR_W:0] cnt;        // 0..`CFG_WORDS inclusive -> `CFG_ADDR_W+1 bits
    reg                 mode_q;

    wire mode_rise = cfg_mode && !mode_q;
    wire last_word = (cnt == `CFG_WORDS - 1);
    wire in_range  = (cnt < `CFG_WORDS);
    wire take      = cfg_mode && cfg_stb && in_range;
    wire overrun   = cfg_mode && cfg_stb && !in_range;

    assign loading    = cfg_mode && in_range;
    assign words_seen = cnt;

    always @(posedge clk) begin
        if (rst) begin
            cnt           <= 0;
            mode_q        <= 1'b0;
            cfg_wr_en     <= 1'b0;
            cfg_addr      <= 0;
            cfg_wr_data   <= 0;
            cfg_blob_done <= 1'b0;
            blob_err      <= 1'b0;
        end else begin
            mode_q <= cfg_mode;

            // rising edge of cfg_mode restarts the load -- the only reset path a host
            // needs, and it clears the error so a retry is a clean retry.
            if (mode_rise) begin
                cnt      <= 0;
                blob_err <= 1'b0;
            end else if (take) begin
                cnt <= cnt + 1'b1;
            end

            cfg_wr_en   <= take;
            cfg_addr    <= cnt[`CFG_ADDR_W-1:0];
            cfg_wr_data <= cfg_din;

            // one-cycle pulse, on the strobe that takes the final word
            cfg_blob_done <= take && last_word;

            if (overrun) blob_err <= 1'b1;
        end
    end

endmodule
