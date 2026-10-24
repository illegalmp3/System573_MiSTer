// tb_s573_mas_gain.v - s573_mas_gain against MAME's gain_to_percentage
//
// The expected Q12 for every 20-bit gain value comes from tools/gen_mas_gain_rom.py
// (MAME's own formula: C round of 20*log10((0x100000-v)/0x80000), powf(10,(db+6)/20)),
// written to build/mas_gain_exp.txt by the Makefile. Checked: unity before any write
// (MAME device_reset), every table threshold and its neighbours, every 61st value
// (all 2^20 / 61 ~ 17k), the values the logs show games writing (dfd91 -12 dB,
// d785e -10 dB, ffeb5 -64 dB, 0 = mute), L/R independence, a write landing mid-scan,
// and the sample path (scale, saturation, mute).
`timescale 1ns/1ps
module tb_s573_mas_gain;
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;
    reg [19:0] gl = 0, gr = 0;
    reg stb = 0;
    reg signed [15:0] il = 0, ir = 0;
    wire signed [15:0] ol, or_;
    wire [14:0] ql, qr;
    s573_mas_gain dut(.clk(clk), .rst(rst), .gain_ll(gl), .gain_rr(gr), .gain_stb(stb),
                      .in_l(il), .in_r(ir), .out_l(ol), .out_r(or_), .q_l(ql), .q_r(qr));

    reg [14:0] exp_q [0:1048575];
    integer fd, v, q, n, errs = 0, checks = 0, i;

    task write_gain(input [19:0] l, input [19:0] r);
        begin
            @(negedge clk); gl = l; gr = r; stb = 1;
            @(negedge clk); stb = 0;
            repeat (240) @(negedge clk);      // two worst-case scans
        end
    endtask
    task check_pair(input [19:0] l, input [19:0] r);
        begin
            write_gain(l, r);
            checks = checks + 1;
            if (ql !== exp_q[l] || qr !== exp_q[r]) begin
                errs = errs + 1;
                if (errs < 20) $display("FAIL v=%05x/%05x got %0d/%0d want %0d/%0d", l, r, ql, qr, exp_q[l], exp_q[r]);
            end
        end
    endtask

    initial begin
        fd = $fopen("build/mas_gain_exp.txt", "r");
        if (fd == 0) begin $display("FAIL: no build/mas_gain_exp.txt"); $finish; end
        for (i = 0; i < 1048576; i = i + 1) begin
            n = $fscanf(fd, "%h %h\n", v, q);
            exp_q[v] = q;
        end
        $fclose(fd);
        repeat (4) @(negedge clk); rst = 0;
        repeat (4) @(negedge clk);
        // 1. unity before any write, and the sample passes through unchanged
        il = 16'sd12345; ir = -16'sd23456; repeat (3) @(negedge clk);
        if (ql !== 15'd4096 || qr !== 15'd4096 || ol !== 16'sd12345 || or_ !== -16'sd23456) begin
            errs = errs + 1; $display("FAIL reset: q=%0d/%0d out=%0d/%0d", ql, qr, ol, or_);
        end
        // 2. the values the games write
        check_pair(20'hdfd91, 20'hdfd91);
        check_pair(20'hd785e, 20'hffeb5);
        check_pair(20'h00000, 20'h80000);
        check_pair(20'h00001, 20'hfffff);
        // sample path at -12 dB / mute: 10000 * 2053 >> 12 = 5012
        write_gain(20'hdfd91, 20'h00000);
        il = 16'sd10000; ir = 16'sd10000; repeat (3) @(negedge clk);
        if (ol !== 16'sd5012 || or_ !== 16'sd0) begin errs = errs + 1; $display("FAIL apply: %0d %0d", ol, or_); end
        il = -16'sd10000; repeat (3) @(negedge clk);
        if (ol !== -16'sd5013) begin errs = errs + 1; $display("FAIL apply neg: %0d", ol); end
        // saturation at +6 dB
        write_gain(20'h00001, 20'h00001);
        il = 16'sd32767; ir = -16'sd32768; repeat (3) @(negedge clk);
        if (ol !== 16'sd32767 || or_ !== -16'sd32768) begin errs = errs + 1; $display("FAIL sat: %0d %0d", ol, or_); end
        // 3. a second write landing in the middle of a scan is not lost
        @(negedge clk); gl = 20'hfff00; gr = 20'hfff00; stb = 1; @(negedge clk); stb = 0;
        repeat (20) @(negedge clk);
        gl = 20'h80000; gr = 20'hd785e; stb = 1; @(negedge clk); stb = 0;
        repeat (480) @(negedge clk);
        checks = checks + 1;
        if (ql !== exp_q[20'h80000] || qr !== exp_q[20'hd785e]) begin
            errs = errs + 1; $display("FAIL mid-scan write: %0d/%0d", ql, qr);
        end
        // 4. every threshold and its neighbours: wherever the expected value changes
        for (v = 1; v < 1048575; v = v + 1)
            if (exp_q[v] !== exp_q[v+1]) check_pair(v, v + 1);
        // 5. a stride sweep across the whole range
        for (v = 0; v < 1048576; v = v + 61)
            check_pair(v, 1048575 - v);
        $display("RESULT: %s (s573_mas_gain: %0d checks, %0d failures)", errs ? "FAIL" : "PASS", checks, errs);
        $finish;
    end
endmodule
