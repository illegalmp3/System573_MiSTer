`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_s573_prof.v - the frame-time profile counters mean what they say
//
// The whole point of this module is that a number in the log can be trusted to
// stand for a real quantity of cycles or events. So drive a KNOWN amount of each
// input and check the counter reads back that amount, at the documented scaling:
//   * cycle counters are cycles >> 10 (levels)
//   * ide/exp1 are ACCESSES (rising edges, not stalled cycles) >> 4 / >> 6
//   * sectors and watchdog kicks are 1:1 event counts
// The edge rule is what keeps a wait-stated access from being counted as many.
// -----------------------------------------------------------------------------
module tb_s573_prof;
    reg clk = 0, rst = 1;
    reg flash_wait = 0, dio_wait = 0, cd_busy = 0;
    reg sec_done = 0, wdog_kick = 0, ide_acc = 0, exp1_acc = 0;
    wire [15:0] p_flash, p_dio, p_cd, p_sect, p_frame, p_ide, p_exp1;
    integer errors = 0;
    integer i;

    always #5 clk = ~clk;

    s573_prof dut (
        .clk(clk), .rst(rst),
        .flash_wait(flash_wait), .dio_wait(dio_wait), .cd_busy(cd_busy),
        .sec_done(sec_done), .wdog_kick(wdog_kick),
        .ide_acc(ide_acc), .exp1_acc(exp1_acc),
        .prof_flash_k(p_flash), .prof_dio_k(p_dio), .prof_cd_k(p_cd),
        .prof_sectors(p_sect), .prof_frames(p_frame),
        .prof_ide(p_ide), .prof_exp1(p_exp1)
    );

    task chk(input [127:0] name, input [31:0] got, input [31:0] want);
        begin
            if (got !== want) begin
                $display("FAIL: %0s = %0d, expected %0d", name, got, want);
                errors = errors + 1;
            end
        end
    endtask

    // hold a level for n cycles
    task hold_flash(input integer n); begin
        @(negedge clk); flash_wait = 1;
        for (i = 0; i < n; i = i + 1) @(negedge clk);
        flash_wait = 0;
    end endtask
    task hold_dio(input integer n); begin
        @(negedge clk); dio_wait = 1;
        for (i = 0; i < n; i = i + 1) @(negedge clk);
        dio_wait = 0;
    end endtask
    task hold_cd(input integer n); begin
        @(negedge clk); cd_busy = 1;
        for (i = 0; i < n; i = i + 1) @(negedge clk);
        cd_busy = 0;
    end endtask
    // one access: asserted for `n` cycles (a wait-stated access), then idle
    task access(input integer n); begin
        @(negedge clk); ide_acc = 1; exp1_acc = 1;
        for (i = 0; i < n; i = i + 1) @(negedge clk);
        ide_acc = 0; exp1_acc = 0;
        @(negedge clk);
    end endtask
    task pulse_sec; begin @(negedge clk); sec_done = 1; @(negedge clk); sec_done = 0; end endtask
    task pulse_kick; begin @(negedge clk); wdog_kick = 1; @(negedge clk); wdog_kick = 0; end endtask

    integer k;
    initial begin
        repeat (4) @(negedge clk);
        rst = 0;
        @(negedge clk);

        // --- reset state ---
        chk("flash after reset", p_flash, 0);
        chk("frames after reset", p_frame, 0);

        // --- cycle counters: 3072 cycles = 3 counts at >>10 ---
        hold_flash(3072);
        @(negedge clk);
        chk("flash 3072 cycles", p_flash, 3);
        // sub-threshold time is KEPT (prescale is the counter's low bits), so a
        // second 1024 completes a 4th count rather than being rounded away.
        hold_flash(1024);
        @(negedge clk);
        chk("flash +1024 cycles", p_flash, 4);
        chk("dio untouched", p_dio, 0);
        chk("cd untouched", p_cd, 0);

        hold_dio(2048);
        @(negedge clk);
        chk("dio 2048 cycles", p_dio, 2);

        hold_cd(1024*5);
        @(negedge clk);
        chk("cd 5120 cycles", p_cd, 5);

        // --- event counters are 1:1 ---
        for (k = 0; k < 7; k = k + 1) pulse_sec;
        chk("7 sectors", p_sect, 7);
        for (k = 0; k < 33; k = k + 1) pulse_kick;
        chk("33 watchdog kicks", p_frame, 33);

        // --- accesses count ONCE each, however long they are held ---
        for (k = 0; k < 16; k = k + 1) access(1);
        @(negedge clk);
        chk("16 short accesses -> ide>>4", p_ide, 1);
        // 16 LONG accesses (12 cycles each): still 16 accesses, not 192
        for (k = 0; k < 16; k = k + 1) access(12);
        @(negedge clk);
        chk("16 long accesses -> ide>>4", p_ide, 2);
        chk("32 accesses -> exp1>>6", p_exp1, 0);
        for (k = 0; k < 32; k = k + 1) access(3);
        @(negedge clk);
        chk("64 accesses -> exp1>>6", p_exp1, 1);
        chk("ide after 64 accesses", p_ide, 4);

        if (errors == 0) $display("RESULT: PASS (s573_prof)");
        else             $display("RESULT: FAIL (s573_prof, %0d errors)", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("RESULT: FAIL (s573_prof, timeout)");
        $finish;
    end
endmodule
