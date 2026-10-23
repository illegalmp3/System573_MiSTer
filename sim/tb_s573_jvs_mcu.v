`timescale 1ns/1ps
// tb_s573_jvs_mcu -- the JVS host MCU model driven exactly as ddr4m's own driver
// drives the real one (game exe 0x800ac5fc reset, 0x800ac924 send, 0x800aca6c
// receive), against psx-spx's description of the MCU. The HPS side is a small
// behavioural JVS bus: it answers everything except the reset (F0 D9), which no
// device answers (psx-spx: "nothing on the bus answers a reset"). ddr4m sends the
// reset to 0xff twice, resetting the MCU before each (0x800adb40), and assigns
// addresses with F1 n sent to 0xff, which the unaddressed device does answer
// (0x800adbf0: send+receive, then the sense line decides whether to continue).
module tb_s573_jvs_mcu;
    reg clk = 0, rst = 1, mcu_rst_n = 1;
    reg wr = 0, clr = 0; reg [15:0] wd = 0;
    wire [15:0] rd; wire irdy, drdy; wire [1:0] status, err;
    wire req_ready; wire [8:0] req_len; wire [7:0] req_seq; reg [7:0] req_raddr = 0; wire [15:0] req_rdata;
    reg resp_we = 0, resp_commit = 0; reg [7:0] resp_waddr = 0, resp_seq = 0; reg [15:0] resp_wdata = 0; reg [8:0] resp_len = 0;
    integer errors = 0;
    s573_jvs_mcu #(.CONSUME_CLKS(64)) dut (.clk(clk), .rst(rst), .mcu_rst_n(mcu_rst_n),
        .wr_data(wr), .wdata(wd), .clr_irdy(clr), .rdata(rd), .irdy(irdy), .drdy(drdy),
        .status(status), .err(err), .req_ready(req_ready), .req_len(req_len), .req_seq(req_seq),
        .req_raddr(req_raddr), .req_rdata(req_rdata), .resp_we(resp_we), .resp_waddr(resp_waddr),
        .resp_wdata(resp_wdata), .resp_commit(resp_commit), .resp_len(resp_len), .resp_seq(resp_seq));
    always #15 clk = ~clk;                       // ~33 MHz
    task cyc(input integer n); begin repeat (n) @(posedge clk); end endtask
    task poll; begin cyc(16); end endtask        // one CPU register poll
    function [7:0] st4; input dummy; st4 = {err, status, 4'h0}; endfunction

    task chk(input c, input [8*90-1:0] what); begin
        if (!c) begin $display("FAIL: %0s", what); errors = errors + 1; end
        else $display("  ok  %0s", what);
    end endtask

    // ---- 0x800ac5fc: reset the MCU, wait for status 0 / error 3, drain JVSIRDY ----
    integer k, ret;
    task konami_reset(output integer r); begin
        @(negedge clk); mcu_rst_n = 0; cyc(200); @(negedge clk); mcu_rst_n = 1; cyc(200);
        r = -1;
        for (k = 0; k < 6 && r != 0; k = k + 1) begin poll; if ({err, status} == 4'hc) r = 0; end
        while (r == 0 && irdy) begin @(negedge clk); clr = 1; @(negedge clk); clr = 0; poll; end
    end endtask

    // ---- 0x800ac924: build E0 addr len+1 payload checksum, send it ----
    reg [7:0] pkt [0:263];
    integer plen, i, n;
    task konami_send(input [7:0] addr, input integer len, output integer r); integer s, words; begin
        pkt[0] = 8'he0; pkt[1] = addr; pkt[2] = len + 1;
        s = addr + len + 1;
        for (i = 0; i < len; i = i + 1) s = s + pkt[3 + i];
        pkt[3 + len] = s; pkt[4 + len] = 0;
        r = 0;
        n = 0; while (status != 0 && n < 48) begin poll; n = n + 1; end
        if (n == 48) r = -3;
        words = (len + 5) / 2;
        for (i = 0; i < words && r == 0; i = i + 1) begin
            cyc(20);
            @(negedge clk); wr = 1; wd = {pkt[2*i+1], pkt[2*i]}; @(negedge clk); wr = 0;
            n = 0; poll; while (drdy && n < 48) begin poll; n = n + 1; end
            if (n == 48) r = -3;
        end
    end endtask

    // ---- 0x800aca6c: receive ----
    reg [7:0] rx [0:263];
    task konami_recv(output integer r); integer left, p; reg [15:0] w; begin
        if (!irdy) begin
            if (err == 2'd3) r = -5; else if (err == 2'd0) r = -2; else r = -4;
        end else begin
            w = rd; @(negedge clk); clr = 1; @(negedge clk); clr = 0;
            rx[0] = w[7:0]; rx[1] = w[15:8];
            if (w != 16'h00e0) r = -4;
            else begin
                r = 0; n = 0; poll; while (!irdy && n < 48) begin poll; n = n + 1; end
                if (n == 48) r = -3;
                else begin
                    w = rd; @(negedge clk); clr = 1; @(negedge clk); clr = 0;
                    rx[2] = w[7:0]; rx[3] = w[15:8];
                    left = rx[2] - 1; p = 4;
                    while (left > 0 && r == 0) begin
                        n = 0; poll; while (!irdy && n < 48) begin poll; n = n + 1; end
                        if (n == 48) r = -3;
                        else begin
                            w = rd; @(negedge clk); clr = 1; @(negedge clk); clr = 0;
                            rx[p] = w[7:0]; rx[p+1] = w[15:8]; p = p + 2; left = left - 2;
                        end
                    end
                    if (r == 0) r = rx[2] - 1;
                end
            end
        end
    end endtask

    // ---- behavioural JVS bus (the HPS side) ----
    reg [7:0] q [0:263]; reg [7:0] rp [0:263];
    integer ql, rl, answered = 0, silent = 0;
    reg answer_enable = 1;
    always @(posedge clk) if (!rst && req_ready && answer_enable) begin : bus
        integer j; reg [7:0] s;
        // read the request out of the MCU
        for (j = 0; j < (req_len + 1) / 2; j = j + 1) begin
            @(negedge clk); req_raddr = j; @(posedge clk); #1; q[2*j] = req_rdata[7:0]; q[2*j+1] = req_rdata[15:8];
        end
        ql = req_len;
        if (q[3] == 8'hf0) begin silent = silent + 1; wait (!req_ready); end    // reset: no answer
        else begin
            rp[0] = 8'he0; rp[1] = 8'h00;
            if (q[3] == 8'hf1) begin rp[3] = 8'h01; rp[4] = 8'h01; rl = 2; end
            else if (q[3] == 8'h70 && q[4] == 8'h00) begin        // buffer read: 1 + q[8] bytes
                rp[3] = 8'h01; rp[4] = 8'h01;
                for (j = 0; j < q[8]; j = j + 1) rp[5 + j] = j ^ 8'h5a;
                rl = 2 + q[8];
            end else begin rp[3] = 8'h01; rp[4] = 8'h01; rl = 2; end
            rp[2] = rl + 1;
            s = 0; for (j = 1; j < rl + 3; j = j + 1) s = s + rp[j];
            rp[rl + 3] = s; rp[rl + 4] = 0;
            cyc(3000);                                                // bus latency
            for (j = 0; j < (rl + 5) / 2; j = j + 1) begin
                @(negedge clk); resp_we = 1; resp_waddr = j; resp_wdata = {rp[2*j+1], rp[2*j]};
            end
            @(negedge clk); resp_we = 0; resp_len = rl + 4; resp_seq = req_seq; resp_commit = 1;
            @(negedge clk); resp_commit = 0;
            answered = answered + 1;
        end
    end

    integer t;
    initial begin
        cyc(4); @(negedge clk); rst = 0; cyc(10);
        chk({err, status} == 4'hc, "power-on: status 0 error 3 = 0x1f400004[7:4] 0xC");

        konami_reset(ret); chk(ret == 0, "Konami MCU reset: status/error = 0/3");

        // JVS reset (E0 FF 03 F0 D9 CB): nothing answers it
        pkt[3] = 8'hf0; pkt[4] = 8'hd9;
        konami_send(8'hff, 2, ret); chk(ret == 0, "send F0 D9 to 0xff: every word taken");
        cyc(8000);
        konami_recv(ret); chk(ret == -5 && status == 2'd1, "reset unanswered: receive -5, status stays 1 (busy)");
        konami_send(8'h01, 0, ret); chk(ret == -3, "next send refused while busy (status != 0)");
        @(negedge clk); wr = 1; wd = 16'h01e0; @(negedge clk); wr = 0; cyc(200);
        chk(drdy, "a word written while busy is never taken (JVSDRDY stays up)");
        konami_reset(ret); chk(ret == 0 && !drdy, "MCU reset recovers: JVSDRDY cleared, status/error 0/3");

        // set address 1, sent to 0xff as ddr4m does; the unaddressed device answers
        pkt[3] = 8'hf1; pkt[4] = 8'h01;
        konami_send(8'hff, 2, ret); chk(ret == 0, "send F1 01 to 0xff");
        t = 0; ret = -5; while (ret == -5 && t < 200) begin cyc(100); konami_recv(ret); t = t + 1; end
        chk(ret == 2 && rx[3] == 8'h01 && rx[4] == 8'h01, "response E0 00 03 01 01: receive returns 2 bytes 01 01");
        cyc(4); chk(status == 2'd0, "status back to 0 after the last word");

        // a long response: 0x70 00 buffer read of 0x80 bytes (1 + 1 + 128 payload bytes)
        pkt[3] = 8'h70; pkt[4] = 8'h00; pkt[5] = 8'h02; pkt[6] = 8'h00; pkt[7] = 8'h00; pkt[8] = 8'h80;
        konami_send(8'h01, 6, ret); chk(ret == 0, "send 70 00 02 00 00 80 (odd total length: 10 bytes)");
        t = 0; ret = -5; while (ret == -5 && t < 200) begin cyc(100); konami_recv(ret); t = t + 1; end
        begin : chk_long
            integer ok; ok = (ret == 130);
            for (i = 0; i < 128; i = i + 1) if (rx[5 + i] !== (i ^ 8'h5a)) ok = 0;
            chk(ok, "130-byte response read word by word, payload intact");
        end
        chk(q[0] == 8'he0 && q[1] == 8'h01 && q[2] == 8'h07 && q[8] == 8'h80 && ql == 10, "bus saw E0 01 07 70 00 02 00 00 80 + checksum");

        // stale answer after an MCU reset is ignored
        answer_enable = 0;
        begin : stale
            reg [7:0] s1;
            pkt[3] = 8'h71; konami_send(8'h01, 1, ret); cyc(200); s1 = req_seq;
            konami_reset(ret);
            pkt[3] = 8'h71; konami_send(8'h01, 1, ret); cyc(200);
            @(negedge clk); resp_we = 1; resp_waddr = 0; resp_wdata = 16'h00e0; @(negedge clk);
            resp_waddr = 1; resp_wdata = 16'h0103; @(negedge clk); resp_waddr = 2; resp_wdata = 16'h0501; @(negedge clk); resp_we = 0;
            @(negedge clk); resp_len = 6; resp_seq = s1; resp_commit = 1; @(negedge clk); resp_commit = 0;
            cyc(100);
            chk(!irdy && status == 2'd1, "answer carrying the abandoned request's sequence number is ignored");
            @(negedge clk); resp_seq = req_seq; resp_commit = 1; @(negedge clk); resp_commit = 0;
            cyc(10);
            konami_recv(ret);
            chk(ret == 2 && rx[3] == 8'h01 && rx[4] == 8'h01, "answer with the current sequence number is delivered");
        end
        answer_enable = 1;

        // bad checksum -> error 1, unresponsive until reset
        @(negedge clk); wr = 1; wd = 16'h01e0; @(negedge clk); wr = 0; cyc(200);
        @(negedge clk); wr = 1; wd = 16'h1002; @(negedge clk); wr = 0; cyc(200);   // len 2: 10 + bad sum 0x77
        @(negedge clk); wr = 1; wd = 16'h0077; @(negedge clk); wr = 0; cyc(200);
        chk(err == 2'd1, "bad checksum -> error 1");
        konami_reset(ret); chk(ret == 0, "reset clears it");
        // bad sync -> error 2
        @(negedge clk); wr = 1; wd = 16'h01d0; @(negedge clk); wr = 0; cyc(200);
        chk(err == 2'd2, "first byte not 0xe0 -> error 2");
        konami_reset(ret);

        chk(answered == 2 && silent == 1, "bus: 2 packets answered, the reset left unanswered");
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
