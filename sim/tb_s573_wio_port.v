// tb_s573_wio_port.v -- the White I/O card port engine (rtl/s573_wio_port.v)
// against a behavioural PS1 card on the SNAC pins.
//
// The card: /SEL low selects it; it drives DAT on CLK falling edges (LSB first),
// samples CMD on rising edges, and after a byte pulls /ACK low for 3 us starting
// 12 us after the last rising edge (psx-spx Timings / Signals).  Each case checks
// the result code the reader program's routine (0x8000560c) would return:
//   A. a normal byte: the card's byte, /ACK seen, latch cleared
//   B. no card: "no /ACK" (-1) after the timeout
//   C. timeout 0 (last byte): the byte, no /ACK wait
//   D. latch left set -> next byte is an error (-2) without clocking
//   E. /ACK stuck low -> error (-2) 7 us after the latch
//   F. clock timing: 8 bits at the routine's ~219 kHz, CMD bits as sent
//   G/H. a late /ACK (915 us) against the 2000 us and 40 us timeouts
`timescale 1ns/1ps
module tb_s573_wio_port;
    reg clk = 0, rst = 1, en = 1;   // +red: en = 0, the pins stay idle (RED)
    always #14.76 clk = ~clk;            // 33.8688 MHz

    reg        reg_we = 0, latch_clr = 0, xfer_start = 0;
    reg  [7:0] reg_val = 8'hff, xfer_cmd = 0;
    reg [15:0] xfer_to = 0;
    wire       busy, done;
    wire [1:0] result;
    wire [7:0] rx_byte;
    wire [6:0] uo;
    reg        card_ack_n = 1, card_dat = 1;
    // USER_IN[3] = /ACK, [4] = DAT (psx/PSX.sv USER_IN3_* ack glitch filter, USER_IN4_* data)
    wire [6:0] ui = {1'b1, 1'b1, card_dat, card_ack_n, 1'b1, 1'b1, 1'b1};

    s573_wio_port #(.CLK_HZ(33_868_800)) dut (
        .clk(clk), .rst(rst), .en(en),
        .reg_we(reg_we), .reg_val(reg_val), .latch_clr(latch_clr),
        .xfer_start(xfer_start), .xfer_cmd(xfer_cmd), .xfer_timeout_us(xfer_to),
        .busy(busy), .done(done), .result(result), .rx_byte(rx_byte),
        .user_out(uo), .user_in(ui));

    wire sel1_n = uo[1], cmd = uo[2], sclk = uo[5];

    // ---- behavioural card on SNAC port 1 ----
    reg        present = 1, stuck = 0;
    integer    ack_delay = 12000;     // ns; G uses the Sony late /ACK (915 us)
    reg  [7:0] out_byte = 8'h5a, in_byte;
    integer    nb = 0;
    real       t_rise;
    real       last_fall = 0, min_low = 1e9, min_high = 1e9, last_rise = 0;
    always @(negedge sclk) if (!sel1_n && present) begin
        card_dat <= out_byte[nb];
        if (last_rise > 0 && ($realtime - last_rise) < min_high) min_high = $realtime - last_rise;
        last_fall = $realtime;
    end
    always @(posedge sclk) if (!sel1_n && present) begin
        in_byte = {cmd, in_byte[7:1]};
        if (($realtime - last_fall) < min_low) min_low = $realtime - last_fall;
        last_rise = $realtime;
        nb = nb + 1;
        if (nb == 8) begin
            nb = 0;
            t_rise = $realtime;
            fork begin
                #(ack_delay) card_ack_n = 0;
                if (!stuck) begin #3000 card_ack_n = 1; end
            end join_none
        end
    end
    always @(posedge sel1_n) begin nb = 0; card_dat = 1; end

    integer fails = 0, checks = 0;
    task check(input cond, input [511:0] what);
        begin checks = checks + 1; if (!cond) begin fails = fails + 1; $display("FAIL %0s", what); end end
    endtask

    task wreg(input [7:0] v);
        begin @(posedge clk) begin reg_we <= 1; reg_val <= v; end @(posedge clk) reg_we <= 0; repeat (6) @(posedge clk); end
    endtask
    task clrl;
        begin @(posedge clk) latch_clr <= 1; @(posedge clk) latch_clr <= 0; end
    endtask
    task xfer(input [7:0] c, input [15:0] to);
        begin
            @(posedge clk) begin xfer_start <= 1; xfer_cmd <= c; xfer_to <= to; end
            @(posedge clk) xfer_start <= 0;
            @(posedge clk);
            while (busy) @(posedge clk);
        end
    endtask

    initial begin
        if ($test$plusargs("red")) en = 0;
        repeat (5) @(posedge clk); rst <= 0;
        wreg(8'hff);                     // deselected, CLK high
        clrl;
        wreg(8'hfb);                     // select port 0 (SNAC port 1)
        $display("  after select: uo %b creg %h", uo, dut.creg);
        check(uo[1] == 0 && uo[0] == 1 && uo[5] == 1, "select: /SEL1 low, /SEL2 high, CLK high");

        // A + F
        out_byte = 8'h3c;
        xfer(8'h81, 16'd40);
        $display("  A: result %0d byte %h card got %h", result, rx_byte, in_byte);
        check(result == 0 && rx_byte == 8'h3c, "A: byte with /ACK");
        check(in_byte == 8'h81, "F: card received the command LSB first");
        $display("  clock: low %0.0f ns, high %0.0f ns", min_low, min_high);
        check(min_low > 2200 && min_low < 2400, "F: CLK low phase ~2.3 us");
        check(min_high > 2200 && min_high < 2500, "F: CLK high phase ~2.3 us");
        check(dut.latch == 0, "A: latch cleared");

        // C: timeout 0 -> byte, no wait; the card still ACKs, which sets the latch
        out_byte = 8'h47;
        xfer(8'h00, 16'd0);
        check(result == 0 && rx_byte == 8'h47, "C: last byte returned without waiting");
        #20000;
        // D: the latch from C is still set -> error, no clocking
        xfer(8'h00, 16'd40);
        check(result == 2, "D: latch set at the start -> error");
        clrl;

        // B: no card
        present = 0;
        xfer(8'h81, 16'd40);
        check(result == 1, "B: no card -> no /ACK");
        present = 1;
        clrl;

        // E: /ACK stuck low
        stuck = 1;
        out_byte = 8'h11;
        xfer(8'h81, 16'd40);
        check(result == 2, "E: /ACK still low 7 us later -> error");
        stuck = 0;
        card_ack_n = 1;
        clrl;

        // G: the late /ACK after a Read's 7th byte (psx-spx: ~915 us on Sony cards),
        //    which the routine waits for with a 2000 us timeout (fw 0x800058c8)
        ack_delay = 915000;
        out_byte = 8'h5c;
        xfer(8'h00, 16'd2000);
        check(result == 0 && rx_byte == 8'h5c, "G: late /ACK inside the 2000 us timeout");
        ack_delay = 12000;
        // H: the same with the 40 us timeout -> no /ACK (and the latch catches it later)
        ack_delay = 915000;
        xfer(8'h00, 16'd40);
        check(result == 1, "H: late /ACK past a 40 us timeout -> no /ACK");
        ack_delay = 12000;

        if (fails) $display("RESULT: FAIL (s573_wio_port, %0d of %0d checks)", fails, checks);
        else       $display("RESULT: PASS (s573_wio_port, %0d checks)", checks);
        $finish;
    end
endmodule
