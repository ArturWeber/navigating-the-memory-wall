    `timescale 1ns/1ps

    module tb_pe();
        parameter byte unsigned      MAX_CMP_QNT=8;
        parameter shortint unsigned  MAX_WGT_QNT=8;
        parameter shortint unsigned  SIMD=64;
        parameter shortint unsigned  PE=8;
        parameter byte unsigned      DATA_WIDTH=8;
        parameter shortint unsigned  MAX_INPUT_DIM=64*DATA_WIDTH;//at least the same as window_size
        parameter shortint unsigned  MAX_OUTPUT_DIM=64*DATA_WIDTH;
        parameter byte unsigned      ACC_BIT_WIDTH=32;
        parameter byte unsigned      M_INT_PRECISION=32;
        parameter longint signed     PRECISION_CORRECTION=1 << (M_INT_PRECISION-1);
        parameter byte unsigned      TEMP_DATA_WIDTH=ACC_BIT_WIDTH+M_INT_PRECISION+1;
        parameter byte unsigned      NUM_ACTS_FUN=2;
        parameter shortint           MAX_VAL = (1 <<< (DATA_WIDTH-1)) - 1;
        parameter shortint           MIN_VAL = -(1 <<< (DATA_WIDTH-1));
        parameter int                WINDOW_SIZE = 25; // 5x5
        //=================FILES====================
        integer weight_file;
        integer input_file;
        integer r;
        //=================DEBUG====================
        int unsigned                                                          check_state;
        int unsigned                                                          check_next_state;
        int unsigned                                                          check_read_posx;
        int unsigned                                                          check_read_posy;
        int unsigned                                                          check_weight_ind;
        int unsigned                                                          check_PE_ind;
        logic                                                                 check_write_complete;
        logic                                                                 check_computing_complete;
        logic              [PE*DATA_WIDTH-1:0]                                check_output_PE;
        logic              [PE*MAX_INPUT_DIM-1:0]                             check_weights;
        logic              [PE*SIMD*DATA_WIDTH-1:0]                           check_current_weights;
        logic              [MAX_INPUT_DIM-1:0]                                check_input;
        logic              [SIMD*DATA_WIDTH-1:0]                              check_input_part;
        // logic              [2*DATA_WIDTH+$clog2(SIMD)-1:0]                    check_out_add;
        logic              [ACC_BIT_WIDTH-1:0]                                check_out_acc;
        logic signed [TEMP_DATA_WIDTH-1:0]                                    check_out_temp;
        //=================DEBUG====================
        //=================inputs=================
        logic 		                                                          clk;
        logic 		                                                          rst_n;
        logic                                                                 set_cfg;
        logic              [$clog2(NUM_ACTS_FUN):0]                           act_fun;
        logic                                                                 wr_en;
        logic                                                                 str_wr;
        logic                                                                 inp_rd;
        logic              [MAX_INPUT_DIM-1:0]                                inp_data;
        logic              [$clog2(MAX_CMP_QNT):0]                            computing_qnt;
        logic              [$clog2(PE):0]                                     pe_qnt;
        logic              [$clog2(MAX_WGT_QNT):0]                            weights_qnt;
        //=================outputs=================
        logic              [MAX_OUTPUT_DIM-1:0]                               out;
        logic                                                                 output_ready;
        logic                                                                 ready_to_receive;
        //=================SIMULATION===============
        int w [SIMD];

        //=================TASKS====================
        //Print the saved weights in a matrix for each PE
        task automatic print_weights_matrix;
            int p, w, s;
            logic [SIMD*DATA_WIDTH-1:0] wgt;
            logic [DATA_WIDTH-1:0] simd_val;
        begin
            $display("=========== WEIGHTS MEMORY ===========");
            for (p = 0; p < pe_qnt; p++) begin
                $write("PE[%0d]: ", p);
                for (w = 0; w < weights_qnt; w++) begin
                    // Extrai o peso completo (SIMD*DATA_WIDTH)
                    wgt = check_weights[ (p*MAX_INPUT_DIM) + (w*SIMD*DATA_WIDTH) +: SIMD*DATA_WIDTH ];
                    $write("W[%0d](", w);
                    // Quebra em SIMD
                    for (s = 0; s < SIMD; s++) begin
                        simd_val = wgt[s*DATA_WIDTH +: DATA_WIDTH];
                        if (s < SIMD-1)
                            $write("%0d,", $signed(simd_val));
                        else
                            $write("%0d", $signed(simd_val));
                    end
                    $write(")  ");
                end
                $write("\n");
            end
            $display("======================================");
        end
        endtask

        //Print the current saved weight selected by the weight_ind
        task automatic print_current_weights;
            int p, s;
            logic [SIMD*DATA_WIDTH-1:0] wgt;
            logic [DATA_WIDTH-1:0] simd_val;
        begin
            $display("======= CURRENT WEIGHTS (weights_ind) =======");
            for (p = 0; p < pe_qnt; p++) begin
                wgt = check_current_weights[
                        p*SIMD*DATA_WIDTH +: SIMD*DATA_WIDTH
                    ];
                $write("PE[%0d] W(", p);
                for (s = 0; s < SIMD; s++) begin
                    simd_val = wgt[s*DATA_WIDTH +: DATA_WIDTH];
                    if (s < SIMD-1)
                        $write("%0d,", $signed(simd_val));
                    else
                        $write("%0d", $signed(simd_val));
                end
                $write(")\n");
            end
            $display("============================================");
        end
        endtask

        //Print the PE's outputs
        task automatic print_output_pe;
            int p;
            logic [DATA_WIDTH-1:0] pe_out;
        begin
            $display("=========== PE OUTPUTS ===========");
            for (p = 0; p < pe_qnt; p++) begin
                pe_out = check_output_PE[p*DATA_WIDTH +: DATA_WIDTH];
                $display("PE[%0d] -> %0d", p, $signed(pe_out));
            end
            $display("==================================");
        end
        endtask

        //Print the outputs
        task automatic print_output;
            int p;
            logic [DATA_WIDTH-1:0] pe_out_final;
        begin
            $display("=========== OUTPUTS ===========");

            for (p = 0; p < pe_qnt; p++) begin
                pe_out_final = out[p*DATA_WIDTH +: DATA_WIDTH];
                $display("PE[%0d] -> %0d", p, $signed(pe_out_final));
            end

            $display("==================================");
        end
        endtask

        //Print the Data in
        task automatic print_inp_data;
            int s;
            logic [DATA_WIDTH-1:0] v;
        begin
            $write("inp_data = (");
            for (s = 0; s < SIMD; s++) begin
                v = inp_data[s*DATA_WIDTH +: DATA_WIDTH];
                if (s < SIMD-1)
                    $write("%0d, ", $signed(v));
                else
                    $write("%0d", $signed(v));
            end
            $write(")\n");
        end
        endtask

        //Print current input part
        task automatic print_current_input;
            int s;
            logic [DATA_WIDTH-1:0] v;
        begin
            $write("INPUT_PART = (");
            for (s = 0; s < SIMD; s++) begin
                v = check_input_part[s*DATA_WIDTH +: DATA_WIDTH];
                if (s < SIMD-1)
                    $write("%0d, ", $signed(v));
                else
                    $write("%0d", $signed(v));
            end
            $write(")\n");
        end
        endtask

        //set all inp_data to zero
        task automatic clear_inp_data;
        begin
            inp_data = '0;
        end
        endtask

        //task para carregar pesos
        task automatic load_weights_from_file;
            int scale_val;
            int simd_vals [SIMD];
        begin
            weight_file = $fopen("weights.txt", "r");
            if (weight_file == 0) begin
                $display("ERROR: Could not open weights.txt");
                $finish;
            end
            $display("\n=========== LOADING WEIGHTS ===========");
            wait (check_state == 1);
            @(posedge clk);
            while (!$feof(weight_file)) begin
                // ===============================
                // LEITURA DOS PESOS
                // ===============================
                for (int w = 0; w < weights_qnt; w++) begin
                    // lê SIMD valores
                    for (int s = 0; s < SIMD; s++) begin
                        r = $fscanf(weight_file, "%d", simd_vals[s]);
                    end
                    // monta inp_data apenas com pesos
                    inp_data = '0;
                    for (int s = 0; s < SIMD; s++) begin
                        inp_data[s*DATA_WIDTH +: DATA_WIDTH] = simd_vals[s];
                    end
                    str_wr = 1;
                    wr_en  = 1;
                    @(posedge clk);
                    wr_en  = 0;
                    str_wr = 0;
                    @(posedge clk);
                    $display("READING WEIGHTS");
                    $display("state=%0d", check_state);
                    $display("INPUT:"); print_inp_data();
                    print_weights_matrix();
                end
                // ===============================
                // LEITURA DO SCALE (1 valor só)
                // ===============================
                r = $fscanf(weight_file, "%d", scale_val);
                inp_data = '0;
                inp_data[M_INT_PRECISION-1:0] = scale_val;
                str_wr = 1;
                wr_en  = 1;
                @(posedge clk);
                wr_en  = 0;
                str_wr = 0;
                @(posedge clk);
                $display("READING SCALE");
                $display("state=%0d", check_state);
                $display("SCALE=%0d", scale_val);
            end
            $fclose(weight_file);
            $display("=========== FINISHED LOADING WEIGHTS ===========\n");
        end
        endtask


        task automatic run_inputs_from_file;
            int window_vals [WINDOW_SIZE];
            bit first_window;
        begin
            input_file = $fopen("input_windows.txt", "r");
            if (input_file == 0) begin
                $display("ERROR: Could not open input_windows.txt");
                $finish;
            end
            $display("\n=========== STARTING COMPUTATION ===========");
            str_wr <= 0;
            wr_en  <= 0;
            inp_rd <= 0;
            first_window = 1;
            while (!$feof(input_file)) begin
                //Só espera output_ready se NÃO for a primeira janela
                if (!first_window) begin
                    @(posedge clk);
                    wait (output_ready == 1);
                end
                first_window = 0;
                // Lê próxima janela
                for (int i = 0; i < WINDOW_SIZE; i++) begin
                    r = $fscanf(input_file, "%d", window_vals[i]);
                end
                // Envia em blocos SIMD
                inp_data = '0;
                for (int i = 0; i < WINDOW_SIZE; i++) begin
                    inp_data[i*DATA_WIDTH +: DATA_WIDTH] = window_vals[i];
                end
                // Pulso de 1 ciclo
                @(posedge clk);
                inp_rd <= 1;
                @(posedge clk);
                inp_rd <= 0;
                // // Envia em blocos SIMD
                // for (int base = 0; base < WINDOW_SIZE; base += SIMD) begin
                //     inp_data = '0;
                //     for (int s = 0; s < SIMD; s++) begin
                //         if ((base+s) < WINDOW_SIZE)
                //             inp_data[s*DATA_WIDTH +: DATA_WIDTH] = window_vals[base+s];
                //     end
                //     // Pulso de 1 ciclo
                //     @(posedge clk);
                //     inp_rd <= 1;
                //     @(posedge clk);
                //     inp_rd <= 0;
                // end
            end
            $fclose(input_file);
            $display("=========== FINISHED COMPUTATION ===========\n");
        end
        endtask


        //=================Clock generation=================
        initial clk = 0;
        always #1 clk = ~clk;  // 100MHz
        //=================Clock generation=================

        pe # (
            .MAX_CMP_QNT(MAX_CMP_QNT),
            .MAX_WGT_QNT(MAX_WGT_QNT),
            .DATA_WIDTH(DATA_WIDTH),
            .MAX_VAL(MAX_VAL),
            .MIN_VAL(MIN_VAL),
            .M_INT_PRECISION(M_INT_PRECISION),
            .PRECISION_CORRECTION(PRECISION_CORRECTION),
            .TEMP_DATA_WIDTH(TEMP_DATA_WIDTH),
            .ACC_BIT_WIDTH(ACC_BIT_WIDTH),
            .NUM_ACTS_FUN(NUM_ACTS_FUN),
            .SIMD(SIMD),
            .PE(PE),
            .MAX_INPUT_DIM(MAX_INPUT_DIM),
            .MAX_OUTPUT_DIM(MAX_OUTPUT_DIM)
        ) dut (
            //=================DEBUG====================
            .check_state(check_state),
            .check_next_state(check_next_state),
            .check_read_posx(check_read_posx),
            .check_read_posy(check_read_posy),
            .check_weight_ind(check_weight_ind),
            .check_write_complete(check_write_complete),
            .check_computing_complete(check_computing_complete),
            .check_output_PE(check_output_PE),
            .check_weights(check_weights),
            .check_PE_ind(check_PE_ind),
            .check_current_weights(check_current_weights),
            .check_input(check_input),
            .check_input_part(check_input_part),
            // .check_out_add(check_out_add),
            .check_out_acc(check_out_acc),
            .check_out_temp(check_out_temp),
            //=================DEBUG====================
            .clk(clk),
            .set_cfg(set_cfg),
            .rst_n(rst_n),
            .act_fun(act_fun),
            .wr_en(wr_en),
            .str_wr(str_wr),
            .inp_rd(inp_rd),
            .inp_data(inp_data),
            .computing_qnt(computing_qnt),
            .pe_qnt(pe_qnt),
            .weights_qnt(weights_qnt),
            .out(out),
            .output_ready(output_ready),
            .ready_to_receive(ready_to_receive)
        );

        always @(posedge clk) begin
            if (check_state>=3) begin
                $display("=========== COMPUTE STEP ===========");
                //print_inp_data();
                print_current_input();
                print_current_weights();
                $display("state=%0d", check_state);
                // $display("out_add=%0d", $signed(check_out_add));
                $display("out_acc=%0d", $signed(check_out_acc));
                $display("out_temp=%0d", $signed(check_out_temp));
                $display("computing complete=%0d", check_computing_complete);
                $display("PE_ind=%0d WGT_ind=%0d", dut.PE_ind, dut.weights_ind);
                $display("out_ready=%0d", output_ready);
                $display("ready_to_receive=%0d", ready_to_receive);
                $display("inp_ready=%0d", inp_rd);
                print_output_pe();
                print_output();
                $display("====================================\n");
            end
        end

        initial begin
            clear_inp_data();
            computing_qnt <= 1;
            pe_qnt        <= 6;
            weights_qnt   <= 1;
            act_fun       <= 0;
            inp_rd  <= 0;
            set_cfg <= 0;
            rst_n   <= 1;
            #5
            set_cfg <= 1;
            rst_n <= 0;
            #5;
            rst_n<=1;
            #5;
            str_wr<=1;
            load_weights_from_file();
            #5;
            str_wr<=0;
            run_inputs_from_file();
            $finish;
        end     
endmodule