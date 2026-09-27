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
    integer errors = 0, i, k;

    always #5 clk = ~clk;

    s573_prof_gpu dut (
        .clk(clk), .rst(rst),
        .flip(flip), .vblank(vblank), .cpupaused(cpupaused), .cpustall(cpustall),
        .gpubusy(gpubusy), .mdecbusy(mdecbusy), .mdecmb(mdecmb),
        .prof_flips(p_flip), .prof_vblanks(p_vb), .prof_paused_k(p_paused),
        .prof_stall_k(p_stall), .prof_gpu_k(p_gpu), .prof_mdec_k(p_mdec), .prof_mdec_mb(p_mb)
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

        if (errors == 0) $display("RESULT: PASS (s573_prof_gpu)");
        else             $display("RESULT: FAIL (s573_prof_gpu, %0d errors)", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("RESULT: FAIL (s573_prof_gpu, timeout)");
        $finish;
    end
endmodule
