/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */
`default_nettype none
module tt_um_neural (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire        ena,
    input  wire        clk,
    input  wire        rst_n
);
    wire [3:0] result;
    wire       result_valid, window_req;

    nn_top u_nn (
        .clk(clk), .rst_n(rst_n),
        .start(ui_in[0]),                       // kies zelf welk bit "start" triggert
        .window_in({uio_in, ui_in}),             // 16-bit venster: hoog=uio_in, laag=ui_in
        .window_valid(ui_in[1]),                 // of een apart strobe-bit
        .window_req(window_req),
        .result(result),
        .result_valid(result_valid)
    );

    assign uo_out  = {3'b0, result_valid, result};  // pas zelf aan naar smaak
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;                          // uio's zijn hier allemaal input

    wire _unused = &{ena, 1'b0};
endmodule