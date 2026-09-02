// requant_rom_x4 -- bias+k ROM for the checkpoint requant lanes: 32 words x 8 b, one
// word per hidden unit, 4 combinational case-statement read ports (one per L2 lane).
// GENERATED from the trained fold's bias and k values -- do not edit by hand; regenerate
// the whole file.
//
// Word layout (decoded in ckpt_block.v): [7:6] = k, the requant shift, values 0..2
// (bincount [2,28,2] over the 32 units); [5:0] = bias, 6-b two's complement, range
// -12..+29, 8 of the 32 values negative. ckpt_block sign-extends the bias to BIAS_W
// (12 b) and shifts it right ARITHMETICALLY by the per-checkpoint bias_sh from
// checkpoint_ctrl before requant_unit adds it to the L1 accumulator. No sign field is
// stored: requant_unit's sgn input is a negate flag driven by checkpoint_ctrl, where it
// is tied 1'b0 because the fold's sign is +1 for all 32 units.
//
// Bus convention (packed, unit-major, the same convention as l2_mac_x4.v's h_in/w_in):
// unit i's address is at addr[CKPT_ADDR_W*i +: CKPT_ADDR_W] and unit i's word is at
// wcol[THETAK_ROW_W*i +: THETAK_ROW_W], for i = 0..3.
//
// Port widths come from ckpt_defs.vh: `P`=4, THETAK_ROW_W (=8), CKPT_ADDR_W
// (=5).
`include "ckpt_defs.vh"

// requant_rom_x4: GROUPED decode -- 4 case(addr) read ports, but each port's decode
// only looks at the top 3 b of its 5-b address field and ignores the low 2 b entirely.
// Valid ONLY because every caller is required to present addr % 4 == p to port p. The
// sole caller, checkpoint_ctrl (via ckpt_block), drives lane gi's field with
// `P*rd_grp + gi, so the guarantee holds by construction there; any other addressing
// pattern returns the WRONG word silently -- there is no error. l2_weight_rom_x4 sits
// on the same address bus under the same contract.
module requant_rom_x4(
    input  wire [(`P*`CKPT_ADDR_W)-1:0] addr,
    output reg  [(`P*`THETAK_ROW_W)-1:0] wcol
  );
  // port 0: addr[4:2] -> wcol[7:0] (addr[1:0] ignored, required == 0)
  always @(*) begin
    case (addr[4:2])
      3'd0: wcol[7:0] = 8'h46;
      3'd1: wcol[7:0] = 8'h76;
      3'd2: wcol[7:0] = 8'h4f;
      3'd3: wcol[7:0] = 8'h78;
      3'd4: wcol[7:0] = 8'h4d;
      3'd5: wcol[7:0] = 8'h4d;
      3'd6: wcol[7:0] = 8'h47;
      3'd7: wcol[7:0] = 8'h9d;
      default: wcol[7:0] = 8'b0;
    endcase
  end
  // port 1: addr[9:7] -> wcol[15:8] (addr[6:5] ignored, required == 1)
  always @(*) begin
    case (addr[9:7])
      3'd0: wcol[15:8] = 8'h7f;
      3'd1: wcol[15:8] = 8'h4c;
      3'd2: wcol[15:8] = 8'h49;
      3'd3: wcol[15:8] = 8'h48;
      3'd4: wcol[15:8] = 8'h4b;
      3'd5: wcol[15:8] = 8'h7c;
      3'd6: wcol[15:8] = 8'h45;
      3'd7: wcol[15:8] = 8'h41;
      default: wcol[15:8] = 8'b0;
    endcase
  end
  // port 2: addr[14:12] -> wcol[23:16] (addr[11:10] ignored, required == 2)
  always @(*) begin
    case (addr[14:12])
      3'd0: wcol[23:16] = 8'h4a;
      3'd1: wcol[23:16] = 8'h42;
      3'd2: wcol[23:16] = 8'h4b;
      3'd3: wcol[23:16] = 8'h4a;
      3'd4: wcol[23:16] = 8'h4a;
      3'd5: wcol[23:16] = 8'h7e;
      3'd6: wcol[23:16] = 8'h04;
      3'd7: wcol[23:16] = 8'h47;
      default: wcol[23:16] = 8'b0;
    endcase
  end
  // port 3: addr[19:17] -> wcol[31:24] (addr[16:15] ignored, required == 3)
  always @(*) begin
    case (addr[19:17])
      3'd0: wcol[31:24] = 8'h93;
      3'd1: wcol[31:24] = 8'h40;
      3'd2: wcol[31:24] = 8'h76;
      3'd3: wcol[31:24] = 8'h4a;
      3'd4: wcol[31:24] = 8'h07;
      3'd5: wcol[31:24] = 8'h7d;
      3'd6: wcol[31:24] = 8'h46;
      3'd7: wcol[31:24] = 8'h74;
      default: wcol[31:24] = 8'b0;
    endcase
  end
endmodule
