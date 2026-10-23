`timescale 1ns/1ps
// tb_573in1_ide.v -- replay 573in1's IDE driver against atapi.v.
//
// Stimulus source: spicyjpeg/573in1 (commit b57da08) src/common/ide.cpp
//   Device::_resetDrive  (CS1 device control SRST pulse, select, wait !BSY)
//   Device::enumerate    (signature 0xEB14 -> IDENTIFY PACKET 0xA1, checksum word
//                         255, SET FEATURES 0xEF transfer mode, then poll())
//   Device::poll / _atapiPacket (TEST UNIT READY, byte count 0x800 in the
//                         cylinder registers, 12-byte packet over the data port)
//   Device::_atapiRead   (READ(12)-style packet, per-sector DRQ, length from the
//                         cylinder registers, then wait !BSY)
// 573in1 enumerates BOTH devices on the bus (ide::devices[2]). A 573 carries one
// CR-589 as device 0; per 573in1's own note and MAME atahle.cpp (m_single_device),
// a lone device 0 shadows the registers for device 1 but ignores its COMMAND writes
// and reads STATUS as 0 -- so the device-1 probe must time out (NO_DRIVE), not find
// a second drive.
module tb_573in1_ide;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg        sel = 0, we = 0, re = 0;
    reg  [3:0] addr = 0;
    reg  [15:0] din = 0;
    wire [15:0] dout;
    wire       intrq;

    atapi #(.NSECT(4)) dut (
        .clk(clk), .rst(rst), .ide_rst(1'b0),
        .sel(sel), .addr(addr), .we(we), .re(re), .din(din), .dout(dout), .intrq(intrq),
        .cd_attached(1'b0), .sec_req(), .sec_lba(), .sbuf_addr(), .sbuf_q(16'h0000), .sec_ready(1'b0),
        .toc_track_count(8'd1), .toc_leadout(32'd1000), .toc_qtrack(), .toc_qstart(32'd0), .toc_qaudio(1'b0),
        .dma_req(), .dma_rd(1'b0), .dma_dout()
    );

    localparam CS0_DATA=0, CS0_FEAT=1, CS0_COUNT=2, CS0_SECTOR=3, CS0_CYL_L=4, CS0_CYL_H=5,
               CS0_DEV=6, CS0_CMD=7, CS1_CTRL=8;
    localparam [7:0] ST_BSY=8'h80, ST_DRDY=8'h40, ST_DRQ=8'h08, ST_ERR=8'h01;

    integer errors = 0;

    task bus_wr(input [3:0] a, input [15:0] d); begin
        @(negedge clk); sel=1; we=1; addr=a; din=d; @(negedge clk); sel=0; we=0;
        repeat (4) @(negedge clk);
    end endtask
    task bus_rd(input [3:0] a, output [15:0] d); begin
        @(negedge clk); sel=1; re=1; addr=a; #1 d = dout; @(negedge clk); sel=0; re=0;
        repeat (4) @(negedge clk);
    end endtask
    task rd8(input [3:0] a, output [7:0] v); reg [15:0] t; begin bus_rd(a, t); v = t[7:0]; end endtask

    // _waitForIdle(drdy=0) / _waitForDRQ, polling every "10 us" (100 clocks here)
    task waitIdle(input integer polls, output integer err); reg [7:0] st; integer k; begin
        err = 4; // STATUS_TIMEOUT
        for (k = 0; k < polls && err == 4; k = k + 1) begin
            rd8(CS0_CMD, st);
            if (!(st & ST_BSY)) err = (st & ST_ERR) ? 6 : 0;
            else repeat (100) @(negedge clk);
        end
    end endtask
    task waitDRQ(input integer polls, output integer err); reg [7:0] st; integer k; begin
        err = 4;
        for (k = 0; k < polls && err == 4; k = k + 1) begin
            rd8(CS0_CMD, st);
            if (!(st & ST_BSY) && (st & ST_ERR)) err = 6;
            else if (st & ST_DRQ) err = 0;
            else repeat (100) @(negedge clk);
        end
    end endtask

    task select(input dev); begin bus_wr(CS0_DEV, dev ? 16'h00B0 : 16'h00A0); end endtask

    // Device::enumerate (returns DeviceError: 0 ok, 2 NO_DRIVE, ...)
    task enumerate(input dev, output integer result); integer e, i; reg [7:0] lo, hi;
        reg [15:0] w; reg [15:0] blk [0:255]; reg [7:0] sum; begin
        result = 0;
        // _resetDrive
        bus_wr(CS1_CTRL, 16'h0006); repeat (50) @(negedge clk);   // IEN|SRST
        bus_wr(CS1_CTRL, 16'h0002); repeat (50) @(negedge clk);   // IEN
        select(dev);
        waitIdle(2500, e);
        if (e) begin result = 2; $display("  dev%0d: select timeout", dev); end
        else begin
            rd8(CS0_CYL_L, lo); rd8(CS0_CYL_H, hi);
            if ({hi, lo} == 16'hEB14) bus_wr(CS0_CMD, 16'h00A1);      // IDENTIFY PACKET
            else                      bus_wr(CS0_CMD, 16'h00EC);      // IDENTIFY
            waitDRQ(2500, e);                                         // _DETECT_TIMEOUT
            if (e) begin
                result = 2;                                           // NO_DRIVE
                bus_wr(CS0_CMD, 16'h0008);                            // _handleTimeout (ATAPI)
            end else begin
                for (i = 0; i < 256; i = i + 1) begin bus_rd(CS0_DATA, w); blk[i] = w; end
                if (blk[255][7:0] == 8'hA5) begin
                    sum = 0; for (i = 0; i < 255; i = i + 1) sum = sum + blk[i][7:0] + blk[i][15:8];
                    sum = sum + 8'hA5;
                    if (sum + blk[255][15:8] != 8'h00) begin result = 5; $display("  dev%0d: IDENTIFY checksum bad", dev); end
                end
                if (result == 0) begin
                    if (blk[0][12:8] != 5'h05) begin result = 6; $display("  dev%0d: word0 0x%04h not a CD-ROM", dev, blk[0]); end
                    select(dev); waitIdle(2500, e);
                    bus_wr(CS0_FEAT, 16'h0003); bus_wr(CS0_COUNT, 16'h0008); bus_wr(CS0_CMD, 16'h00EF);
                    waitIdle(2500, e);
                    if (e) begin result = e; $display("  dev%0d: SET FEATURES error %0d", dev, e); end
                end
            end
        end
    end endtask

    // _atapiPacket: write byte count 0x800, PACKET, 12 bytes, then wait DRQ or idle
    task packet(input dev, input [95:0] cdb, input has_data, output integer err); integer e, i; begin
        select(dev); waitIdle(2500, e);
        if (!e) begin
            bus_wr(CS0_FEAT, 0); bus_wr(CS0_CYL_L, 16'h0000); bus_wr(CS0_CYL_H, 16'h0008);
            bus_wr(CS0_CMD, 16'h00A0);
            waitDRQ(2500, e);
        end
        if (!e) begin
            for (i = 0; i < 6; i = i + 1) bus_wr(CS0_DATA, {cdb[95-16*i-8 -: 8], cdb[95-16*i -: 8]});
            if (has_data) waitDRQ(2500, e); else waitIdle(2500, e);
        end
        err = e;
    end endtask

    integer r0, r1, e, i, bad; reg [7:0] lo, hi, exp_lo, exp_hi; reg [15:0] w;
    initial begin
        repeat (10) @(negedge clk); rst = 0; repeat (10) @(negedge clk);

        $display("[device 0 = CR-589]");
        enumerate(1'b0, r0);
        if (r0 != 0) begin $display("  FAIL dev0 enumerate -> %0d", r0); errors = errors + 1; end
        else $display("  ok   dev0 enumerated as an ATAPI CD-ROM");
        packet(1'b0, 96'h00_00_00_00_00_00_00_00_00_00_00_00, 1'b0, e);       // TEST UNIT READY
        if (e) begin $display("  FAIL dev0 TEST UNIT READY -> %0d", e); errors = errors + 1; end
        else $display("  ok   dev0 TEST UNIT READY good");

        $display("[device 1 = absent]");
        enumerate(1'b1, r1);
        if (r1 != 2) begin $display("  FAIL dev1 enumerate -> %0d (want 2 = NO_DRIVE: phantom second drive)", r1); errors = errors + 1; end
        else $display("  ok   dev1 probe timed out -> NO_DRIVE");

        $display("[device 0 after the device-1 probe]");
        // READ(12) LBA 1, 1 sector, PIO, byte count from the cylinder registers
        packet(1'b0, 96'hA8_00_00_00_00_01_00_00_00_01_00_00, 1'b1, e);
        if (e) begin $display("  FAIL dev0 READ(12) -> %0d", e); errors = errors + 1; end
        else begin
            rd8(CS0_CYL_L, lo); rd8(CS0_CYL_H, hi);
            if ({hi, lo} != 16'h0800) begin $display("  FAIL byte count 0x%04h", {hi, lo}); errors = errors + 1; end
            bad = 0;
            for (i = 0; i < 1024; i = i + 1) begin
                bus_rd(CS0_DATA, w);
                exp_lo = 2*i; exp_hi = 2*i + 1;                     // sim disc pattern: byte n = n[7:0]
                if (w !== {exp_hi, exp_lo}) bad = bad + 1;
            end
            waitIdle(2500, e);
            if (bad || e) begin $display("  FAIL dev0 sector data (%0d bad words, idle err %0d)", bad, e); errors = errors + 1; end
            else $display("  ok   dev0 read LBA 1 by PIO (2048 bytes)");
        end

        if (errors == 0) $display("RESULT: PASS (573in1_ide)");
        else             $display("RESULT: FAIL (573in1_ide, %0d errors)", errors);
        $finish;
    end
endmodule
