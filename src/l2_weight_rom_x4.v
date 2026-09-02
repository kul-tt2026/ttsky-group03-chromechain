// l2_weight_rom_x4 -- W2 ternary weight ROM: 32 words x 20 b (10 classes x 2 b per word),
// four read ports (one per L2 lane), each a combinational case table.
// GENERATED from the trained W2 weights -- do not edit by hand; regenerate the whole file.
//
// Word encoding (decoded by l2_mac_x4): class c of unit u is the bit pair
// wcol[20*u + 2*c +: 2]; the LOW bit (2c) set means +h[u], the HIGH bit (2c+1) set
// means -h[u], neither set means 0 (no word below sets both bits of a pair). This is
// the OPPOSITE bit order from W1, where l1_horner_acc takes +1 from w_col[2j+1] (high)
// and -1 from w_col[2j] (low). The hex tables below encode exactly this convention; a
// decoder with the two selects swapped negates every W2 weight and nothing reports it.
//
// Bus convention (packed, matches l2_mac_x4's unit-major packing of h_in/w_in):
// port i's address is addr[CKPT_ADDR_W*i +: CKPT_ADDR_W] and its word is
// wcol[W2_ROW_W*i +: W2_ROW_W], i = 0..3. ckpt_block wires wcol straight into
// l2_mac_x4's w_in[79:0] with no reshuffling -- w_in[20*u +: 20] == wcol[20*u +: 20].
//
// GROUPED DECODE CONTRACT: port i's address field MUST satisfy addr % 4 == i, i.e.
// port i only ever reads hidden units i, i+4, i+8, ... (the 32 units are read in
// blocks of 4 consecutive units per cycle; l1_acc_shadow's rd_grp uses the same
// grouping). Port i's decode looks only at the top 3 b of its 5-b address field; the
// low 2 b are ignored in hardware and NOT checked, so a caller that violates the
// contract gets WRONG data, not an error. The only caller, checkpoint_ctrl, guarantees
// it: rom_addr[5*gi +: 5] = rd_grp*4 + gi for gi = 0..3. The ports are therefore not
// independently addressable; entry k of port i holds hidden unit 4*k + i.
//
// Port widths come from ckpt_defs.vh: `P`=4 (L2 units/cycle), W2_ROW_W (=20),
// CKPT_ADDR_W (=5).
`include "ckpt_defs.vh"

// Four independent case(addr) read ports; each decodes only the top 3 b of its 5-b
// address field and ignores the low 2 b. Valid ONLY because every caller presents
// addr % 4 == p to port p (see the header). Content: 32 words x 20 b.
module l2_weight_rom_x4(
    input  wire [(`P*`CKPT_ADDR_W)-1:0] addr,
    output reg  [(`P*`W2_ROW_W)-1:0] wcol
  );
  // port 0: addr[4:2] -> wcol[19:0] (addr[1:0] ignored, required == 0)
  always @(*) begin
    case (addr[4:2])
      3'd0: wcol[19:0] = 20'h48818;
      3'd1: wcol[19:0] = 20'h82a5a;
      3'd2: wcol[19:0] = 20'h266a4;
      3'd3: wcol[19:0] = 20'h1206a;
      3'd4: wcol[19:0] = 20'h88660;
      3'd5: wcol[19:0] = 20'ha8098;
      3'd6: wcol[19:0] = 20'h416a8;
      3'd7: wcol[19:0] = 20'h29186;
      default: wcol[19:0] = 20'b0;
    endcase
  end
  // port 1: addr[9:7] -> wcol[39:20] (addr[6:5] ignored, required == 1)
  always @(*) begin
    case (addr[9:7])
      3'd0: wcol[39:20] = 20'h65a28;
      3'd1: wcol[39:20] = 20'ha8640;
      3'd2: wcol[39:20] = 20'h82aa9;
      3'd3: wcol[39:20] = 20'h18208;
      3'd4: wcol[39:20] = 20'h4a926;
      3'd5: wcol[39:20] = 20'h2a889;
      3'd6: wcol[39:20] = 20'ha2899;
      3'd7: wcol[39:20] = 20'h216a8;
      default: wcol[39:20] = 20'b0;
    endcase
  end
  // port 2: addr[14:12] -> wcol[59:40] (addr[11:10] ignored, required == 2)
  always @(*) begin
    case (addr[14:12])
      3'd0: wcol[59:40] = 20'ha0064;
      3'd1: wcol[59:40] = 20'h2660a;
      3'd2: wcol[59:40] = 20'h06a54;
      3'd3: wcol[59:40] = 20'ha4944;
      3'd4: wcol[59:40] = 20'h0a562;
      3'd5: wcol[59:40] = 20'h91180;
      3'd6: wcol[59:40] = 20'h08894;
      3'd7: wcol[59:40] = 20'ha5068;
      default: wcol[59:40] = 20'b0;
    endcase
  end
  // port 3: addr[19:17] -> wcol[79:60] (addr[16:15] ignored, required == 3)
  always @(*) begin
    case (addr[19:17])
      3'd0: wcol[79:60] = 20'h84296;
      3'd1: wcol[79:60] = 20'ha6585;
      3'd2: wcol[79:60] = 20'h6a442;
      3'd3: wcol[79:60] = 20'h92092;
      3'd4: wcol[79:60] = 20'h668aa;
      3'd5: wcol[79:60] = 20'h180a2;
      3'd6: wcol[79:60] = 20'h22198;
      3'd7: wcol[79:60] = 20'h198a1;
      default: wcol[79:60] = 20'b0;
    endcase
  end
endmodule
