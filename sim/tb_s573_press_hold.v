`timescale 1ns/1ps
// tb_s573_press_hold -- the minimum-press-width stretcher (rtl/s573_press_hold.v).
// Uses a fast CLK_HZ so a "millisecond" is 100 clocks: same arithmetic, short sim.
module tb_s573_press_hold;
    localparam integer CLK_HZ = 100_000, HOLD = 32, MS = 100;  // 1 ms = 100 clk
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;
    reg  [3:0] in = 0;
    wire [3:0] out;
    integer errors = 0, n, i;
    s573_press_hold #(.W(4), .CLK_HZ(CLK_HZ), .HOLD_MS(HOLD)) dut(.clk(clk), .rst(rst), .in(in), .out(out));

    task chk(input [255:0] what, input cond);
        begin if (!cond) begin errors = errors + 1; $display("FAIL: %0s", what); end end
    endtask
    // count clocks out[0] stays high after in[0] drops
    task measure_tail(output integer clocks);
        begin clocks = 0; while (out[0]) begin @(negedge clk); clocks = clocks + 1; end end
    endtask

    initial begin
        repeat (3) @(negedge clk); rst = 0; repeat (3) @(negedge clk);
        chk("idle -> out idle", out == 0);

        // A: 1-clock pulse becomes ~HOLD ms
        in[0] = 1; @(negedge clk); in[0] = 0;
        chk("press edge visible immediately", out[0] == 1);
        measure_tail(n);
        $display("1-clk pulse held %0d clocks (~%0d.%0d ms)", n, n / MS, (n % MS) / 10);
        chk("short press stretched to >= HOLD-1 ms", n >= (HOLD - 1) * MS);
        chk("short press stretched to <= HOLD+1 ms", n <= (HOLD + 1) * MS);

        // B: a press longer than HOLD passes through, release NOT delayed
        repeat (5 * MS) @(negedge clk);
        in[1] = 1; repeat (100 * MS) @(negedge clk);
        chk("long press still held", out[1] == 1);
        in[1] = 0; @(negedge clk); @(negedge clk);
        chk("long press releases at once", out[1] == 0);

        // C: two taps 40 ms apart are two presses (a gap survives)
        in[2] = 1; @(negedge clk); in[2] = 0;
        repeat (40 * MS) @(negedge clk);
        chk("first tap has released before the second (gap visible)", out[2] == 0);
        in[2] = 1; @(negedge clk); in[2] = 0; @(negedge clk);
        chk("second tap visible", out[2] == 1);

        // D: bits are independent
        chk("other bits untouched", out[0] == 0 && out[1] == 0 && out[3] == 0);

        // E: reset clears a held press
        in[3] = 1; @(negedge clk); in[3] = 0; @(negedge clk);
        chk("armed before reset", out[3] == 1);
        rst = 1; @(negedge clk); rst = 0; @(negedge clk);
        chk("reset drops the hold", out[3] == 0);

        if (errors == 0) $display("RESULT: PASS (s573_press_hold)");
        else             $display("RESULT: FAIL (s573_press_hold, %0d errors)", errors);
        $finish;
    end
endmodule
