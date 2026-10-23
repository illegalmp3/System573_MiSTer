`timescale 1ns/1ps
// tb_s573_mas_gain -- MAS3507D volume matrix (LL/RR), against the data sheet
// (Table 3-19/3-21, Fig. 3-2: out = -coef * in, $80000 = 0 dB) and the values
// ddr4m actually writes (its dB table at game exe 0x800df160; normal play uses
// level byte 0xfe -> -8 dB = $CD0AD, mute = -100 dB = $00000).
module tb_s573_mas_gain;
    reg clk = 0, rst = 1;
    reg [19:0] gl = 0, gr = 0; reg stb = 0;
    reg signed [15:0] il = 0, ir = 0;
    wire signed [15:0] ol, orr;
    integer errors = 0;
    s573_mas_gain dut (.clk(clk), .rst(rst), .gain_ll(gl), .gain_rr(gr), .gain_stb(stb),
                       .in_l(il), .in_r(ir), .out_l(ol), .out_r(orr));
    always #5 clk = ~clk;

    function integer expect_q(input integer x, input integer coef20);
        integer c; reg signed [63:0] p;
        begin
            c = (coef20 & 20'h80000) ? coef20 - 32'h100000 : coef20;
            p = -x * c;                                   // Q19 product
            p = p >>> 19;                                 // floor
            if (p > 32767) p = 32767; if (p < -32768) p = -32768;
            expect_q = p;
        end
    endfunction

    task setg(input [19:0] l, input [19:0] r); begin
        @(negedge clk); gl = l; gr = r; stb = 1; @(negedge clk); stb = 0;
    end endtask
    task chk(input integer x, input integer y, input integer el, input integer er, input [8*40-1:0] what); begin
        @(negedge clk); il = x; ir = y; @(negedge clk); @(negedge clk);
        if (ol !== el[15:0] || orr !== er[15:0]) begin
            $display("FAIL: %0s: in %0d/%0d -> %0d/%0d (want %0d/%0d)", what, x, y, ol, orr, el, er);
            errors = errors + 1;
        end else $display("  ok  %0s: %0d/%0d -> %0d/%0d", what, x, y, ol, orr);
    end endtask

    initial begin
        repeat (3) @(negedge clk); rst = 0;
        // before the game writes: chip default ($80000) = unity
        chk(12345, -23456, 12345, -23456, "power-on default (unity)");
        // ddr4m normal level, -8 dB
        setg(20'hCD0AD, 20'hCD0AD);
        chk(10000, -10000, expect_q(10000, 20'hCD0AD), expect_q(-10000, 20'hCD0AD), "ddr4m -8 dB ($CD0AD)");
        chk(32767, -32768, expect_q(32767, 20'hCD0AD), expect_q(-32768, 20'hCD0AD), "ddr4m -8 dB, full scale");
        if (expect_q(10000, 20'hCD0AD) !== 3981) begin $display("FAIL: -8 dB reference %0d", expect_q(10000, 20'hCD0AD)); errors = errors + 1; end
        // data sheet Table 3-21 -20 dB = $F3333 -> 0.1
        setg(20'hF3333, 20'h80000);
        chk(20000, 20000, expect_q(20000, 20'hF3333), 20000, "-20 dB left, 0 dB right");
        // mute (-100 dB in Konami's table = 0)
        setg(20'h00000, 20'h00000);
        chk(30000, -30000, 0, 0, "mute ($00000)");
        // unity again, full-scale negative stays in range (-1.0 coef -> +1.0 gain)
        setg(20'h80000, 20'h80000);
        chk(-32768, 32767, -32768, 32767, "0 dB full scale");
        // positive coefficient = phase-inverted output (Fig. 3-2 '-1' stage); +1.0-2^-19
        setg(20'h7FFFF, 20'h7FFFF);
        chk(-32768, 1000, expect_q(-32768, 20'h7FFFF), expect_q(1000, 20'h7FFFF), "$7FFFF inverts");
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
