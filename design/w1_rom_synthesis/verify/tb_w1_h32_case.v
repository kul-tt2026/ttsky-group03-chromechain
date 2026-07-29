`timescale 1ns/1ps
module tb;
  reg [5:0] addr; wire [63:0] wcol; integer errs=0;
  w1_h32_case dut(.addr(addr), .wcol(wcol));
  initial begin
    addr=6'd0; #1; if (wcol!==64'h4000010144) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",0,wcol,64'h4000010144); errs=errs+1; end
    addr=6'd1; #1; if (wcol!==64'h1404801512804288) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",1,wcol,64'h1404801512804288); errs=errs+1; end
    addr=6'd2; #1; if (wcol!==64'h9401801556066488) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",2,wcol,64'h9401801556066488); errs=errs+1; end
    addr=6'd3; #1; if (wcol!==64'h5485a11456445281) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",3,wcol,64'h5485a11456445281); errs=errs+1; end
    addr=6'd4; #1; if (wcol!==64'h5405a51552441a95) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",4,wcol,64'h5405a51552441a95); errs=errs+1; end
    addr=6'd5; #1; if (wcol!==64'h5645a59556045615) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",5,wcol,64'h5645a59556045615); errs=errs+1; end
    addr=6'd6; #1; if (wcol!==64'h5655a595168646a9) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",6,wcol,64'h5655a595168646a9); errs=errs+1; end
    addr=6'd7; #1; if (wcol!==64'h4444819556044068) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",7,wcol,64'h4444819556044068); errs=errs+1; end
    addr=6'd8; #1; if (wcol!==64'h6000450018211914) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",8,wcol,64'h6000450018211914); errs=errs+1; end
    addr=6'd9; #1; if (wcol!==64'h6554210148205954) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",9,wcol,64'h6554210148205954); errs=errs+1; end
    addr=6'd10; #1; if (wcol!==64'h4555a95040851104) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",10,wcol,64'h4555a95040851104); errs=errs+1; end
    addr=6'd11; #1; if (wcol!==64'h2160985048952880) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",11,wcol,64'h2160985048952880); errs=errs+1; end
    addr=6'd12; #1; if (wcol!==64'h480181611956201) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",12,wcol,64'h480181611956201); errs=errs+1; end
    addr=6'd13; #1; if (wcol!==64'h1194001021948660) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",13,wcol,64'h1194001021948660); errs=errs+1; end
    addr=6'd14; #1; if (wcol!==64'h1945604985a20660) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",14,wcol,64'h1945604985a20660); errs=errs+1; end
    addr=6'd15; #1; if (wcol!==64'h5169044905254666) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",15,wcol,64'h5169044905254666); errs=errs+1; end
    addr=6'd16; #1; if (wcol!==64'h5011012611955) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",16,wcol,64'h5011012611955); errs=errs+1; end
    addr=6'd17; #1; if (wcol!==64'h205501584a210954) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",17,wcol,64'h205501584a210954); errs=errs+1; end
    addr=6'd18; #1; if (wcol!==64'h405540516421a400) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",18,wcol,64'h405540516421a400); errs=errs+1; end
    addr=6'd19; #1; if (wcol!==64'ha101000162564a0) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",19,wcol,64'ha101000162564a0); errs=errs+1; end
    addr=6'd20; #1; if (wcol!==64'h264a50861a291900) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",20,wcol,64'h264a50861a291900); errs=errs+1; end
    addr=6'd21; #1; if (wcol!==64'h28a0500200218550) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",21,wcol,64'h28a0500200218550); errs=errs+1; end
    addr=6'd22; #1; if (wcol!==64'h51285040a4696550) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",22,wcol,64'h51285040a4696550); errs=errs+1; end
    addr=6'd23; #1; if (wcol!==64'h55695049a529566a) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",23,wcol,64'h55695049a529566a); errs=errs+1; end
    addr=6'd24; #1; if (wcol!==64'h2815055052698854) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",24,wcol,64'h2815055052698854); errs=errs+1; end
    addr=6'd25; #1; if (wcol!==64'h125a4541040066a1) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",25,wcol,64'h125a4541040066a1); errs=errs+1; end
    addr=6'd26; #1; if (wcol!==64'h12084621644256a0) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",26,wcol,64'h12084621644256a0); errs=errs+1; end
    addr=6'd27; #1; if (wcol!==64'h4965668909846268) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",27,wcol,64'h4965668909846268); errs=errs+1; end
    addr=6'd28; #1; if (wcol!==64'h84254441089a8955) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",28,wcol,64'h84254441089a8955); errs=errs+1; end
    addr=6'd29; #1; if (wcol!==64'h4280002042100591) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",29,wcol,64'h4280002042100591); errs=errs+1; end
    addr=6'd30; #1; if (wcol!==64'h5a82061610506599) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",30,wcol,64'h5a82061610506599); errs=errs+1; end
    addr=6'd31; #1; if (wcol!==64'h4168085585590518) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",31,wcol,64'h4168085585590518); errs=errs+1; end
    addr=6'd32; #1; if (wcol!==64'h248101411a818146) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",32,wcol,64'h248101411a818146); errs=errs+1; end
    addr=6'd33; #1; if (wcol!==64'h5000616a04501199) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",33,wcol,64'h5000616a04501199); errs=errs+1; end
    addr=6'd34; #1; if (wcol!==64'h505a212a45561018) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",34,wcol,64'h505a212a45561018); errs=errs+1; end
    addr=6'd35; #1; if (wcol!==64'h599aa812114a080) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",35,wcol,64'h599aa812114a080); errs=errs+1; end
    addr=6'd36; #1; if (wcol!==64'h6192a6108002105) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",36,wcol,64'h6192a6108002105); errs=errs+1; end
    addr=6'd37; #1; if (wcol!==64'h404025a842801045) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",37,wcol,64'h404025a842801045); errs=errs+1; end
    addr=6'd38; #1; if (wcol!==64'h154254040101a18) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",38,wcol,64'h154254040101a18); errs=errs+1; end
    addr=6'd39; #1; if (wcol!==64'ha18489695505450a) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",39,wcol,64'ha18489695505450a); errs=errs+1; end
    addr=6'd40; #1; if (wcol!==64'h45a515455a959026) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",40,wcol,64'h45a515455a959026); errs=errs+1; end
    addr=6'd41; #1; if (wcol!==64'h51a1995201959141) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",41,wcol,64'h51a1995201959141); errs=errs+1; end
    addr=6'd42; #1; if (wcol!==64'h21a0881415406419) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",42,wcol,64'h21a0881415406419); errs=errs+1; end
    addr=6'd43; #1; if (wcol!==64'h80558014056a2411) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",43,wcol,64'h80558014056a2411); errs=errs+1; end
    addr=6'd44; #1; if (wcol!==64'h1421810804401040) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",44,wcol,64'h1421810804401040); errs=errs+1; end
    addr=6'd45; #1; if (wcol!==64'h6101811401841002) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",45,wcol,64'h6101811401841002); errs=errs+1; end
    addr=6'd46; #1; if (wcol!==64'h2151995441955026) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",46,wcol,64'h2151995441955026); errs=errs+1; end
    addr=6'd47; #1; if (wcol!==64'h8118996055455565) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",47,wcol,64'h8118996055455565); errs=errs+1; end
    addr=6'd48; #1; if (wcol!==64'h5501a14448959404) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",48,wcol,64'h5501a14448959404); errs=errs+1; end
    addr=6'd49; #1; if (wcol!==64'h1194115458818502) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",49,wcol,64'h1194115458818502); errs=errs+1; end
    addr=6'd50; #1; if (wcol!==64'h184101210818142) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",50,wcol,64'h184101210818142); errs=errs+1; end
    addr=6'd51; #1; if (wcol!==64'h490450140104206a) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",51,wcol,64'h490450140104206a); errs=errs+1; end
    addr=6'd52; #1; if (wcol!==64'h190441081042a02) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",52,wcol,64'h190441081042a02); errs=errs+1; end
    addr=6'd53; #1; if (wcol!==64'h8051104261042086) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",53,wcol,64'h8051104261042086); errs=errs+1; end
    addr=6'd54; #1; if (wcol!==64'h1559194245546426) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",54,wcol,64'h1559194245546426); errs=errs+1; end
    addr=6'd55; #1; if (wcol!==64'h54a982255441425) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",55,wcol,64'h54a982255441425); errs=errs+1; end
    addr=6'd56; #1; if (wcol!==64'h5004610122809206) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",56,wcol,64'h5004610122809206); errs=errs+1; end
    addr=6'd57; #1; if (wcol!==64'h465455a55a809226) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",57,wcol,64'h465455a55a809226); errs=errs+1; end
    addr=6'd58; #1; if (wcol!==64'h561154015a801082) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",58,wcol,64'h561154015a801082); errs=errs+1; end
    addr=6'd59; #1; if (wcol!==64'h4291540552a10086) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",59,wcol,64'h4291540552a10086); errs=errs+1; end
    addr=6'd60; #1; if (wcol!==64'h4a90548552216586) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",60,wcol,64'h4a90548552216586); errs=errs+1; end
    addr=6'd61; #1; if (wcol!==64'h29a54a55a216484) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",61,wcol,64'h29a54a55a216484); errs=errs+1; end
    addr=6'd62; #1; if (wcol!==64'h864a5424121460a4) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",62,wcol,64'h864a5424121460a4); errs=errs+1; end
    addr=6'd63; #1; if (wcol!==64'h2508114414012822) begin $display("MISMATCH %s addr=%0d got %h exp %h","w1_h32_case",63,wcol,64'h2508114414012822); errs=errs+1; end
    if (errs==0) $display("PASS w1_h32_case (64/64 addresses match npz)");
    else $display("FAIL w1_h32_case errs=%0d",errs);
    $finish;
  end
endmodule
