`timescale 1ns/1ns

module tb_pe;
    parameter DATA_WIDTH                = 8;
    parameter BIAS_DATA_WIDTH           = 32;
    parameter BRAM_DATA_WIDTH           = 128;

    parameter KY_MAX                    = 10;
    parameter KX_MAX                    = 36;
    parameter W_MAX                     = 96;
    parameter C_MAX                     = 256;

    parameter MAX_OUTPUTS_PARALEL       = 8;
    parameter MAX_OUTPUTS_TOTAL         = 256;
    parameter BYTES_PER_DATA            = 8;
    parameter MAX_CHANNELS              = BRAM_DATA_WIDTH/DATA_WIDTH;
    parameter MAX_WEIGHTS               = BRAM_DATA_WIDTH/DATA_WIDTH;
    parameter MAX_BIAS_PARALEL          = 4;

    parameter MAX_MEM_CHANNEL_DISTANCE  = C_MAX*2;

    parameter DELAY_TIME                = 2;

    parameter PRECISION_N = 32;
    parameter ROUND = 1 <<< (PRECISION_N - 1);

    parameter MEM_DEPTH                 = 384;
    parameter WEIGHT_MEM_DEPTH          = 1024;
    parameter BIAS_MEM_DEPTH            = 32;

    //SIMULATION ONLY PARAMETERS
    parameter BIAS_PER_LINE             = 2;

    logic                                clk;
    logic                                rst_n;

    logic [$clog2(W_MAX)-1:0]            cfg_w;
    logic [$clog2(C_MAX)-1:0]            cfg_c;
    logic [$clog2(C_MAX)-1:0]            cfg_mem_shifter;
    logic [$clog2(MAX_MEM_CHANNEL_DISTANCE)-1:0]             cfg_mem_channel_distance_1;
    logic [$clog2(MAX_MEM_CHANNEL_DISTANCE)-1:0]             cfg_mem_channel_distance_2; 
    logic [$clog2(KX_MAX)-1:0]           cfg_kx;
    logic [$clog2(KY_MAX)-1:0]           cfg_ky;

    logic                                 cfg_op_type;   //0 for Convolution 1 for Dense Layer                                
    logic                                 cfg_conv_D;    //0 for 2D convolution 1 for 1D convolution
    logic                                 cfg_depth_conv; //Convetional Convolution 0, Depthwise Convolution 1
    logic [$clog2(WEIGHT_MEM_DEPTH)-1:0]  cfg_w_wg;
    logic [$clog2(WEIGHT_MEM_DEPTH)-1:0]  cfg_w_wg_max_out;
    logic [$clog2(BIAS_MEM_DEPTH)-1:0]    cfg_w_bias_max_out;
    logic [$clog2(MAX_OUTPUTS_TOTAL)-1:0] cfg_max_out;
    logic signed [PRECISION_N-1:0]        m_int;

    logic                                in_valid;
    logic                                wr_wgt_valid;
    logic                                wr_bias_valid;
    logic [BRAM_DATA_WIDTH-1:0]      in_pixel;

    logic                                out_valid;
    logic [DATA_WIDTH-1:0]               out_pixel [MAX_OUTPUTS_PARALEL];

    int cycle;
    
    //Multiplication Operations
    int macc;

    //FILES
    integer weight_file;
    integer bias_file;
    integer input_file;
    integer r, r2;

    logic DEBUG_CMPT;
    logic DEBUG_MEM;
    logic DEBUG_WGT;

    //---------------------------------
    // Clock
    //---------------------------------
    initial clk = 0;
    always #1 clk = ~clk;

    

    //---------------------------------
    // DUT
    //---------------------------------
    pe #(
        .DATA_WIDTH(DATA_WIDTH),
        .BRAM_DATA_WIDTH(BRAM_DATA_WIDTH),

        .W_MAX(W_MAX),
        .C_MAX(C_MAX),

        .KX_MAX(KX_MAX),
        .KY_MAX(KY_MAX),

        .MAX_OUTPUTS_PARALEL(MAX_OUTPUTS_PARALEL),
        .MAX_OUTPUTS_TOTAL(MAX_OUTPUTS_TOTAL),
        .BYTES_PER_DATA(BYTES_PER_DATA),
        .MAX_CHANNELS(MAX_CHANNELS),
        .MAX_WEIGHTS(MAX_WEIGHTS),

        .MAX_MEM_CHANNEL_DISTANCE(MAX_MEM_CHANNEL_DISTANCE),

        .PRECISION_N(PRECISION_N),
        .ROUND(ROUND),

        .MEM_DEPTH(MEM_DEPTH),
        .WEIGHT_MEM_DEPTH(WEIGHT_MEM_DEPTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .cfg_w(cfg_w),
        .cfg_c(cfg_c),
        .cfg_mem_shifter(cfg_mem_shifter),
        .cfg_mem_channel_distance_1(cfg_mem_channel_distance_1),
        .cfg_mem_channel_distance_2(cfg_mem_channel_distance_2),
        .cfg_kx(cfg_kx),
        .cfg_ky(cfg_ky),

        .cfg_op_type(cfg_op_type),
        .cfg_conv_D(cfg_conv_D),
        .cfg_depth_conv(cfg_depth_conv),
        .cfg_w_wg(cfg_w_wg),
        .cfg_w_wg_max_out(cfg_w_wg_max_out),
        .cfg_w_bias_max_out(cfg_w_bias_max_out),
        .cfg_max_out(cfg_max_out),
        .m_int(m_int),

        .in_valid(in_valid),
        .wr_wgt_valid(wr_wgt_valid),
        .wr_bias_valid(wr_bias_valid),
        .in_pixel(in_pixel),

        .out_valid(out_valid),
        .out_pixel(out_pixel)
    );

    //============================================================
    // TASKS
    //============================================================  
    task print_input;
        begin
            $write("IN_PIXEL: ");
            for (int c = 0; c < MAX_CHANNELS; c++) begin 
                $write("%0d ", $signed(in_pixel[c*DATA_WIDTH +: DATA_WIDTH]));
            end
            $write("\n");
        end
    endtask

    task print_line_mem;
        begin
            $display("---- LINE MEM ----");
            for (int ky = 0; ky < cfg_ky; ky++) begin
                for (int x = 0; x < cfg_w; x++) begin
                    logic [BRAM_DATA_WIDTH-1:0] val;
                    $write("L%0d X%0d:", ky, x);
                        case(ky)
                            0: val = dut.mem_0[x];
                            1: val = dut.mem_5[x];
                        endcase
                        for (int c = 0; c < MAX_CHANNELS; c++) begin 
                            $write("%0d ", $signed(val[c*DATA_WIDTH +: DATA_WIDTH]));
                        end
                    $write(")  ");
                end
                $write("\n");
            end
        end
    endtask

    task print_weight_mem;
        begin
        $display("---- WEIGHT MEM ----");
        for (int y = 0; y < 8; y++) begin//FIXADO EM 8 POIS É O TAMANHO MÁXIMO DE MEMÓRIAS POR PADRÃO
            $write("WGT %0d:",y);
            for (int x = 0; x < cfg_w_wg_max_out; x++) begin
                logic [BRAM_DATA_WIDTH-1:0] val;
                    case (y)
                        0: val = dut.wg_mem_0[x];
                        1: val = dut.wg_mem_1[x];
                        2: val = dut.wg_mem_2[x];
                        3: val = dut.wg_mem_3[x];
                        4: val = dut.wg_mem_4[x];
                        5: val = dut.wg_mem_5[x];
                        6: val = dut.wg_mem_6[x];
                        7: val = dut.wg_mem_7[x];
                    endcase 
                    for (int c = 0; c < MAX_WEIGHTS; c++) begin 
                        $write("%0d ", $signed(val[c*DATA_WIDTH +: DATA_WIDTH]));
                    end
                end
                $write("\n");
            end
        end
    endtask

    task print_mem_read;
        logic [BRAM_DATA_WIDTH-1:0] mem_array [0:10];
        begin
            if (dut.start_cmpt_d_d) begin
                mem_array[0] = dut.mem_read_1_d;
                mem_array[1] = dut.mem_read_2_d;
                mem_array[2] = dut.mem_read_3_d;
                mem_array[3] = dut.mem_read_4_d;
                mem_array[4] = dut.mem_read_5_d;
                mem_array[5] = dut.mem_read_6_d;
                mem_array[6] = dut.mem_read_7_d;
                mem_array[7] = dut.mem_read_8_d;
                if (cfg_ky==2) begin
                    $display("---- MEM READ Linear Layer (Temporary) ----");
                    $write("[");
                    for (int c = 0; c < MAX_CHANNELS; c++) begin
                        $write("%0d", $signed(mem_array[dut.mem_idx][c*DATA_WIDTH +: DATA_WIDTH]));
                        if (c != MAX_CHANNELS-1)
                            $write(",");
                    end
                    $write("]\n");
                end
            end
        end
    endtask

    task print_weight_read;
        logic [BRAM_DATA_WIDTH-1:0] wg_array [0:8];
        begin
            if (dut.start_cmpt_d_d) begin
                wg_array[0] = dut.wg_read_1_d;
                wg_array[1] = dut.wg_read_2_d;
                wg_array[2] = dut.wg_read_3_d;
                wg_array[3] = dut.wg_read_4_d;
                wg_array[4] = dut.wg_read_5_d;
                wg_array[5] = dut.wg_read_6_d;
                wg_array[6] = dut.wg_read_7_d;
                wg_array[7] = dut.wg_read_8_d;
                $display("---- WEIGHT READ ----");
                for (int o = 0; o < MAX_OUTPUTS_PARALEL+1; o++) begin
                    $write("WGT%0d: [", o);
                    for (int k = 0; k < MAX_WEIGHTS; k++) begin
                        $write("%0d", $signed(wg_array[o][k*DATA_WIDTH +: DATA_WIDTH]));
                        if (k != MAX_WEIGHTS-1)
                            $write(",");
                    end
                    $write("]\n");
                end
            end
        end
    endtask

    task print_check_read_mems;
        begin
            $write("mem_read_1 %0d\n", dut.mem_read_1);
            $write("mem_read_1_d %0d \n", dut.mem_read_1_d);
            $write("p[0][0] %0d\n", dut.p[0][0]);
            $write("wg_read_1 %0d\n", dut.wg_read_1);
            $write("wg_read_1_d %0d\n", dut.wg_read_1_d);
            $write("w[0][0] %0d\n", dut.w[0][0]);
        end 
    endtask 

    task print_mac;
        begin
            if (dut.start_cmpt_d_d) begin
                $write("MAC: ");
                for (int o=0;o<MAX_OUTPUTS_PARALEL;o++) begin
                    $write("%0d ", $signed(dut.mac[o]));
                end
                $write("\n");
            end
        end
    endtask

    task print_acc;
        begin
            if (dut.start_cmpt_d_d) begin
                $write("ACC: ");
                for (int o=0;o<MAX_OUTPUTS_PARALEL;o++) begin
                    $write("%0d ", $signed(dut.acc[o]));
                end
                $write("\n");
            end
        end
    endtask

    task print_sub_mult;
        begin
            if (dut.start_cmpt_d_d) begin
                $write("SUB MULT: \n");
                for (int o=0;o<MAX_OUTPUTS_PARALEL;o++) begin
                    $write("MACC FOR %0d: \n", o);
                    macc=0;
                    for (int i=0; i<9; i++) begin
                        macc += $signed(dut.w[o][i]) * $signed(dut.p[i][dut.mem_idx]);
                        $write("w[%0d][%0d]*p[%0d][%0d] | %0d = %0d * %0d \n", o, i, i, dut.mem_idx, $signed(dut.w[o][i]) * $signed(dut.p[i][dut.mem_idx]), $signed(dut.w[o][i]), $signed(dut.p[i][dut.mem_idx]));
                    end
                    $write("%0d MACC : %0d\n", o, macc);
                end
            end
        end
    endtask

    task print_output;
        begin
            if (out_valid) begin
                $write("OUT_PIXEL: ");
                for (int o=0;o<MAX_OUTPUTS_PARALEL;o++) begin
                    $write("%0d ", $signed(out_pixel[o]));
                end
                $write("\n");
            end
        end
    endtask

    task print_status;
        begin
            if (DEBUG_MEM)
                $display("STATUS: CYCLE=%0d in_valid=%0d col_cnt=%0d line_cnt=%0d wr_line=%0d", 
                    cycle,
                    in_valid,
                    dut.col_cnt,
                    dut.line_cnt,
                    dut.wr_line,
                );
            if((wr_bias_valid || wr_wgt_valid) && DEBUG_WGT) // only show when writing weights and bias
                $display("STATUS WGT READING: col_cnt_wg=%0d wr_line_wg=%0d col_cnt_bias=%0d wr_line_bias=%0d",
                    dut.col_cnt_wg,
                    dut.wr_line_wg,
                    dut.col_cnt_bias,
                    dut.wr_line_bias
                );
            if (DEBUG_CMPT) begin // if not writing weights and bias
                $display("STATUS COMPUTING: CYCLE=%0d out_valid=%0d read_req=%0d read_req_d=%0d start_cmpt=%0d start_cmpt_d=%0d start_cmpt_d_d=%0d cnt_cmpt=%0d cnt_outs=%0d mem_idx=%0d", 
                    cycle,
                    out_valid,
                    dut.read_req,
                    dut.read_req_d,
                    dut.start_cmpt,
                    dut.start_cmpt_d,
                    dut.start_cmpt_d_d,
                    dut.cnt_cmpt,
                    dut.cnt_outs,
                    dut.mem_idx
                );
                $display("STATUS MEM READING: col_cnt_rlm=%0d col_cnt_rlm_bckup=%0d cfg_mem_shifter=%0d",
                    dut.col_cnt_rlm,
                    dut.col_cnt_rlm_bckup,
                    dut.cfg_mem_shifter
                );
                $display("STATUS WGT READING: col_wgt_cmpt=%0d col_bias_cmpt=%0d",
                    dut.col_wgt_cmpt,
                    dut.col_bias_cmpt,
                );
            end
        end
    endtask

    //task para carregar pesos
    task load_weights_and_bias_from_file;
        int scale_val;
        int weights [MAX_WEIGHTS];
        int bias    [MAX_CHANNELS];
        begin
            weight_file = $fopen("weights_int8.txt", "r");
            if (weight_file == 0) begin
                $display("ERROR: Could not open weights_int8.txt");
                $finish;
            end
            $display("\n=========== LOADING WEIGHTS ===========");
            wr_wgt_valid=0;
            wr_bias_valid=0;
            @(posedge clk);
            while (!$feof(weight_file)) begin
                // ===============================
                // LEITURA DOS PESOS
                // ===============================
                for (int w = 0; w < cfg_w_wg_max_out; w++) begin
                    @(posedge clk);
                    wr_wgt_valid = 1;
                    for (int s = 0; s < MAX_WEIGHTS; s++) begin
                        r = $fscanf(weight_file, "%d", weights[s]);
                    end
                    in_pixel = '0;
                    for (int s = 0; s < MAX_WEIGHTS; s++) begin
                        in_pixel[s*DATA_WIDTH +: DATA_WIDTH] = weights[s];
                    end
                    @(negedge clk);
                    if (DEBUG_WGT) begin
                        print_status();
                        print_input();
                        print_weight_mem();
                        $display("=====================================");
                    end
                end
            end
            wr_wgt_valid = 0;
            wr_bias_valid = 0;
            $fclose(weight_file);
            $display("=========== FINISHED LOADING WEIGHTS ===========\n");
        end
    endtask

    //task para carregar inputs
    task load_inputs_from_file;
        int inputs [MAX_CHANNELS];
        begin
            input_file = $fopen("input.txt", "r");
            if (input_file == 0) begin
                $display("ERROR: Could not open input.txt");
                $finish;
            end
            $display("\n=========== LOADING INPUTS ===========");
            @(posedge clk);
            while (!$feof(input_file)) begin
                @(posedge clk);
                if (!dut.start_cmpt)
                    in_valid = 1;
                else
                    in_valid = 0;
                for (int s = 0; s < MAX_CHANNELS; s++)
                    r2 = $fscanf(input_file, "%d", inputs[s]);
                in_pixel = '0;
                for (int s = 0; s < MAX_CHANNELS; s++)
                    in_pixel[s*DATA_WIDTH +: DATA_WIDTH] = inputs[s];
                @(negedge clk);
                print_status();
                if (DEBUG_MEM) begin
                    print_input();
                    print_line_mem();
                end
                if (DEBUG_CMPT) begin
                    print_mem_read();
                    print_weight_read();
                    print_sub_mult();
                    print_mac();
                    print_acc();
                end
                print_output();
            end
            $fclose(input_file);
            $display("=========== FINISHED LOADING INPUTS ===========\n");
        end
    endtask

    always @(posedge clk)
        cycle++;

    //============================================================
    // Stimulus
    //============================================================
    initial begin

        rst_n = 0;
        in_valid = 0;
        wr_wgt_valid = 0;
        wr_bias_valid = 0;
        in_pixel = 0;

        //OPÇÕES DE DEBUG SE TODOS EM 0 SÓ MOSTRA OS OUTPUS
        DEBUG_CMPT=0; //SE 1 MOSTRA CADA OPERAÇÃO ARITIMÉTICA DE CADA CICLO, INCLUINDO ACUMULADORES, E MAC
        DEBUG_MEM=0;  //SE 1 MOSTRA O QUE ESTÁ SENDO ESCRITO NA MEMÓRIA DE INPUTS
        DEBUG_WGT=0;  //SE 1 MOSTRA O O QUE ESTÁ SENDO ESCRITO NA MEMÓRIA DE PESOS, APENAS NO PASO INICIAL ONDE OS PESOS SÃO GRAVADOS NA MEMÓRIA

        cfg_c  = 64;
        cfg_ky = 2;
        cfg_kx = 1;
        cfg_w  = 4;
        cfg_mem_channel_distance_1= 1;
        cfg_mem_channel_distance_2= 2;
        cfg_op_type = 1;
        cfg_conv_D = 0;
        cfg_depth_conv = 0;
        cfg_w_wg = 4;
        cfg_max_out = 8;
        cfg_w_wg_max_out = 4;
        cfg_w_bias_max_out = 1;
        cfg_mem_shifter = 1;
        m_int = 4216863;

        #5 rst_n = 1;

        //--------------------------------------------------------
        // WRITE MEM
        //--------------------------------------------------------
        load_weights_and_bias_from_file();

        wr_wgt_valid = 0;
        wr_bias_valid = 0;
        in_valid = 0;
        cycle = 0;
        //--------------------------------------------------------
        // Feed pixels
        //--------------------------------------------------------
        load_inputs_from_file();
        load_inputs_from_file();
        load_inputs_from_file();
        load_inputs_from_file();
        load_inputs_from_file();
        load_inputs_from_file();

        $finish;
    end

endmodule