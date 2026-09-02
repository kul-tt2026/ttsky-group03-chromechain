// w1_rom_final4 -- W1 weight ROM: 64 words x 64 b, addr = pixel index 0..63 (`PIX_W = 6).
// GENERATED from the trained W1 fold -- do not edit by hand; regenerate the whole file.
//
// Word layout: 32 hidden units (`NHID) x 2 b. Unit j is the pair {p,n} at wcol[2j+1:2j]:
// p (bit 2j+1, the HIGH bit) selects +1, n (bit 2j, the low bit) selects -1, 00 is a
// zero weight. Real content never sets p and n together. Consumed by l1_horner_acc /
// l1_horner_cnt (inc = w_col[2j+1], dec = w_col[2j]).
//
// NOTE: this is the OPPOSITE pair order to W2 -- l2_mac_x4 reads w_in[20u+2c] as +h
// (the LOW bit of its pair) and w_in[20u+2c+1] as -h. Each ROM encodes its own
// consumer's order; swapping either convention without regenerating the ROM negates
// every weight it feeds.
//
// Instantiated once in cc_top (u_w1, addr = w1_addr from the pixel scanner); ckpt_block
// takes the row as its w1_row input port rather than instantiating the ROM itself.
// w1_rom_final4: case(addr) with 64 constant literals, default 0
module w1_rom_final4(input wire [5:0] addr, output reg [63:0] wcol);
  always @(*) begin
    case (addr)
      6'd0: wcol = 64'h4501100002200000;
      6'd1: wcol = 64'ha246245055855aa8;
      6'd2: wcol = 64'ha262455551954a9a;
      6'd3: wcol = 64'ha242645555856a8a;
      6'd4: wcol = 64'h2a566455458542a8;
      6'd5: wcol = 64'haa566554559568a9;
      6'd6: wcol = 64'haa522554598559aa;
      6'd7: wcol = 64'h205960554021499a;
      6'd8: wcol = 64'h4511508806224061;
      6'd9: wcol = 64'h4451400126256021;
      6'd10: wcol = 64'h0418604504a50009;
      6'd11: wcol = 64'h054a405012819201;
      6'd12: wcol = 64'h11421850489156a2;
      6'd13: wcol = 64'h0804005028919014;
      6'd14: wcol = 64'h4a45a10091959915;
      6'd15: wcol = 64'h4819a6029895a944;
      6'd16: wcol = 64'h61555800a4609241;
      6'd17: wcol = 64'h45596015a4250941;
      6'd18: wcol = 64'h15526005a2010011;
      6'd19: wcol = 64'h110a91111921a908;
      6'd20: wcol = 64'h59415910002a6068;
      6'd21: wcol = 64'h15110800201a2251;
      6'd22: wcol = 64'h55158066905aa040;
      6'd23: wcol = 64'h4914a6669856a965;
      6'd24: wcol = 64'h65551115a4269869;
      6'd25: wcol = 64'h6146518598429542;
      6'd26: wcol = 64'h2286012190128542;
      6'd27: wcol = 64'ha885a40212009165;
      6'd28: wcol = 64'h04a4850a66a65419;
      6'd29: wcol = 64'h840041801118165a;
      6'd30: wcol = 64'h855409001158540a;
      6'd31: wcol = 64'h45128246496285a5;
      6'd32: wcol = 64'h54550410a6a56a18;
      6'd33: wcol = 64'h4694680445508420;
      6'd34: wcol = 64'h22904aa145580102;
      6'd35: wcol = 64'h8080a66948455296;
      6'd36: wcol = 64'h028524a900056412;
      6'd37: wcol = 64'h0894428466810440;
      6'd38: wcol = 64'h6416605566211121;
      6'd39: wcol = 64'h54a8625559292896;
      6'd40: wcol = 64'h5016564866a50a59;
      6'd41: wcol = 64'h5115125640112214;
      6'd42: wcol = 64'h0048885458484686;
      6'd43: wcol = 64'ha668001495564495;
      6'd44: wcol = 64'h0041020605050020;
      6'd45: wcol = 64'h2050024402050801;
      6'd46: wcol = 64'h5440464558814884;
      6'd47: wcol = 64'h54a8565591840096;
      6'd48: wcol = 64'h411a526065a54a40;
      6'd49: wcol = 64'h5144584921904a90;
      6'd50: wcol = 64'h5041104001980200;
      6'd51: wcol = 64'h8958014088880801;
      6'd52: wcol = 64'h0040810188018861;
      6'd53: wcol = 64'h566009610a059a04;
      6'd54: wcol = 64'h5628582599140a14;
      6'd55: wcol = 64'h5288101005066a55;
      6'd56: wcol = 64'h495645202292a059;
      6'd57: wcol = 64'h0196558962a46a09;
      6'd58: wcol = 64'h1194158942012868;
      6'd59: wcol = 64'h191415810a402a4a;
      6'd60: wcol = 64'h991015911a002058;
      6'd61: wcol = 64'h198615981840215a;
      6'd62: wcol = 64'h5826118058046052;
      6'd63: wcol = 64'h100a504409062805;
      default: wcol = 64'b0;
    endcase
  end
endmodule
