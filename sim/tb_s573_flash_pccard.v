`timescale 1ns/1ps
// Testbench for the PCMCIA slot-2 32 MB linear flash card in s573_flash.v
// (SIM_BACKING=0, the SDRAM-backed path that actually synthesises).
//
// AUTHORITATIVE SOURCES (dumps/mame573/, mame0288):
//   ksys573.cpp:982-995   flashbank_map: 0x8000000-0xbffffff -> "pccard2"
//   ksys573.cpp:1149      m_flashbank->set_bank(m_control & 0x3f)  (raw, no shift)
//   ksys573.cpp:2584      ADDRESS_MAP_BANK ... 0x400000 stride    -> pccard2 = banks 32-47
//   ksys573.cpp:2662-2667 pccard2_32mb -> FUJITSU_32MB_FLASH_CARD
//   ksys573.cpp:2779-2788 ddr3mp (= ddr4m's config) calls pccard2_32mb
//   linflash.h            fujitsu_32mb_flash_card_device : linear_flash_pccard_29f017a_device<8>
//   linflash.cpp amap     global_mask((8*0x400000)-1) = 0x1FFFFFF; each pair maps
//                         0x400000 bytes, .L on umask16 0x00ff / .U on 0xff00
//   linflash.cpp          read_memory(offset) -> m_space->read_word(offset*2)
//   intelfsh.cpp:201      FUJITSU_29F016A = 0x200000 bytes/die, maker 0x04, dev 0xAD
//   pccard.cpp            pccard_slot_device::read_memory returns 0xffff with no card
//
// The contract under test:
//   card_word[23:0] = { bank[2:0], win_addr[20:0] }   (16 M words = 32 MB)
//   bank[3] is the 64 MB-window mirror global_mask folds away (40-47 alias 32-39)
//   the line-buffer tag carries a REGION bit so an onboard line and a card line at
//   the same flat offset can never alias
//   card_en=0 -> banks 32-47 are an EMPTY SLOT: 0xFFFF, and no SDRAM fill at all
//   banks 16-31 (slot 1, not modelled) stay 0xFFFF even with the card enabled
//   program / sector-erase bookkeeping is PER CHIP PAIR across BOTH images
//   (pu = {region, pair}), so a card erase never makes an onboard bank busy
//
// RED/GREEN: `make S573_FLASH_NO_PCCARD=1 s573_flash_pccard` compiles s573_flash.v
// with the pre-Tier-3 decode (banks 32-47 permanently absent). This bench is RED
// under that define and GREEN by default -- proof it exercises the card decode
// without hand-reverting RTL. Default builds (and `all`) never set it.
module tb_s573_flash_pccard;
    reg        clk = 0, rst = 1;
    reg        ctl_we = 0;
    reg [15:0] ctl_din = 0;
    reg        card_en = 0;
    wire [5:0] bank;
    wire       sec_io0_dir, cpld_sig;
    reg        win_sel = 0, win_we = 0;
    reg [20:0] win_addr = 0;
    reg [15:0] win_din = 0;
    wire [15:0] win_dout;
    wire        flash_ready;
    wire        flash_mem_req;
    wire [26:0] flash_mem_addr;
    wire        flash_mem_card;
    reg [127:0] flash_mem_q = 0;
    reg         flash_mem_ready = 0;
    wire        flash_wr_req;
    wire        flash_wr_busy;
    wire [26:0] flash_wr_addr;
    wire        flash_wr_card;
    wire [15:0] flash_wr_data;
    reg         flash_wr_ack = 0;
    integer errors = 0;

    s573_flash #(.WIN_WORDS(2048), .SECTOR_WORDS(512), .NUM_BANKS(4),
                 .CARD_PAIRS(8), .ERASE_CHIP_WORDS(4096), .SIM_BACKING(0)) dut (
        .clk(clk), .rst(rst), .card_en(card_en), .card_slot1(1'b0),
        .ctl_we(ctl_we), .ctl_din(ctl_din),
        .bank(bank), .sec_io0_dir(sec_io0_dir), .cpld_sig(cpld_sig),
        .win_sel(win_sel), .win_addr(win_addr), .win_we(win_we),
        .win_din(win_din), .win_dout(win_dout), .flash_ready(flash_ready),
        .flash_mem_req(flash_mem_req), .flash_mem_addr(flash_mem_addr),
        .flash_mem_card(flash_mem_card),
        .flash_mem_q(flash_mem_q), .flash_mem_ready(flash_mem_ready),
        .flash_wr_req(flash_wr_req), .flash_wr_busy(flash_wr_busy),
        .flash_wr_addr(flash_wr_addr), .flash_wr_card(flash_wr_card),
        .flash_wr_data(flash_wr_data), .flash_wr_ack(flash_wr_ack),
        .dbg_flash()
    );

    always #5 clk = ~clk;

    // ---- behavioral TWO-IMAGE SDRAM model ----------------------------------
    // Key = {card, flat 24-bit word}: emu.sv adds FLASH_START for card=0 and
    // CARD_START for card=1, so the two images are physically disjoint. The
    // factory patterns are deliberately DIFFERENT per image, so any region-tag
    // aliasing in the line buffer shows up as wrong data rather than silently
    // passing.
    function [15:0] backing(input [24:0] k);
        backing = k[24] ? ({k[6:0], 9'h05A} ^ 16'h3C00)
                        : ({k[6:0], 9'h0A5} ^ 16'hC000);
    endfunction

    // Programmed-word overlay CAM + erased-range layer (same shape as
    // tb_s573_flash_erase: the walker commits 64K+ sequential 0xFFFF writes, far
    // beyond any word CAM).
    localparam OV = 64;
    reg [24:0] ov_addr [0:OV-1];
    reg [15:0] ov_data [0:OV-1];
    reg        ov_val  [0:OV-1];
    localparam NR = 8;
    reg [24:0] rg_base [0:NR-1];
    reg [24:0] rg_end  [0:NR-1];
    reg        rg_val  [0:NR-1];
    integer    oi;
    initial begin
        for (oi = 0; oi < OV; oi = oi + 1) ov_val[oi] = 0;
        for (oi = 0; oi < NR; oi = oi + 1) rg_val[oi] = 0;
    end

    function [15:0] read_word(input [24:0] k);
        integer j; reg [15:0] r;
        begin
            r = backing(k);
            for (j = 0; j < NR; j = j + 1)
                if (rg_val[j] && k >= rg_base[j] && k <= rg_end[j]) r = 16'hFFFF;
            for (j = 0; j < OV; j = j + 1)
                if (ov_val[j] && ov_addr[j] == k) r = ov_data[j];   // CAM wins
            read_word = r;
        end
    endfunction

    task commit_write(input [24:0] a, input [15:0] d);
        integer j; reg done;
        begin
            done = 0;
            for (j = 0; j < OV; j = j + 1)
                if (!done && ov_val[j] && ov_addr[j] == a) begin
                    ov_data[j] = d; done = 1;
                end
            if (!done && d == 16'hFFFF) begin
                for (j = 0; j < NR; j = j + 1)
                    if (!done && rg_val[j] && a == rg_end[j] + 1) begin
                        rg_end[j] = a; done = 1;
                    end
                for (j = 0; j < NR; j = j + 1)
                    if (!done && rg_val[j] && a >= rg_base[j] && a <= rg_end[j])
                        done = 1;
                for (j = 0; j < NR; j = j + 1)
                    if (!done && !rg_val[j]) begin
                        rg_val[j] = 1; rg_base[j] = a; rg_end[j] = a; done = 1;
                    end
                if (!done) begin
                    $display("TB-INFRA FAIL: erased-range slots exhausted at %h", a);
                    errors = errors + 1;
                end
            end else if (!done) begin
                for (j = 0; j < OV; j = j + 1)
                    if (!done && !ov_val[j]) begin
                        ov_val[j] = 1; ov_addr[j] = a; ov_data[j] = d; done = 1;
                    end
                if (!done) begin
                    $display("TB-INFRA FAIL: overlay CAM full at %h", a);
                    errors = errors + 1;
                end
            end
        end
    endtask

    // Fill model: answer a burst 3 cycles after flash_mem_req, from the image
    // flash_mem_card names. Also RECORDS the image bit of the last fill so the
    // bench can assert which backing store the DUT asked for.
    reg [2:0]  dly = 0;
    reg        pending = 0;
    reg [24:0] base = 0;
    reg        last_fill_card = 1'bx;
    reg [26:0] last_fill_addr = 0;
    integer    fill_reqs = 0;
    integer    i;
    always @(posedge clk) begin
        flash_mem_ready <= 0;
        if (flash_mem_req && !pending) begin
            pending <= 1; dly <= 3;
            base <= {flash_mem_card, flash_mem_addr[23:0]};
            last_fill_card <= flash_mem_card;
            last_fill_addr <= flash_mem_addr;
            fill_reqs = fill_reqs + 1;
        end else if (pending) begin
            if (dly > 1) dly <= dly - 1;
            else begin
                for (i = 0; i < 8; i = i + 1)
                    flash_mem_q[i*16 +: 16] <= read_word(base + i[24:0]);
                flash_mem_ready <= 1;
                pending <= 0;
            end
        end
    end

    // ch3 single-word write-back model (3-cycle latency), two-image aware.
    reg [2:0]  wdly = 0;
    reg        wpend = 0;
    reg [24:0] wadr = 0;
    reg [15:0] wdat = 0;
    reg        last_wr_card = 1'bx;
    reg [26:0] last_wr_addr = 0;
    always @(posedge clk) begin
        flash_wr_ack <= 0;
        if (flash_wr_req && !wpend) begin
            wpend <= 1; wdly <= 3;
            wadr <= {flash_wr_card, flash_wr_addr[23:0]};
            wdat <= flash_wr_data;
            last_wr_card <= flash_wr_card;
            last_wr_addr <= flash_wr_addr;
        end else if (wpend) begin
            if (wdly > 1) wdly <= wdly - 1;
            else begin
                commit_write(wadr, wdat);
                flash_wr_ack <= 1;
                wpend <= 0;
            end
        end
    end

    // ---- bus tasks (same shape as tb_s573_flash_sdram / _erase) -------------
    integer last_stall;
    task flash_read(input [20:0] a, output [15:0] d);
        integer guard;
        begin
            @(negedge clk); win_sel = 1; win_we = 0; win_addr = a;
            #1;
            guard = 0;
            while (flash_ready !== 1'b1 && guard < 400) begin
                @(negedge clk); #1; guard = guard + 1;
            end
            last_stall = guard;
            d = win_dout;
            @(negedge clk); win_sel = 0;
        end
    endtask

    task win_write(input [20:0] a, input [15:0] dd);
        begin @(negedge clk); win_sel=1; win_we=1; win_addr=a; win_din=dd;
              @(negedge clk); win_sel=0; win_we=0; end
    endtask

    task flash_program(input [20:0] a, input [15:0] dd);
        begin
            win_write(21'h555, 16'h00AA);
            win_write(21'h2AA, 16'h0055);
            win_write(21'h555, 16'h00A0);
            win_write(a, dd);
            @(negedge clk);
            while (flash_wr_busy === 1'b1) @(negedge clk);
        end
    endtask

    task flash_sector_erase(input [20:0] a);
        begin
            win_write(21'h555, 16'h00AA);
            win_write(21'h2AA, 16'h0055);
            win_write(21'h555, 16'h0080);
            win_write(21'h555, 16'h00AA);
            win_write(21'h2AA, 16'h0055);
            win_write(a,       16'h0030);
        end
    endtask

    task autoselect_on;
        begin
            win_write(21'h555, 16'h00AA);
            win_write(21'h2AA, 16'h0055);
            win_write(21'h555, 16'h0090);
        end
    endtask

    task set_ctl(input [15:0] dd);
        begin @(negedge clk); ctl_we=1; ctl_din=dd; @(negedge clk); ctl_we=0; end
    endtask

    task chk(input [15:0] got, input [15:0] exp, input [255:0] what);
        begin if (got!==exp) begin
            $display("FAIL: %0s = %04h (expected %04h)", what, got, exp);
            errors=errors+1; end
        end
    endtask

    task chk1(input got, input exp, input [255:0] what);
        begin if (got!==exp) begin
            $display("FAIL: %0s = %b (expected %b)", what, got, exp);
            errors=errors+1; end
        end
    endtask

    task chk_addr(input [26:0] got, input [26:0] exp, input [255:0] what);
        begin if (got!==exp) begin
            $display("FAIL: %0s = %07h (expected %07h)", what, got, exp);
            errors=errors+1; end
        end
    endtask

    task want_miss(input [255:0] what);
        begin if (last_stall == 0) begin
            $display("FAIL: %0s should MISS (stall>0)", what); errors=errors+1; end
        end
    endtask

    task want_hit(input [255:0] what);
        begin if (last_stall != 0) begin
            $display("FAIL: %0s should HIT (no stall)", what); errors=errors+1; end
        end
    endtask

    // DQ7 data poll of an erasing pair: (read ^ 0xFFFF) & 0x8080 == 0 -> done.
    task dq7_poll(input [20:0] a, input integer maxacc, output integer acc);
        reg [15:0] d;
        begin
            acc = 0; d = 16'h0000;
            while (acc < maxacc && (((d ^ 16'hFFFF) & 16'h8080) != 16'h0000)) begin
                flash_read(a, d);
                acc = acc + 1;
            end
        end
    endtask

    reg [15:0] v;
    integer    f0, polls;
    initial begin
        repeat (4) @(posedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============ 1) EMPTY SLOT: card_en=0 -> banks 32-47 read 0xFFFF ======
        // MAME pccard.cpp: pccard_slot_device::read_memory returns 0xffff when no
        // card device is attached. Critically it must ALSO issue no SDRAM fill --
        // an absent slot is not backed by anything.
        card_en = 1'b0;
        set_ctl(16'h0020);                 // bank 32 = pccard2 pair 0
        f0 = fill_reqs;
        flash_read(21'h0040, v); chk(v, 16'hFFFF, "empty slot bank32 word 0x40");
        want_hit("empty-slot read");
        if (fill_reqs != f0) begin
            $display("FAIL: empty slot requested %0d SDRAM fill(s)", fill_reqs - f0);
            errors = errors + 1;
        end

        // ============ 2) card enabled: bank 32 is the card image ===============
        card_en = 1'b1;
        set_ctl(16'h0020);                 // bank 32 -> card pair 0
        flash_read(21'h0040, v);
        chk(v, backing({1'b1, 24'h000040}), "card pair0 word 0x40");
        want_miss("first card read");
        chk1(last_fill_card, 1'b1, "fill image bit for a card read");
        // both bursts of a fill share bits [23:4] (line base, then base+8), so
        // compare the LINE, not the last burst's low nibble.
        chk_addr({last_fill_addr[26:4], 4'h0}, 27'h0000040, "card fill line base");

        // ============ 3) the SAME flat offset onboard is a DIFFERENT image =====
        // The line-buffer tag carries the region bit; without it this read would
        // hit the card line just filled and return card data.
        set_ctl(16'h0000);                 // bank 0 -> onboard pair 0
        flash_read(21'h0040, v);
        chk(v, backing({1'b0, 24'h000040}), "onboard pair0 word 0x40");
        want_miss("onboard read after a card read at the same offset");
        chk1(last_fill_card, 1'b0, "fill image bit for an onboard read");

        // back to the card: must MISS again and return CARD data
        set_ctl(16'h0020);
        flash_read(21'h0040, v);
        chk(v, backing({1'b1, 24'h000040}), "card pair0 word 0x40 (refetch)");
        want_miss("card refetch after onboard evicted the line");

        // in-line neighbour still HITs normally
        flash_read(21'h0041, v);
        chk(v, backing({1'b1, 24'h000041}), "card pair0 word 0x41");
        want_hit("card in-line neighbour");

        // ============ 4) pair flattening: bank 32+k -> card_word[23:21] = k ====
        set_ctl(16'h0027);                 // bank 39 -> card pair 7
        flash_read(21'h00100, v);
        chk(v, backing({1'b1, 3'd7, 21'h00100}), "card pair7 word 0x100");
        set_ctl(16'h0025);                 // bank 37 -> card pair 5
        flash_read(21'h1F000, v);
        chk(v, backing({1'b1, 3'd5, 21'h1F000}), "card pair5 word 0x1F000");

        // ============ 5) the 64 MB-window MIRROR (global_mask 0x1FFFFFF) =======
        // banks 40-47 alias 32-39: bank[3] is don't-care.
        set_ctl(16'h0028);                 // bank 40 == bank 32
        flash_read(21'h00100, v);
        chk(v, backing({1'b1, 3'd0, 21'h00100}), "bank40 mirrors bank32");
        set_ctl(16'h002F);                 // bank 47 == bank 39
        flash_read(21'h00100, v);
        chk(v, backing({1'b1, 3'd7, 21'h00100}), "bank47 mirrors bank39");

        // ============ 6) PCMCIA slot 1 (banks 16-31) is still absent ===========
        // Not modelled: no Tier-3 title we target uses it (ddr3mp/ddr4m/ddr5m are
        // all pccard2). It must read as an empty slot even with the card enabled.
        set_ctl(16'h0010);                 // bank 16 -> pccard1
        f0 = fill_reqs;
        flash_read(21'h0040, v); chk(v, 16'hFFFF, "slot1 bank16 absent");
        if (fill_reqs != f0) begin
            $display("FAIL: absent slot 1 requested an SDRAM fill");
            errors = errors + 1;
        end

        // ============ 7) autoselect IDs on a CARD pair ========================
        // linflash.cpp builds the card from FUJITSU_29F016A dies (intelfsh.cpp:201,
        // maker 0x04 / device 0xAD), two per 16-bit word -> both lanes, exactly as
        // onboard. The ID read must answer with NO stall (no SDRAM).
        set_ctl(16'h0023);                 // bank 35 -> card pair 3
        autoselect_on;
        flash_read(21'h000, v); chk(v, 16'h0404, "card autoselect MFR id");
        want_hit("card autoselect MFR read");
        flash_read(21'h001, v); chk(v, 16'hADAD, "card autoselect DEV id");
        want_hit("card autoselect DEV read");
        win_write(21'h000, 16'h00F0);      // reset out of autoselect

        // ============ 8) NOR program on a CARD pair ===========================
        set_ctl(16'h0025);                 // bank 37 -> card pair 5
        flash_program(21'h01234, 16'hBEEF);
        chk1(last_wr_card, 1'b1, "program write-back image bit (card)");
        chk_addr(last_wr_addr, {3'b000, 3'd5, 21'h01234},
                 "program write-back flat address (card pair 5)");
        flash_read(21'h01234, v); chk(v, 16'hBEEF, "card pair5 programmed word");
        // evict and re-read: proves it really reached the backing store
        set_ctl(16'h0000); flash_read(21'h00000, v);
        set_ctl(16'h0025); flash_read(21'h01234, v);
        chk(v, 16'hBEEF, "card pair5 programmed word after eviction");

        // the SAME flat offset in the ONBOARD image must be untouched
        set_ctl(16'h0002);                 // bank 2 -> onboard pair 2
        flash_read(21'h01234, v);
        chk(v, backing({1'b0, 3'd2, 21'h01234}), "onboard pair2 word untouched by card program");

        // ============ 9) NOR program on an ONBOARD bank still targets onboard ==
        flash_program(21'h01234, 16'h1234);
        chk1(last_wr_card, 1'b0, "program write-back image bit (onboard)");
        chk_addr(last_wr_addr, {3'b000, 3'd2, 21'h01234},
                 "program write-back flat address (onboard pair 2)");
        flash_read(21'h01234, v); chk(v, 16'h1234, "onboard pair2 programmed word");
        set_ctl(16'h0025); flash_read(21'h01234, v);
        chk(v, 16'hBEEF, "card pair5 word survives the onboard program");

        // ============ 10) SECTOR ERASE on a card pair (per-pair busy state) ====
        // intelfsh.cpp FM_ERASEAMD3 0x30 default branch: 64 KB per x8 die = 128 KB
        // per 16-bit sector = win_addr[20:16], identical to onboard. Erase card
        // pair 3 sector 1 (words 0x10000-0x1FFFF of that pair).
        //
        // Card pair 3 and ONBOARD pair 3 share the same 24-bit flat word
        // (0x610000) and differ only in the region bit, so this is also the
        // sharpest cross-image isolation test in the bench.
        set_ctl(16'h0023);                 // bank 35 -> card pair 3
        flash_program(21'h10000, 16'hA5A5);   // something to erase away
        flash_program(21'h1FFFF, 16'h5A5A);
        set_ctl(16'h0003);                 // bank 3 -> ONBOARD pair 3
        flash_program(21'h10000, 16'hC0DE);   // canary in the other image

        set_ctl(16'h0023);                 // bank 35 -> card pair 3
        flash_sector_erase(21'h10000);

        // busy status on the erasing pair: DQ7=0, DQ6/DQ2 toggle per access,
        // DQ3=1, DQ5=0 -> 0x4C4C then 0x0808, both x8 lanes, never stalling.
        flash_read(21'h10000, v); chk(v, 16'h4C4C, "card erase status #1");
        want_hit("card erase status read #1");
        flash_read(21'h10000, v); chk(v, 16'h0808, "card erase status #2");
        want_hit("card erase status read #2");

        // ONBOARD pair 3 must NOT be busy while the card pair erases.
        set_ctl(16'h0003);
        flash_read(21'h10000, v);
        chk(v, 16'hC0DE, "onboard pair3 live during a card erase");
        // ... and an ONBOARD pair with the same low index is not busy either
        set_ctl(16'h0000);
        flash_read(21'h00040, v);
        chk(v, backing({1'b0, 24'h000040}), "onboard pair0 live during a card erase");

        // another CARD pair stays live too (installers ID-check the next pair)
        set_ctl(16'h0024);                 // bank 36 -> card pair 4
        flash_read(21'h10000, v);
        chk(v, backing({1'b1, 3'd4, 21'h10000}), "card pair4 live during pair3 erase");

        // poll the erasing pair to completion
        set_ctl(16'h0023);
        dq7_poll(21'h10000, 200000, polls);
        if (polls >= 200000) begin
            $display("FAIL: card sector-erase DQ7 poll timed out (%0d accesses)", polls);
            errors = errors + 1;
        end else
            $display("INFO: card sector erase completed after %0d poll accesses", polls);

        // the whole 128 KB sector really is 0xFFFF in the backing store
        flash_read(21'h10000, v); chk(v, 16'hFFFF, "card erased sector base");
        flash_read(21'h18000, v); chk(v, 16'hFFFF, "card erased sector middle");
        flash_read(21'h1FFFF, v); chk(v, 16'hFFFF, "card erased sector last word");
        // outside the sector, untouched
        flash_read(21'h0FFFF, v);
        chk(v, backing({1'b1, 3'd3, 21'h0FFFF}), "card pair3 sector0 untouched");
        // the ONBOARD canary at the SAME flat word survived the card erase
        set_ctl(16'h0003);
        flash_read(21'h10000, v); chk(v, 16'hC0DE, "onboard pair3 canary survived");
        // the card pair 5 program from step 8 also survived
        set_ctl(16'h0025);
        flash_read(21'h01234, v); chk(v, 16'hBEEF, "card pair5 word survived the erase");

        // ============ 11) program after erase, on the card ====================
        set_ctl(16'h0023);
        flash_program(21'h10010, 16'h0F0F);
        flash_read(21'h10010, v); chk(v, 16'h0F0F, "card program after erase");
        flash_read(21'h10011, v); chk(v, 16'hFFFF, "card neighbour still erased");

        // ============ 12) card_en drops -> the slot is empty again ============
        card_en = 1'b0;
        set_ctl(16'h0023);
        flash_read(21'h10010, v); chk(v, 16'hFFFF, "card ejected -> empty slot");
        card_en = 1'b1;
        flash_read(21'h10010, v); chk(v, 16'h0F0F, "card re-inserted -> data back");

        if (errors == 0) $display("RESULT: PASS (s573_flash_pccard)");
        else             $display("RESULT: FAIL (s573_flash_pccard, %0d errors)", errors);
        $finish;
    end
endmodule
