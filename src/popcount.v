// popcount -- stage 6: the per-plane population count that feeds the length compare.
//
// One combinational `NPIX -> `PC_W adder tree. Its only consumer is
// active_pixel_scan's plane-length rule
//
//     plane_len = max(popcount(plane), `ZS_FILL)
//
// which is the DESIGN_LEDGER Aug-10 property (`cycles == max(popcount, fill)`), so
// this module is directly load-bearing for the 41.4-cycle zero-skip headline. It is
// evaluated on the plane AFTER K10 inversion (bitplane_buffer applies the XOR on its
// `plane` output) -- that is the whole point of K10: on page-2 offset-binary thermal
// data the un-inverted MSB plane is nearly all ones, popcount is ~`NPIX, and zero-skip
// buys nothing.
//
// ---------------------------------------------------------------- width
// `PC_W = 7, not 6. The range is 0..`NPIX inclusive = 65 distinct values, and an
// all-ones plane really does occur (the directed vectors include one; the 10k MNIST
// test set's maximum is 27). A 6-bit count would alias 64 -> 0 and turn the densest
// possible plane into the SHORTEST one -- a silent wrong answer of exactly the kind
// docs/cc_verilog_build_prompts.md §0.1 exists to enumerate, not a compile error.
//
// ---------------------------------------------------------------- structure
// A balanced binary adder tree, `LOGN = 6 levels, held in one flat node array:
//
//     nd[0 .. `NPIX-1]                       the input bits, zero-extended
//     level k (k = 1..`LOGN) has `NPIX>>k nodes, based at 2*`NPIX - (2*`NPIX >> k)
//     nd[2*`NPIX-2]                          the root = the count
//
// Every node is declared the full `PC_W wide and the upper bits of the low levels are
// constant 0; yosys's opt_expr/opt_clean strip them before abc ever sees them, so the
// uniform width costs nothing and keeps the generate loop free of per-level widths.
//
// This is written as a plain adder tree rather than a Wallace / 3:2-compressor network
// on purpose: it is one flat combinational cone with no state, so abc's structural
// hashing and rewriting (`strash; dch; map`) is what actually picks the gate-level
// structure, and hand-compressing the RTL mostly moves work abc would do anyway. The
// measured cell count is in l2_synthesis/results.md; treat that, not this comment, as
// the cost.
//
// Widths come from ckpt_rtl/ckpt_defs.vh. Nothing is re-declared here.
`include "ckpt_defs.vh"

module popcount #(parameter N = `NPIX) (
    input  wire [N-1:0]      bits,
    output wire [`PC_W-1:0]  count
);
    localparam LOGN = $clog2(N);

    // nd[0..N-1] are the leaves; the internal levels follow, root last.
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
        // The flat node indexing above assumes an exact power of two, and the width
        // assumes the count fits. Both are true for `NPIX = 64 / `PC_W = 7; a future
        // page with a different input size must not discover that silently.
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
