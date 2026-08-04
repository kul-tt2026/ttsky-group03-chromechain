`include "ckpt_defs.vh"

module top_fsm(input  wire                clk,
               input  wire                rst_n,        // sync, active low
               input  wire                start,
               input  wire                blob_loaded,
               input  wire [`N_CAP_W-1:0] n_cap,
               input  wire                fill_full,
               input  wire                scan_busy,
               input  wire                plane_end,
               input  wire                exit_strobe,
               input  wire                ans_valid,
               output reg                 img_start,
               output wire                swap,
               output wire                scan_start,
               output wire                busy,
               output reg                 done,
               output wire [2:0]          planes_run,
               output reg                 cap_err);

    reg       running;
    reg       priming;
    reg       scan_start_r;
    reg [2:0] pstarted;
    reg       stopped;

    // n_cap is 3b (0..7) but only 0 < n <= `PLANES is valid; fall back to `PLANES.
    localparam [2:0] PLANE_MAX = `PLANES;
    wire [2:0] cap_raw   = n_cap[2:0];
    wire       cap_bad   = (cap_raw == 3'd0) || (cap_raw > PLANE_MAX);
    wire [2:0] plane_cap = cap_bad ? PLANE_MAX : cap_raw;

    wire more_planes = (pstarted < plane_cap) && !stopped && !exit_strobe;

    // !img_start: without it, a swap landing the same cycle as img_start gets
    // swallowed by bitplane_buffer and the scanner starts on an unloaded plane.
    wire want_swap = running && !img_start &&
                     ((priming && fill_full) ||
                      (scan_busy && plane_end && more_planes));

    assign swap       = want_swap;
    assign scan_start  = scan_start_r;
    assign busy        = running;
    assign planes_run  = pstarted;

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
            img_start <= start && blob_loaded && !running;
            done      <= ans_valid;

            if (start && blob_loaded && !running) begin
                running  <= 1'b1;
                priming  <= 1'b1;
                pstarted <= 3'd0;
                stopped  <= 1'b0;
                if (cap_bad) cap_err <= 1'b1;
            end else begin
                if (want_swap)   priming  <= 1'b0;
                if (want_swap)   pstarted <= pstarted + 3'd1;
                if (exit_strobe) stopped  <= 1'b1;
                if (ans_valid)   running  <= 1'b0;
            end

            scan_start_r <= want_swap;
        end
    end

endmodule
