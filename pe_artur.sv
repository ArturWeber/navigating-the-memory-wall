// ============================================================
//            Projeto de Formatura I - SCC0670               
//                                                           
//      By: Artur Brenner Weber                              
//      Last Update: 26/5/2026                               
//                                                           
//  Original version written by Eduardo Sperle Honorato      
//  based on work from "On the RTL Implementation of FINN    
//  Matrix Vector Unit".    
//  This is the RTL Code describing the Matrix-Vector Unit (MVU)                                 
// ============================================================

`timescale 1ns/1ps
`include "rtl_cfg.svh"

module pe #
(
        parameter byte unsigned      DATA_WIDTH = `DATA_WIDTH,                          //Data width of inputs and outputs
        parameter shortint           MAX_VAL = (1 <<< (DATA_WIDTH-1)) - 1,              //Maximum output value based on data width. Used to clip the accumulator output when scaling values
        parameter shortint           MIN_VAL = -(1 <<< (DATA_WIDTH-1)),                 //Minimum output value based on data width. Used to clip the accumulator output when scaling values
        parameter byte unsigned      ACC_BIT_WIDTH=32,                                  //Accumulator data width
        parameter byte unsigned      M_INT_PRECISION=32,                                //Precision of the scaler. Used in scaling
        parameter longint signed     PRECISION_CORRECTION=1 << (M_INT_PRECISION-1),     //Rounding correction, used to properly round numbers
        parameter byte unsigned      TEMP_DATA_WIDTH=ACC_BIT_WIDTH+M_INT_PRECISION+1,   //Data width for scaling operation. out_temp= scale * acc_out + correction
        parameter byte unsigned      NUM_ACTS_FUN=2,                                    //Number of implemented activation functions: Identity, ReLU
        parameter shortint unsigned  SIMD = `SIMD,                                      //SIMD width, received from testbench
        parameter shortint unsigned  PE = `PE,                                          //Number of logical PEs, i.e. output channels
        parameter shortint unsigned  MAX_CHANNELS = `MAX_CHANNELS,                      //Maximum number of input channels
        parameter shortint unsigned  KERNEL_X = `KERNEL_X,                              //Kernel width         
        parameter shortint unsigned  KERNEL_Y = `KERNEL_Y,                              //Kernel height
        parameter int unsigned       MAX_DOT_LANES = MAX_CHANNELS*KERNEL_X*KERNEL_Y,    //Number of values to be multiplied per filter/PE
        parameter int unsigned       MAX_FOLDS = (MAX_DOT_LANES + SIMD - 1) / SIMD,     //Number of folds needed to process MAX_DOT_LANES with SIMD lanes
        parameter int unsigned       PAD_LANES = MAX_FOLDS * SIMD,                      //Ammount of numbers in filter/input after padding 
        parameter int unsigned       MAX_INPUT_DIM = PAD_LANES * DATA_WIDTH,            //Length of each filter/input after padding in bits
        parameter shortint unsigned  MAX_OUTPUT_DIM = PE*DATA_WIDTH                     //Length of output from all filters in bits 
    )
    (   
    `ifndef SYNTHESIS
        //===========================DEBUG===========================
        output int unsigned                                                    check_state, check_next_state,
        output int unsigned                                                    check_read_posx,
        output int unsigned                                                    check_read_posy,
        output int unsigned                                                    check_weight_ind,
        output int unsigned                                                    check_PE_ind,
        output logic                                                           check_write_complete,
        output logic                                                           check_computing_complete,
        output logic [PE*MAX_INPUT_DIM-1:0]                                    check_weights,
        output logic [PE*SIMD*DATA_WIDTH-1:0]                                  check_current_weights,
        output logic [PE*DATA_WIDTH-1:0]                                       check_output_PE,
        output logic [MAX_INPUT_DIM-1:0]                                       check_input,
        output logic [SIMD*DATA_WIDTH-1:0]                                     check_input_part,
        // output logic [2*DATA_WIDTH+$clog2(SIMD)-1:0]                        check_out_add,
        output logic [ACC_BIT_WIDTH-1:0]                                       check_out_acc,
        output logic signed [TEMP_DATA_WIDTH-1:0]                              check_out_temp,
        //===========================DEBUG===========================
    `endif
        //===========================INPUTS===========================
        input   logic                                                          rst_n,
        input   logic                                                          clk,
        input   logic                                                          set_cfg_n,
        input logic [((NUM_ACTS_FUN <= 1) ? 1 : $clog2(NUM_ACTS_FUN))-1:0]     act_fun,
        input   logic                                                          wr_en,
        input   logic                                                          str_wr,
        input   logic                                                          inp_rd,
        input   logic   [MAX_INPUT_DIM-1:0]                                    inp_data,
        input logic [$clog2(MAX_FOLDS+1)-1:0]                                  fold_qnt,
        input logic [$clog2(PE+1)-1:0]                                         pe_qnt,
        //===========================OUTPUTS===========================
        output logic [MAX_OUTPUT_DIM-1:0]                                      out,
        output  logic                                                          output_ready,
        output  logic                                                          ready_to_receive
    );
    
    enum logic [1:0] { empty=0, writing=1, ready=2, computing=3 } state, next_state;

    logic signed [DATA_WIDTH-1:0]                                              out_PE [PE-1:0];
    `ifndef SYNTHESIS
    logic signed [TEMP_DATA_WIDTH-1:0]                                         out_temp;
    `endif
    logic [MAX_INPUT_DIM-1:0]                                                  weights  [PE-1:0];
    logic signed [M_INT_PRECISION-1:0]                                         scales;
    logic [MAX_INPUT_DIM-1:0]                                                  inp_data_reg;
    logic signed [ACC_BIT_WIDTH-1:0]                                           out_acc;
    logic                                                                      write_complete;
    logic                                                                      computing_complete;
    
    logic [$clog2(MAX_FOLDS+2)-1:0]                                            read_posx;
    logic [$clog2(PE+1)-1:0]                                                   read_posy;
    localparam int unsigned                                                    W_FOLD_IDX = (MAX_FOLDS <= 1) ? 1 : $clog2(MAX_FOLDS);
    logic [W_FOLD_IDX-1:0]                                                     weights_ind;
    localparam int unsigned                                                    W_PE_IDX = (PE <= 1) ? 1 : $clog2(PE);
    logic [W_PE_IDX-1:0]                                                       PE_ind;

    logic [$clog2(MAX_FOLDS+2)-1:0]                                            fold_qnt_reg;
    logic [$clog2(PE+1)-1:0]                                                   pe_qnt_reg;
    localparam int unsigned                                                    W_ACT = (NUM_ACTS_FUN <= 1) ? 1 : $clog2(NUM_ACTS_FUN);
    logic [W_ACT-1:0]                                                          act_fun_reg;

    
    always_comb begin : state_change_logic
        next_state = state; // state change
        case (state)
            empty: begin
                if (str_wr) //if start writing is enabled then go to writing state
                    next_state = writing;
            end

            writing: begin
                if (write_complete) //if the weights have already been filled, change to ready state
                    next_state = ready;
            end

            ready: begin
                if (inp_rd) //if input is ready goes to computing state
                    next_state = computing;
            end

            computing: begin
                if (computing_complete) begin
                    if (inp_rd) //if computing complete and input ready keeps computing state
                        next_state = computing;
                    else //otherwise go to ready state to wait for the inp_rd signal
                        next_state = ready;
                end
            end

        endcase
    end

    always_ff @(posedge clk) begin: state_change_ff
        //resets the state to empty when rst_n is low, otherwise updates to the next state
        if (!rst_n)
            state <= empty;
        else
            state <= next_state;
    end

    always_ff @(posedge clk) begin : main_logic
        if (!rst_n) begin 
            // Resetting flags used by the control unit
            computing_complete <= '0;  
            write_complete     <= '0;
            output_ready       <= '0;
            ready_to_receive   <= '0;
            
            // Resetting small index counters to be safe
            weights_ind        <= '0;
            PE_ind             <= '0;
            read_posx          <= '0;
            read_posy          <= '0;

            // Initialize critical tiny registers to prevent X propagation
            scales             <= '0;
            inp_data_reg       <= '0;
        end
        else if (!set_cfg_n) begin 
            fold_qnt_reg <= fold_qnt;
            pe_qnt_reg <= pe_qnt;
            act_fun_reg <= act_fun;
        end
        // Latch new input data only when it is accepted
        else if (((state == ready) && inp_rd) || ((state == computing) && computing_complete && inp_rd)) begin
            inp_data_reg <= inp_data;
            // Clear per-inference state here so out_PE never carries old/X lanes across PEs or inputs
            out_PE <= '{default: '0};
            out <= '0;
            out_acc <= '0;
            weights_ind <= '0;
            PE_ind <= '0;
            computing_complete <= 1'b0;
            output_ready <= 1'b0;
            ready_to_receive <= 1'b0;
        end
        else begin
            case(state)
                //==============WRITING STATE==============
                writing: begin
                    logic [$bits(read_posx)-1:0] read_posx_next;
                    logic [$bits(read_posy)-1:0] read_posy_next;
                    output_ready <= '0;
                    ready_to_receive <= '0;
                    read_posx_next = read_posx;
                    read_posy_next = read_posy;

                    if (wr_en) begin
                        if (!write_complete) begin
                            // weights phase: read_posy = 0..pe_qnt_reg-1
                            if (read_posy < pe_qnt_reg) begin
                                // write fold
                                weights[read_posy][read_posx * SIMD * DATA_WIDTH +: SIMD * DATA_WIDTH] <= inp_data[SIMD*DATA_WIDTH-1:0];

                                // finished this PE's folds?
                                if (read_posx == fold_qnt_reg - 1) begin
                                    read_posy_next = read_posy + 1;
                                    read_posx_next = '0;
                                end
                                else begin
                                    read_posx_next = read_posx + 1;
                                    read_posy_next = read_posy;
                                end
                            end
                            else begin
                                // scale phase: single beat after all PEs, using signed so compiler doesnt complain about signed/unsigned assignments
                                scales <= signed'(inp_data[M_INT_PRECISION-1:0]);
                                write_complete <= '1;
                                read_posx_next = '0;
                                read_posy_next = '0;
                            end

                            read_posx <= read_posx_next;
                            read_posy <= read_posy_next;
                        end
                    end
                end
                //==============WRITING STATE==============
                //==============READY STATE==============
                ready: begin // just set to zero buffers, flags and counters
                    output_ready <= '0;
                    ready_to_receive <= '1;
                    computing_complete <= '0;
                    weights_ind <= 0;
                    PE_ind <= 0;
                end
                //==============READY STATE==============
                //==============COMPUTING STATE============== 
                computing: begin
                    //==============ACCUMULATOR==============
                    logic signed [ACC_BIT_WIDTH-1:0] acc_next;
                    //Uses signed to avoid warnings of signed/unsigned attribution
                    acc_next = (weights_ind == 0) ? signed'(0) : out_acc;

                    for (shortint unsigned simd_ind = 0; simd_ind < SIMD; simd_ind++) begin
                        acc_next +=
                        $signed(weights[PE_ind][(weights_ind * SIMD + simd_ind) * DATA_WIDTH +: DATA_WIDTH]) *
                        $signed(inp_data_reg[(weights_ind * SIMD + simd_ind) * DATA_WIDTH +: DATA_WIDTH]);
                    end

                    out_acc <= acc_next;
                    //==============ACCUMULATOR==============

                    //==============ACTIVATION FUNCTION==============
                    if (weights_ind == fold_qnt_reg - 1) begin
                        logic signed [TEMP_DATA_WIDTH-1:0] temp_next;
                        logic signed [DATA_WIDTH-1:0] result_dw;
                        logic signed [DATA_WIDTH-1:0] out_PE_next [PE-1:0];

                        // Calculate math instantly
                        temp_next = ((scales * acc_next) + PRECISION_CORRECTION) >>> M_INT_PRECISION;

                    `ifndef SYNTHESIS
                        out_temp <= temp_next;
                    `endif

                        // Clip values
                        if (temp_next > MAX_VAL)
                            result_dw = signed'(MAX_VAL[DATA_WIDTH-1:0]);
                        else if (temp_next < 0 && act_fun_reg == 1)
                            result_dw = '0;
                        else if (temp_next < MIN_VAL)
                            result_dw = signed'(MIN_VAL[DATA_WIDTH-1:0]);
                        else
                            result_dw = signed'(temp_next[DATA_WIDTH-1:0]);
                        
                        // Create the "next state" of the entire array instantly
                        out_PE_next = out_PE;
                        out_PE_next[PE_ind] = result_dw;

                        // Write back to internal registers
                        out_PE <= out_PE_next;

                        // Publish to the 1D output bus cleanly
                        if (PE_ind == pe_qnt_reg - 1) begin
                            // Unconditionally pack the 2D array into the 1D output bus.
                            // Because there are no "if" statements checking variable indexes here,
                            // this wires the flip-flops directly WITHOUT a massive MUX!
                            for (int i = 0; i < PE; i++) begin
                                // Cast the signed internal math back to raw unsigned bits for the output port
                                out[i * DATA_WIDTH +: DATA_WIDTH] <= unsigned'(out_PE_next[i]);
                            end
                            output_ready <= '1;
                            ready_to_receive <= '1;
                            computing_complete <= '1;
                        end
                        else begin
                            out <= '0; 
                            output_ready <= '0;
                            ready_to_receive <= '0;
                            computing_complete <= '0;
                        end
                    end
                    //==============ACTIVATION FUNCTION==============

                    //==============STATE PROGRESSION==============
                    if (PE_ind == pe_qnt_reg - 1 && weights_ind == fold_qnt_reg - 1) begin
                        // Outputs handled in Activation block above. 
                    end
                    else if (weights_ind == fold_qnt_reg - 1) begin
                        //when weight fold is completed means that one output(filter or element) is finished
                        //set weight index to zero and increment PE index
                        weights_ind <= 0;
                        PE_ind <= PE_ind + 1;
                    end
                    else begin
                        //in normal situation just increment the weight index, meaning to compute the next weight fold
                        weights_ind <= weights_ind + 1;
                    end
                    //==============STATE PROGRESSION==============
                end
                //==============COMPUTING STATE==============
                default: begin
                    output_ready <= '0;
                    ready_to_receive <= '0;
                end
            endcase
        end
    end

    `ifndef SYNTHESIS
    //=================DEBUG=================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            check_state <= '0;
            check_next_state <= '0;
            check_read_posy <= '0;
            check_read_posx <= '0;
            check_write_complete <= '0;
            check_input <= '0;
            check_input_part  <= '0;
            check_current_weights <= 'b0;
            check_output_PE <= 'b0;
            check_out_acc <= '0;
            check_out_temp <= '0;
            check_PE_ind <= 0;
            check_weight_ind <= 0;
        end
        else begin
            check_state <= state;
            check_next_state <= next_state;
            check_weight_ind <= weights_ind;
            check_PE_ind <= PE_ind;
            check_input <= inp_data_reg;
            check_input_part <= inp_data_reg[weights_ind * SIMD * DATA_WIDTH +: SIMD * DATA_WIDTH];
            check_read_posx <= read_posx;
            check_read_posy <= read_posy;
            for (int unsigned pe_indx = 0; pe_indx < PE; pe_indx++) begin
                if (pe_indx < pe_qnt_reg) begin
                    check_current_weights[pe_indx * SIMD * DATA_WIDTH +: SIMD * DATA_WIDTH] <= weights[pe_indx][weights_ind * SIMD * DATA_WIDTH +: SIMD * DATA_WIDTH];
                end
                else begin
                    check_current_weights[pe_indx * SIMD * DATA_WIDTH +: SIMD * DATA_WIDTH] <= '0;
                end
            end
            // Repack the 2D array back into a 1D vector for the testbench debug port
            for (int i = 0; i < PE; i++) begin
                check_output_PE[i * DATA_WIDTH +: DATA_WIDTH] <= out_PE[i];
            end
            check_computing_complete <= computing_complete;
            check_write_complete <= write_complete;
            check_out_acc <= out_acc;
            check_out_temp <= out_temp;
        end
    end
    //Output weights to the testbench
    genvar dbg_pe;
    generate
        for (dbg_pe = 0; dbg_pe < PE; dbg_pe++) begin : DBG_WEIGHTS
            assign check_weights[dbg_pe * MAX_INPUT_DIM +: MAX_INPUT_DIM] = weights[dbg_pe];
        end
    endgenerate
    //=================DEBUG=================
    `endif

endmodule
