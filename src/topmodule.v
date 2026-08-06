module nn_top(input  wire clk,
              input  wire rst_n,
              input  wire start,
              input  wire [15:0] window_in,
              input  wire window_valid,   
              output wire window_req,    
              output wire [3:0] result,
              output wire result_valid
);


    wire        scan_req, next_req;
    wire        l1_en, l1_clear;
    wire        l2_en, l2_clear;
    wire        am_valid, am_last, quantize_now;
    wire [4:0]  neuron_idx, window_idx;
    wire [3:0]  class_idx;
    wire        ctrl_result_valid;
    wire        window_ready;
    wire [4:0] scan_base_full = window_idx - 5'd1;   


    reg  [15:0] window_reg;
    reg         window_ready_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            window_reg     <= 16'd0;
            window_ready_r <= 1'b0;
        end else begin
            if (scan_req && window_ready_r) begin
                window_ready_r <= 1'b0;
            end

            else if (window_valid && !window_ready_r) begin
                window_reg     <= window_in;
                window_ready_r <= 1'b1;
            end
        end
    end

    assign window_ready = window_ready_r;
    assign window_req   = !window_ready_r;  

    wire [3:0] zs_pixel;
    wire [5:0] zs_index;
    wire       zs_valid;
    wire       zs_buffer_free;

    zero_skip_pixel_serial u_zeroskip(
        .clk(clk), .rst_n(rst_n),
        .scan(scan_req && window_ready),  
        .window(window_reg),
        .window_base(scan_base_full[3:0]),
        .next(next_req),
        .pixel(zs_pixel),
        .index(zs_index),
        .valid(zs_valid),
        .buffer_free(zs_buffer_free)
    );

    wire signed [8:0] l1_acc    [0:31];

    wire [63:0] w1_all;
    gewicht_rom_L1 u_rom1(
        .pixel_index(zs_index),
        .w1_all(w1_all)
    );

    genvar n;
    generate
        for (n = 0; n < 32; n = n + 1) begin : L1_LANES
            ternary_mac_L1 u_mac1(
                .clk(clk), .rst_n(rst_n),
                .en(l1_en), .clear(l1_clear),
                .pixel(zs_pixel),
                .weight(w1_all[2*n +: 2]),
                .accumulator(l1_acc[n])
            );
        end
    endgenerate

    wire signed [5:0] q_bias;
    wire [1:0]        q_k;
    rekwantisatie_rom u_qrom(
        .neuron_index(neuron_idx),
        .bias(q_bias), .k(q_k)
    );

    wire [3:0] h_value;
    shift_kwantisatie u_shiftq(
        .accumulator(l1_acc[neuron_idx]),
        .bias(q_bias), .k(q_k),
        .h(h_value)
    );

    wire signed [6:0] l2_bias[0:9];
    wire signed [9:0] l2_acc [0:9];

    // ONE shared decoder for all 10 class lanes (was: 10 separate
    // gewicht_rom_L2 instances, each re-decoding the same neuron_index).
    // w2_all[2c+1:2c] is class c's weight -- identical values, one lookup
    // instead of 10. bias_rom_L2 is untouched -- still needs its own content.
    wire [19:0] w2_all;
    gewicht_rom_L2_wide u_wrom2(
        .neuron_index(neuron_idx),
        .w2_all(w2_all)
    );

    genvar c;
    generate
        for (c = 0; c < 10; c = c + 1) begin : L2_LANES
            bias_rom_L2 u_brom2(
                .class_index(c[3:0]),
                .bias(l2_bias[c])
            );

            ternary_mac_L2 u_mac2(
                .clk(clk), .rst_n(rst_n),
                .en(l2_en), .clear(l2_clear),
                .neuron(h_value),
                .bias(l2_bias[c]), .weight(w2_all[2*c +: 2]),
                .accumulator(l2_acc[c])
            );
        end
    endgenerate

    wire [3:0] am_best;
    wire [8:0] am_best_value;
    wire       am_done;

    argmax u_argmax(
        .clk(clk), .rst_n(rst_n),
        .valid(am_valid),
        .current(class_idx),
        .class_value(l2_acc[class_idx][8:0]),
        .last(am_last),
        .best(am_best),
        .best_value(am_best_value),
        .done(am_done)
    );

    nn_controller u_ctrl(
        .clk(clk), .rst_n(rst_n), .start(start),
        .zs_valid(zs_valid),
        .zs_buffer_free(zs_buffer_free),
        .window_ready(window_ready),
        .am_done(am_done),
        .scan_req(scan_req), .next_req(next_req),
        .l1_en(l1_en), .l1_clear(l1_clear),
        .window_idx(window_idx),
        .l2_en(l2_en), .l2_clear(l2_clear),
        .neuron_idx(neuron_idx),
        .quantize_now(quantize_now),
        .am_valid(am_valid), .am_last(am_last),
        .class_idx(class_idx),
        .result_valid(ctrl_result_valid)
    );

    assign result       = am_best;
    assign result_valid = ctrl_result_valid;

endmodule