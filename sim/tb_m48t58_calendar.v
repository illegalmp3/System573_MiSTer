`timescale 1ns/1ps
// tb_m48t58_calendar.v -- month lengths and leap years of the M48T58 calendar.
//
// Source: M48T58Y datasheet (NaokiS28 Konami-System-573-Documentation,
// DataSheets/m48t58y.pdf), "Clock operations": "Corrections for 28, 29 (leap
// year - valid until 2100), 30, and 31 day months are made automatically."
// The clock is set the way 573in1 io.cpp setRTCTime does (same harness as
// tb_573in1_rtc.v) one second before midnight on the last day of a month, and the
// date read back two seconds later must be the 1st of the next month (or the 29th
// of February in a leap year). RED before 2026-11-02: the model wrapped every
// month at 31, so 2027-02-28 became 02-29 and 2026-04-30 became 04-31.
module tb_m48t58_calendar;
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

    task last_day(input [7:0] yy, input [7:0] mm, input [7:0] dd,
                  input [7:0] want_mm, input [7:0] want_dd); begin
        setRTCTime(yy, mm, dd, 8'h23, 8'h59, 8'h59, 3'd3);
        repeat (20*2 + 4) @(negedge clk);           // ~2 s at CLK_FREQ_HZ=20
        getRTCTime;
        $display("  20%02h-%02h-%02h 23:59:59 -> %02h-%02h", yy, mm, dd, mo & 8'h1f, d & 8'h3f);
        check("month", mo & 8'h1f, want_mm);
        check("date",  d & 8'h3f, want_dd);
    end endtask

    initial begin
        repeat (5) @(negedge clk); rst = 0; repeat (5) @(negedge clk);
        last_day(8'h27, 8'h02, 8'h28, 8'h03, 8'h01);   // 2027 not a leap year
        last_day(8'h28, 8'h02, 8'h28, 8'h02, 8'h29);   // 2028 leap year
        last_day(8'h28, 8'h02, 8'h29, 8'h03, 8'h01);
        last_day(8'h00, 8'h02, 8'h28, 8'h02, 8'h29);   // 2000 leap year
        last_day(8'h26, 8'h02, 8'h28, 8'h03, 8'h01);
        last_day(8'h12, 8'h02, 8'h28, 8'h02, 8'h29);   // tens odd, units 2
        last_day(8'h14, 8'h02, 8'h28, 8'h03, 8'h01);   // tens odd, units 4: not leap
        last_day(8'h26, 8'h04, 8'h30, 8'h05, 8'h01);
        last_day(8'h26, 8'h06, 8'h30, 8'h07, 8'h01);
        last_day(8'h26, 8'h09, 8'h30, 8'h10, 8'h01);
        last_day(8'h26, 8'h11, 8'h30, 8'h12, 8'h01);
        last_day(8'h26, 8'h01, 8'h31, 8'h02, 8'h01);
        last_day(8'h26, 8'h07, 8'h31, 8'h08, 8'h01);
        last_day(8'h26, 8'h08, 8'h31, 8'h09, 8'h01);
        last_day(8'h26, 8'h10, 8'h31, 8'h11, 8'h01);
        last_day(8'h26, 8'h12, 8'h31, 8'h01, 8'h01);
        if (errors == 0) $display("RESULT: PASS (m48t58_calendar)");
        else             $display("RESULT: FAIL (m48t58_calendar, %0d errors)", errors);
        $finish;
    end
endmodule
