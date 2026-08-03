module nn_controller(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire         zs_valid,
    input  wire         zs_buffer_free,
    input  wire         window_ready,
    input  wire         am_done,
    output reg          scan_req,
    output reg          next_req,
    output reg          l1_en,      
    output reg          l1_clear,    
    output reg  [4:0]   window_idx,  
    output reg          l2_en,       
    output reg          l2_clear,    
    output reg  [4:0]   neuron_idx,  
    output reg          quantize_now,
    output reg          am_valid,
    output reg          am_last,
    output reg  [3:0]   class_idx,   
    output reg           result_valid);

    wire all_windows_sent = (window_idx >= 5'd16);

    localparam S_IDLE        = 3'd0;
    localparam S_L1_INIT     = 3'd1;
    localparam S_L1_SCAN     = 3'd2;
    localparam S_QUANT_INIT  = 3'd3;
    localparam S_QUANT_LOOP  = 3'd4;
    localparam S_ARGMAX_INIT = 3'd5;
    localparam S_ARGMAX_FEED = 3'd6;
    localparam S_DONE        = 3'd7;

    reg [2:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            window_idx   <= 5'd0;
            neuron_idx   <= 5'd0;
            class_idx    <= 4'd0;
            l1_clear     <= 1'b0;
            l1_en        <= 1'b0;
            l2_clear     <= 1'b0;
            l2_en        <= 1'b0;
            scan_req     <= 1'b0;
            next_req     <= 1'b0;
            am_valid     <= 1'b0;
            am_last      <= 1'b0;
            quantize_now <= 1'b0;
            result_valid <= 1'b0;
        end else begin
            // standaardwaarden elke cyclus (pulse-signalen)
            l1_clear     <= 1'b0;
            l1_en        <= 1'b0;
            l2_clear     <= 1'b0;
            l2_en        <= 1'b0;
            scan_req     <= 1'b0;
            next_req     <= 1'b0;
            am_valid     <= 1'b0;
            am_last      <= 1'b0;
            quantize_now <= 1'b0;
            result_valid <= 1'b0;

            case (state)

                S_IDLE: begin
                    if (start) begin
                        state <= S_L1_INIT;
                    end
                end

                S_L1_INIT: begin
                    l1_clear   <= 1'b1;   
                    window_idx <= 5'd0;
                    state      <= S_L1_SCAN;
                end

                S_L1_SCAN: begin
                    if (!all_windows_sent && zs_buffer_free && window_ready) begin
                        scan_req   <= 1'b1;
                        window_idx <= window_idx + 5'd1;
                    end

                    if (zs_valid) begin
                        l1_en    <= 1'b1;   // alle 32 MACs accumuleren dezelfde pixel
                        next_req <= 1'b1;
                    end

                    if (all_windows_sent && zs_buffer_free && !zs_valid) begin
                        state <= S_QUANT_INIT;
                    end
                end

                S_QUANT_INIT: begin
                    l2_clear   <= 1'b1;  
                    neuron_idx <= 5'd0;
                    state      <= S_QUANT_LOOP;
                end

                S_QUANT_LOOP: begin
                    quantize_now <= 1'b1;   
                    l2_en        <= 1'b1;   

                    if (neuron_idx == 5'd31) begin
                        state <= S_ARGMAX_INIT;
                    end else begin
                        neuron_idx <= neuron_idx + 5'd1;
                    end
                end

                S_ARGMAX_INIT: begin
                    class_idx <= 4'd0;
                    state     <= S_ARGMAX_FEED;
                end

                S_ARGMAX_FEED: begin
                    am_valid <= 1'b1;
                    am_last  <= (class_idx == 4'd9);

                    if (class_idx == 4'd9) begin
                        state <= S_DONE;
                    end else begin
                        class_idx <= class_idx + 4'd1;
                    end
                end

                S_DONE: begin
                    if (am_done) begin
                        result_valid <= 1'b1;
                        state        <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule