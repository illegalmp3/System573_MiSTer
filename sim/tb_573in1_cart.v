`timescale 1ns/1ps
// tb_573in1_cart.v -- replay 573in1's security-cartridge driver against s573_seccart.
//
// Source of the stimulus: spicyjpeg/573in1 (commit b57da08)
//   src/common/io.cpp  CartI2CDriver::_setSDA/_setSCL/_setCS/_setReset/_getSDA,
//                      I2CDriver::start/startWithCS/stop/stopWithCS/getACK/sendACK/
//                      readByte/writeByte, I2CDriver::resetX76/resetZS01,
//                      OneWireDriver::reset/readByte/writeByte, CartDS2401Driver
//   src/main/cart/cartio.cpp  newCartDriver (detection order + IDs),
//                      X76Driver::_x76Command, X76F041Driver::readPrivateData,
//                      X76F100Driver::readPrivateData
//
// The point of difference from the Konami drivers: 573in1 keeps latch D0 at 0 and
// moves SDA with the 0x1f500000 bit-6 OUTPUT ENABLE alone ("SDA is open-drain so it
// is toggled by tristating the pin"). On the GX700 board (NaokiS28 schematics,
// Security-cart + Ksys573 sheets) bank-latch 27G Q6 -> 74LS14 24E -> /OE of the
// 74LS125 35H gate whose input is cart latch 35K Q0 (D0) and whose output is cart
// pin 28, the same net the ASIC reads back (KCUS-93). So the host level on SDA is
//     bit6 ? D0 : released(1)
// for EVERY cassette type. This bench checks the core against that.
//
// Delays are in microseconds at a 100 MHz bench clock (DS_CLK_HZ matches), so the
// DS2401 1-Wire timing is real. I2C_US is scaled down from 573in1's 50 us -- the
// EEPROM models are edge-driven, so only the ORDER of pin changes matters there.
module tb_573in1_cart;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;                    // 100 MHz
    localparam integer CLK_PER_US = 100;
    localparam integer I2C_US     = 5;       // 573in1 _I2C_BUS_DELAY = 50
    localparam integer RESET_US   = 500;     // 573in1 _I2C_RESET_DELAY

    reg  [1:0] cart_type = 2'd1;
    reg  [7:0] cart_out = 8'h00;             // 573in1 _cartOutputReg
    reg        bank6    = 1'b0;              // 573in1 _bankSwitchReg bit 6
    reg        latch_we = 1'b0;

    reg        L_we = 0; reg [12:0] L_addr = 0; reg [7:0] L_data = 0;
    reg        Ls_we = 0; reg [2:0] Ls_addr = 0; reg [7:0] Ls_data = 0;

    wire [7:0] sec_in;
    wire       sec_io0, sec_drdy, sec_irdy;

    s573_seccart #(.DS_SERIAL(48'h0123_4567_89AB), .DS_CLK_HZ(100_000_000)) dut (
        .clk(clk), .rst(rst), .cart_type(cart_type),
        .latch_we(latch_we), .d_latch(cart_out), .io0_dir(bank6),
        .load_eep_we(L_we), .load_eep_addr(L_addr), .load_eep_data(L_data),
        .load_ser_we(Ls_we), .load_ser_addr(Ls_addr), .load_ser_data(Ls_data),
        .load_eep_zs01_only(1'b0), .inst_sel(1'b0), .inst_type(1'b0),
        .load_ieep_we(1'b0), .load_ieep_addr(10'd0), .load_ieep_data(8'd0),
        .load_iser_we(1'b0), .load_iser_addr(3'd0), .load_iser_data(8'd0),
        .sec_dbg(), .sec_cs_n(), .sec_rst_line(), .sec_scl_line(), .sec_sda_line(),
        .sec_ds_line(), .sec_zs01_state(), .sec_rtr_edges(), .sec_in_rtr(), .sec_rtr_emit(),
        .sec_io0(sec_io0), .sec_in(sec_in), .sec_drdy(sec_drdy), .sec_irdy(sec_irdy),
        .zs01_dump_addr(8'd0), .zs01_dump_data(), .zs01_nv_wr()
    );

    integer errors = 0;

    task delay_us(input integer us); begin repeat (us*CLK_PER_US) @(negedge clk); end endtask

    // ---- io.cpp primitives ----
    task wr_latch; begin
        @(negedge clk); latch_we = 1; @(negedge clk); latch_we = 0;
    end endtask
    task setCartOutput(input integer pin, input v); begin
        cart_out[pin] = v; wr_latch;
    end endtask
    task setCartSDADirection(input v); begin
        @(negedge clk); bank6 = v;           // SYS573_BANK_CTRL write
    end endtask
    // CartI2CDriver
    task setSDA(input v); begin setCartOutput(0, 1'b0); setCartSDADirection(~v); end endtask
    task setSCL(input v); begin setCartOutput(1, v); end endtask
    task setCS (input v); begin setCartOutput(2, v); end endtask
    task setRST(input v); begin setCartOutput(3, v); end endtask
    function getSDA(input dummy); getSDA = sec_io0; endfunction

    // ---- I2CDriver ----
    task i2c_start; begin
        setSDA(1); setSCL(1); delay_us(I2C_US);
        setSDA(0); delay_us(I2C_US);
        setSCL(0); delay_us(I2C_US);
    end endtask
    task i2c_startWithCS; begin
        setSDA(1); setSCL(0); setCS(1); delay_us(I2C_US);
        setCS(0); delay_us(I2C_US);
        setSCL(1); delay_us(I2C_US);
        setSDA(0); delay_us(I2C_US);
        setSCL(0); delay_us(I2C_US);
    end endtask
    task i2c_stopWithCS; begin
        setSDA(0);
        setSCL(1); delay_us(I2C_US);
        setSDA(1); delay_us(I2C_US);
        setSCL(0); delay_us(I2C_US);
        setCS(1);  delay_us(I2C_US);
    end endtask
    task i2c_getACK(output ack); reg b; begin
        delay_us(I2C_US);
        setSCL(1); delay_us(I2C_US);
        b = getSDA(0);
        setSCL(0); delay_us(2*I2C_US);
        ack = ~b;
    end endtask
    task i2c_sendACK(input ack); begin
        setSDA(~ack);
        setSCL(1); delay_us(I2C_US);
        setSCL(0); delay_us(I2C_US);
        setSDA(1); delay_us(I2C_US);
    end endtask
    task i2c_readByte(output [7:0] v); integer i; begin
        v = 0;
        for (i = 7; i >= 0; i = i - 1) begin
            setSCL(1); delay_us(I2C_US);
            v[i] = getSDA(0);
            setSCL(0); delay_us(I2C_US);
        end
        delay_us(I2C_US);
    end endtask
    task i2c_writeByte(input [7:0] v); integer i; begin
        for (i = 7; i >= 0; i = i - 1) begin
            setSDA(v[i]);
            setSCL(1); delay_us(I2C_US);
            setSCL(0); delay_us(I2C_US);
        end
        setSDA(1); delay_us(I2C_US);
    end endtask

    task resetX76(output [31:0] value); integer i; begin
        value = 0;
        setSDA(1); setSCL(0); setCS(0); setRST(0);
        setRST(1); delay_us(RESET_US);
        setSCL(1); delay_us(I2C_US);
        setSCL(0); delay_us(I2C_US);
        setRST(0); delay_us(RESET_US);
        for (i = 0; i < 32; i = i + 1) begin          // LSB first
            setSCL(1); delay_us(I2C_US);
            value[i] = getSDA(0);
            setSCL(0); delay_us(I2C_US);
        end
        setCS(1);  delay_us(I2C_US);
        setSCL(1); delay_us(I2C_US);
    end endtask

    task resetZS01(output [31:0] value); integer i; begin
        value = 0;
        setSDA(1); setSCL(0); setCS(0); setRST(1);
        setRST(0); delay_us(RESET_US);
        setRST(1); delay_us(RESET_US);
        setSCL(1); delay_us(I2C_US);
        setSCL(0); delay_us(I2C_US);
        for (i = 31; i >= 0; i = i - 1) begin         // MSB first
            value[i] = getSDA(0);
            setSCL(1); delay_us(I2C_US);
            setSCL(0); delay_us(I2C_US);
        end
        setSCL(1); delay_us(I2C_US);
    end endtask

    // X76Driver::_x76Command with an all-zero data key (= the passwords below)
    task x76Command(input [7:0] pollByte, input [7:0] cmd, input integer param, output ok);
        integer k; reg a; begin
        ok = 0;
        delay_us(I2C_US);
        i2c_startWithCS;
        i2c_writeByte(cmd); i2c_getACK(a);
        if (!a) begin $display("  NACK on cmd 0x%02h", cmd); i2c_stopWithCS; end
        else begin
            if (param >= 0) begin
                i2c_writeByte(param[7:0]); i2c_getACK(a);
                if (!a) $display("  NACK on param 0x%02h", param[7:0]);
            end
            for (k = 0; k < 8 && a; k = k + 1) begin
                i2c_writeByte(8'h00); i2c_getACK(a);
                if (!a) $display("  NACK on key byte %0d", k);
            end
            if (!a) i2c_stopWithCS;
            else begin
                for (k = 0; k < 16 && !ok; k = k + 1) begin   // _X76_MAX_ACK_POLLS
                    delay_us(I2C_US);
                    i2c_start;
                    i2c_writeByte(pollByte); i2c_getACK(a);
                    if (a) ok = 1;
                end
                if (!ok) begin $display("  ACK-poll timeout"); i2c_stopWithCS; end
            end
        end
    end endtask

    // ---- DS2401 (OneWireDriver + CartDS2401Driver, real 1-Wire timing) ----
    task ow_set(input v); begin setCartOutput(4, ~v); end endtask
    function ow_get(input dummy); ow_get = sec_in[0]; endfunction   // -> 0x1f400004 bit14 (I6)
    task ow_reset(output present); reg b; begin
        ow_set(0); delay_us(480);
        ow_set(1); delay_us(70);
        b = ow_get(0);
        delay_us(410);
        present = ~b;
    end endtask
    task ow_writeByte(input [7:0] v); integer i; begin
        for (i = 0; i < 8; i = i + 1) begin
            if (v[i]) begin ow_set(0); delay_us(10); ow_set(1); delay_us(55); end
            else      begin ow_set(0); delay_us(65); ow_set(1); delay_us(5);  end
        end
    end endtask
    task ow_readByte(output [7:0] v); integer i; begin
        v = 0;
        for (i = 0; i < 8; i = i + 1) begin
            ow_set(0); delay_us(3);
            ow_set(1); delay_us(10);
            v[i] = ow_get(0);
            delay_us(53);
        end
    end endtask

    // ---- image loads ----
    task load_byte(input integer a, input [7:0] d); begin
        @(negedge clk); L_we = 1; L_addr = a; L_data = d; @(negedge clk); L_we = 0;
    end endtask

    function [7:0] pat(input integer i); pat = (i * 37 + 11) & 8'hFF; endfunction

    task expect32(input [255:0] what, input [31:0] got, input [31:0] exp); begin
        if (got === exp) $display("  ok   %0s = 0x%08h", what, got);
        else begin $display("  FAIL %0s = 0x%08h, expected 0x%08h", what, got, exp); errors = errors + 1; end
    end endtask

    reg [31:0] id; reg ok, pres; reg [7:0] b; integer i, bad, blk;
    reg [7:0] rom [0:7]; reg [7:0] crc;

    initial begin
        repeat (10) @(negedge clk); rst = 0; repeat (10) @(negedge clk);

        // ============ X76F041 (dsem-class cassette) ============
        $display("[X76F041]");
        cart_type = 2'd1;
        for (i = 4; i < 36; i = i + 1) load_byte(i, 8'h00);     // passwords + config regs 0
        for (i = 0; i < 512; i = i + 1) load_byte(36 + i, pat(i));
        // newCartDriver: ZS01 probe first, then X76
        resetZS01(id);
        if (id === 32'h5a530001) begin $display("  FAIL X76F041 mis-detected as ZS01"); errors = errors + 1; end
        else $display("  ok   ZS01 probe on X76F041 -> 0x%08h (not a ZS01)", id);
        resetX76(id);  expect32("X76 reset id", id, 32'h55aa5519);
        // X76F041Driver::readPrivateData, first 128-byte block
        x76Command(8'hc0, 8'h60, 0, ok);
        if (!ok) begin $display("  FAIL X76F041 read command not accepted"); errors = errors + 1; end
        else begin
            i2c_readByte(b);                    // "secure read setup" byte (ignored)
            i2c_start;
            i2c_writeByte(8'h00); i2c_getACK(ok);
            if (!ok) begin $display("  FAIL NACK after resending address"); errors = errors + 1; end
            bad = 0;
            for (i = 0; i < 128; i = i + 1) begin
                i2c_readByte(b);
                if (i < 127) i2c_sendACK(1);
                if (b !== pat(i)) begin
                    if (bad < 4) $display("  byte %0d = 0x%02h, expected 0x%02h", i, b, pat(i));
                    bad = bad + 1;
                end
            end
            i2c_stopWithCS;
            if (bad) begin $display("  FAIL X76F041 data read: %0d/128 bytes wrong", bad); errors = errors + 1; end
            else $display("  ok   X76F041 data block 0 read back (128 bytes)");
        end

        // ============ X76F100 (hyperbbc / ddrs2k-class cassette) ============
        $display("[X76F100]");
        cart_type = 2'd0;
        for (i = 4; i < 20; i = i + 1) load_byte(i, 8'h00);
        for (i = 0; i < 112; i = i + 1) load_byte(20 + i, pat(i));
        resetZS01(id);
        if (id === 32'h5a530001) begin $display("  FAIL X76F100 mis-detected as ZS01"); errors = errors + 1; end
        else $display("  ok   ZS01 probe on X76F100 -> 0x%08h (not a ZS01)", id);
        resetX76(id);  expect32("X76 reset id", id, 32'h55aa0019);
        x76Command(8'h55, 8'h81, -1, ok);
        if (!ok) begin $display("  FAIL X76F100 read command not accepted"); errors = errors + 1; end
        else begin
            bad = 0;
            for (i = 0; i < 112; i = i + 1) begin
                i2c_readByte(b);
                if (i < 111) i2c_sendACK(1);
                if (b !== pat(i)) begin
                    if (bad < 4) $display("  byte %0d = 0x%02h, expected 0x%02h", i, b, pat(i));
                    bad = bad + 1;
                end
            end
            i2c_stopWithCS;
            if (bad) begin $display("  FAIL X76F100 data read: %0d/112 bytes wrong", bad); errors = errors + 1; end
            else $display("  ok   X76F100 data read back (112 bytes)");
        end

        // ============ ZS01 (ddrusa / ddr4m-class cassette) ============
        $display("[ZS01]");
        cart_type = 2'd2;
        resetZS01(id); expect32("ZS01 reset id", id, 32'h5a530001);

        // ============ cassette DS2401 (CartDS2401Driver::readCartID path) ============
        $display("[cassette DS2401]");
        ow_reset(pres);
        if (!pres) begin $display("  FAIL no presence pulse on I6"); errors = errors + 1; end
        else begin
            ow_writeByte(8'h33);
            for (i = 0; i < 8; i = i + 1) ow_readByte(rom[i]);
            crc = 8'h00;
            for (i = 0; i < 7; i = i + 1) begin : crcl
                integer j; reg [7:0] x; x = rom[i];
                for (j = 0; j < 8; j = j + 1) begin
                    if ((crc[0] ^ x[0]) == 1'b1) crc = (crc >> 1) ^ 8'h8C; else crc = crc >> 1;
                    x = x >> 1;
                end
            end
            $display("  rom = %02h %02h%02h%02h%02h%02h%02h %02h",
                     rom[0], rom[6], rom[5], rom[4], rom[3], rom[2], rom[1], rom[7]);
            if (rom[0] !== 8'h01 || crc !== rom[7]) begin
                $display("  FAIL family/CRC (crc calc 0x%02h)", crc); errors = errors + 1;
            end else $display("  ok   family 0x01 + CRC8 valid");
        end

        if (errors == 0) $display("RESULT: PASS (573in1_cart)");
        else             $display("RESULT: FAIL (573in1_cart, %0d errors)", errors);
        $finish;
    end
endmodule
