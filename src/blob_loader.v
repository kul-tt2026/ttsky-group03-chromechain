// blob_loader -- the host write path into config_latch. Fase 3.
//
// config_latch has wr_en / addr / wr_data / blob_done and, until this file, NOTHING
// drove them: the only reloadable state on the chip had no way to be loaded. The
// blob is `CFG_WORDS x `CFG_W (ckpt_defs.vh's "config latch / blob contract"):
// 6 x 8 = 48 b since v1.1, 16 x 8 = 128 b in v1. `CFG_W is 8 because TT's ui_in is 8 b
// wide, so one word is one host cycle and the loader needs no serialiser.
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
//
// ---------------------------------------------------------------- NWORDS IS A CONTRACT
// v1.1 lever 3 shrinks config_latch to NWORDS=6 / ADDR_W=3 (48 b, the 43 b payload with
// no page-2 spare). THAT LEVER IS NOT A CONFIG_LATCH-ONLY CHANGE. This loader owns the
// word counter and the address, so if the latch shrinks and the loader does not, the
// host still sends `CFG_WORDS words, the address wraps modulo 2^ADDR_W, and words 8..15
// -- all zero in every shipped blob -- land back on top of words 0..5. The chip would
// come up with T1=T2=T3=0, i.e. an always-true exit at checkpoint 1, from a load that
// reports no error. That is a silently wrong chip, which is exactly the failure class
// this file's OVERRUN note exists to prevent.
//
// So the two are parameterised together and cc_top drives both from one pair
// (CFG_NWORDS / CFG_ADDRW). The elaboration check below makes a mismatched ADDR_W a loud
// failure. Defaults follow ckpt_defs.vh, which is v1.1: 6 x 8 = 48 b.
`include "ckpt_defs.vh"

module blob_loader #(
    parameter NWORDS = `CFG_WORDS,      // 6 -> the 48 b blob; 16 was v1's 128 b contract
    parameter ADDR_W = `CFG_ADDR_W      // 3; 4 alongside NWORDS=16 for the v1 window
) (
    input  wire                      clk,
    input  wire                      rst,        // synchronous, active high

    // ---- host side (from the TT pins)
    input  wire                      cfg_mode,   // held high for the whole load
    input  wire                      cfg_stb,    // one pulse per word
    input  wire [`CFG_W-1:0]         cfg_din,    // the word, ui_in

    // ---- config_latch side
    output reg                       cfg_wr_en,
    output reg  [ADDR_W-1:0]         cfg_addr,
    output reg  [`CFG_W-1:0]         cfg_wr_data,
    output reg                       cfg_blob_done,

    // ---- status
    output wire                      loading,
    output wire [ADDR_W:0]           words_seen, // 0..NWORDS, so one bit wider
    output reg                       blob_err    // sticky: strobe past the last word
);

    reg [ADDR_W:0] cnt;             // 0..NWORDS inclusive -> ADDR_W+1 bits
    reg            mode_q;

    wire mode_rise = cfg_mode && !mode_q;

    // A host may raise cfg_mode in the SAME cycle as its first cfg_stb -- the simplest
    // one does exactly that, and test/test.py::test_config_load is that host. `cnt_eff`
    // is the count this cycle's strobe acts on, so a restart and a first word can land
    // together: the word goes to address 0 and IS counted. Without it the write still
    // happened (cfg_wr_en was never gated by mode_rise) but the counter was reset
    // instead of incremented, so every later word landed one address low, the final
    // strobe never saw `last_word`, and blob_done never pulsed -- a chip that never
    // becomes ready, with blob_err clear and nothing to explain why.
    wire [ADDR_W:0] cnt_eff = mode_rise ? 0 : cnt;

    wire last_word = (cnt_eff == NWORDS - 1);
    wire in_range  = (cnt_eff < NWORDS);
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
            // needs, and it clears the error so a retry is a clean retry. The restart
            // and the first word may be the SAME cycle, so the count advances from
            // cnt_eff and `take` is tested before the bare restart.
            if (mode_rise) blob_err <= 1'b0;

            if (take)           cnt <= cnt_eff + 1'b1;
            else if (mode_rise) cnt <= 0;

            cfg_wr_en   <= take;
            cfg_addr    <= cnt_eff[ADDR_W-1:0];
            cfg_wr_data <= cfg_din;

            // one-cycle pulse, on the strobe that takes the final word
            cfg_blob_done <= take && last_word;

            if (overrun) blob_err <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    initial begin
        // The counter must be able to name every word, and the payload must still fit.
        // Both are loud failures rather than a wrapped address or a truncated blob.
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
