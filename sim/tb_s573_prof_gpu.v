`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_s573_prof_gpu.v - the PSX-side profile counters mean what they say
//
// The frame rate this module reports is the number the whole Tier-3 #2/#3
// investigation now turns on, so drive a known number of flips, vblanks and busy
// cycles and check each one reads back exactly. The edge rule matters here too: a
// tap that arrives as a multi-cycle LEVEL (a different psx_top revision, a slower
// clock domain) must still count ONE frame, never one per cycle -- that failure
// would report a plausible 60 fps while the game rendered 30.
// -----------------------------------------------------------------------------
module tb_s573_prof_gpu;
    reg clk = 0, rst = 1;
    reg flip = 0, vblank = 0, cpupaused = 0, cpustall = 0, gpubusy = 0, mdecbusy = 0, mdecmb = 0;
    wire [15:0] p_flip, p_vb, p_paused, p_stall, p_gpu, p_mdec, p_mb;
    wire [47:0] p_hist;
    reg  [47:0] hb;                  // histogram baseline
    integer f;
    integer errors = 0, i, k;

    always #5 clk = ~clk;

    s573_prof_gpu dut (
        .clk(clk), .rst(rst),
        .flip(flip), .vblank(vblank), .cpupaused(cpupaused), .cpustall(cpustall),
        .gpubusy(gpubusy), .mdecbusy(mdecbusy), .mdecmb(mdecmb),
        .prof_flips(p_flip), .prof_vblanks(p_vb), .prof_paused_k(p_paused),
        .prof_stall_k(p_stall), .prof_gpu_k(p_gpu), .prof_mdec_k(p_mdec), .prof_mdec_mb(p_mb),
        .prof_fliphist(p_hist)
    );

    task chk(input [175:0] name, input [31:0] got, input [31:0] want);
        begin
            if (got !== want) begin
                $display("FAIL: %0s = %0d, expected %0d", name, got, want);
                errors = errors + 1;
            end
        end
    endtask

    task strobe_flip(input integer len);   // a flip held `len` cycles
        begin
            @(negedge clk); flip = 1;
            for (i = 0; i < len; i = i + 1) @(negedge clk);
            flip = 0; @(negedge clk);
        end
    endtask
    task strobe_vb; begin @(negedge clk); vblank = 1; @(negedge clk); vblank = 0; @(negedge clk); end endtask
    task hold_paused(input integer n); begin
        @(negedge clk); cpupaused = 1;
        for (i = 0; i < n; i = i + 1) @(negedge clk);
        cpupaused = 0;
    end endtask
    task hold_gpu(input integer n); begin
        @(negedge clk); gpubusy = 1;
        for (i = 0; i < n; i = i + 1) @(negedge clk);
        gpubusy = 0;
    end endtask
    task hold_mdec(input integer n); begin
        @(negedge clk); mdecbusy = 1;
        for (i = 0; i < n; i = i + 1) @(negedge clk);
        mdecbusy = 0;
    end endtask
    task hold_stall(input integer n); begin
        @(negedge clk); cpustall = 1;
        for (i = 0; i < n; i = i + 1) @(negedge clk);
        cpustall = 0;
    end endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 0;
        @(negedge clk);
        chk("flips after reset", p_flip, 0);

        // 60 single-cycle flips = 60 frames
        for (k = 0; k < 60; k = k + 1) strobe_flip(1);
        chk("60 flips", p_flip, 60);
        // 30 flips held 7 cycles each: still 30 frames, NOT 210
        for (k = 0; k < 30; k = k + 1) strobe_flip(7);
        chk("30 long flips", p_flip, 90);

        for (k = 0; k < 17; k = k + 1) strobe_vb;
        chk("17 vblanks", p_vb, 17);
        chk("vblanks did not leak into flips", p_flip, 90);

        // cycle counters at >>10
        hold_paused(1024*3);
        @(negedge clk);
        chk("dma paused 3072 cycles", p_paused, 3);
        hold_stall(1024*2);
        @(negedge clk);
        chk("cpu stall 2048 cycles", p_stall, 2);
        hold_gpu(1024*9);
        @(negedge clk);
        chk("gpu busy 9216 cycles", p_gpu, 9);
        hold_mdec(1024);
        @(negedge clk);
        chk("mdec busy 1024 cycles", p_mdec, 1);
        chk("paused unchanged by gpu/mdec", p_paused, 3);

        // macroblock rate: 300 decoded macroblocks = one 320x240 frame's worth
        // mdecmb is a TOGGLE (one level change per macroblock, either direction)
        for (k = 0; k < 300; k = k + 1) begin
            @(negedge clk); mdecmb = ~mdecmb; @(negedge clk);
        end
        chk("300 macroblocks (300 toggles)", p_mb, 300);
        // a level held for 5 cycles is still ONE macroblock (no re-counting a level)
        for (k = 0; k < 4; k = k + 1) begin
            @(negedge clk); mdecmb = ~mdecmb;
            for (i = 0; i < 5; i = i + 1) @(negedge clk);
        end
        chk("4 held toggles", p_mb, 304);

        // ---- flip-interval histogram: flips binned by vblanks since the last flip ----
        strobe_flip(1);                           // close whatever interval is open
        hb = p_hist;
        // a 60 fps second: one vblank between flips, 60 times
        for (f = 0; f < 60; f = f + 1) begin strobe_vb; strobe_flip(1); end
        chk("60 fps: bin1", (p_hist[15:8] - hb[15:8]) & 8'hff, 60);
        chk("60 fps: bin2", (p_hist[23:16] - hb[23:16]) & 8'hff, 0);
        // ONE late frame in it: 2 vblanks before the flip -> exactly one count in bin 2
        strobe_vb; strobe_vb; strobe_flip(1);
        chk("late frame at 60 fps: bin2", (p_hist[23:16] - hb[23:16]) & 8'hff, 1);
        chk("late frame at 60 fps: bin1 unchanged", (p_hist[15:8] - hb[15:8]) & 8'hff, 60);
        // a 30 fps run: 2 vblanks per flip, then one hitch of 3
        hb = p_hist;
        for (f = 0; f < 30; f = f + 1) begin strobe_vb; strobe_vb; strobe_flip(1); end
        strobe_vb; strobe_vb; strobe_vb; strobe_flip(1);
        chk("30 fps: bin2", (p_hist[23:16] - hb[23:16]) & 8'hff, 30);
        chk("hitch at 30 fps: bin3", (p_hist[31:24] - hb[31:24]) & 8'hff, 1);
        // two flips with no vblank between -> bin 0; a long gap saturates in bin 5+
        strobe_flip(1);
        chk("double flip: bin0", (p_hist[7:0] - hb[7:0]) & 8'hff, 1);
        for (f = 0; f < 4; f = f + 1) strobe_vb;
        strobe_flip(1);
        chk("4 vblanks: bin4", (p_hist[39:32] - hb[39:32]) & 8'hff, 1);
        for (f = 0; f < 9; f = f + 1) strobe_vb;
        strobe_flip(1);
        chk("9 vblanks: bin5+", (p_hist[47:40] - hb[47:40]) & 8'hff, 1);
        // the counters wrap mod 256 and the diff stays exact
        hb = p_hist;
        for (f = 0; f < 300; f = f + 1) begin strobe_vb; strobe_flip(1); end
        chk("300 flips mod 256", (p_hist[15:8] - hb[15:8]) & 8'hff, 300 % 256);

        if (errors == 0) $display("RESULT: PASS (s573_prof_gpu)");
        else             $display("RESULT: FAIL (s573_prof_gpu, %0d errors)", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("RESULT: FAIL (s573_prof_gpu, timeout)");
        $finish;
    end
endmodule
