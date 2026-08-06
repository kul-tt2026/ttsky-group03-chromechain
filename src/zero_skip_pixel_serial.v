module zero_skip_pixel_serial(input wire clk,
                              input wire rst_n,
                              input wire scan,
                              input wire [15:0] window,
                              input wire [3:0] window_base,
                              input wire next,
                              output wire [3:0] pixel,
                              output wire [5:0] index,
                              output wire valid,
                              output wire buffer_free);

    wire [3:0] p0 = window[3:0];
    wire [3:0] p1 = window[7:4];
    wire [3:0] p2 = window[11:8];
    wire [3:0] p3 = window[15:12];
    wire nz0 = (p0 != 4'd0);
    wire nz1 = (p1 != 4'd0);
    wire nz2 = (p2 != 4'd0);
    wire nz3 = (p3 != 4'd0);

    reg [3:0] s_pix [0:3];
    reg [1:0] s_pos [0:3];
    reg [2:0] s_count;

    always @(*) begin
        s_count = 0;
        s_pix[0] = 0; s_pix[1] = 0; s_pix[2] = 0; s_pix[3] = 0;
        s_pos[0] = 0; s_pos[1] = 0; s_pos[2] = 0; s_pos[3] = 0;

        if(nz0) begin s_pix[s_count[1:0]] = p0;
                      s_pos[s_count[1:0]] = 2'd0;
                      s_count = s_count + 1;
        end
        
        if(nz1) begin s_pix[s_count[1:0]] = p1;
                      s_pos[s_count[1:0]] = 2'd1;
                      s_count = s_count + 1;
        end

        if(nz2) begin s_pix[s_count[1:0]] = p2;
                      s_pos[s_count[1:0]] = 2'd2;
                      s_count = s_count + 1;
        end

        if(nz3) begin s_pix[s_count[1:0]] = p3;
                      s_pos[s_count[1:0]] = 2'd3;
                      s_count = s_count + 1;
        end
    end

    reg [3:0] pix_r [0:1][0:3];
    reg [1:0] pos_r [0:1][0:3];
    reg [3:0] base_r [0:1];
    reg [2:0] count_r [0:1];
    reg occupied[0:1];
    reg active;
    reg [2:0] read_pointer;

    wire other = ~active;
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            read_pointer <= 3'd0;
            occupied[0] <= 1'b0;
            occupied[1] <= 1'b0;
        end else begin

            if (scan && !occupied[other]) begin
                for (i=0; i<4; i=i+1) begin
                    pix_r[other][i] <= s_pix[i];
                    pos_r[other][i] <= s_pos[i];
                end
                count_r[other] <= s_count;
                base_r[other] <= window_base;
                occupied[other] <= 1'b1;
            end

            if (next && valid) begin
                            if(read_pointer + 1'b1 >= count_r[active]) begin
                                occupied[active] <= 1'b0;
                                read_pointer <= 3'd0;
                                if (occupied[other]) active <= other;
                            end else begin
                                read_pointer <= read_pointer + 1'b1;
                            end
                        end else if (!occupied[active] && occupied[other]) begin
                            active <= other;
                        end
                    end
                end
assign pixel = pix_r[active][read_pointer[1:0]];
assign index = {base_r[active], pos_r[active][read_pointer[1:0]]};
assign valid = occupied[active] && (read_pointer < count_r[active]);
assign buffer_free = !occupied[other] && !scan;
endmodule