// tb_model.v -- drives images from a file through the TT pins and prints the result
// of each, so equiv/model/cc_model.py can compare the silicon's arithmetic against an
// independent implementation. Dense ordering, default blob.
//   iverilog -g2005 -I <src> -o m.vvp -s tb_model tb_model.v <21 sources>
//   vvp m.vvp +imgs=images.txt        # one image per line: p0 p1 p2 p3, hex
`timescale 1ns/1ps
`default_nettype none

module tb_model;
  reg clk = 0, rst_n = 0, ena = 1;
  reg [7:0] ui_in = 0, uio_in = 0;
  wire [7:0] uo_out, uio_out, uio_oe;

  tt_um_kul_chromechain dut (
    .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in),
    .uio_out(uio_out), .uio_oe(uio_oe), .ena(ena), .clk(clk), .rst_n(rst_n));

  always #5 clk = ~clk;

  localparam LD_EN = 0, CFG_MODE = 2, CFG_STB = 3, START = 4;

  integer fh, code, i, guard, nimg;
  reg [2047:0] fname;   // 256 chars: a tmpdir path overflows a narrower reg
  reg [63:0] p0, p1, p2, p3;
  reg [3:0]  answer;
  reg [2:0]  exit_k;
  reg        seen_done;

  task tick; begin @(posedge clk); #1; end endtask

  task do_reset;
    begin
      rst_n = 0; ui_in = 0; uio_in = 0;
      repeat (6) tick;
      rst_n = 1;
      repeat (2) tick;
    end
  endtask

  // default blob: T1 1023 (P1 disarmed), T2 8, T3 12, arm {P2,P3}, dense, n_cap 4
  task load_blob;
    reg [47:0] b;
    begin
      b = 48'd0;
      b[9:0] = 10'd1023; b[19:10] = 10'd8; b[29:20] = 10'd12;
      b[32:30] = 3'b110; b[41:39] = 3'd4;
      for (i = 0; i < 6; i = i + 1) begin
        ui_in = b[8*i +: 8];
        uio_in[CFG_MODE] = 1; uio_in[CFG_STB] = 1; tick;
        uio_in[CFG_STB] = 0;                       tick;
      end
      uio_in[CFG_MODE] = 0; ui_in = 0; tick;
    end
  endtask

  // one plane, 8 beats, only while LD_READY (view 0, uo_out[5]) is high
  task feed_plane(input [63:0] bits);
    begin
      for (i = 0; i < 8; i = i + 1) begin
        guard = 0;
        while (!(uo_out[5] === 1'b1) && guard < 400) begin
          uio_in[LD_EN] = 0; tick; guard = guard + 1;
        end
        ui_in = bits[8*i +: 8];
        uio_in[LD_EN] = 1; tick;
        uio_in[LD_EN] = 0; ui_in = 0;
      end
    end
  endtask

  // DONE is a one-cycle pulse that can land while the host is still feeding, so watch
  // view 0 every cycle from START and latch the first one seen.
  always @(posedge clk) begin
    if (rst_n && uio_in[6:5] == 2'd0 && uo_out[4] === 1'b1 && !seen_done) begin
      seen_done <= 1'b1;
      answer    <= uo_out[3:0];
    end
  end

  task run_image;
    begin
      seen_done = 1'b0;
      uio_in[6:5] = 2'd0;
      uio_in[START] = 1; tick;
      uio_in[START] = 0; tick;
      feed_plane(p0); feed_plane(p1); feed_plane(p2); feed_plane(p3);
      guard = 0;
      while (!seen_done && guard < 3000) begin tick; guard = guard + 1; end
      uio_in[6:5] = 2'd2; #1; exit_k = uo_out[2:0]; uio_in[6:5] = 2'd0; #1;
      repeat (80) tick;                 // post-DONE scanner drain
    end
  endtask

  initial begin
    if (!$value$plusargs("imgs=%s", fname)) begin
      $display("tb_model: need +imgs=<file>"); $finish;
    end
    fh = $fopen(fname, "r");
    if (fh == 0) begin $display("tb_model: cannot open %0s", fname); $finish; end

    do_reset;
    load_blob;

    nimg = 0;
    while (!$feof(fh)) begin
      code = $fscanf(fh, "%h %h %h %h\n", p0, p1, p2, p3);
      if (code == 4) begin
        run_image;
        $display("RESULT %0d %0d %0d", nimg, answer, exit_k);
        nimg = nimg + 1;
      end
    end
    $fclose(fh);
    $display("tb_model: %0d images", nimg);
    $finish;
  end
endmodule
