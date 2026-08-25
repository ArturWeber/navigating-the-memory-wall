// ==============================================================
//               Projeto de Formatura I - SCC0670               
//                                                              
//       Name: Artur Brenner Weber                              
//       Last Update: 26/5/2026                                 
//                                                              
//   Based on Testbench written by Eduardo Sperle Honorato.    
//   This is the Testbench used to test the Matrix-Vector Unit (MVU), 
//   as well as simulate memory behavior and measure performance metrics. 
// ==============================================================

`timescale 1ns/1ps
`include "rtl_cfg.svh"

module tb_pe;

  // -------------------------------
  // Compile-time parameters (match DUT build)
  // -------------------------------
  parameter shortint unsigned  SIMD            = `SIMD;
  parameter shortint unsigned  PE              = `PE;
  parameter byte unsigned      DATA_WIDTH      = `DATA_WIDTH;

  parameter byte unsigned      ACC_BIT_WIDTH   = 32;
  parameter byte unsigned      M_INT_PRECISION = 32;
  parameter longint signed     PRECISION_CORRECTION = 1 << (M_INT_PRECISION-1);
  parameter byte unsigned      TEMP_DATA_WIDTH = ACC_BIT_WIDTH + M_INT_PRECISION + 1;

  parameter byte unsigned      NUM_ACTS_FUN    = 2;
  parameter int unsigned       ACT_FUN_SEL     = 1;

  localparam int unsigned      W_ACT = (NUM_ACTS_FUN <= 1) ? 1 : $clog2(NUM_ACTS_FUN);

  parameter shortint           MAX_VAL = (1 <<< (DATA_WIDTH-1)) - 1;
  parameter shortint           MIN_VAL = -(1 <<< (DATA_WIDTH-1));

  parameter shortint unsigned  MAX_CHANNELS = `MAX_CHANNELS;
  parameter shortint unsigned  KERNEL_X = `KERNEL_X;
  parameter shortint unsigned  KERNEL_Y = `KERNEL_Y;
  parameter int unsigned       MAX_DOT_LANES = MAX_CHANNELS*KERNEL_X*KERNEL_Y;
  parameter int unsigned       MAX_FOLDS = (MAX_DOT_LANES + SIMD - 1) / SIMD;

  parameter int unsigned       PAD_LANES = MAX_FOLDS * SIMD;
  parameter int unsigned       MAX_INPUT_DIM   = PAD_LANES * DATA_WIDTH;
  parameter int unsigned       MAX_OUTPUT_DIM  = PE * DATA_WIDTH;

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
  int NIN     = 1000;
  int PEQNT   = 16;
  string VEC_DIR = ".";

  int DOT_LEN;
  int FOLD_QNT_INT;

  // -------------------------------
  // Memory-model knobs (absolute time, then converted to cycles using FCLK)
  // -------------------------------
  real FCLK_HZ   = 1.0e9;     // accelerator frequency (Hz)
  real MEM_B_GBPS = 30.0;     // bandwidth in GB/s (decimal, 1 GB = 1e9 bytes)
  real MEM_L_S    = 2.0e-9;   // latency in seconds

  // -------------------------------
  // DUT inputs
  // -------------------------------
  logic clk;
  logic rst_n;
  logic set_cfg_n;                 // active-low in DUT
  logic [W_ACT-1:0] act_fun;
  logic wr_en;
  logic str_wr;
  logic inp_rd;
  logic [MAX_INPUT_DIM-1:0] inp_data;

  logic [$clog2(MAX_FOLDS+1)-1:0] fold_qnt;
  logic [$clog2(PE+1)-1:0] pe_qnt;

  // DUT outputs
  logic [MAX_OUTPUT_DIM-1:0] out;
  logic output_ready;
  logic ready_to_receive;

  // -------------------------------
  // DEBUG signals
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

  // --------------------------------------------------------
  // VCD dump for power (will be converted to SAIF via vcd2saif)
  // --------------------------------------------------------
  initial begin
    $display("[TB] Dumping VCD activity to work/dut.vcd ...");
    $dumpfile("work/dut.vcd");
    $dumpvars(0, tb_pe);
  end

  // -------------------------------
  // Clock generation
  // -------------------------------
  // IMPORTANT: This TB generates a clock derived from 
  // FCLK_HZ so the cycle counts and the memory-model math
  // match the simulated clock.
  //
  // timescale is 1ns/1ps, so:
  //   period_ns = 1e9 / FCLK_HZ
  //   half_period_ns = period_ns / 2
  // -------------------------------
  real CLK_PERIOD_NS;
  real CLK_HALF_NS;

  initial begin
    clk = 0;
    // default before plusargs are parsed; will be recomputed later too
    CLK_PERIOD_NS = 1.0e9 / FCLK_HZ;
    CLK_HALF_NS   = CLK_PERIOD_NS / 2.0;
    forever begin
      #(CLK_HALF_NS) clk = ~clk;
    end
  end

  // -------------------------------
  // Helpers
  // -------------------------------
  task automatic clear_inp_data;
    inp_data = '0;
  endtask

  function automatic int ceil_div_int(int a, int b);
    return (a + b - 1) / b;
  endfunction

  // ceil(x) for real -> int
  function automatic int ceil_real_to_int(real x);
    int xi;
    xi = $rtoi(x);
    if (x > xi) return xi + 1;
    else return xi;
  endfunction

  // Convert seconds to cycles with ceil
  function automatic int sec_to_cycles(real t_s, real f_hz);
    return ceil_real_to_int(t_s * f_hz);
  endfunction

  // -------------------------------
  // DUT instance
  // -------------------------------
  pe #(
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
    .rst_n(rst_n),
    .clk(clk),
    .set_cfg_n(set_cfg_n),
    .act_fun(act_fun),
    .wr_en(wr_en),
    .str_wr(str_wr),
    .inp_rd(inp_rd),
    .inp_data(inp_data),
    .fold_qnt(fold_qnt),
    .pe_qnt(pe_qnt),
    .out(out),
    .output_ready(output_ready),
    .ready_to_receive(ready_to_receive)
  );

  // -------------------------------
  // Load weights (no memory model here)
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

    // Keep wr_en asserted to stream at 1 beat per cycle
    wr_en = 1;

    // Stream folds for all PEs
    for (int p = 0; p < pe_qnt; p++) begin
      for (int fold = 0; fold < fold_qnt; fold++) begin

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

        @(posedge clk);
      end
    end

    // Final Mint (one per layer)
    r = $fscanf(weight_file, "%d", scale_val);
    if (r != 1) begin
      $display("ERROR: missing final Mint line (one per layer)");
      $fatal(1);
    end

    $display("[TB] Loaded layer scale(Mint) = %0d (0x%0h)", scale_val, scale_val);

    // Make the scale beat explicit and synchronous
    inp_data = '0;
    inp_data[M_INT_PRECISION-1:0] = scale_val[M_INT_PRECISION-1:0];
    
    // Keep wr_en high through the sampling edge
    wr_en = 1; 
    @(posedge clk);  // DUT samples scale here

    // Now drop wr_en and clear inp_data
    wr_en = 0;
    inp_data = '0;

    $fclose(weight_file);
    $display("[TB] Weights loaded.\n");
  end
  endtask

  // -------------------------------
  // Run + check + memory model
  // -------------------------------
  task automatic run_and_check(string in_path, string exp_path, int nin);
    int simd_vals [SIMD];
    int exp_vals  [PE];
    logic signed [DATA_WIDTH-1:0] dut_val;
    logic [MAX_OUTPUT_DIM-1:0] out_sample;

    // Timing counters
    longint unsigned cycle_ctr;
    longint unsigned start_cycle;
    longint unsigned done_cycle;

    // Memory model per input
    int s_in_bytes;
    real Tmem_s;
    int Tmem_c;
    int Tidle_c;
    int Tcomp_c;
    int Tcomp_prev_c;
    int Tmem_BW_c;
    int Tmem_L_c;

    real ops_per_input;
    real macs_per_input;
    real gops_t;
    real gmacs_t;
    real oi_gop;
    real oi_gmac;
    real Tmem_BW_s;
    real Tmem_L_s;

  begin
    Tcomp_prev_c = 0;

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

    cycle_ctr = 0;

    // Cycle counter (local to this task)
    fork
      begin
        forever begin
          @(posedge clk);
          cycle_ctr++;
        end
      end
    join_none

    $display("[TB] Running %0d inputs from %s, checking vs %s", nin, in_path, exp_path);
    $display("[TB][MEM] FCLK_HZ=%g MEM_L_S=%g MEM_B_GBPS=%g", FCLK_HZ, MEM_L_S, MEM_B_GBPS);

    // bytes transferred per input (includes padding)
    s_in_bytes = FOLD_QNT_INT * SIMD * (DATA_WIDTH/8);

    for (int t = 0; t < nin; t++) begin

      // Pack full inp_data across folds *before* waiting
      inp_data = '0;
      for (int fold = 0; fold < fold_qnt; fold++) begin
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

      // --- Memory model (serialized): wait Tmem_c cycles before issuing inp_rd ---
      // Tmem_s = L + s/B
      Tmem_s = MEM_L_S + (real'(s_in_bytes) / (MEM_B_GBPS * 1.0e9));
      Tmem_c = sec_to_cycles(Tmem_s, FCLK_HZ);
      Tmem_L_s = MEM_L_S;
      Tmem_L_c = sec_to_cycles(Tmem_L_s, FCLK_HZ);
      Tmem_BW_s = real'(s_in_bytes) / (MEM_B_GBPS * 1.0e9);
      Tmem_BW_c = sec_to_cycles(Tmem_BW_s, FCLK_HZ);

      // wait until DUT ready
      do @(posedge clk); while (ready_to_receive !== 1);

      // Inject idle cycles to emulate memory fetch time (overlap version)
      Tidle_c = (Tmem_c > Tcomp_prev_c) ? (Tmem_c - Tcomp_prev_c) : 0;
      repeat (Tidle_c) @(posedge clk);

      // Issue input: make it a clean 1-cycle pulse aligned to posedge
      inp_rd <= 1'b1;
      start_cycle = cycle_ctr;
      @(posedge clk);
      inp_rd <= 1'b0;

      // Wait for a clock edge where output_ready is high
      do @(posedge clk); while (output_ready !== 1);
      out_sample = out;
      done_cycle = cycle_ctr;

      Tcomp_c = int'(done_cycle - start_cycle);
      Tcomp_prev_c = Tcomp_c;

      // Calculate instantaneous performance for this specific input
      // Ops = PEs * (2 * SIMD * fold_qnt) | MACs = PEs * SIMD * fold_qnt
      ops_per_input  = real'(pe_qnt) * ((2.0 * real'(SIMD) * real'(fold_qnt)) + 3.0); // +3 for scaling
      macs_per_input = real'(pe_qnt) * real'(SIMD) * real'(fold_qnt);

      // GOPS = (Ops / 1e9) / (Cycles_this_input / FCLK_HZ)
      gops_t  = (ops_per_input / 1.0e9) / (real'(Tidle_c + Tcomp_c) / FCLK_HZ);
      gmacs_t = (macs_per_input / 1.0e9) / (real'(Tidle_c + Tcomp_c) / FCLK_HZ);

      // Calculates Operational Intensity
      oi_gop  = ops_per_input / real'(s_in_bytes);
      oi_gmac = macs_per_input / real'(s_in_bytes);

      $display("[TB][t=%0d] Tbw_s= %gs Tl_s= %gs Tbw_c= %0d Tl_c= %0d Tmem=%0d Tidle=%0d Tcomp=%0d | %g GOP/s | %g GMAC/s | %g OP/Byte | %g MAC/Byte",
               t, Tmem_BW_s, Tmem_L_s, Tmem_BW_c, Tmem_L_c, Tmem_c, Tidle_c, Tcomp_c, gops_t, gmacs_t, oi_gop, oi_gmac);

      for (int p = 0; p < pe_qnt; p++) begin
        r = $fscanf(exp_file, "%d", exp_vals[p]);
        if (r != 1) begin
          $display("ERROR: expected file ended early t=%0d p=%0d", t, p);
          $fatal(1);
        end
      end

      for (int p = 0; p < pe_qnt; p++) begin
        // Slice the specific PE's result out of the 1D bus
        dut_val = out_sample[p*DATA_WIDTH +: DATA_WIDTH]; 
        
        if ($signed(dut_val) !== exp_vals[p]) begin
          $display("\n==== MISMATCH ====");
          $display("t=%0d p=%0d", t, p);
          $display("DUT out = %0d (0x%0h)", $signed(dut_val), dut_val);
          $display("EXP out = %0d", exp_vals[p]);
          $display("Raw out bus = 0x%0h", out); // We can print the raw bus again!
          $display("cfg: CIN=%0d KX=%0d KY=%0d DOT_LEN=%0d SIMD=%0d fold_qnt=%0d pe_qnt=%0d act_fun=%0d",
                   CIN, KX, KY, DOT_LEN, SIMD, fold_qnt, pe_qnt, act_fun);
          $display("state=%0d weight_ind=%0d PE_ind=%0d out_acc=%0d out_temp=%0d",
                   check_state, check_weight_ind, check_PE_ind, $signed(check_out_acc), $signed(check_out_temp));
          $display("==============\n");
          $fatal(1);
        end
      end

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
    if (!$value$plusargs("CIN=%d", CIN)) CIN = 16;
    if (!$value$plusargs("KX=%d", KX))   KX  = 3;
    if (!$value$plusargs("KY=%d", KY))   KY  = 3;
    if (!$value$plusargs("NIN=%d", NIN)) NIN = 10;
    if (!$value$plusargs("PEQNT=%d", PEQNT)) PEQNT = 6;
    void'($value$plusargs("VEC_DIR=%s", VEC_DIR));

    // Memory-model plusargs (all optional)
    void'($value$plusargs("FCLK_HZ=%f", FCLK_HZ));
    void'($value$plusargs("MEM_B_GBPS=%f", MEM_B_GBPS));
    void'($value$plusargs("MEM_L_S=%f", MEM_L_S));

    // Recompute sim clock after FCLK plusarg is known
    CLK_PERIOD_NS = 1.0e9 / FCLK_HZ;
    CLK_HALF_NS   = CLK_PERIOD_NS / 2.0;

    DOT_LEN = CIN * KX * KY;
    FOLD_QNT_INT = ceil_div_int(DOT_LEN, SIMD);

    // Initial stable state (Time 0)
    fold_qnt = FOLD_QNT_INT[$bits(fold_qnt)-1:0];
    pe_qnt   = PEQNT[$bits(pe_qnt)-1:0];
    act_fun  = ACT_FUN_SEL[W_ACT-1:0];

    wr_en     = 0;
    str_wr    = 0;
    inp_rd    = 0;
    set_cfg_n = 1; // Keep config disabled initially
    rst_n     = 0; // Assert reset initially
    clear_inp_data();

    $display("[TB] CIN=%0d KX=%0d KY=%0d DOT_LEN=%0d SIMD=%0d => fold_qnt=%0d; pe_qnt=%0d; NIN=%0d; VEC_DIR=%s; ACT_FUN_SEL=%0d",
            CIN, KX, KY, DOT_LEN, SIMD, FOLD_QNT_INT, PEQNT, NIN, VEC_DIR, ACT_FUN_SEL);

    // Hold reset for a few cycles to clear all DUT registers
    repeat (2) @(posedge clk);
    rst_n = 1; // Release reset
    
    // Give it one cycle of breathing room after reset
    @(posedge clk);

    // Strobe the Config (Inputs have been stable for 3 cycles now)
    set_cfg_n = 0; 
    @(posedge clk); // DUT cleanly samples fold_qnt and pe_qnt right here
    
    set_cfg_n = 1;  // Lock it in
    @(posedge clk);

    // Force DUT into writing state
    str_wr <= 1;
    wait (check_state == 1); // Wait for FSM to enter 'writing'
    @(posedge clk);

    weights_path  = {VEC_DIR, "/weights.txt"};
    inputs_path   = {VEC_DIR, "/inputs.txt"};
    expected_path = {VEC_DIR, "/expected.txt"};

    load_weights_from_file(weights_path);

    // Wait until DUT says weights are complete before dropping str_wr
    wait (check_write_complete == 1);
    @(posedge clk);
    str_wr <= 0;

    // Optional but safe: wait for DUT to transition to 'ready' state
    wait (check_state == 2);
    @(posedge clk);

    run_and_check(inputs_path, expected_path, NIN);

    $finish;
  end

endmodule
