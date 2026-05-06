`timescale 1ns/1ps

module pe #
(
        parameter byte unsigned      DATA_WIDTH=8,
        parameter shortint           MAX_VAL = (1 <<< (DATA_WIDTH-1)) - 1,              //maximum output value based on data width. Used to clip the accumulator output when scaling values
        parameter shortint           MIN_VAL = -(1 <<< (DATA_WIDTH-1)),                 //minimum output value based on data width. Used to clip the accumulator output when scaling values
        parameter byte unsigned      ACC_BIT_WIDTH=32,                                  //accumulator data width, set as 32 by default
        parameter byte unsigned      M_INT_PRECISION=32,                                //precision of the scaler to use when scaling the weights*inputs
        parameter longint signed     PRECISION_CORRECTION=1 << (M_INT_PRECISION-1),     //precision correction, due to imprecision nature, this is added so rounding values wont do too much damage. It is added to rounded value beforehand to avoid always rounding down with bit-shift. 
        parameter byte unsigned      TEMP_DATA_WIDTH=ACC_BIT_WIDTH+M_INT_PRECISION+1,   //out_temp data width, out_temp=scale*acc_out+correction
        parameter byte unsigned      NUM_ACTS_FUN=2,                                    //Number of implemented activation functions: Identity, ReLU, ReLU6 , LeakyReLU
        parameter shortint unsigned  SIMD=64,                                           //Number of SIMDs
        parameter shortint unsigned  PE=16,                                             //Number of PEs, i.e, outputs
        parameter shortint unsigned  MAX_CHANNELS = 16,                                  //Maximum number of input channels
        parameter shortint unsigned  KERNEL_X = 3,                                       
        parameter shortint unsigned  KERNEL_Y = 3,
        parameter int unsigned       MAX_DOT_LANES = MAX_CHANNELS*KERNEL_X*KERNEL_Y,    // maximum ammount of folds, control how many times the computation/weight reading will be done with for the same PE_out, each computation will do SIMDs multiplications and sums and will acumulate till the number specief is given. Basically, this is the maximum number of folds
        parameter int unsigned       MAX_FOLDS = (MAX_DOT_LANES + SIMD - 1) / SIMD,     // Fold-aligned padded lanes so part-selects are always in range
        parameter int unsigned       PAD_LANES = MAX_FOLDS * SIMD,                      // Fold-aligned MAX_INPUT_DIM in BITS (this is what all your buses/memories use)
        parameter int unsigned       MAX_INPUT_DIM = PAD_LANES * DATA_WIDTH,            //MAX_CHANNEL * KERNEL_X * KERNEL_Y, must be at least SIMD size and also a multiple of SIMD!!
        parameter shortint unsigned  MAX_OUTPUT_DIM = PE*DATA_WIDTH                     //MAX_CHANNEL * DATA_WIDTH
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
        output  logic   [MAX_OUTPUT_DIM-1:0]                                   out,
        output  logic                                                          output_ready,
        output  logic                                                          ready_to_receive
    );

    enum byte unsigned { empty=0, writing=1, ready=2, computing=3} state, next_state;

    logic [PE*DATA_WIDTH-1:0]                                                  out_PE;
    `ifndef SYNTHESIS
    logic signed [TEMP_DATA_WIDTH-1:0]                                         out_temp;
    `endif
    logic [MAX_INPUT_DIM-1:0]                                                  weights  [PE-1:0];
    //logic signed [M_INT_PRECISION-1:0]                                       scales   [PE-1:0];
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
        next_state = state; // default
        case (state)
            empty: begin
                if (str_wr) //if start writing is enable then change to writing state
                    next_state = writing;
            end

            writing: begin
                if (write_complete) //if the weights have already been filled, change to ready state
                    next_state = ready;
            end

            ready: begin
                if (inp_rd) //if input ready changes to computing state and also assign the input to the register
                    next_state = computing;
            end

            computing: begin
                if (computing_complete) begin
                    if (inp_rd) //if computing complete and input ready assign the input to register and keeps in the computing state
                        next_state = computing;
                    else //otherwise go to ready state to wait for the inp_rd signal
                        next_state = ready;
                end
            end

            default: next_state = empty;
        endcase
    end

    always_ff @(posedge clk) begin: state_change_ff
        if (!rst_n)
            state <= empty;
        else
            state <= next_state;
    end

    always_ff @(posedge clk) begin : main_logic
        if (!rst_n) begin // reset buffers, counters and memory
            computing_complete <= '0;  
            write_complete <= '0;
            output_ready <= '0;
            ready_to_receive <= '0;
            out <= '0;
            out_PE <= '0;
            out_acc <= '0;
            weights_ind <= '0;
            PE_ind <= '0;
            read_posx <= '0;
            read_posy <= '0;
            scales <= '0;
            for (int unsigned PE_indx = 0; PE_indx < PE; PE_indx++) begin
                weights[PE_indx] <= '0;  
            end;
        end
        else if (!set_cfg_n) begin // set input values into register
            fold_qnt_reg <= fold_qnt + 1;
            pe_qnt_reg <= pe_qnt;
            act_fun_reg <= act_fun;
        end
        // Latch new input data only when it is accepted
        else if (((state == ready) && inp_rd) || ((state == computing) && computing_complete && inp_rd)) begin
            inp_data_reg <= inp_data;
        end
        else begin
            case(state)
                //==============WRITING STATE==============
                writing: begin
                    logic [$bits(read_posx)-1:0] read_posx_next;
                    logic [$bits(read_posy)-1:0] read_posy_next;
                    out <= '0;
                    out_PE <= '0;
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

                                read_posx_next = read_posx + 1;
                                read_posy_next = read_posy;

                                // finished this PE's folds?
                                if (read_posx_next == fold_qnt_reg - 1) begin
                                    read_posy_next = read_posy + 1;
                                    read_posx_next = '0;
                                end
                            end
                            else begin
                                // scale phase: single beat after all PEs
                                scales <= inp_data[M_INT_PRECISION-1:0];
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
                    out <= '0;
                    out_PE <= '0;
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
                    acc_next = (weights_ind == 0) ? '0 : out_acc;

                    for (shortint unsigned simd_ind = 0; simd_ind < SIMD; simd_ind++) begin
                        acc_next +=
                        $signed(weights[PE_ind][(weights_ind * SIMD + simd_ind) * DATA_WIDTH +: DATA_WIDTH]) *
                        $signed(inp_data_reg[(weights_ind * SIMD + simd_ind) * DATA_WIDTH +: DATA_WIDTH]);
                    end

                    out_acc <= acc_next;
                    //==============ACCUMULATOR==============

                    //==============ACTIVATION FUNCTION==============
                    if (weights_ind == fold_qnt - 1) begin
                        logic [MAX_OUTPUT_DIM-1:0] out_PE_next;
                        logic signed [TEMP_DATA_WIDTH-1:0] temp_next; // Option 2B: Local combinational temp

                        out_PE_next = out_PE;

                        // 1. Calculate math instantly
                        temp_next = ((scales * acc_next) + PRECISION_CORRECTION) >>> M_INT_PRECISION;

                    `ifndef SYNTHESIS
                        // 2. Safely pass to debug variable ONLY in simulation
                        out_temp <= temp_next;
                    `endif

                        // 3. Use the local variable for unambiguous comparisons
                        if (temp_next > MAX_VAL)
                            out_PE_next[(PE_ind) * DATA_WIDTH +: DATA_WIDTH] = MAX_VAL;
                        else if (temp_next < 0 && act_fun_reg == 1)
                            out_PE_next[(PE_ind) * DATA_WIDTH +: DATA_WIDTH] = 0;
                        else if (temp_next < MIN_VAL)
                            out_PE_next[(PE_ind) * DATA_WIDTH +: DATA_WIDTH] = MIN_VAL;
                        else
                            out_PE_next[(PE_ind) * DATA_WIDTH +: DATA_WIDTH] = temp_next[DATA_WIDTH-1:0];

                        out_PE <= out_PE_next;

                        if (PE_ind == pe_qnt_reg - 1) begin
                            //if the number of outputs was computed and the number of weights fold was finished set computing_complete to 1
                            // also set the counters index of weight and PE to zero
                            out <= out_PE_next;
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
                    if (PE_ind == pe_qnt_reg - 1 && weights_ind == fold_qnt - 1) begin
                        // Outputs handled in Activation block above. 
                    end
                    else if (weights_ind == fold_qnt - 1) begin
                        //when weight fold is completed meand that one output(filter or element) is finished
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
                    out <= '0;
                    out_PE <= '0;
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
            // check_out_add<= '0;
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
            check_output_PE <= out_PE;
            check_computing_complete <= computing_complete;
            check_write_complete <= write_complete;
            // check_out_add <= out_add;
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