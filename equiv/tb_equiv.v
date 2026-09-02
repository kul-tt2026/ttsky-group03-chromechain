// tb_equiv.v -- differential harness for the Chrome Chain TT wrapper.
// Drives ONLY the TT pins, records every observable every cycle to a text trace.
// Build once per RTL tree; diff the two traces. Identical trace == equivalent.
//   iverilog -g2005 -I <src> -o eq.vvp -s tb_equiv tb_equiv.v <21 sources>
//   vvp eq.vvp +trace=base.txt
`timescale 1ns/1ps
`default_nettype none

module tb_equiv;
  reg clk = 0, rst_n = 0, ena = 1;
  reg [7:0] ui_in = 0, uio_in = 0;
  wire [7:0] uo_out, uio_out, uio_oe;

  tt_um_kul_chromechain dut (
    .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in),
    .uio_out(uio_out), .uio_oe(uio_oe), .ena(ena), .clk(clk), .rst_n(rst_n));

  always #5 clk = ~clk;

  // ---- pin positions
  localparam LD_EN = 0, LD_VSTB = 1, CFG_MODE = 2, CFG_STB = 3, START = 4;

  integer fd, cyc = 0, i, j, img, guard;
  reg [31:0] seed = 32'd20260902;      // FIXED. Determinism is the whole point.
  reg [255:0] fname;
  reg [63:0] plane_bits;
  reg [7:0]  beats [0:31];

  // ---- trace: one line per cycle. dft_sel sweeps 0..3 so all four views are seen.
  //      Recorded AFTER the edge, with dft_sel already applied combinationally.
  task tick;
    begin
      @(posedge clk);
      uio_in[6:5] = cyc[1:0];          // sweep the view
      #1;
      $fdisplay(fd, "%0d %02h %02h %02h", cyc, uo_out, uio_out, uio_oe);
      cyc = cyc + 1;
    end
  endtask

  task do_reset;
    begin
      rst_n = 0; ui_in = 0; uio_in = 0;
      repeat (6) tick;
      rst_n = 1;
      repeat (2) tick;
    end
  endtask

  // ---- blob: word 0 is bits [7:0]. Layout from ckpt_defs.vh:171-180.
  function [47:0] mkblob(input [9:0] t1, input [9:0] t2, input [9:0] t3,
                         input [2:0] en, input skip, input page,
                         input [3:0] inv, input [2:0] ncap, input vst);
    begin
      mkblob = 48'd0;
      mkblob[9:0]   = t1;  mkblob[19:10] = t2;  mkblob[29:20] = t3;
      mkblob[32:30] = en;  mkblob[33]    = skip; mkblob[34]   = page;
      mkblob[38:35] = inv; mkblob[41:39] = ncap; mkblob[42]   = vst;
    end
  endfunction

  task load_blob(input [47:0] b, input integer nwords);
    begin
      for (i = 0; i < nwords; i = i + 1) begin
        ui_in = b[8*i +: 8];
        uio_in[CFG_MODE] = 1; uio_in[CFG_STB] = 1; tick;
        uio_in[CFG_STB] = 0;                       tick;
      end
      uio_in[CFG_MODE] = 0; ui_in = 0; tick;
    end
  endtask

  task pulse_start;
    begin
      uio_in[START] = 1; tick;
      uio_in[START] = 0; tick;          // the idle cycle the host owes at img_start
    end
  endtask

  // ---- feed one plane, honouring LD_READY (view 0, uo_out[5]).
  //      The view sweep means LD_READY is only visible every 4th cycle, so the
  //      feeder waits for a cycle where the view happens to be 0 AND ready is high.
  task feed_plane(input [63:0] bits, input use_vstb);
    begin
      for (i = 0; i < 8; i = i + 1) begin
        guard = 0;
        while (!(uio_in[6:5] == 2'd0 && uo_out[5] === 1'b1) && guard < 400) begin
          uio_in[LD_EN] = 0; tick; guard = guard + 1;
        end
        ui_in = bits[8*i +: 8];
        uio_in[LD_EN] = 1;
        uio_in[LD_VSTB] = use_vstb && (i == 7);
        tick;
        uio_in[LD_EN] = 0; uio_in[LD_VSTB] = 0; ui_in = 0;
      end
    end
  endtask

  task run_image(input [63:0] p0, input [63:0] p1, input [63:0] p2, input [63:0] p3,
                 input integer nplanes, input use_vstb, input integer maxwait);
    begin
      pulse_start;
      if (nplanes > 0) feed_plane(p0, use_vstb);
      if (nplanes > 1) feed_plane(p1, use_vstb);
      if (nplanes > 2) feed_plane(p2, use_vstb);
      if (nplanes > 3) feed_plane(p3, use_vstb);
      guard = 0;
      while (!(uio_in[6:5] == 2'd0 && uo_out[4] === 1'b1) && guard < maxwait) begin
        tick; guard = guard + 1;
      end
      repeat (70) tick;                 // >= 64: the documented post-DONE drain
    end
  endtask

  // dummy arg: iverilog requires >=1 input port. Called only into a temporary,
  // never twice inside one call's argument list -- argument evaluation order is
  // unspecified in Verilog and would silently destroy determinism.
  function [63:0] rnd64(input dummy);
    begin
      rnd64 = {$random(seed), $random(seed)};
    end
  endfunction

  reg [63:0] r0, r1, r2, r3;

  reg [47:0] B_DEF, B_SKIP, B_INV, B_VST;

  initial begin
    if (!$value$plusargs("trace=%s", fname)) fname = "trace.txt";
    fd = $fopen(fname, "w");
    if (fd == 0) begin $display("cannot open trace"); $finish; end

    B_DEF  = mkblob(10'd1023, 10'd8, 10'd12, 3'b110, 1'b0, 1'b0, 4'h0, 3'd4, 1'b0);
    B_SKIP = mkblob(10'd1023, 10'd8, 10'd12, 3'b110, 1'b1, 1'b0, 4'h0, 3'd4, 1'b0);
    B_INV  = mkblob(10'd1023, 10'd8, 10'd12, 3'b110, 1'b0, 1'b0, 4'hA, 3'd4, 1'b0);
    B_VST  = mkblob(10'd1023, 10'd8, 10'd12, 3'b110, 1'b0, 1'b0, 4'h0, 3'd4, 1'b1);

    // ---- S1 reset behaviour, and START refused before any blob (K12)
    do_reset;
    uio_in[START] = 1; tick; uio_in[START] = 0; repeat (8) tick;

    // ---- S2 well-formed load, then a dense image
    load_blob(B_DEF, 6);
    run_image(64'hF0F0_0F0F_AA55_1234, 64'h0123_4567_89AB_CDEF,
              64'hFFFF_0000_FFFF_0000, 64'h8001_4002_2004_1008, 4, 0, 3000);

    // ---- S3 zero-skip ordering
    do_reset; load_blob(B_SKIP, 6);
    run_image(64'h0000_0001_0000_0080, 64'h0000_0000_0000_00FF,
              64'h8000_0000_0000_0000, 64'h0000_0000_0000_0000, 4, 0, 3000);

    // ---- S4 K10 per-plane inversion
    do_reset; load_blob(B_INV, 6);
    run_image(64'h1111_2222_3333_4444, 64'h5555_6666_7777_8888,
              64'h9999_AAAA_BBBB_CCCC, 64'hDDDD_EEEE_FFFF_0000, 4, 0, 3000);

    // ---- S5 K11 valid strobes armed
    do_reset; load_blob(B_VST, 6);
    run_image(64'hDEAD_BEEF_CAFE_BABE, 64'h0F0F_F0F0_3C3C_C3C3,
              64'h1234_5678_9ABC_DEF0, 64'hFEDC_BA98_7654_3210, 4, 1, 3000);

    // ---- S6 back-to-back with NO drain wait -- must trip scan_err identically
    do_reset; load_blob(B_DEF, 6);
    pulse_start;
    feed_plane(64'hAAAA_5555_AAAA_5555, 0); feed_plane(64'h5555_AAAA_5555_AAAA, 0);
    feed_plane(64'hFFFF_FFFF_0000_0000, 0); feed_plane(64'h0000_0000_FFFF_FFFF, 0);
    guard = 0;
    while (!(uio_in[6:5] == 2'd0 && uo_out[4] === 1'b1) && guard < 3000) begin
      tick; guard = guard + 1; end
    pulse_start;                                   // deliberately early
    feed_plane(64'h1111_1111_1111_1111, 0); feed_plane(64'h2222_2222_2222_2222, 0);
    feed_plane(64'h3333_3333_3333_3333, 0); feed_plane(64'h4444_4444_4444_4444, 0);
    repeat (400) tick;

    // ---- S7 N_cap sweep, including the values that hang (bounded, then reset)
    for (j = 0; j <= 5; j = j + 1) begin
      do_reset;
      load_blob(mkblob(10'd1023, 10'd8, 10'd12, 3'b110, 1'b0, 1'b0, 4'h0, j[2:0], 1'b0), 6);
      pulse_start;
      feed_plane(64'h0F1E_2D3C_4B5A_6978, 0);
      if (j != 1) feed_plane(64'h1122_3344_5566_7788, 0);
      if (j > 2 || j == 0) feed_plane(64'h99AA_BBCC_DDEE_FF00, 0);
      if (j > 3 || j == 0) feed_plane(64'hC0FF_EE00_1234_5678, 0);
      repeat (500) tick;                           // bounded: a hang traces as a hang
    end

    // ---- S8 malformed config: short load, overrun, aborted-then-restarted
    do_reset; load_blob(B_DEF, 3); repeat (10) tick;      // short
    do_reset; load_blob(B_DEF, 9); repeat (10) tick;      // overrun -> blob_err
    do_reset;
    load_blob(B_DEF, 2);                                  // abort mid-load
    load_blob(B_DEF, 6);                                  // restart: covers cnt_eff
    run_image(64'hA5A5_5A5A_A5A5_5A5A, 64'h3C3C_C3C3_3C3C_C3C3,
              64'h0F0F_F0F0_0F0F_F0F0, 64'h00FF_FF00_00FF_FF00, 4, 0, 3000);

    // ---- S9 random images, fixed seed. This is where a restructure gets caught.
    do_reset; load_blob(B_DEF, 6);
    for (img = 0; img < 300; img = img + 1) begin
      r0 = rnd64(0); r1 = rnd64(0); r2 = rnd64(0); r3 = rnd64(0);
      run_image(r0, r1, r2, r3, 4, 0, 3000);
    end
    do_reset; load_blob(B_SKIP, 6);
    for (img = 0; img < 300; img = img + 1) begin
      r0 = rnd64(0); r1 = rnd64(0); r2 = rnd64(0); r3 = rnd64(0);
      run_image(r0, r1, r2, r3, 4, 0, 3000);
    end

    $fclose(fd);
    $display("tb_equiv: %0d cycles traced to %0s", cyc, fname);
    $finish;
  end
endmodule
