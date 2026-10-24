`timescale 1ns/1ps
/**********************************************
* Module Name        : tb_programmable_spi
* Authors            : Ryan Karami, Saahas Swaroop
* Discord Usernames  : soupchef_, shilo11
* Creation Date      : 10/8/2026
* Description        : spi testbench. uses a slave model to simulate functionality. 3 directed test cases.
**********************************************/
module tb_programmable_spi;

  localparam logic [31:0] TEST3_WORD       = 32'h1234_5678;  // word sent in test 3
  localparam logic [31:0] TEST3_SLAVE_WORD = 32'h8765_4321;  // word slave returns

  // Register addresses
  localparam logic [4:0] CONFIG = 5'h00, CHIP_SELECT = 5'h04, TX_DATA = 5'h08,
                         RX_DATA = 5'h0C, STATUS = 5'h10, IRQ_ENABLE = 5'h14;
  // STATUS bits
  localparam int BUSY = 0, TX_FULL = 1, TX_EMPTY = 2, RX_FULL = 3, RX_EMPTY = 4,
                 DONE = 5, CONFIG_PENDING = 6, ERROR = 7;
  // IRQ_ENABLE bits
  localparam logic [31:0] IRQ_DONE = 32'h1, IRQ_TX_EMPTY = 32'h2,
                          IRQ_RX_AVAIL = 32'h4, IRQ_ERROR = 32'h8;


  logic        clk = 0, rstn = 0;
  logic        enable = 0, write_enable = 0;
  logic [4:0]  address = 0;
  logic [31:0] write_data = 0, read_data;
  logic        read_valid, irq, sclk, mosi, miso = 0;
  logic [3:0]  cs_n;
  int          test_num = 0;

  always #5 clk = ~clk;                        // 100 MHz

  programmable_spi dut (
    .clk_i(clk), 
    .rstn_i(rstn),
    .enable_i(enable), 
    .write_enable_i(write_enable), 
    .address_i(address),
    .write_data_i(write_data), 
    .read_data_o(read_data), 
    .read_valid_o(read_valid),
    .interrupt_request_o(irq),
    .sclk_o(sclk), 
    .chip_select_n_o(cs_n), 
    .mosi_o(mosi), 
    .miso_i(miso)
  );


  //SPI SLAVE MODEL (on CS0)

  logic [31:0] slave_send[$], slave_got[$];
  int          slave_bits = 32;
  logic        slave_cpol = 0, slave_cpha = 0;
  logic [31:0] s_out, s_in;
  int          s_bit;

  function automatic logic [31:0] next_slave_word();
    if (slave_send.size() != 0) return slave_send.pop_front();
    else                        return 32'h0;
  endfunction

  always @(negedge cs_n[0]) begin              // selected
    s_bit = 0; s_in = 0;
    if (!slave_cpha) begin                     // CPHA=0: first bit out before 1st edge
      s_out = next_slave_word();
      miso  = s_out[slave_bits-1];
    end
  end

  always @(sclk) if (!cs_n[0]) begin
    if (sclk != slave_cpol) begin              // ---- leading edge
      if (!slave_cpha)
        s_in = {s_in[30:0], mosi};             // CPHA=0: sample
      else begin                               // CPHA=1: drive
        if (s_bit == 0) s_out = next_slave_word();
        miso = s_out[slave_bits-1-s_bit];
      end
    end else begin                             // ---- trailing edge
      if (slave_cpha) s_in = {s_in[30:0], mosi};   // CPHA=1: sample
      s_bit++;
      if (s_bit == slave_bits) begin           // word complete
        slave_got.push_back(s_in);
        s_in = 0; s_bit = 0;
        if (!slave_cpha) s_out = next_slave_word();
      end
      if (!slave_cpha) miso = s_out[slave_bits-1-s_bit];  // CPHA=0: drive
    end
  end

  task automatic write_reg(input logic [4:0] a, input logic [31:0] d);
    @(negedge clk); enable = 1; write_enable = 1; address = a; write_data = d;
    @(negedge clk); enable = 0; write_enable = 0;
  endtask

  task automatic read_reg(input logic [4:0] a, output logic [31:0] d);
    @(negedge clk); enable = 1; write_enable = 0; address = a;
    @(negedge clk); enable = 0;
    d = read_data;
  endtask

  task automatic read_status(output logic [31:0] s);
    read_reg(STATUS, s);
  endtask


  task automatic setup(input int ratio, input int bits, input int mode);
    logic [31:0] c;
    c       = 32'h0;
    c[21]   = 1'b1;
    c[20:5] = ratio;
    c[4:3]  = (bits == 4) ? 2'b00 : (bits == 8) ? 2'b01 : (bits == 16) ? 2'b10 : 2'b11;
    c[1]    = mode[1];                         // CPOL
    c[0]    = mode[0];                         // CPHA
    write_reg(CHIP_SELECT, 4'hF);
    write_reg(CONFIG, c);
    slave_bits = bits;
    slave_cpol = mode[1];
    slave_cpha = mode[0];
  endtask

  // ---- chip select
  task automatic select(input int dev);        // dev 0..3, slave model is on 0
    write_reg(CHIP_SELECT, 4'hF & ~(4'h1 << dev));
  endtask

  task automatic deselect();
    write_reg(CHIP_SELECT, 4'hF);
  endtask

  // ---- data
  task automatic slave_load(input logic [31:0] w);   // word the slave will send
    slave_send.push_back(w);
  endtask

  task automatic send_word(input logic [31:0] w);    // waits if TX FIFO is full
    logic [31:0] s;
    do read_status(s); while (s[TX_FULL]);
    write_reg(TX_DATA, w);
  endtask

  task automatic read_word(output logic [31:0] w);   // waits for a received word
    logic [31:0] s;
    do begin repeat (10) @(posedge clk); read_status(s); end while (s[RX_EMPTY]);
    read_reg(RX_DATA, w);
  endtask

  task automatic wait_done();                        // TX empty, core idle
    logic [31:0] s;
    do begin repeat (10) @(posedge clk); read_status(s); end while (!s[DONE]);
  endtask

  task automatic wait_busy();                        // a word is shifting
    logic [31:0] s;
    do read_status(s); while (!s[BUSY]);
  endtask

  int errors = 0;

  task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      $display("  FAIL  %-30s got 0x%h, expected 0x%h", what, got, exp);
      errors++;
    end else
      $display("  ok    %-30s 0x%h", what, got);
  endtask


  logic [31:0] st, rd;

  // TEST 1: load 4 words, 32-bit, clock ratio 50, mode 1, receive 4 words
  logic [31:0] test1_tx [0:3];                 // words the DUT sends
  logic [31:0] test1_rx [0:3];                 // words the slave returns

  task automatic test1();
    test_num = 1;
    $display("\nTEST 1: 4 words, 32-bit, mode 1, ratio 50   (starts %t)", $realtime);

    test1_tx[0] = 32'h0000_AAAA;  test1_rx[0] = 32'h0000_1111;
    test1_tx[1] = 32'h0000_BBBB;  test1_rx[1] = 32'h0000_2222;
    test1_tx[2] = 32'h0000_CCCC;  test1_rx[2] = 32'h0000_3333;
    test1_tx[3] = 32'h0000_DDDD;  test1_rx[3] = 32'h0000_4444;

   //Configure: clock ratio 50, 32-bit words, mode 1
    setup(50, 32, 1);

    slave_send.delete();
    for (int i = 0; i < 4; i++) slave_load(test1_rx[i]);
    slave_got.delete();

    select(0);

    for (int i = 0; i < 4; i++) send_word(test1_tx[i]);

    for (int i = 0; i < 4; i++) begin
      read_word(rd);
      check($sformatf("received word %0d", i + 1), rd, test1_rx[i]);
    end

    wait_done();
    deselect();

    check("slave word count", slave_got.size(), 4);
    for (int i = 0; i < 4; i++)
      check($sformatf("slave saw word %0d", i + 1), slave_got[i], test1_tx[i]);

    read_status(st);
    check("STATUS.error", st[ERROR], 0);
  endtask

  // TEST 2: send 9 words (1..9), 8-bit, clock ratio 50, mode 1, receive data
  //   The TX FIFO holds 8: the 1st word moves into the shifter right away,
  //   so all 9 fit. Words are read back as they arrive.
  task automatic test2();
    test_num = 2;
    $display("\nTEST 2: 9 words, 8-bit, mode 1, ratio 50   (starts %t)", $realtime);
    setup(50, 8, 1);
    write_reg(IRQ_ENABLE, IRQ_RX_AVAIL);
    for (int i = 1; i <= 9; i++) slave_load(10 - i);   // slave returns 9..1
    slave_got.delete();

    select(0);
    for (int i = 1; i <= 9; i++) send_word(i);         // send 1..9
    for (int i = 1; i <= 9; i++) begin
      read_word(rd);
      check($sformatf("received word %0d", i), rd, 10 - i);
    end
    wait_done();
    deselect();

    for (int i = 1; i <= 9; i++)
      check($sformatf("slave saw word %0d", i), slave_got[i-1], i);
    read_status(st);
    check("STATUS.error", st[ERROR], 0);
  endtask

  // TEST 3: 1 word, 32-bit, clock ratio 100, mode 0. Change CS mid-transfer.
  //   The DUT must ignore the CS write, set STATUS.error and raise the error
  //   interrupt, and still finish the word correctly.
  task automatic test3();
    test_num = 3;
    $display("\nTEST 3: error from CS change mid-transfer, 32-bit, ratio 100   (starts %t)", $realtime);
    setup(100, 32, 0);
    write_reg(STATUS, 0);                      // start with error clear
    write_reg(IRQ_ENABLE, IRQ_ERROR);
    slave_load(TEST3_SLAVE_WORD);
    slave_got.delete();
    check("irq before the error", irq, 0);

    select(0);
    send_word(TEST3_WORD);
    wait_busy();
    write_reg(CHIP_SELECT, 4'hD);              // try to switch to device 1
    check("irq", irq, 1);
    read_status(st);
    check("STATUS.error", st[ERROR], 1);
    check("CS pins unchanged", cs_n, 4'hE);

    write_reg(STATUS, 0);                      // any STATUS write clears error
    check("irq after clearing", irq, 0);

    read_word(rd);
    check("received word", rd, TEST3_SLAVE_WORD);
    wait_done();
    deselect();
    check("slave saw word", slave_got[0], TEST3_WORD);
    write_reg(IRQ_ENABLE, 0);
  endtask


  initial begin
    $timeformat(-6, 2, " us", 10);
    repeat (3) @(posedge clk);
    @(negedge clk) rstn = 1;

    test1();
    test2();
    test3();

    test_num = 0;
    $display("\n%s  (%0d failed checks, finished at %t)",
             (errors == 0) ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED", errors, $realtime);
    $finish;
  end

endmodule
