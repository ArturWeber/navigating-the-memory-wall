`timescale 1ns/1ns

(* use_dsp = "yes" *)
module pe #
(
    parameter DATA_WIDTH                = 8,
    parameter BIAS_DATA_WIDTH           = 32,
    parameter BRAM_DATA_WIDTH           = 128,

    parameter KY_MAX                    = 10,
    parameter KX_MAX                    = 36,
    parameter W_MAX                     = 96,
    parameter C_MAX                     = 256,

    parameter MAX_OUTPUTS_PARALEL       = 8,
    parameter MAX_OUTPUTS_TOTAL         = 256,
    parameter BYTES_PER_DATA            = 8,
    parameter MAX_CHANNELS              = BRAM_DATA_WIDTH/DATA_WIDTH,
    parameter MAX_WEIGHTS               = BRAM_DATA_WIDTH/DATA_WIDTH,
    parameter MAX_BIAS_PARALEL          = 4,

    parameter MAX_MEM_CHANNEL_DISTANCE  = C_MAX*2,

    parameter DELAY_TIME                = 2,

    parameter PRECISION_N = 32,
    parameter ROUND = 1 <<< (PRECISION_N - 1),
    parameter MAX_VAL = (1 <<< (DATA_WIDTH-1)) - 1,              //maximum value to clip the accumulator output when scalling values
    parameter MIN_VAL = -(1 <<< (DATA_WIDTH-1)),  

    parameter MEM_DEPTH                 = 384,     //W_MAX*C_USUAL*K_USUAL*K_USUAL
    parameter WEIGHT_MEM_DEPTH          = 1024,     //
    parameter BIAS_MEM_DEPTH            = 32       //
)
(
    input  logic                                 clk,
    input  logic                                 rst_n,

    //SWU
    input  logic [$clog2(W_MAX)-1:0]             cfg_w,
    input  logic [$clog2(C_MAX)-1:0]             cfg_c,
    input  logic [$clog2(C_MAX)-1:0]             cfg_mem_shifter,
    input  logic [$clog2(MAX_MEM_CHANNEL_DISTANCE)-1:0]             cfg_mem_channel_distance_1,
    input  logic [$clog2(MAX_MEM_CHANNEL_DISTANCE)-1:0]             cfg_mem_channel_distance_2,           
    input  logic [$clog2(KX_MAX)-1:0]            cfg_kx, //will accept any value up to KX_MAX
    input  logic [$clog2(KY_MAX)-1:0]            cfg_ky, //will accept 1, 3, 4
    

    //PE
    input  logic                                 cfg_op_type,   //0 for Convolution 1 for Dense Layer                                
    input  logic                                 cfg_conv_D,    //0 for 2D convolution 1 for 1D convolution
    input  logic                                 cfg_depth_conv, //Convetional Convolution 0, Depthwise Convolution 1
    input  logic [$clog2(WEIGHT_MEM_DEPTH)-1:0]  cfg_w_wg, //number of multiplications. It does 72 multiplications each clock for 8 channels, so 9 multiplications per channel. This parameter set the number of multiplications needed for each 8 channels, so if it is 0 it does one multiplication set, if 1 do 2, 2 do 3 and so on. Force it to be at least 3 because of delay
    input  logic [$clog2(WEIGHT_MEM_DEPTH)-1:0]  cfg_w_wg_max_out,
    input  logic [$clog2(BIAS_MEM_DEPTH)-1:0]    cfg_w_bias_max_out,
    input  logic [$clog2(MAX_OUTPUTS_TOTAL)-1:0] cfg_max_out, // number of output channels. Ideally multiple of 8. If set to 8 does once, if 16 does twice, if 24 does three times and so on
    input  logic signed [PRECISION_N-1:0]        m_int,

    input  logic                                 in_valid,
    input  logic                                 wr_wgt_valid,
    input  logic                                 wr_bias_valid,
    input  logic [BRAM_DATA_WIDTH-1:0]           in_pixel,

    output logic                                 out_valid,
    output logic [DATA_WIDTH-1:0]                out_pixel [MAX_OUTPUTS_PARALEL]
);

(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] mem_0 [0:MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] mem_1 [0:MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] mem_2 [0:MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] mem_3 [0:MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] mem_4 [0:MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] mem_5 [0:MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] mem_6 [0:MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] mem_7 [0:MEM_DEPTH-1];


(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] wg_mem_0 [0:WEIGHT_MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] wg_mem_1 [0:WEIGHT_MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] wg_mem_2 [0:WEIGHT_MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] wg_mem_3 [0:WEIGHT_MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] wg_mem_4 [0:WEIGHT_MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] wg_mem_5 [0:WEIGHT_MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] wg_mem_6 [0:WEIGHT_MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] wg_mem_7 [0:WEIGHT_MEM_DEPTH-1];

(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] bias_mem_0 [0:BIAS_MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] bias_mem_1 [0:BIAS_MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] bias_mem_2 [0:BIAS_MEM_DEPTH-1];
(* ram_style="block" *)
logic [BRAM_DATA_WIDTH-1:0] bias_mem_3 [0:BIAS_MEM_DEPTH-1];

logic [BRAM_DATA_WIDTH-1:0]        mem_read_1;
logic [BRAM_DATA_WIDTH-1:0]        mem_read_1_d;
logic [BRAM_DATA_WIDTH-1:0]        mem_read_2;
logic [BRAM_DATA_WIDTH-1:0]        mem_read_2_d;
logic [BRAM_DATA_WIDTH-1:0]        mem_read_3;
logic [BRAM_DATA_WIDTH-1:0]        mem_read_3_d;
logic [BRAM_DATA_WIDTH-1:0]        mem_read_4;
logic [BRAM_DATA_WIDTH-1:0]        mem_read_4_d;
logic [BRAM_DATA_WIDTH-1:0]        mem_read_5;
logic [BRAM_DATA_WIDTH-1:0]        mem_read_5_d;
logic [BRAM_DATA_WIDTH-1:0]        mem_read_6;
logic [BRAM_DATA_WIDTH-1:0]        mem_read_6_d;
logic [BRAM_DATA_WIDTH-1:0]        mem_read_7;
logic [BRAM_DATA_WIDTH-1:0]        mem_read_7_d;
logic [BRAM_DATA_WIDTH-1:0]        mem_read_8;
logic [BRAM_DATA_WIDTH-1:0]        mem_read_8_d;

logic [BRAM_DATA_WIDTH-1:0]        wg_read_1;
logic [BRAM_DATA_WIDTH-1:0]        wg_read_1_d;
logic [BRAM_DATA_WIDTH-1:0]        wg_read_2;
logic [BRAM_DATA_WIDTH-1:0]        wg_read_2_d;
logic [BRAM_DATA_WIDTH-1:0]        wg_read_3;
logic [BRAM_DATA_WIDTH-1:0]        wg_read_3_d;
logic [BRAM_DATA_WIDTH-1:0]        wg_read_4;
logic [BRAM_DATA_WIDTH-1:0]        wg_read_4_d;
logic [BRAM_DATA_WIDTH-1:0]        wg_read_5;
logic [BRAM_DATA_WIDTH-1:0]        wg_read_5_d;
logic [BRAM_DATA_WIDTH-1:0]        wg_read_6;
logic [BRAM_DATA_WIDTH-1:0]        wg_read_6_d;
logic [BRAM_DATA_WIDTH-1:0]        wg_read_7;
logic [BRAM_DATA_WIDTH-1:0]        wg_read_7_d;
logic [BRAM_DATA_WIDTH-1:0]        wg_read_8;
logic [BRAM_DATA_WIDTH-1:0]        wg_read_8_d;

logic [BRAM_DATA_WIDTH-1:0]        bias_read_1;
logic [BRAM_DATA_WIDTH-1:0]        bias_read_1_d;
logic [BRAM_DATA_WIDTH-1:0]        bias_read_2;
logic [BRAM_DATA_WIDTH-1:0]        bias_read_2_d;
logic [BRAM_DATA_WIDTH-1:0]        bias_read_3;
logic [BRAM_DATA_WIDTH-1:0]        bias_read_3_d;
logic [BRAM_DATA_WIDTH-1:0]        bias_read_4;
logic [BRAM_DATA_WIDTH-1:0]        bias_read_4_d;


logic [$clog2(MEM_DEPTH)-1:0]           col_cnt;
logic [$clog2(KY_MAX):0]                line_cnt;
logic [$clog2(KY_MAX):0]                wr_line;

logic [$clog2(WEIGHT_MEM_DEPTH)-1:0]    col_cnt_wg;
logic [$clog2(MAX_OUTPUTS_PARALEL+1):0] wr_line_wg;

logic [$clog2(BIAS_MEM_DEPTH)-1:0]      col_cnt_bias;
logic [$clog2(MAX_BIAS_PARALEL): 0]     wr_line_bias;

// REGISTERED CONTROL (ALINHAMENTO TEMPORAL)
logic [$clog2(MEM_DEPTH):0]             col_cnt_rlm;
logic [$clog2(MEM_DEPTH):0]             col_cnt_rlm_bckup;
logic [$clog2(MEM_DEPTH):0]             col_cnt_r;
logic [$clog2(KY_MAX):0]                line_cnt_r;

logic                                   read_req;
logic                                   read_req_d;

logic                                   start_cmpt;
logic                                   start_cmpt_d;
logic                                   start_cmpt_d_d;

//Convolution operation signals
logic [DATA_WIDTH-1:0]                  w   [0:MAX_OUTPUTS_PARALEL-1][0:MAX_WEIGHTS-1];
logic [DATA_WIDTH-1:0]                  p   [0:MAX_WEIGHTS-1][0:MAX_CHANNELS-1];
logic [BIAS_DATA_WIDTH-1:0]             b   [0:MAX_CHANNELS-1];
logic signed [2*2*DATA_WIDTH-1:0]       mac [0:MAX_OUTPUTS_PARALEL-1];
logic signed [2*2*2*DATA_WIDTH-1:0]     acc [0:MAX_OUTPUTS_PARALEL-1];


logic signed [2*2*2*DATA_WIDTH-1:0]     out_temp_0;
logic signed [2*2*2*DATA_WIDTH-1:0]     out_temp_1;
logic signed [2*2*2*DATA_WIDTH-1:0]     out_temp_2;
logic signed [2*2*2*DATA_WIDTH-1:0]     out_temp_3;
logic signed [2*2*2*DATA_WIDTH-1:0]     out_temp_4;
logic signed [2*2*2*DATA_WIDTH-1:0]     out_temp_5;
logic signed [2*2*2*DATA_WIDTH-1:0]     out_temp_6;
logic signed [2*2*2*DATA_WIDTH-1:0]     out_temp_7;

//memory control signals
logic [$clog2(WEIGHT_MEM_DEPTH)-1:0]    col_wgt_cmpt;
logic [$clog2(BIAS_MEM_DEPTH)-1:0]      col_bias_cmpt;
logic [$clog2(WEIGHT_MEM_DEPTH)-1:0]    cnt_cmpt;
logic [$clog2(MAX_OUTPUTS_TOTAL)-1:0]   cnt_outs;
logic [MAX_CHANNELS-1:0]                mem_idx;



//===========================================================
//============================SWU============================
//===========================================================

    //===========================================================
    //=====================WRITE SIDE============================
    //===========================================================
    always_ff @(posedge clk ) begin
        if (in_valid) begin
            case (wr_line)
                0:begin
                    mem_0[col_cnt] <= in_pixel;
                    mem_1[col_cnt] <= in_pixel;
                    mem_2[col_cnt] <= in_pixel;
                    mem_3[col_cnt] <= in_pixel;
                end
                1:begin
                    mem_4[col_cnt] <= in_pixel;
                    mem_5[col_cnt] <= in_pixel;
                    mem_6[col_cnt] <= in_pixel;
                    mem_7[col_cnt] <= in_pixel;
                end
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            col_cnt  <= 0;
            line_cnt <= 0;
            wr_line  <= 0;
        end
        else if (in_valid) begin
            if (col_cnt == cfg_w-1) begin
                col_cnt <= 0;
                if (wr_line == cfg_ky-1)
                    wr_line <= 0;
                else
                    wr_line <= wr_line + 1;
                line_cnt <= line_cnt + 1;
            end
            else begin
                col_cnt <= col_cnt + 1;
            end
        end
    end

    //===========================================================
    //=====================READ SIDE=============================
    //===========================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            read_req     <= 0;
            read_req_d   <= 0;
        end
        else begin
            if (
                (in_valid && !cfg_op_type && line_cnt_r >= cfg_ky-1 && col_cnt_r  >= cfg_kx-1 && !start_cmpt) ||
                (in_valid && cfg_op_type && (col_cnt_r==cfg_w-1 || read_req))
                )
                begin
                    read_req <= 1;
                    read_req_d <= read_req;
                end
            else
                read_req <= 0;
        end
    end

    always_ff @(posedge clk) begin
        line_cnt_r <= line_cnt;
        col_cnt_r <= col_cnt;
    end

    always_ff @(posedge clk) begin
            mem_read_1 <= mem_0[col_cnt_rlm];
            mem_read_2 <= mem_1[col_cnt_rlm+1];
            mem_read_3 <= mem_2[col_cnt_rlm+2];
            mem_read_4 <= mem_3[col_cnt_rlm+3];
            mem_read_5 <= mem_4[col_cnt_rlm];
            mem_read_6 <= mem_5[col_cnt_rlm+1];
            mem_read_7 <= mem_6[col_cnt_rlm+2];
            mem_read_8 <= mem_7[col_cnt_rlm+3];
    end

//===========================================================
//============================PE=============================
//===========================================================

    //===========================================================
    //======================WRITE WEIGHTS========================
    //===========================================================
    always_ff @(posedge clk ) begin
        if (wr_wgt_valid) begin
            case (wr_line_wg) 
                0:wg_mem_0[col_cnt_wg] <= in_pixel;
                1:wg_mem_1[col_cnt_wg] <= in_pixel;
                2:wg_mem_2[col_cnt_wg] <= in_pixel;
                3:wg_mem_3[col_cnt_wg] <= in_pixel;
                4:wg_mem_4[col_cnt_wg] <= in_pixel;
                5:wg_mem_5[col_cnt_wg] <= in_pixel;
                6:wg_mem_6[col_cnt_wg] <= in_pixel;
                7:wg_mem_7[col_cnt_wg] <= in_pixel;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            col_cnt_wg  <= 0;
            wr_line_wg  <= 0;
        end
        else if (wr_wgt_valid) begin
            if (col_cnt_wg == cfg_w_wg_max_out-1) begin
                col_cnt_wg <= 0;
                wr_line_wg <= wr_line_wg + 1;
            end
            else begin
                col_cnt_wg <= col_cnt_wg + 1;
            end
        end
    end

    //===========================================================
    //======================WRITE BIAS========================
    //===========================================================
    always_ff @(posedge clk ) begin
        if (wr_bias_valid) begin
            case (wr_line_bias) 
                0:bias_mem_0[col_cnt_bias] <= in_pixel[BRAM_DATA_WIDTH-1:0];
                1:bias_mem_1[col_cnt_bias] <= in_pixel[BRAM_DATA_WIDTH-1:0];
                2:bias_mem_2[col_cnt_bias] <= in_pixel[BRAM_DATA_WIDTH-1:0];
                3:bias_mem_3[col_cnt_bias] <= in_pixel[BRAM_DATA_WIDTH-1:0];
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            col_cnt_bias  <= 0;
            wr_line_bias  <= 0;
        end
        else if (wr_bias_valid) begin
            if (col_cnt_bias == cfg_w_bias_max_out-1) begin
                col_cnt_bias <= 0;
                wr_line_bias <= wr_line_bias + 1;
            end
            else begin
                col_cnt_bias <= col_cnt_bias + 1;
            end
        end
    end


    //===========================================================
    //=====================READ SIDE=============================
    //===========================================================
    always_ff @(posedge clk) begin
        wg_read_1 <= wg_mem_0[col_wgt_cmpt];
        wg_read_2 <= wg_mem_1[col_wgt_cmpt];
        wg_read_3 <= wg_mem_2[col_wgt_cmpt];
        wg_read_4 <= wg_mem_3[col_wgt_cmpt];
        wg_read_5 <= wg_mem_4[col_wgt_cmpt];
        wg_read_6 <= wg_mem_5[col_wgt_cmpt];
        wg_read_7 <= wg_mem_6[col_wgt_cmpt];
        wg_read_8 <= wg_mem_7[col_wgt_cmpt];

        bias_read_1 <= bias_mem_0[col_bias_cmpt];
        bias_read_2 <= bias_mem_1[col_bias_cmpt];
        bias_read_3 <= bias_mem_2[col_bias_cmpt];
        bias_read_4 <= bias_mem_3[col_bias_cmpt];
    end


//===========================================================
//=====================COMPUTING SIDE========================
//===========================================================

    //===========================================================
    //=====================READ FROM RAM=========================
    //===========================================================
    always_ff @(negedge clk) begin
        wg_read_1_d <= wg_read_1;
        wg_read_2_d <= wg_read_2;
        wg_read_3_d <= wg_read_3;
        wg_read_4_d <= wg_read_4;
        wg_read_5_d <= wg_read_5;
        wg_read_6_d <= wg_read_6;
        wg_read_7_d <= wg_read_7;
        wg_read_8_d <= wg_read_8;

        bias_read_1_d <= bias_read_1;
        bias_read_2_d <= bias_read_2;
        bias_read_3_d <= bias_read_3;
        bias_read_4_d <= bias_read_4;

        case (wr_line)
            0: begin
                mem_read_1_d <= mem_read_5;
                mem_read_2_d <= mem_read_6;
                mem_read_3_d <= mem_read_7;
                mem_read_4_d <= mem_read_8;
                mem_read_5_d <= mem_read_1;
                mem_read_6_d <= mem_read_2;
                mem_read_7_d <= mem_read_3;
                mem_read_8_d <= mem_read_4;
            end
            1: begin
                mem_read_1_d <= mem_read_1;
                mem_read_2_d <= mem_read_2;
                mem_read_3_d <= mem_read_3;
                mem_read_4_d <= mem_read_4;
                mem_read_5_d <= mem_read_5;
                mem_read_6_d <= mem_read_6;
                mem_read_7_d <= mem_read_7;
                mem_read_8_d <= mem_read_8;
            end
            endcase
    end

    //===========================================================
    //==========ASSIGN THE WEIGHTS AND INPUTS====================
    //===========================================================
    //ASSUMINDO MAX_OUTPUTS_PARALEL=8, CASO QUERIA UTILIZAR VALORES DIFERENTES AUMENTAR O NÚMERO DE MEMÓRIAS BRAM(wg_read E mem_read) PARA SE ADEQUAR AO NÚMERO DE SAÍDAS PARALELAS
    always_ff @(posedge clk) begin        
        //WEIGHTS
        for (int k=0;k<MAX_WEIGHTS;k++) begin
            w[0][k] <= wg_read_1_d[k*DATA_WIDTH +: DATA_WIDTH];
            w[1][k] <= wg_read_2_d[k*DATA_WIDTH +: DATA_WIDTH];
            w[2][k] <= wg_read_3_d[k*DATA_WIDTH +: DATA_WIDTH];
            w[3][k] <= wg_read_4_d[k*DATA_WIDTH +: DATA_WIDTH];
            w[4][k] <= wg_read_5_d[k*DATA_WIDTH +: DATA_WIDTH];
            w[5][k] <= wg_read_6_d[k*DATA_WIDTH +: DATA_WIDTH];
            w[6][k] <= wg_read_7_d[k*DATA_WIDTH +: DATA_WIDTH];
            w[7][k] <= wg_read_8_d[k*DATA_WIDTH +: DATA_WIDTH];
        end
   
        //INPUTS
        for (int c=0;c<MAX_CHANNELS;c++) begin
            p[c][0] <= mem_read_1_d[c*DATA_WIDTH +: DATA_WIDTH];
            p[c][1] <= mem_read_2_d[c*DATA_WIDTH +: DATA_WIDTH];
            p[c][2] <= mem_read_3_d[c*DATA_WIDTH +: DATA_WIDTH];
            p[c][3] <= mem_read_4_d[c*DATA_WIDTH +: DATA_WIDTH];
            p[c][4] <= mem_read_5_d[c*DATA_WIDTH +: DATA_WIDTH];
            p[c][5] <= mem_read_6_d[c*DATA_WIDTH +: DATA_WIDTH];
            p[c][6] <= mem_read_7_d[c*DATA_WIDTH +: DATA_WIDTH];
            p[c][7] <= mem_read_8_d[c*DATA_WIDTH +: DATA_WIDTH];
        end
        //BIAS
        b[0] <= '0;
        b[1] <= '0;
        b[2] <= '0;
        b[3] <= '0;
        b[4] <= '0;
        b[5] <= '0;
        b[6] <= '0;
        b[7] <= '0;
        // b[0] <= bias_read_1_d[0*BIAS_DATA_WIDTH +: BIAS_DATA_WIDTH];
        // b[1] <= bias_read_1_d[1*BIAS_DATA_WIDTH +: BIAS_DATA_WIDTH];
        // b[2] <= bias_read_2_d[0*BIAS_DATA_WIDTH +: BIAS_DATA_WIDTH];
        // b[3] <= bias_read_2_d[1*BIAS_DATA_WIDTH +: BIAS_DATA_WIDTH];
        // b[4] <= bias_read_3_d[0*BIAS_DATA_WIDTH +: BIAS_DATA_WIDTH];
        // b[5] <= bias_read_3_d[1*BIAS_DATA_WIDTH +: BIAS_DATA_WIDTH];
        // b[6] <= bias_read_4_d[0*BIAS_DATA_WIDTH +: BIAS_DATA_WIDTH];
        // b[7] <= bias_read_4_d[1*BIAS_DATA_WIDTH +: BIAS_DATA_WIDTH];
    end 


    //===========================================================
    //===========================MAC=============================
    //===========================================================
    always_comb begin
        for (int o=0;o<MAX_OUTPUTS_PARALEL;o++) begin
            mac[o] = 0;
            for (int c=0; c<MAX_CHANNELS; c++) begin
                mac[o] +=  $signed(w[o][c]) * $signed(p[c][mem_idx]);
            end
        end
    end


    //===========================================================
    //=======================ACCUMULATOR=========================
    //===========================================================

    always_ff @(posedge clk) begin
        for (int o=0;o<MAX_OUTPUTS_PARALEL;o++) begin
            if (!cfg_depth_conv) begin
                if (cnt_cmpt==0 || cnt_cmpt==cfg_w_wg)
                    acc[o] <= mac[o];
                else
                    acc[o] <= acc[o] + mac[o];
            end
            else begin
                if (mem_idx == o)
                    acc[o] <= mac[o];
                else
                    acc[o] <= acc[o];
            end
        end
    end

    //===========================================================
    //=======================OUTPUT ASSINGMENT===================
    //===========================================================
    always_comb begin
        out_temp_0 = ((($signed(acc[0]) + $signed(b[0]))*$signed(m_int)) - $signed(ROUND) ) >>> PRECISION_N;
        out_temp_1 = ((($signed(acc[1]) + $signed(b[1]))*$signed(m_int)) - $signed(ROUND) ) >>> PRECISION_N;
        out_temp_2 = ((($signed(acc[2]) + $signed(b[2]))*$signed(m_int)) - $signed(ROUND) ) >>> PRECISION_N;
        out_temp_3 = ((($signed(acc[3]) + $signed(b[3]))*$signed(m_int)) - $signed(ROUND) ) >>> PRECISION_N;
        out_temp_4 = ((($signed(acc[4]) + $signed(b[4]))*$signed(m_int)) - $signed(ROUND) ) >>> PRECISION_N;
        out_temp_5 = ((($signed(acc[5]) + $signed(b[5]))*$signed(m_int)) - $signed(ROUND) ) >>> PRECISION_N;
        out_temp_6 = ((($signed(acc[6]) + $signed(b[6]))*$signed(m_int)) - $signed(ROUND) ) >>> PRECISION_N;
        out_temp_7 = ((($signed(acc[7]) + $signed(b[7]))*$signed(m_int)) - $signed(ROUND) ) >>> PRECISION_N;
    end

    //===========================================================
    //===================CONTROL AND OUTPUT======================
    //===========================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            col_cnt_rlm <= 0;
            col_cnt_rlm_bckup <= 0;
            start_cmpt <= 0;
            start_cmpt_d <= 0;
            start_cmpt_d_d <= 0;
            col_wgt_cmpt <= 0;
            col_bias_cmpt <= 0;
            cnt_cmpt <= 0;
            cnt_outs <= 0;
            mem_idx <= 0;
        end
        //start computation delay block
        if (read_req_d || (start_cmpt && ~(cnt_cmpt==cfg_w_wg && cnt_outs==cfg_max_out)))
            start_cmpt <= 1;
        else 
            start_cmpt <= 0;
        start_cmpt_d <= start_cmpt;
        start_cmpt_d_d <= start_cmpt_d;
        
        if (start_cmpt && cnt_cmpt==cfg_w_wg-DELAY_TIME && cnt_outs==cfg_max_out-MAX_OUTPUTS_PARALEL)
            col_wgt_cmpt <= 0;
        else if(start_cmpt && !cfg_depth_conv && !(cnt_cmpt==cfg_w_wg-DELAY_TIME && cnt_outs==cfg_max_out-MAX_OUTPUTS_PARALEL))
            col_wgt_cmpt <= col_wgt_cmpt +1;
        else if(start_cmpt && cfg_depth_conv && cnt_cmpt==cfg_w_wg-DELAY_TIME && cnt_outs!=cfg_max_out-MAX_OUTPUTS_PARALEL)
            col_wgt_cmpt <= col_wgt_cmpt +1;
        // else begin
        //     col_wgt_cmpt <= 0;
        //     col_bias_cmpt <= 0;
        //     col_cnt_rlm <= 0;
        //     cnt_cmpt <= 0;
        //     cnt_outs <= 0;
        //     mem_idx <= 0;
        // end

        if(start_cmpt_d_d || (start_cmpt && cfg_c==1 && cfg_ky==10)) begin
            //col_cnt_rlm control
            if (cnt_cmpt==cfg_w_wg-DELAY_TIME && cnt_outs==cfg_max_out-MAX_OUTPUTS_PARALEL) begin // start the processing of reading the next inputs from RAM
                col_cnt_rlm <= col_cnt_rlm_bckup + cfg_mem_shifter;
                col_cnt_rlm_bckup <= col_cnt_rlm_bckup + cfg_mem_shifter;
            end
            else if (!cfg_depth_conv && cnt_cmpt==cfg_w_wg-(DELAY_TIME+1) && cnt_outs!=cfg_max_out-MAX_OUTPUTS_PARALEL)
                col_cnt_rlm <= col_cnt_rlm_bckup;
            else if (!cfg_op_type && !cfg_depth_conv && cfg_c>MAX_CHANNELS && mem_idx==MAX_CHANNELS-(DELAY_TIME+1))
                col_cnt_rlm <= col_cnt_rlm + 1;
            else if (!cfg_op_type && cfg_depth_conv && cfg_c>MAX_CHANNELS && mem_idx==MAX_CHANNELS-(DELAY_TIME))
                col_cnt_rlm <= col_cnt_rlm + 1;
            else if (cfg_op_type && cfg_c>MAX_CHANNELS && mem_idx==4-(DELAY_TIME+1))
                col_cnt_rlm <= col_cnt_rlm + 4;
            else if (cfg_c==1)
                col_cnt_rlm <= col_cnt_rlm + 1;
            else
                col_cnt_rlm <= col_cnt_rlm;

            // out_valid, cnt_cmp, mem_idx and cnt_outs control
            if (cnt_cmpt==cfg_w_wg && cnt_outs==cfg_max_out-MAX_OUTPUTS_PARALEL) begin //if finished all channels
                out_valid <= 1;

                if (out_temp_0 > MAX_VAL)
                    out_pixel[0] <= MAX_VAL;
                else if (out_temp_0 < MIN_VAL)
                    out_pixel[0] <= MIN_VAL;
                else
                    out_pixel[0] <= out_temp_0[DATA_WIDTH-1:0];
                if (out_temp_1 > MAX_VAL)
                    out_pixel[1] <= MAX_VAL;
                else if (out_temp_1 < MIN_VAL)
                    out_pixel[1] <= MIN_VAL;
                else
                    out_pixel[1] <= out_temp_1[DATA_WIDTH-1:0];
                if (out_temp_2 > MAX_VAL)
                    out_pixel[2] <= MAX_VAL;
                else if (out_temp_2 < MIN_VAL)
                    out_pixel[2] <= MIN_VAL;
                else
                    out_pixel[2] <= out_temp_2[DATA_WIDTH-1:0];
                if (out_temp_3 > MAX_VAL)
                    out_pixel[3] <= MAX_VAL;
                else if (out_temp_3 < MIN_VAL)
                    out_pixel[3] <= MIN_VAL;
                else
                    out_pixel[3] <= out_temp_3[DATA_WIDTH-1:0];
                if (out_temp_4 > MAX_VAL)
                    out_pixel[4] <= MAX_VAL;
                else if (out_temp_4 < MIN_VAL)
                    out_pixel[4] <= MIN_VAL;
                else
                    out_pixel[4] <= out_temp_4[DATA_WIDTH-1:0];
                if (out_temp_5 > MAX_VAL)
                    out_pixel[5] <= MAX_VAL;
                else if (out_temp_5 < MIN_VAL)
                    out_pixel[5] <= MIN_VAL;
                else
                    out_pixel[5] <= out_temp_5[DATA_WIDTH-1:0];
                if (out_temp_6 > MAX_VAL)
                    out_pixel[6] <= MAX_VAL;
                else if (out_temp_6 < MIN_VAL)
                    out_pixel[6] <= MIN_VAL;
                else
                    out_pixel[6] <= out_temp_6[DATA_WIDTH-1:0];
                if (out_temp_7 > MAX_VAL)
                    out_pixel[7] <= MAX_VAL;
                else if (out_temp_7 < MIN_VAL)
                    out_pixel[7] <= MIN_VAL;
                else
                    out_pixel[7] <= out_temp_7[DATA_WIDTH-1:0];
                
                cnt_cmpt <= 0;
                mem_idx <= 0;
                cnt_outs <= 0;
                col_bias_cmpt <= 0;
            end
            else if (cnt_cmpt==cfg_w_wg && cnt_outs!=cfg_max_out-MAX_OUTPUTS_PARALEL) begin // if finished MAX_OUTPUTS_PARALEL channels
                out_valid <= 1;

                if (out_temp_0 > MAX_VAL)
                    out_pixel[0] <= MAX_VAL;
                else if (out_temp_0 < MIN_VAL)
                    out_pixel[0] <= MIN_VAL;
                else
                    out_pixel[0] <= out_temp_0[DATA_WIDTH-1:0];
                if (out_temp_1 > MAX_VAL)
                    out_pixel[1] <= MAX_VAL;
                else if (out_temp_1 < MIN_VAL)
                    out_pixel[1] <= MIN_VAL;
                else
                    out_pixel[1] <= out_temp_1[DATA_WIDTH-1:0];
                if (out_temp_2 > MAX_VAL)
                    out_pixel[2] <= MAX_VAL;
                else if (out_temp_2 < MIN_VAL)
                    out_pixel[2] <= MIN_VAL;
                else
                    out_pixel[2] <= out_temp_2[DATA_WIDTH-1:0];
                if (out_temp_3 > MAX_VAL)
                    out_pixel[3] <= MAX_VAL;
                else if (out_temp_3 < MIN_VAL)
                    out_pixel[3] <= MIN_VAL;
                else
                    out_pixel[3] <= out_temp_3[DATA_WIDTH-1:0];
                if (out_temp_4 > MAX_VAL)
                    out_pixel[4] <= MAX_VAL;
                else if (out_temp_4 < MIN_VAL)
                    out_pixel[4] <= MIN_VAL;
                else
                    out_pixel[4] <= out_temp_4[DATA_WIDTH-1:0];
                if (out_temp_5 > MAX_VAL)
                    out_pixel[5] <= MAX_VAL;
                else if (out_temp_5 < MIN_VAL)
                    out_pixel[5] <= MIN_VAL;
                else
                    out_pixel[5] <= out_temp_5[DATA_WIDTH-1:0];
                if (out_temp_6 > MAX_VAL)
                    out_pixel[6] <= MAX_VAL;
                else if (out_temp_6 < MIN_VAL)
                    out_pixel[6] <= MIN_VAL;
                else
                    out_pixel[6] <= out_temp_6[DATA_WIDTH-1:0];
                if (out_temp_7 > MAX_VAL)
                    out_pixel[7] <= MAX_VAL;
                else if (out_temp_7 < MIN_VAL)
                    out_pixel[7] <= MIN_VAL;
                else
                    out_pixel[7] <= out_temp_7[DATA_WIDTH-1:0];

                if (cfg_depth_conv) begin
                    cnt_cmpt <= 0;
                    mem_idx <= 0;
                end
                else if(cfg_c==1) begin
                    cnt_cmpt <= 1;
                    mem_idx <= 0;
                end
                else begin
                    cnt_cmpt <= 1;
                    mem_idx <= 1;
                end

                col_bias_cmpt <= col_bias_cmpt + 1;
                cnt_outs <= cnt_outs + MAX_OUTPUTS_PARALEL;
            end
            else if (cfg_c==1) begin
                out_valid <= 0;
                out_pixel[0] <= '0;
                out_pixel[1] <= '0;
                out_pixel[2] <= '0;
                out_pixel[3] <= '0;
                out_pixel[4] <= '0;
                out_pixel[5] <= '0;
                out_pixel[6] <= '0;
                out_pixel[7] <= '0;
                if (start_cmpt_d_d)
                    cnt_cmpt <= cnt_cmpt + 1;
                else
                    cnt_cmpt <= 0;
                mem_idx  <= 0;
            end
            else if  ((!cfg_op_type && ((mem_idx==MAX_CHANNELS-1 && cfg_w_wg>=MAX_CHANNELS) || (cfg_w_wg<MAX_CHANNELS && mem_idx==cfg_w_wg-1))) ||
                     ( cfg_op_type && mem_idx==4-1)) begin // if used all MAX_CHANNELS, restart mem_idx
                out_valid <= 0;
                out_pixel[0] <= '0;
                out_pixel[1] <= '0;
                out_pixel[2] <= '0;
                out_pixel[3] <= '0;
                out_pixel[4] <= '0;
                out_pixel[5] <= '0;
                out_pixel[6] <= '0;
                out_pixel[7] <= '0;

                cnt_cmpt <= cnt_cmpt + 1;
                mem_idx  <= 0;
            end
            else begin
                out_valid <= 0;
                out_pixel[0] <= '0;
                out_pixel[1] <= '0;
                out_pixel[2] <= '0;
                out_pixel[3] <= '0;
                out_pixel[4] <= '0;
                out_pixel[5] <= '0;
                out_pixel[6] <= '0;
                out_pixel[7] <= '0;

                cnt_cmpt <= cnt_cmpt + 1;
                mem_idx  <= mem_idx + 1;
            end
        end
        else begin
            out_valid <= 0;

            out_pixel[0] <= '0;
            out_pixel[1] <= '0;
            out_pixel[2] <= '0;
            out_pixel[3] <= '0;
            out_pixel[4] <= '0;
            out_pixel[5] <= '0;
            out_pixel[6] <= '0;
            out_pixel[7] <= '0;
        end
    end

endmodule