`timescale 1ns/1ps
// tb_s573_audio_trim -- the "573 Music Level" trim (rtl/s573_audio_trim.v), 2026-11-01:
// 0..+6 dB in 1 dB steps on the MP3 path only. Position 0 is a bit-exact passthrough
// (the core as it was); n dB = Q12 round(4096 * 10^(n/20)); floor, saturating at the
// 16-bit rails; one register of latency; codes 7 = passthrough.
module tb_s573_audio_trim;
    reg clk = 0, rst = 1;
    reg  [2:0] sel = 0;
    reg  signed [15:0] ml = 0, mr = 0;
    wire signed [15:0] oml, omr;
    integer errors = 0;
    integer g [0:7];
    integer k;
    s573_audio_trim dut (.clk(clk), .rst(rst), .sel(sel), .mp3_l(ml), .mp3_r(mr),
                         .mp3_ol(oml), .mp3_or(omr));
    always #5 clk = ~clk;

    function integer q12(input integer x, input integer gg);   // floor(x*g/4096), saturated
        reg signed [63:0] p;
        begin
            p = x * gg; p = p >>> 12;
            if (p > 32767) p = 32767; if (p < -32768) p = -32768;
            q12 = p;
        end
    endfunction

    task chk(input [2:0] s, input integer a, input integer b, input integer ea, input integer eb,
             input [8*48-1:0] what); begin
        @(negedge clk); sel = s; ml = a; mr = b;
        @(negedge clk);                                         // registered: one clock
        if (oml !== ea[15:0] || omr !== eb[15:0]) begin
            $display("FAIL: %0s: sel %0d mp3 %0d/%0d -> %0d/%0d (want %0d/%0d)", what, s, a, b, oml, omr, ea, eb);
            errors = errors + 1;
        end else $display("  ok  %0s: sel %0d %0d/%0d -> %0d/%0d", what, s, a, b, oml, omr);
    end endtask

    initial begin
        g[0] = 4096; g[1] = 4596; g[2] = 5157; g[3] = 5786; g[4] = 6492; g[5] = 7284; g[6] = 8173; g[7] = 4096;
        repeat (3) @(negedge clk); rst = 0;
        chk(0, 12345, -23456, 12345, -23456, "0 dB: passthrough, bit exact");
        chk(0, -32768, 32767, -32768, 32767, "0 dB: passthrough, rails");
        for (k = 1; k <= 6; k = k + 1)
            chk(k, 10000, -10000, q12(10000, g[k]), q12(-10000, g[k]), "+k dB, mid level");
        // the steps are 1 dB apart: 10000 * 10^(k/20)
        if (q12(10000, g[1]) !== 11220 || q12(10000, g[3]) !== 14125 || q12(10000, g[6]) !== 19953) begin
            $display("FAIL: dB references %0d %0d %0d", q12(10000, g[1]), q12(10000, g[3]), q12(10000, g[6])); errors = errors + 1;
        end
        chk(6, 20000, -20000, 32767, -32768, "+6 dB saturates at the rails");
        chk(3, 32767, -32768, 32767, -32768, "+3 dB full scale saturates");
        chk(7, 111, -222, 111, -222, "code 7 = passthrough");
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
