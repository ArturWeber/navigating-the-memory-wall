`timescale 1ns/1ps

module tb_pe;

  // -------------------------------
  // Compile-time parameters (match DUT build)
  // -------------------------------
  parameter byte unsigned      MAX_CMP_QNT     = 8;
  parameter shortint unsigned  MAX_WGT_QNT     = 8;
  parameter shortint unsigned  SIMD            = 64;
  parameter shortint unsigned  PE              = 16;
  parameter byte unsigned      DATA_WIDTH      = 8;

  // MUST match DUT's MAX_INPUT_DIM / MAX_OUTPUT_DIM
  // IMPORTANT: must be large enough for computing_qnt*SIMD lanes.
  // Example: CIN=16,K=3 => dot_len=144, SIMD=64 => computing_qnt=3 => 192 lanes
  parameter int unsigned       MAX_INPUT_DIM   = 192 * DATA_WIDTH;
  parameter int unsigned       MAX_OUTPUT_DIM  = PE * DATA_WIDTH;

  parameter byte unsigned      ACC_BIT_WIDTH   = 32;
  parameter byte unsigned      M_INT_PRECISION = 32;
  parameter longint signed     PRECISION_CORRECTION = 1 << (M_INT_PRECISION-1);
  parameter byte unsigned      TEMP_DATA_WIDTH = ACC_BIT_WIDTH + M_INT_PRECISION + 1;
  parameter byte unsigned      NUM_ACTS_FUN    = 2;

  parameter shortint           MAX_VAL = (1 <<< (DATA_WIDTH-1)) - 1;
  parameter shortint           MIN_VAL = -(1 <<< (DATA_WIDTH-1));

  // -------------------------------
  // File handles + paths (module scope)
  // -------------------------------
  integer weight_file;
  integer input_file;
  integer exp_file;
  int r;

  string weights_path;
  string inputs_path;
  string expected_path;

  // -------------------------------
  // Runtime-configurable knobs
  // -------------------------------
  int CIN     = 16;
  int KX      = 3;
  int KY      = 3;
  int NIN     = 10;
  int PEQ_INT = 6;
  string VEC_DIR = ".";

  int DOT_LEN;
  int COMPUTING_QNT_INT;

  // -------------------------------
  // DUT inputs
  // -------------------------------
  logic clk;
  logic rst_n;
  logic set_cfg;
  logic [$clog2(NUM_ACTS_FUN):0] act_fun;
  logic wr_en;
  logic str_wr;
  logic inp_rd;
  logic [MAX_INPUT_DIM-1:0] inp_data;
  logic [$clog2(MAX_CMP_QNT):0] computing_qnt;
  logic [$clog2(PE):0] pe_qnt;
  logic [$clog2(MAX_WGT_QNT):0] weights_qnt;

  // DUT outputs
  logic [MAX_OUTPUT_DIM-1:0] out;
  logic output_ready;
  logic ready_to_receive;

  // -------------------------------
  // DEBUG signals (must exist in DUT, else remove from instantiation)
  // -------------------------------
  int unsigned check_state, check_next_state;
  int unsigned check_read_posx, check_read_posy;
  int unsigned check_weight_ind, check_PE_ind;
  logic check_write_complete, check_computing_complete;
  logic [PE*MAX_INPUT_DIM-1:0] check_weights;
  logic [PE*SIMD*DATA_WIDTH-1:0] check_current_weights;
  logic [PE*DATA_WIDTH-1:0] check_output_PE;
  logic [MAX_INPUT_DIM-1:0] check_input;
  logic [SIMD*DATA_WIDTH-1:0] check_input_part;
  logic [ACC_BIT_WIDTH-1:0] check_out_acc;
  logic signed [TEMP_DATA_WIDTH-1:0] check_out_temp;

  // -------------------------------
  // Clock generation
  // -------------------------------
  initial clk = 0;
  always #1 clk = ~clk;

  // -------------------------------
  // Helpers
  // -------------------------------
  task automatic clear_inp_data;
    inp_data = '0;
  endtask

  function automatic int ceil_div(int a, int b);
    return (a + b - 1) / b;
  endfunction

  // -------------------------------
  // DUT instance
  // -------------------------------
  pe #(
    .MAX_CMP_QNT(MAX_CMP_QNT),
    .MAX_WGT_QNT(MAX_WGT_QNT),
    .DATA_WIDTH(DATA_WIDTH),
    .MAX_VAL(MAX_VAL),
    .MIN_VAL(MIN_VAL),
    .ACC_BIT_WIDTH(ACC_BIT_WIDTH),
    .M_INT_PRECISION(M_INT_PRECISION),
    .PRECISION_CORRECTION(PRECISION_CORRECTION),
    .TEMP_DATA_WIDTH(TEMP_DATA_WIDTH),
    .NUM_ACTS_FUN(NUM_ACTS_FUN),
    .SIMD(SIMD),
    .PE(PE),
    .MAX_INPUT_DIM(MAX_INPUT_DIM),
    .MAX_OUTPUT_DIM(MAX_OUTPUT_DIM)
  ) dut (
    // =============== DEBUG (remove if DUT doesn't have them) ===============
    .check_state(check_state),
    .check_next_state(check_next_state),
    .check_read_posx(check_read_posx),
    .check_read_posy(check_read_posy),
    .check_weight_ind(check_weight_ind),
    .check_PE_ind(check_PE_ind),
    .check_write_complete(check_write_complete),
    .check_computing_complete(check_computing_complete),
    .check_weights(check_weights),
    .check_current_weights(check_current_weights),
    .check_output_PE(check_output_PE),
    .check_input(check_input),
    .check_input_part(check_input_part),
    .check_out_acc(check_out_acc),
    .check_out_temp(check_out_temp),
    // =============== DUT ports ===============
    .rst_n(rst_n),
    .clk(clk),
    .set_cfg(set_cfg),
    .act_fun(act_fun),
    .wr_en(wr_en),
    .str_wr(str_wr),
    .inp_rd(inp_rd),
    .inp_data(inp_data),
    .computing_qnt(computing_qnt),
    .weights_qnt(weights_qnt),
    .pe_qnt(pe_qnt),
    .out(out),
    .output_ready(output_ready),
    .ready_to_receive(ready_to_receive)
  );

  // -------------------------------
  // Load weights:
  // weights.txt format expected:
  // For p=0..pe_qnt-1:
  //   for fold=0..weights_qnt-1: line with SIMD ints
  //   then 1 line with Mint (scale)
  // -------------------------------
  task automatic load_weights_from_file(string path);
    int simd_vals [SIMD];
    int scale_val;
  begin
    weight_file = $fopen(path, "r");
    if (weight_file == 0) begin
      $display("ERROR: Could not open %s", path);
      $fatal(1);
    end

    $display("\n[TB] Loading weights from %s", path);

    // Ensure we are in writing state (state==1 in your enum)
    wait (check_state == 1);
    @(posedge clk);

    for (int p = 0; p < pe_qnt; p++) begin
      for (int fold = 0; fold < weights_qnt; fold++) begin

        for (int s = 0; s < SIMD; s++) begin
          r = $fscanf(weight_file, "%d", simd_vals[s]);
          if (r != 1) begin
            $display("ERROR: weights file ended early p=%0d fold=%0d s=%0d", p, fold, s);
            $fatal(1);
          end
        end

        inp_data = '0;
        for (int s = 0; s < SIMD; s++) begin
          inp_data[s*DATA_WIDTH +: DATA_WIDTH] = simd_vals[s][DATA_WIDTH-1:0];
        end

        str_wr = 1;
        wr_en  = 1;
        @(posedge clk);
        wr_en  = 0;
        str_wr = 0;
        @(posedge clk);
      end

      // Mint (scale)
      r = $fscanf(weight_file, "%d", scale_val);
      if (r != 1) begin
        $display("ERROR: missing scale line for output p=%0d", p);
        $fatal(1);
      end

      $display("[TB] Loaded scale(Mint) for p=%0d = %0d (0x%0h)", p, scale_val, scale_val);

      // Print the first 12 lanes of the *last fold read* (or just print fold 0 earlier)
      $write("[TB] Last loaded weight fold first 12 lanes: ");
      for (int i = 0; i < 12; i++) begin
        $write("%0d ", simd_vals[i]);
      end
      $write("\n");

      inp_data = '0;
      inp_data[M_INT_PRECISION-1:0] = scale_val[M_INT_PRECISION-1:0];

      str_wr = 1;
      wr_en  = 1;
      @(posedge clk);
      wr_en  = 0;
      str_wr = 0;
      @(posedge clk);
    end

    $fclose(weight_file);
    $display("[TB] Weights loaded.\n");
  end
  endtask

  // -------------------------------
  // Run + check:
  // inputs.txt format expected:
  // For t=0..NIN-1:
  //   for fold=0..computing_qnt-1: line with SIMD ints
  //
  // expected.txt format:
  // For t=0..NIN-1:
  //   1 line with pe_qnt ints (expected out bytes)
  // -------------------------------
  task automatic run_and_check(string in_path, string exp_path, int nin);
    int simd_vals [SIMD];
    int exp_vals  [PE];
    logic signed [DATA_WIDTH-1:0] dut_val;
  begin
    input_file = $fopen(in_path, "r");
    if (input_file == 0) begin
      $display("ERROR: Could not open %s", in_path);
      $fatal(1);
    end

    exp_file = $fopen(exp_path, "r");
    if (exp_file == 0) begin
      $display("ERROR: Could not open %s", exp_path);
      $fatal(1);
    end

    $display("[TB] Running %0d inputs from %s, checking vs %s", nin, in_path, exp_path);

    for (int t = 0; t < nin; t++) begin
      // wait until DUT says ready for new input
      wait (ready_to_receive == 1);
      @(posedge clk);

      // pack full inp_data across folds (build next vector first)
      inp_data = '0;
      for (int fold = 0; fold < computing_qnt; fold++) begin
        for (int s = 0; s < SIMD; s++) begin
          r = $fscanf(input_file, "%d", simd_vals[s]);
          if (r != 1) begin
            $display("ERROR: inputs file ended early t=%0d fold=%0d s=%0d", t, fold, s);
            $fatal(1);
          end
        end
        for (int s = 0; s < SIMD; s++) begin
          int lane = fold*SIMD + s;
          inp_data[lane*DATA_WIDTH +: DATA_WIDTH] = simd_vals[s][DATA_WIDTH-1:0];
        end
      end

      // Wait until DUT ready, then assert inp_rd aligned to a clock edge
      wait (ready_to_receive == 1);
      @(posedge clk);
      inp_rd <= 1;

      // Keep inp_rd asserted for exactly 1 cycle
      @(posedge clk);
      inp_rd <= 0;

      // wait for output
      wait (output_ready == 1);      
      @(posedge clk); // give DUT a full cycle to transition back to ready

      $write("[TB] Latched input first 16 lanes: ");
      for (int i=0; i<16; i++) begin
        logic signed [DATA_WIDTH-1:0] v;
        v = check_input[i*DATA_WIDTH +: DATA_WIDTH];
        $write("%0d ", $signed(v));
      end
      $write("\n");

      // read expected outputs for this input
      for (int p = 0; p < pe_qnt; p++) begin
        r = $fscanf(exp_file, "%d", exp_vals[p]);
        if (r != 1) begin
          $display("ERROR: expected file ended early t=%0d p=%0d", t, p);
          $fatal(1);
        end
      end

      // compare
      for (int p = 0; p < pe_qnt; p++) begin
        dut_val = out[p*DATA_WIDTH +: DATA_WIDTH];
        if ($signed(dut_val) !== exp_vals[p]) begin
          $display("\n==== MISMATCH ====");
          $display("t=%0d p=%0d", t, p);
          $display("DUT out = %0d (0x%0h)", $signed(dut_val), dut_val);
          $display("EXP out = %0d", exp_vals[p]);
          $display("Raw out bus = 0x%0h", out);
          $display("cfg: CIN=%0d KX=%0d KY=%0d DOT_LEN=%0d SIMD=%0d computing_qnt=%0d pe_qnt=%0d",
                   CIN, KX, KY, DOT_LEN, SIMD, computing_qnt, pe_qnt);
          $display("state=%0d weight_ind=%0d PE_ind=%0d out_acc=%0d out_temp=%0d",
                   check_state, check_weight_ind, check_PE_ind, $signed(check_out_acc), $signed(check_out_temp));
          $display("==============\n");
                    $display("DUT vector:");
          for (int pp = 0; pp < pe_qnt; pp++) begin
            logic signed [DATA_WIDTH-1:0] v;
            v = out[pp*DATA_WIDTH +: DATA_WIDTH];
            $display("  p=%0d -> %0d (0x%0h)", pp, $signed(v), v);
          end

          $display("EXP vector:");
          for (int pp = 0; pp < pe_qnt; pp++) begin
            $display("  p=%0d -> %0d", pp, exp_vals[pp]);
          end
          $fatal(1);
        end
      end

      $display("[TB] PASS t=%0d", t);
    end

    $fclose(input_file);
    $fclose(exp_file);
    $display("\n[TB] ALL TESTS PASSED.\n");
  end
  endtask

  // -------------------------------
  // Main
  // -------------------------------
  initial begin
    // Parse plusargs
    if (!$value$plusargs("CIN=%d", CIN)) CIN = 16;
    if (!$value$plusargs("KX=%d", KX))   KX  = 3;
    if (!$value$plusargs("KY=%d", KY))   KY  = 3;
    if (!$value$plusargs("NIN=%d", NIN)) NIN = 10;
    if (!$value$plusargs("PEQ=%d", PEQ_INT)) PEQ_INT = 6;
    void'($value$plusargs("VEC_DIR=%s", VEC_DIR));

    DOT_LEN = CIN * KX * KY;
    COMPUTING_QNT_INT = ceil_div(DOT_LEN, SIMD);

    // Drive config to DUT
    computing_qnt <= COMPUTING_QNT_INT[$bits(computing_qnt)-1:0];
    weights_qnt   <= COMPUTING_QNT_INT[$bits(weights_qnt)-1:0];
    pe_qnt        <= PEQ_INT[$bits(pe_qnt)-1:0];
    act_fun       <= 0;

    // Init signals
    wr_en   <= 0;
    str_wr  <= 0;
    inp_rd  <= 0;
    set_cfg <= 0;
    rst_n   <= 1;
    clear_inp_data();

    $display("[TB] CIN=%0d KX=%0d KY=%0d DOT_LEN=%0d SIMD=%0d => computing_qnt=%0d; pe_qnt=%0d; NIN=%0d; VEC_DIR=%s",
             CIN, KX, KY, DOT_LEN, SIMD, COMPUTING_QNT_INT, PEQ_INT, NIN, VEC_DIR);

    // Reset / cfg sequence (kept from your style)
    #5 set_cfg <= 1;
    rst_n <= 0;
    #5 rst_n <= 1;
    #5;

    // Enter writing state and load weights
    str_wr <= 1;

    weights_path  = {VEC_DIR, "/weights.txt"};
    inputs_path   = {VEC_DIR, "/inputs.txt"};
    expected_path = {VEC_DIR, "/expected.txt"};

    load_weights_from_file(weights_path);
    str_wr <= 0;

    // Run and check
    run_and_check(inputs_path, expected_path, NIN);

    $finish;
  end

endmodule