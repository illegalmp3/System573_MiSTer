`timescale 1ns/1ps
// tb_s573_wio_snac -- the White I/O card-port byte engine against a behavioural
// PS1 card on the pins: the card shifts CMD in on CLK rising, drives DAT on CLK
// falling, LSB first (psx-spx), and pulls /ACK low ~12 us after a byte unless told
// not to. Checks the firmware-shaped primitives: SELECT (40 us deselected, latch
// cleared, 10 us selected), XFER bit order + ACK outcomes, DESELECT.
module tb_s573_wio_snac;
    reg clk = 0, rst = 1, en = 1, start = 0, port = 0;
    reg [1:0] op = 0, am = 1; reg [7:0] tx = 0;
    wire busy, ack_seen, line_err; wire [7:0] rx;
    wire [1:0] sel_n; wire sclk, cmd;
    reg dat = 1, ack_n = 1;
    integer errors = 0;
    s573_wio_snac dut (.clk(clk), .rst(rst), .en(en), .start(start), .op(op), .port(port),
        .ack_mode(am), .tx(tx), .busy(busy), .rx(rx), .ack_seen(ack_seen), .line_err(line_err),
        .sel_n(sel_n), .clk_o(sclk), .cmd_o(cmd), .dat_i(dat), .ack_n_i(ack_n));
    always #14.76 clk = ~clk;                    // 33.8688 MHz

    task chk(input c, input [8*80-1:0] what); begin
        if (!c) begin $display("FAIL: %0s", what); errors = errors + 1; end
        else $display("  ok  %0s", what);
    end endtask

    // ---- the card ----
    reg [7:0] in_sh, out_b; integer nb = 0; reg [7:0] reply = 8'h3c;
    integer ack_delay_ns = 12000, ack_len_ns = 3000; reg no_ack = 0, ack_stuck = 0;
    reg [7:0] got [0:15];
    always @(negedge sclk) if (sel_n != 2'b11) begin dat <= out_b[0]; out_b <= {1'b1, out_b[7:1]}; end
    always @(posedge sclk) if (sel_n != 2'b11) begin
        in_sh = {cmd, in_sh[7:1]}; nb = nb + 1;
        if (nb % 8 == 0) begin
            got[(nb/8 - 1) & 15] = in_sh;
            fork begin
                if (!no_ack) begin
                    #(ack_delay_ns); ack_n = 0;
                    if (!ack_stuck) begin #(ack_len_ns); ack_n = 1; end
                end
            end join_none
        end
    end
    always @(negedge sel_n[0] or negedge sel_n[1]) begin nb = 0; out_b = reply; end

    task cmdx(input [1:0] o, input p, input [1:0] m, input [7:0] t); begin
        @(negedge clk); op = o; port = p; am = m; tx = t; start = 1; @(negedge clk); start = 0;
        @(negedge clk); while (busy) @(negedge clk);
    end endtask

    time t0, t1;
    initial begin
        repeat (4) @(posedge clk); rst = 0; repeat (4) @(posedge clk);
        chk(sel_n == 2'b11 && sclk == 1, "idle: deselected, CLK high");

        t0 = $time; cmdx(0, 1, 0, 0); t1 = $time;
        chk(sel_n == 2'b01, "SELECT port 1 drives sel_n[1] low only");
        chk((t1 - t0) > 49000 && (t1 - t0) < 52000, "SELECT takes 40 + 10 us");

        reply = 8'h5a;
        // reselect so the card loads the reply
        cmdx(0, 1, 0, 0);
        t0 = $time; cmdx(2, 1, 1, 8'h81); t1 = $time;
        chk(got[0] == 8'h81, "card received 0x81 LSB first");
        chk(rx == 8'h5a, "host received the card's byte LSB first");
        chk(ack_seen && !line_err, "ACK seen");
        chk((t1 - t0) > 64000 + 12000 && (t1 - t0) < 64000 + 12000 + 9000, "8 bits at 8 us + ACK at 12 us + 7 us check");

        no_ack = 1; cmdx(2, 1, 1, 8'h00);
        chk(!ack_seen && !line_err, "no ACK within 40 us -> timeout");
        no_ack = 0;

        ack_delay_ns = 900000;                   // Sony's late ACK (~915 us)
        cmdx(2, 1, 1, 8'h00);
        chk(!ack_seen, "late ACK misses the 40 us window");
        #(1000000);
        cmdx(0, 1, 0, 0);                       // latch was set by the late ACK: SELECT clears it
        cmdx(2, 1, 2, 8'h00);
        chk(ack_seen && !line_err, "long mode (2000 us) catches the late ACK");
        ack_delay_ns = 12000;

        no_ack = 1; cmdx(2, 1, 0, 8'h47);
        chk(ack_seen && !line_err, "ack_mode 0: done after the byte, ACK not waited for");
        no_ack = 0;

        ack_stuck = 1; cmdx(2, 1, 1, 8'h00);
        chk(line_err, "ACK still low 7 us after the latch -> line error");
        #(20000);
        cmdx(2, 1, 1, 8'h00);
        chk(line_err, "latch left set -> next XFER refused at once");
        ack_stuck = 0; ack_n = 1;

        t0 = $time; cmdx(1, 1, 0, 0); t1 = $time;
        chk(sel_n == 2'b11 && (t1 - t0) > 4900 && (t1 - t0) < 6000, "DESELECT after 5 us");

        en = 0; @(negedge clk); chk(sel_n == 2'b11 && sclk == 1 && !busy, "en low: pins idle");

        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end
endmodule
