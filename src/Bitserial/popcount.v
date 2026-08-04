// popcount -- stage 6: per-plane population count feeding active_pixel_scan's
// plane_len = max(popcount, `ZS_FILL). Counts the plane AFTER K10 inversion (consumes
// bitplane_buffer's already-XORed `plane` output) -- that's the whole point of K10.
//
// `PC_W = 7, not 6: range is 0..`NPIX inclusive (65 values). 6 b would wrap 64 -> 0,
// making the densest possible plane look like the shortest -- a silent wrong answer.
//
// Plain adder tree, not Wallace/compressor: this is one flat combinational cone with
// no state, so synthesis's own structural hashing picks the gate-level structure.
`include "ckpt_defs.vh"

module popcount #(parameter N = `NPIX) (
    input  wire [N-1:0]      bits,
    output wire [`PC_W-1:0]  count
);
    localparam LOGN = $clog2(N);

    wire [`PC_W-1:0] nd [0:2*N-2];

    genvar i, k;
    generate
        for (i = 0; i < N; i = i + 1) begin : leaf
            assign nd[i] = {{(`PC_W-1){1'b0}}, bits[i]};
        end
        for (k = 1; k <= LOGN; k = k + 1) begin : level
            for (i = 0; i < (N >> k); i = i + 1) begin : node
                assign nd[(2*N - (2*N >> k)) + i] =
                       nd[(2*N - (2*N >> (k-1))) + 2*i] +
                       nd[(2*N - (2*N >> (k-1))) + 2*i + 1];
            end
        end
    endgenerate

    assign count = nd[2*N-2];

`ifndef SYNTHESIS
    initial begin
        if ((1 << LOGN) != N) begin
            $display("popcount: FAIL N = %0d is not a power of two", N);
            $finish;
        end
        if ((1 << `PC_W) <= N) begin
            $display("popcount: FAIL `PC_W = %0d cannot hold a count of %0d", `PC_W, N);
            $finish;
        end
    end
`endif
endmodule
