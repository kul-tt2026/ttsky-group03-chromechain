module argmax(input wire clk,
              input wire rst_n,
              input wire valid,
              input wire [3:0] current,
              input wire signed [8:0] class_value,
              input wire last,
              output reg [3:0] best,
              output reg [8:0] best_value,
              output reg done
              );
            
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            best <= 4'd0;
            best_value <= 9'sd0;
            done <= 1'b0;
        end else if (valid) begin
            done <=1'b0;
            if (current == 4'd0 || class_value > best_value) begin
                best_value <= class_value;
                best <= current;
            end
            if (last) done <= 1'b1;
        end

    end
endmodule