// Wrapper for formal_wrap.sh: the TT wrapper with DFT view 2 bit 3 forced to 0, so that
// P3a (which puts scan_busy on that bit) can be proven identical everywhere else.
module tt_mask_view2_bit3 (
    input  wire [7:0] ui_in, output wire [7:0] uo_out, input wire [7:0] uio_in,
    output wire [7:0] uio_out, output wire [7:0] uio_oe,
    input  wire ena, input wire clk, input wire rst_n);
    wire [7:0] uo;
    tt_um_kul_chromechain u (.ui_in(ui_in), .uo_out(uo), .uio_in(uio_in),
        .uio_out(uio_out), .uio_oe(uio_oe), .ena(ena), .clk(clk), .rst_n(rst_n));
    assign uo_out = (uio_in[6:5] == 2'd2) ? {uo[7:4], 1'b0, uo[2:0]} : uo;
endmodule
