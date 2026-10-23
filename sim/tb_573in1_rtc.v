`timescale 1ns/1ps
// tb_573in1_rtc.v -- 573in1's RTC routines against m48t58.v.
//
// Stimulus source: spicyjpeg/573in1 (commit b57da08) src/common/io.cpp
//   setRTCTime: WRITE freeze, seconds/minutes/hours, WEEKDAY | CB | CEB (0x30),
//               DATE | BLE (0x80), month, year, release WRITE
//   getRTCTime: READ freeze, read, release; BCD masks as in the source
//   isRTCBatteryLow: DATE |= BLE, then read BL (DATE bit 6)
// Register map: M48T58Y datasheet Table 5 (NaokiS28 Konami-System-573-Documentation,
// DataSheets/m48t58y.pdf): DATE bit7 BLE, bit6 BL (read-only); DAY bit6 FT,
// bit5 CEB, bit4 CB. Before the fix the model counted those control bits as part
// of the BCD value, so a clock set by 573in1 jumped to the 1st of the next month
// (and lost the weekday) at the next midnight.
module tb_573in1_rtc;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg  [12:0] addr = 0; reg [7:0] din = 0; reg we = 0;
    wire [7:0]  dout;

    m48t58 #(.CLK_FREQ_HZ(20)) dut (
        .clk(clk), .rst(rst), .addr(addr), .din(din), .we(we), .dout(dout),
        .nvram_we(1'b0), .nvram_addr(13'd0), .nvram_din(8'd0),
        .sav_addr(13'd0), .sav_dout(), .sav_rd_ok(),
        .set_valid(1'b0), .set_stb(1'b0), .set_data(56'd0)
    );

    localparam [12:0] CTRL=13'd8184, SEC=13'd8185, MIN=13'd8186, HOUR=13'd8187,
                      WDAY=13'd8188, DAY=13'd8189, MON=13'd8190, YEAR=13'd8191;
    integer errors = 0;

    task w(input [12:0] a, input [7:0] d); begin
        @(negedge clk); addr = a; din = d; we = 1; @(negedge clk); we = 0; repeat (2) @(negedge clk);
    end endtask
    task r(input [12:0] a, output [7:0] d); begin
        @(negedge clk); addr = a; repeat (2) @(negedge clk); d = dout;
    end endtask

    task setRTCTime(input [7:0] y, input [7:0] mo, input [7:0] d, input [7:0] h,
                    input [7:0] mi, input [7:0] s, input [2:0] wd); reg [7:0] c; begin
        r(CTRL, c); w(CTRL, c | 8'h80);
        w(SEC, s); w(MIN, mi); w(HOUR, h);
        w(WDAY, {2'b00, 1'b1, 1'b1, 1'b0, wd});    // | CENTURY | CENTURY_ENABLE
        w(DAY, d | 8'h80);                          // | BATTERY_MONITOR
        w(MON, mo); w(YEAR, y);
        r(CTRL, c); w(CTRL, c & ~8'h80);
    end endtask

    reg [7:0] c, s, mi, h, wd, d, mo, y;
    task getRTCTime; begin
        r(CTRL, c); w(CTRL, c | 8'h40);
        r(SEC, s); r(MIN, mi); r(HOUR, h); r(WDAY, wd); r(DAY, d); r(MON, mo); r(YEAR, y);
        r(CTRL, c); w(CTRL, c & ~8'h40);
    end endtask

    task check(input [255:0] what, input [7:0] got, input [7:0] exp); begin
        if (got !== exp) begin $display("  FAIL %0s = %02h (want %02h)", what, got, exp); errors = errors + 1; end
    end endtask

    initial begin
        repeat (5) @(negedge clk); rst = 0; repeat (5) @(negedge clk);

        // 2026-12-31 23:59:58, Thursday (getDayOfWeek()+1 = 5)
        setRTCTime(8'h26, 8'h12, 8'h31, 8'h23, 8'h59, 8'h58, 3'd5);
        repeat (20*4) @(negedge clk);                 // ~4 s at CLK_FREQ_HZ=20
        getRTCTime;
        $display("  after rollover: 20%02h-%02h-%02h %02h:%02h:%02h wday=%02h", y, mo, d & 8'h3f, h, mi, s, wd);
        check("year", y, 8'h27);
        check("month", mo & 8'h1f, 8'h01);
        check("date", d & 8'h3f, 8'h01);
        check("weekday", wd & 8'h07, 8'h06);
        check("CEB/CB kept", wd & 8'h30, 8'h30);
        check("BLE kept", d & 8'h80, 8'h80);

        // a full day later the date must advance by one, not jump
        setRTCTime(8'h27, 8'h03, 8'h14, 8'h23, 8'h59, 8'h59, 3'd1);
        repeat (20*3) @(negedge clk);
        getRTCTime;
        check("mid-month date", d & 8'h3f, 8'h15);
        check("mid-month month", mo, 8'h03);
        check("mid-month weekday", wd & 8'h07, 8'h02);

        // isRTCBatteryLow
        r(DAY, d); w(DAY, d | 8'h80); r(DAY, d);
        if (d & 8'h40) begin $display("  FAIL battery reported low"); errors = errors + 1; end

        // century: 2099-12-31 23:59:59 with CEB -> CB toggles
        setRTCTime(8'h99, 8'h12, 8'h31, 8'h23, 8'h59, 8'h59, 3'd5);
        repeat (20*3) @(negedge clk);
        getRTCTime;
        check("year 99->00", y, 8'h00);
        check("CB toggled", wd & 8'h10, 8'h00);

        if (errors == 0) $display("RESULT: PASS (573in1_rtc)");
        else             $display("RESULT: FAIL (573in1_rtc, %0d errors)", errors);
        $finish;
    end
endmodule
