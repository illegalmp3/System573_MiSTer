`timescale 1ns/1ps
// tb_s573_audio_trim -- the "573 Music Level" trim (rtl/s573_audio_trim.v).
// Position 0 must be a bit-exact passthrough of both paths (the core as it was).
// The others are fixed gains: +3 dB = 10^(3/20) (Q12 5793), +6 dB = x2 exactly,
// SPU -3 dB (Q12 2900) / -6 dB = /2 exactly; saturating at the 16-bit rails.
module tb_s573_audio_trim;
    reg clk = 0, rst = 1;
    reg  [2:0] sel = 0;
    reg  signed [15:0] ml = 0, mr = 0, sl = 0, sr = 0;
    wire signed [15:0] oml, omr, osl, osr;
    integer errors = 0;
    s573_audio_trim dut (.clk(clk), .rst(rst), .sel(sel), .mp3_l(ml), .mp3_r(mr), .spu_l(sl), .spu_r(sr),
                         .mp3_ol(oml), .mp3_or(omr), .spu_ol(osl), .spu_or(osr));
    always #5 clk = ~clk;

    function integer q12(input integer x, input integer g);   // floor(x*g/4096), saturated
        reg signed [63:0] p;
        begin
            p = x * g; p = p >>> 12;
            if (p > 32767) p = 32767; if (p < -32768) p = -32768;
            q12 = p;
        end
    endfunction

    task chk(input [2:0] s, input integer a, input integer b, input integer c, input integer d,
             input integer ea, input integer eb, input integer ec, input integer ed, input [8*48-1:0] what); begin
        @(negedge clk); sel = s; ml = a; mr = b; sl = c; sr = d;
        @(negedge clk);                                         // registered: one clock
        if (oml !== ea[15:0] || omr !== eb[15:0] || osl !== ec[15:0] || osr !== ed[15:0]) begin
            $display("FAIL: %0s: sel %0d mp3 %0d/%0d spu %0d/%0d -> %0d/%0d %0d/%0d (want %0d/%0d %0d/%0d)",
                     what, s, a, b, c, d, oml, omr, osl, osr, ea, eb, ec, ed);
            errors = errors + 1;
        end else $display("  ok  %0s", what);
    end endtask

    initial begin
        repeat (3) @(negedge clk); rst = 0;
        chk(0, 12345, -23456, 32767, -32768, 12345, -23456, 32767, -32768, "0: passthrough, bit exact");
        chk(0, -1, 1, -1, 1, -1, 1, -1, 1, "0: passthrough, +-1 LSB");
        chk(1, 10000, -10000, 7000, -7000, q12(10000,5793), q12(-10000,5793), 7000, -7000, "1: music +3 dB, SPU 0");
        if (q12(10000,5793) !== 14143) begin $display("FAIL: +3 dB reference %0d", q12(10000,5793)); errors = errors + 1; end
        chk(2, 10000, -10000, 7000, -7000, 20000, -20000, 7000, -7000, "2: music +6 dB (x2), SPU 0");
        chk(2, 20000, -20000, 0, 0, 32767, -32768, 0, 0, "2: music +6 dB saturates at the rails");
        chk(3, 1000, -1000, 10000, -10000, 2000, -2000, q12(10000,2900), q12(-10000,2900), "3: music +6, SPU -3 dB");
        if (q12(10000,2900) !== 7080) begin $display("FAIL: -3 dB reference %0d", q12(10000,2900)); errors = errors + 1; end
        chk(4, 1000, -1000, 10000, -10001, 2000, -2000, 5000, -5001, "4: music +6, SPU -6 dB (/2, floor)");
        chk(5, 111, -222, 333, -444, 111, -222, 333, -444, "5: unused code = passthrough");
        chk(7, -32768, 32767, 5, -5, -32768, 32767, 5, -5, "7: unused code = passthrough");
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
