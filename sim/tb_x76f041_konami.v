`timescale 1ns/1ps
// tb_x76f041_konami -- x76f041.v driven with the EXACT bus sequences of the two
// X76F041 drivers we have code for, against the REAL ddr4m install cassette image
// (gea33aa.u1: config password cdf2a448fb2a8802, BCR1 = BCR2 = 0xff, so every data
// read needs the configuration password -- command 0x60).
//
// Part K  Konami, ddr4m boot loader PSX.EXE (a33aaa02 / a33jaa02, identical code),
//         X76F041 driver vtable at 0x803594f0, read entry 0x8032477c:
//           ack-poll START + (0x60 | addr[8]) (0x803245c4), addr[7:0], 8 password
//           bytes, ack-poll START + 0xC0 until ACK, then (n-1) bytes read with ACK
//           (0x80323ec0) and the last byte read with ACK followed at once by STOP
//           while SCL is still high (0x80323f70). The FIRST byte after the poll is
//           stored as data[addr] -- there is no byte to skip. Callers read in
//           8-byte chunks (0x80323534, 0x803239b0).
// Part N  Konami's no-password read (0x80324c44, taken when the read address has
//         bit 15 set): START + (0x20 | addr[8]), addr, then for every further byte
//         8 bits with NO ninth clock, START + new address, ... last byte ACK+STOP.
//         gea33aa's BCR (Z=T=1) refuses command 0x20, as MAME does; Part N runs it
//         on a fresh device with BCR = 0x00 (compile-time params).
// Part S  573in1 X76F041Driver::readPrivateData: 0x60 + addr + password, ack
//         poll, read and DISCARD one byte ("secure read setup"), START, the SAME
//         address again (no command, no password), 128 bytes. Datasheet: after
//         the first byte "another start can be issued followed by a new 8-bit
//         address" within the 1K-bit block, no password again.
//         RED before the rd_auth/rd_restart change (MAME's load_address() asked
//         for the password again and the data bytes were eaten as one).
// Part X  re-address into ANOTHER 128-byte block after an authenticated read: the
//         datasheet confines it to the original block; the model falls back to
//         MAME's load_address() (password required again) -- asserted so a later
//         change is deliberate.
module tb_x76f041_konami;
    reg  clk = 0, rst = 1;
    reg  cs = 1, sec_rst = 0, scl = 0, sda_m = 1;
    wire sda_o, sda2_o;
    reg        ld_we = 0; reg [9:0] ld_a = 0; reg [7:0] ld_d = 0;
    integer errors = 0;

    x76f041 dut (
        .clk(clk), .rst(rst), .cs(cs), .sec_rst(sec_rst),
        .scl(scl), .sda_i(sda_m), .sda_o(sda_o),
        .load_we(ld_we), .load_addr(ld_a), .load_data(ld_d)
    );
    // Part N device: password-free blocks (BCR1 = BCR2 = 0x00)
    x76f041 #(.CONFIG_REGS(64'h0000_0000_0000_0000)) dut2 (
        .clk(clk), .rst(rst), .cs(cs), .sec_rst(sec_rst),
        .scl(scl), .sda_i(sda_m), .sda_o(sda2_o),
        .load_we(1'b0), .load_addr(10'd0), .load_data(8'd0)
    );
    reg use2 = 0;
    wire sda_dev = use2 ? sda2_o : sda_o;
    wire sda_line = sda_m & sda_dev;       // wired-AND, as the cassette bus

    always #5 clk = ~clk;
    task tk; begin repeat (3) @(posedge clk); end endtask

    // ---- Konami primitives (PSX.EXE 0x80323a28 / 0x80323b08 / 0x80323bc0 / ...) ----
    task start; begin sda_m = 1; tk; scl = 1; tk; sda_m = 0; tk; scl = 0; tk; end endtask
    task stop;  begin sda_m = 0; tk; scl = 1; tk; sda_m = 1; tk; scl = 0; tk; end endtask
    task send(input [7:0] d, output nak);
        integer i; begin
            for (i = 7; i >= 0; i = i - 1) begin sda_m = d[i]; tk; scl = 1; tk; scl = 0; tk; end
            sda_m = 1; tk; scl = 1; tk; nak = sda_line; scl = 0; tk;
        end
    endtask
    task rd8(output [7:0] d);                       // 0x80323e08: 8 bits, no 9th clock
        integer i; begin
            sda_m = 1; d = 0;
            for (i = 7; i >= 0; i = i - 1) begin scl = 1; tk; d[i] = sda_line; scl = 0; tk; end
        end
    endtask
    task rd_ack(output [7:0] d); begin              // 0x80323ec0
        rd8(d); sda_m = 0; tk; scl = 1; tk; scl = 0; tk; sda_m = 1; tk;
    end endtask
    task rd_last(output [7:0] d); begin             // 0x80323f70: ACK then STOP on the same high
        rd8(d); sda_m = 0; tk; scl = 1; tk; sda_m = 1; tk; scl = 0; tk;
    end endtask
    task rd_nak(output [7:0] d); begin              // plain NAK (573in1 last byte)
        rd8(d); sda_m = 1; tk; scl = 1; tk; scl = 0; tk;
    end endtask
    task poll(input [7:0] b, output nak);           // 0x803245c4: START + byte until ACK
        integer n; begin
            n = 0; nak = 1;
            while (nak && n < 16) begin start; send(b, nak); n = n + 1; end
        end
    endtask

    reg [7:0] img [0:563];           // ddr4m_cas.hex: {gca33aa.u6, gea33aa.u6, gea33aa.u1}
    reg [7:0] d, cpw [0:7];
    reg       nak;
    integer   i, a, bad, fd;

    function [7:0] pat(input [8:0] x); pat = x[7:0] ^ {x[8], 7'h5a}; endfunction
    task send_cpw; integer j; begin for (j = 0; j < 8; j = j + 1) send(cpw[j], nak); end endtask

    initial begin
        fd = $fopen("secdata/ddr4m_cas.hex", "r");
        if (fd == 0) begin
            $display("FAIL: secdata/ddr4m_cas.hex missing (run gen_secdata.sh with the ddr4m dump)");
            $display("RESULT: FAIL"); $finish;
        end
        $fclose(fd);
        $readmemh("secdata/ddr4m_cas.hex", img);
        for (i = 0; i < 8; i = i + 1) cpw[i] = img[16 + 20 + i];
        $display("  gea33aa: cpw %02h%02h%02h%02h%02h%02h%02h%02h  BCR1 %02h BCR2 %02h",
                 cpw[0],cpw[1],cpw[2],cpw[3],cpw[4],cpw[5],cpw[6],cpw[7], img[16+28], img[16+29]);

        repeat (4) @(posedge clk); @(negedge clk); rst = 0;
        for (i = 0; i < 548; i = i + 1) begin
            @(negedge clk); ld_we = 1; ld_a = i; ld_d = img[16 + i];
        end
        @(negedge clk); ld_we = 0; tk;
        cs = 0; tk; stop;

        // ---------------- Part K: Konami 0x60 read, 8-byte chunks ----------------
        bad = 0;
        for (a = 0; a < 512; a = a + 8) begin
            poll(8'h60 | a[8], nak);
            if (nak) begin $display("FAIL: K cmd NAK @%03h", a); errors = errors + 1; end
            send(a[7:0], nak);
            send_cpw;
            poll(8'hc0, nak);
            if (nak) begin $display("FAIL: K password poll NAK @%03h", a); errors = errors + 1; end
            for (i = 0; i < 8; i = i + 1) begin
                if (i < 7) rd_ack(d); else rd_last(d);
                if (d !== img[16 + 36 + a + i]) begin
                    if (bad < 4) $display("  K data[%03h] = %02h, image %02h", a + i, d, img[16 + 36 + a + i]);
                    bad = bad + 1;
                end
            end
        end
        if (bad) begin $display("FAIL: K Konami 0x60 read: %0d/512 bytes wrong", bad); errors = errors + 1; end
        else $display("  ok  K Konami 0x60 8-byte reads: all 512 bytes = gea33aa.u1");

        // command 0x20 (no password) is refused by this image's BCR (Z = T = 1)
        start; send(8'h20, nak); send(8'h00, nak);
        if (nak !== 1'b1) begin $display("FAIL: K 0x20 accepted despite BCR Z/T"); errors = errors + 1; end
        else $display("  ok  K 0x20 refused on gea33aa (BCR 0xff), as MAME");
        stop;

        // The real image is mostly 0x00, which would let a broken re-address pass by
        // luck: fill the array with a position-dependent pattern first, using
        // Konami's write entry (0x803248a8: START + 0x40|addr[8], addr, password,
        // ack-poll 0xC0, 8 data bytes, STOP), then check it with Konami's read.
        for (a = 0; a < 512; a = a + 8) begin
            poll(8'h40 | a[8], nak); send(a[7:0], nak); send_cpw; poll(8'hc0, nak);
            if (nak) begin $display("FAIL: W password poll NAK @%03h", a); errors = errors + 1; end
            for (i = 0; i < 8; i = i + 1) send(pat(a + i), nak);
            stop; tk;
        end
        bad = 0;
        for (a = 0; a < 512; a = a + 8) begin
            poll(8'h60 | a[8], nak); send(a[7:0], nak); send_cpw; poll(8'hc0, nak);
            for (i = 0; i < 8; i = i + 1) begin
                if (i < 7) rd_ack(d); else rd_last(d);
                if (d !== pat(a + i)) bad = bad + 1;
            end
        end
        if (bad) begin $display("FAIL: W pattern write/read: %0d bytes wrong", bad); errors = errors + 1; end
        else $display("  ok  W Konami 0x40 writes + 0x60 reads of a 512-byte pattern");

        // ---------------- Part S: 573in1 readPrivateData ----------------
        bad = 0;
        for (a = 0; a < 512; a = a + 128) begin
            start; send(8'h60 | a[8], nak); send(a[7:0], nak); send_cpw;
            poll(8'hc0, nak);
            if (nak) begin $display("FAIL: S password poll NAK @%03h", a); errors = errors + 1; end
            rd_nak(d);                               // ignore "secure read setup" byte
            start; send(a[7:0], nak);
            if (nak) begin $display("FAIL: S NAK after resending addr %02h", a[7:0]); errors = errors + 1; end
            for (i = 0; i < 128; i = i + 1) begin
                if (i < 127) rd_ack(d); else rd_nak(d);
                if (d !== pat(a + i)) begin
                    if (bad < 4) $display("  S data[%03h] = %02h, want %02h", a + i, d, pat(a + i));
                    bad = bad + 1;
                end
            end
            stop;
        end
        if (bad) begin $display("FAIL: S 573in1 re-addressed read: %0d/512 bytes wrong", bad); errors = errors + 1; end
        else $display("  ok  S 573in1 setup byte + re-address: all 512 bytes");

        // ---------------- Part X: re-address into another block ----------------
        start; send(8'h60, nak); send(8'h00, nak); send_cpw; poll(8'hc0, nak);
        rd_ack(d); start; send(8'h80, nak);          // block 1 address: MAME path -> password
        // the device now expects a password: data reads must not return block 1
        rd_ack(d);
        if (d === pat(9'h080)) begin
            $display("FAIL: X cross-block re-address served data without a password"); errors = errors + 1;
        end else $display("  ok  X cross-block re-address falls back to load_address()");
        stop;

        // ---------------- Part N: Konami no-password per-byte re-address ----------------
        use2 = 1;
        // write 8 known bytes at 0x40 (password-free WRITE, command 0x00)
        start; send(8'h00, nak); send(8'h40, nak);
        for (i = 0; i < 8; i = i + 1) send(8'hA0 + i[7:0], nak);
        stop; tk;
        start; send(8'h20, nak); send(8'h40, nak);
        bad = 0;
        for (i = 0; i < 8; i = i + 1) begin
            if (i > 0) poll(8'h40 + i[7:0], nak);
            if (i < 7) rd8(d); else rd_last(d);
            if (d !== 8'hA0 + i[7:0]) begin $display("  N byte %0d = %02h", i, d); bad = bad + 1; end
        end
        if (bad) begin $display("FAIL: N Konami 0x20 re-addressed read"); errors = errors + 1; end
        else $display("  ok  N Konami 0x20 per-byte re-address (no 9th clock) reads back");

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
