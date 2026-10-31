`timescale 1ns/1ps
// tb_s573_voice_duck -- replays the MAME ddrextrm / ddrmax2 / ddr5m timelines
// (local/mame/study9, study_ddrmax2, study_ddr5m; docs/2026-10-30-music-level-and-
// announcer.md) against rtl/s573_voice_duck.v with a 1 kHz "second" (CLK_HZ=1000).
// Every KON below is one the game really keyed; times are seconds from the song's
// play command, the stream advancing at the measured CBR byte rate.
module tb_s573_voice_duck;
    localparam integer HZ = 1000;
    reg clk = 0, rst = 1;
    reg        we = 0; reg [9:0] addr = 0; reg [15:0] din = 0;
    reg [15:0] fctl = 0; reg [31:0] st = 0, en = 0; reg [24:0] cur = 0;
    wire [23:0] duck; wire in_song, window;
    integer errors = 0;
    s573_voice_duck #(.CLK_HZ(HZ)) dut (.clk(clk), .rst(rst), .spu_we(we), .spu_addr(addr), .spu_din(din),
        .fpga_ctrl(fctl), .mp3_start(st), .mp3_end(en), .cur_pos(cur), .duck(duck), .in_song(in_song), .window(window));
    always #5 clk = ~clk;

    // stream model: advance cur at RATE bytes/s while enabled and inside the window
    integer rate = 0; integer acc = 0;
    always @(posedge clk) if (!rst && fctl[14] && fctl[13] && cur < en) begin
        acc = acc + rate;
        if (acc >= HZ) begin cur <= cur + acc / HZ; acc = acc % HZ; end
    end

    task play(input [31:0] s, input [31:0] l, input integer r); begin
        @(negedge clk); fctl = 16'h0000; st = s; en = s + l; cur = s; acc = 0; rate = r;
        @(negedge clk); fctl = 16'he000;                 // MP3_ENABLE | STREAMING_ENABLE (+bit15)
    end endtask
    task wait_s(input real secs); begin
        repeat ($rtoi(secs * HZ)) @(negedge clk);
    end endtask
    task kon(input integer v); begin
        @(negedge clk); we = 1; addr = (v < 16) ? 10'h188 : 10'h18A; din = (v < 16) ? (16'd1 << v) : (16'd1 << (v - 16));
        @(negedge clk); we = 0;
    end endtask
    task chk_duck(input integer v, input exp, input [8*44-1:0] what); begin
        @(negedge clk);
        if (duck[v] !== exp) begin $display("FAIL: %0s: voice %0d duck=%b want %b", what, v, duck[v], exp); errors = errors + 1; end
        else $display("  ok  %0s: voice %0d duck=%b", what, v, duck[v]);
    end endtask
    // key voice v at absolute song time t (seconds from play), check the decision
    real now;
    task at(input real t, input integer v, input exp, input [8*44-1:0] what); begin
        wait_s(t - now); now = t; kon(v); chk_duck(v, exp, what);
    end endtask

    initial begin
        repeat (3) @(negedge clk); rst = 0;

        // ---- menu BGM (ddrextrm style select, start 0x31ae4c, 348901 B): never a song
        play(32'h031ae4c, 348901, 14032); now = 0;
        at(0.10, 0, 0, "extrm menu BGM, +0.1 s");
        at(6.00, 1, 0, "extrm menu BGM, +6 s");
        // ---- 3rd Mix preview: start 0 but 287575 B: not a song
        play(32'h0, 287575, 14000); now = 0;
        at(5.00, 2, 0, "3rd Mix preview at 0, +5 s");
        // ---- ddr3mj 848881 B file at 0x2942a4 (core log, session 8): long but not at 0
        play(32'h02942a4, 848881, 14000); now = 0;
        at(10.00, 4, 0, "3rd Mix 849 KB file at 0x2942a4, +10 s");
        // ---- ddr5m menu BGM 705981 B at 0x43a040: not a song
        play(32'h043a040, 705981, 16035); now = 0;
        at(8.00, 3, 0, "ddr5m menu BGM 706 KB, +8 s");

        // ---- ddrextrm stage song (study9): start 0, 1479319 B, 14032 B/s
        play(32'h0, 1479319, 14032); now = 0;
        at(0.18, 0, 0, "extrm READY crowd +0.18");
        at(0.40, 1, 0, "extrm READY call +0.40");
        at(2.12, 1, 0, "extrm HERE WE GO call +2.12");
        at(2.77, 2, 0, "extrm HERE WE GO crowd +2.77");
        if (duck[2] !== 1'b0) begin $display("FAIL: window opening ducked a sounding voice"); errors = errors + 1; end
        at(25.27, 0, 1, "extrm mid-song call +25.3");
        at(64.25, 0, 1, "extrm mid-song crowd +64.3");
        at(95.01, 0, 1, "extrm crowd 10.4 s before the end");
        at(101.84, 0, 0, "extrm end crowd 3.6 s before the end");
        at(108.00, 1, 0, "extrm results screen (stream over)");
        if (in_song !== 1'b0) begin $display("FAIL: still in song after the stream ended"); errors = errors + 1; end

        // ---- ddrmax2 stage song: start 0, 1919581 B, 20035 B/s
        play(32'h0, 1919581, 20035); now = 0;
        at(0.18, 16, 0, "max2 start crowd (voice 16, KON hi) +0.18");
        at(2.69, 2, 0, "max2 HERE WE GO crowd +2.69");
        at(32.34, 0, 1, "max2 mid crowd (same clip as start) +32.3");
        at(84.70, 16, 1, "max2 mid call +84.7 (voice 16)");
        at(92.38, 0, 0, "max2 end crowd 3.4 s before the end");

        // ---- ddr5m stage song: start 0, 1632003 B, 16035 B/s
        play(32'h0, 1632003, 16035); now = 0;
        at(0.28, 0, 0, "5th start call +0.28");
        at(2.56, 1, 0, "5th start sound +2.56");
        at(27.83, 0, 1, "5th mid +27.8");
        at(91.82, 0, 1, "5th mid 10.0 s before the end");
        at(96.05, 0, 0, "5th end call 5.6 s before the end");
        at(96.20, 1, 0, "5th end call 5.4 s before the end");

        // ---- a new song command mid-window restarts the KEEP phase
        play(32'h0, 1479319, 14032); now = 0;
        at(10.0, 5, 1, "song A mid");
        play(32'h0, 1479319, 14032); now = 0;
        at(1.0, 6, 0, "song B start set after a restart");
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
