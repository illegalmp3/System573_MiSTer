// -----------------------------------------------------------------------------
// s573_flash.v - System 573 bank-switched flash / PCMCIA window + control latch
//
// The 573 sees a single 4 MB window at 0x1f000000 into a much larger backing
// store, selected by the bank field of the control register at 0x1f500000:
//
//   bits 0-5 : bank number  (0-3 = internal onboard flash, 16-31 = PCMCIA slot 1,
//              32-47 = PCMCIA slot 2) -- the RAW value, no shift
//   bit  6   : security-cart IO0 direction (0 = input)
//   bit  7   : CPLD signal
//
// AUTHORITATIVE SOURCE = MAME konami/ksys573.cpp (mame0288, which boots our exact
// dumps): `m_flashbank->set_bank( m_control & 0x3f );`  (no shift) over a 4 MB-
// stride flashbank map: bank 0 -> 29f016a.31m, 1 -> 31l, 2 -> 31j, 3 -> 31h (the
// four onboard 4 MB banks at image offsets 0/4/8/12 MB); banks 16-31 -> pccard1,
// 32-47 -> pccard2. So the BIOS selects onboard bank N by writing the RAW value N
// (0/1/2/3): the internal-bank index is `bank[1:0]` with `bank < 4`, NOT `bank[5:4]`.
// Our own tools/pack_hyperbbc.py lays bank N at image offset N*0x400000, matching.
// (Commit da83148's `bank[5:4]` decode was a REGRESSION: control values 0x01/0x02/
// 0x03 fell through to "absent" -> banks 1/2/3 read 0xFFFF, leaving 12 MB of
// program/gfx/sample data unreadable -> the PROGRAM ROM CHECK self-test stalled.
// Confirmed by the RTL-witness audit + MAME source, 2026-06-06.)
//
// ================== PCMCIA SLOT 2: the 32 MB linear flash card ==================
//
// Tier 3 (DDR 3rd/4th/5th Mix, MAX, Extreme) installs its game data onto a
// Fujitsu 32 MB linear flash PC card in SLOT 2. ddr4m's machine config is
// `ddr3mp` (ksys573.cpp L2779-2788), which is dsfdr's config plus exactly one new
// device: `pccard2_32mb(config)`.
//
// What that card IS (mame/bus/pccard/linflash.{h,cpp}):
//   fujitsu_32mb_flash_card_device : linear_flash_pccard_29f017a_device<8>
//     -> N = 8 CHIP PAIRS, each pair = one low (.nL) + one high (.nU) x8 die,
//        both FUJITSU_29F016A. intelfsh.cpp:201 -> 0x200000 bytes per die,
//        maker 0x04, device 0xAD. 8 * (2 MB + 2 MB) = 32 MB.
//   linear_flash_pccard_8bit_device<N>::amap:
//     map.global_mask((N * 0x00400000) - 1);            // 0x1FFFFFF = 32 MB
//     map(0x400000*i, ...).rw(m_l[i], ...).umask16(0x00ff);
//     map(0x400000*i, ...).rw(m_u[i], ...).umask16(0xff00);
//   linear_flash_pccard_device::read_memory(offset) -> m_space->read_word(offset*2)
//     over a 16-bit / 26-address-bit space.
//
// So the card is the SAME PART as the onboard flash: same AMD/Fujitsu command set
// (rtl/flash_nor.v, unchanged), same dual-lane autoselect IDs (MFR 0x0404 /
// DEV 0xADAD -- two x8 dies per 16-bit word), and the same sector geometry.
// intelfsh.cpp's FM_ERASEAMD3 0x30 default branch erases `base & ~0xffff`, i.e.
// 64 KB per x8 die = 128 KB per 16-bit sector = win_addr[20:16], exactly the
// index this module already uses for onboard. Chip erase (0x10) wipes m_size =
// 2 MB per die = one PAIR = 4 MB of window = ERASE_CHIP_WORDS, also unchanged.
//
// The addressing falls out of the two maps above:
//   pccard2 window = flashbank 0x8000000..0xbffffff = banks 32..47
//   card byte addr = (offset*2) & 0x1FFFFFF, offset = word index in the window
//   => card_word[23:0] = { bank[2:0], win_addr[20:0] }     (16 M words = 32 MB)
//   => chip pair       = card_word[23:21] == bank[2:0]     (0..7)
// bank[3] is the 64 MB-window MIRROR that global_mask folds away, so banks 40-47
// alias 32-39 and bank[3] is don't-care. Note the pleasing symmetry: one bank
// value == one chip pair, exactly as onboard (bank[1:0] == one onboard pair). The
// per-pair erase/busy bookkeeping below therefore generalises from 4 pairs to 12
// (4 onboard + 8 card) with no structural change -- indexed by `pu = {region,pair}`.
//
// `card_en` = 0 makes banks 32-47 read 0xFFFF, which is what MAME does for a slot
// with no card device attached (pccard.cpp: pccard_slot_device::read_memory returns
// 0xffff when m_dev is null). Titles with no card are therefore bit-identical to
// the pre-card core.
//
// This module latches the control register (exposing the bank and the two
// security/CPLD bits to the rest of the board) and maps the 4 MB window onto a
// flat backing memory: effective word = {pair, window offset}, with `*_card`
// telling the parent WHICH backing image (onboard 16 MB or card 32 MB) the flat
// word indexes.
//
// Two backing modes (parameter SIM_BACKING):
//
//   SIM_BACKING=1 (default, iverilog):  each pair -- onboard AND card -- is a small
//     inline AMD/Fujitsu NOR flash_nor chip with its own writable mem[] BRAM. Reads
//     are combinational and `flash_ready` is permanently 1 (no wait handshake, the
//     SDRAM ports are unused). This is the path the decode unit tests exercise.
//
//   SIM_BACKING=0 (Quartus/HW):  the 16 MB onboard flash and the 32 MB card both
//     live in SDRAM (onboard at FLASH_START, card at CARD_START -- the parent adds
//     the base, selected by flash_mem_card / flash_wr_card). A flat word address
//     `{pair_idx, win_addr[20:0]}` (24 bits = 16 M words = 32 MB) indexes the
//     selected image. A 16-word (32-byte) line buffer holds the most-recently
//     filled burst; tag = {region, flat_word[23:4]}. A HIT returns combinational
//     `win_dout` with `flash_ready=1` (no stall); a MISS drops `flash_ready=0` and
//     kicks one 128-bit SDRAM burst fill (flash_mem_req/addr -> flash_mem_q/ready).
//     The EXP1 read FSM (memorymux, psx_patches/0006) holds in its read-strobe
//     state while `flash_ready=0`, so the bus never advances on stale data. The
//     JEDEC autoselect MFR/DEV ID path stays combinational and answers immediately
//     (flash_ready=1, no SDRAM) so POST's flash-ID check is unchanged.
//
// SDRAM byte address = (flash_mem_card ? CARD_START : FLASH_START) + {word, 1'b0},
// with the base added by the parent (emu.sv) -- this module emits the flat word
// index plus the image-select bit only.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_flash #(
    parameter integer WIN_WORDS    = 2048, // 16-bit words per bank in SIM_BACKING
                                           // mode (>=2048 so the NOR unlock
                                           // addresses 0x555/0x2AA fit)
    parameter integer SECTOR_WORDS = 512,
    parameter integer NUM_BANKS    = 4,    // internal onboard-flash chip pairs
    parameter integer CARD_PAIRS   = 8,    // PCMCIA slot-2 chip pairs (32 MB card =
                                           // 8 x 29F017A pairs, linflash.cpp
                                           // linear_flash_pccard_29f017a_device<8>)
    parameter integer ERASE_CHIP_WORDS = 2097152, // CHIP-erase (0x10) span on the SDRAM
                                           // path: 2M 16-bit words = one whole 4 MB
                                           // pair (a .31x/.27x or .nL/.nU chip pair).
                                           // Parameter ONLY so the TB can shrink the
                                           // chip-erase walk to a simulable length;
                                           // synthesis always uses the real default.
                                           // SECTOR erase geometry is NOT parameterized
                                           // -- win_addr[20:16], the real 29F016A pair
                                           // layout (32 sectors x 128 KB per pair),
                                           // identical onboard and on the card.
    parameter integer SIM_BACKING  = 1     // 1 = inline flash_nor BRAM (sim/tests)
                                           // 0 = SDRAM-backed line buffer
)(
    input  wire        clk,
    input  wire        rst,

    // control register (0x1f500000, write)
    input  wire        ctl_we,
    input  wire [15:0] ctl_din,
    output reg  [5:0]  bank,
    output reg         sec_io0_dir,   // bit 6
    output reg         cpld_sig,      // bit 7

    // PCMCIA slot 2 card present (OSD "573 PCMCIA Card"). 0 = EMPTY SLOT: banks
    // 32-47 read 0xFFFF, matching MAME pccard_slot_device::read_memory with no
    // card device attached (bus/pccard/pccard.cpp). Every pre-Tier-3 title runs
    // with this at 0 and is bit-identical to the pre-card core.
    input  wire        card_en,

    // flash window (0x1f000000 region)
    input  wire        win_sel,
    input  wire [20:0] win_addr,      // word offset within the 4 MB window
    input  wire        win_we,
    input  wire [15:0] win_din,
    output reg  [15:0] win_dout,
    output wire        flash_ready,   // 1 = read data valid this cycle (no stall);
                                      // 0 = MISS in progress (drives EXP1 wait)

    // SDRAM line-fill port (used only when SIM_BACKING=0)
    output reg         flash_mem_req,    // pulse: request a 128-bit burst fill
    output reg  [26:0] flash_mem_addr,   // flat 16-bit word index (parent adds base)
    output reg         flash_mem_card,   // 0 = onboard 16 MB image, 1 = PCMCIA card
    input  wire [127:0] flash_mem_q,     // the 16-byte burst (8 words) returned
    input  wire        flash_mem_ready,  // 1-cycle: flash_mem_q valid

    // SDRAM single-word WRITE-BACK port (used only when SIM_BACKING=0): NOR program
    // and JEDEC ERASE make the onboard flash AND the PCMCIA card WRITABLE so a CD
    // game's installer can re-program them. On a program data cycle we write the line
    // buffer through (so the verify read HITs the new value immediately) AND emit one
    // 16-bit write-back here; the parent (emu.sv) muxes it into the free SDRAM ch3
    // writer (cheats engine is disabled, psx_patches/0008). flash_wr_req pulses one
    // cycle; flash_wr_ack (the ch3 completion) ends it. Array reads stall
    // (flash_ready=0) while a PROGRAM write-back is pending (prog_pend below), so the
    // BIOS's post-program AMD data-poll read serialises each program -> SDRAM commit
    // -> next program (no lost writes).
    //
    // ERASE (chip 0x10 / sector 0x30) is REAL on this path: a background walker
    // streams 0xFFFF over the erased region into the SDRAM backing through this same
    // port, while reads of the erasing pair return AMD busy status (see the erase
    // engine below -- the DQ7 data-poll ddrsbm's installer runs). PROGRAM still
    // OVERWRITES the cell rather than applying the faithful NOR AND, deliberately:
    // our blank flash images and slot-4 .savs are 0x00-filled (not the 0xFF of real
    // erased NOR), and hypbbc2p's installer programs WITHOUT erasing first -- a
    // faithful AND against a 0x00-backed cell would commit 0x0000 and corrupt those
    // installs (the exact .sav-vs-MAME-golden corruption signature that motivated
    // the overwrite, tb_s573_flash_sdram #11). Erase-then-program-once (ddrsbm) and
    // program-only-onto-blank (hypbbc2p) installs both reach the correct final
    // image with overwrite.
    output reg         flash_wr_req,     // pulse: request a 16-bit SDRAM write-back
    output reg         flash_wr_busy,    // LEVEL: held high for the whole write-back
                                         // transaction (req pulse .. ack). The parent
                                         // mux selects flash_wr_addr/data onto ch3 with
                                         // THIS, not the req pulse, so the address stays
                                         // presented until the SDRAM controller services
                                         // it (it samples the bus continuously).
    output reg  [26:0] flash_wr_addr,    // flat 16-bit word index (parent adds base)
    output reg         flash_wr_card,    // 0 = onboard 16 MB image, 1 = PCMCIA card
    output reg  [15:0] flash_wr_data,    // the programmed 16-bit word (overwrite, not NOR-ANDed)
    input  wire        flash_wr_ack,     // 1-cycle: the ch3 write completed

    // DEBUG (HW bring-up): observe WHY the fill FSM does/doesn't trigger. Round-2
    // bars proved flash_mem_req never pulses (req_cnt=0) -> the array_read trigger
    // never fires. Expose the trigger inputs so the next bar-decode pins the cause:
    //   [23:18] bank   [17] win_sel_seen  [16] selected_seen  [15] winwe_seen
    //   [14] idread_seen [13] arrayread_seen [12] tag_hit_seen [11:10] fstate_max
    //   [9:0] = low 10 bits of the last win_addr observed during a flash read
    output wire [23:0] dbg_flash
);
    // ---------------------------------------------------------------------------
    // Bank decode. Onboard flash is selected by the BIOS writing the RAW bank number
    // (0/1/2/3) to the control register (MAME: set_bank(control & 0x3f)); PCMCIA
    // slot 1 is 16-31 and slot 2 is 32-47. Slot 1 is not modelled (no Tier-3 title
    // we target uses it -- ddr3mp/ddr4m/ddr5m all use pccard2), so banks 16-31 keep
    // reading 0xFFFF = empty slot.
    //
    //   internal : bank < 4                      -> onboard 16 MB, pair = bank[1:0]
    //   card2    : bank[5:4] == 2'b10 (32..47)   -> 32 MB card,    pair = bank[2:0]
    //              bank[3] is the global_mask mirror (40-47 alias 32-39): don't-care
    //   pu       : {region, pair} -- the flat per-CHIP-PAIR index used for the erase
    //              busy/sector state. 0-3 = onboard pairs, 8-15 = card pairs.
    // ---------------------------------------------------------------------------
    wire internal = (bank[5:2] == 4'b0000);              // bank < 4 -> onboard flash
`ifdef S573_FLASH_NO_PCCARD
    // RED reference for the Tier-3 red/green test ONLY (never synthesised -- no
    // .sdc/.qsf define): the pre-Tier-3 decode, in which banks 32-47 are an EMPTY
    // slot regardless of card_en. tb_s573_flash_pccard is RED under this define
    // (every card read returns 0xFFFF and no fill is ever requested) and GREEN by
    // default -- proof the bench exercises the card decode without hand-reverting RTL.
    wire card2    = 1'b0;
`else
    wire card2    = card_en && (bank[5:4] == 2'b10);     // banks 32-47 -> pccard2
`endif
    wire sel_mem  = internal | card2;                    // a backed window is selected
    wire region   = ~internal;                           // 0 = onboard, 1 = card
    wire [2:0] pair_idx = internal ? {1'b0, bank[1:0]} : bank[2:0];
    wire [3:0] pu = {region, pair_idx};

    always @(posedge clk) begin
        if (rst) begin
            bank <= 6'd0; sec_io0_dir <= 1'b0; cpld_sig <= 1'b0;
        end else if (ctl_we) begin
            bank        <= ctl_din[5:0];
            sec_io0_dir <= ctl_din[6];
            cpld_sig    <= ctl_din[7];
        end
    end

    generate
    if (SIM_BACKING != 0) begin : g_sim
        // ----- iverilog / behavioral path: inline per-pair NOR flash chips -----
        // Each chip pair -- 4 onboard + CARD_PAIRS on the card -- is a real
        // AMD/Fujitsu NOR flash chip (writes go through the unlock/program/erase
        // command sequences); the selected pair is exposed. flash_ready is
        // permanently asserted (no wait handshake); the SDRAM ports are unused.
        localparam integer SIM_CHIPS = NUM_BANKS + CARD_PAIRS;
        // Flat behavioral-chip index: 0..NUM_BANKS-1 = onboard, then the card pairs.
        // (SIM_CARD_BASE is a sized localparam rather than a part-select of the
        // NUM_BANKS parameter -- part-selecting a parameter is not portable.)
        localparam [3:0] SIM_CARD_BASE = NUM_BANKS;
        wire [3:0] sim_idx = internal ? {2'b00, bank[1:0]}
                                      : (SIM_CARD_BASE + {1'b0, bank[2:0]});
        wire [15:0] chip_dout [0:SIM_CHIPS-1];
        genvar gi;
        for (gi = 0; gi < SIM_CHIPS; gi = gi + 1) begin : chips
            // Two x8 dies (.31x low lane / .27x high lane onboard; .nL / .nU on the
            // card) form each 16-bit word, so autoselect drives the ID into BOTH
            // lanes: MFR 0x0404, DEV 0xADAD (a single x16 die would read 0x0004/
            // 0x00AD). Matches MAME umask16 0x00ff/0xff00 and 573in1's low==high
            // two-x8-chips-per-bank detect. The card uses the SAME part
            // (FUJITSU_29F016A, intelfsh.cpp:201) so the IDs are identical.
            flash_nor #(.WORDS(WIN_WORDS), .SECTOR_WORDS(SECTOR_WORDS),
                        .MFR_ID(16'h0404), .DEV_ID(16'hADAD),
                        .BACKING_EXTERNAL(0)) chip (
                .clk(clk), .rst(rst),
                .ce(win_sel && sel_mem && (sim_idx == gi)),
                .we(win_we),
                .addr(win_addr[15:0]),
                .din(win_din),
                .dout(chip_dout[gi]),
                .ext_rd_data(16'hFFFF),
                .id_read()
            );
        end

        integer m;
        always @(*) begin
            win_dout = 16'hFFFF;            // absent PCMCIA slot / unselected
            if (win_sel && sel_mem)
                for (m = 0; m < SIM_CHIPS; m = m + 1)
                    if (sim_idx == m) win_dout = chip_dout[m];
        end

        assign flash_ready = 1'b1;          // always ready in behavioral mode
        assign dbg_flash   = 24'd0;         // debug observers unused in behavioral mode

        // SDRAM fill + write-back ports unused in behavioral mode (the inline
        // flash_nor chips have their own writable mem[] BRAM). Held at reset values.
        always @(posedge clk) begin
            flash_mem_req  <= 1'b0;
            flash_mem_addr <= 27'd0;
            flash_mem_card <= 1'b0;
            flash_wr_req   <= 1'b0;
            flash_wr_busy  <= 1'b0;
            flash_wr_addr  <= 27'd0;
            flash_wr_card  <= 1'b0;
            flash_wr_data  <= 16'd0;
        end
    end else begin : g_sdram
        // ----- HW path: SDRAM-backed flash/card with a 16-word line buffer -----
        //
        // Flat 16-bit WORD address into the selected image:
        //   unit_word = {pair_idx, win_addr[20:0]}   (24 bits = 16 M words = 32 MB)
        // pair_idx = the onboard pair 0-3 or the card pair 0-7. Line buffer = 16
        // words (32 bytes): index = unit_word[3:0], tag = {region, unit_word[23:4]}
        // (21 bits -- the REGION bit is part of the tag so an onboard line and a card
        // line at the same offset can never alias). One 128-bit SDRAM burst is 8
        // words, so two bursts (line base, line base+8) fill the 16-word line.
        wire [23:0] unit_word = {pair_idx, win_addr[20:0]};

        // Line buffer storage + valid tag.
        reg [15:0] line [0:15];
        reg [20:0] line_tag;          // {region, unit_word[23:4]}
        reg        line_valid;
        reg [1:0]  fstate;            // fill-FSM state (declared here so the debug
                                      // block below can read it; assigned in the FSM)

        wire [20:0] req_tag = {region, unit_word[23:4]};
        wire [3:0]  req_idx = unit_word[3:0];
        wire        tag_hit = line_valid && (line_tag == req_tag);

        // -- The JEDEC command / autoselect-ID FSM (flash_nor, BACKING_EXTERNAL=1)
        // -- is the single source of truth for command decode. It hands back the
        // -- current line-buffer word on a normal read, the MFR/DEV ID in
        // -- autoselect, and flags ID reads via `id_read` so we can skip the SDRAM
        // -- fill for them (POST's flash-ID check must never stall). One instance
        // -- serves BOTH images: only one bank is selected at a time, and the 573
        // -- BIOS/installers never interleave a command sequence across a bank
        // -- switch (a switch mid-unlock would abort the sequence on real silicon
        // -- too, since the chip that saw 0xAA is deselected).
        wire [15:0] cmd_dout;
        wire        id_read;
        wire        prog_now;
        wire        erase_now;
        wire        erase_chip;
        wire [15:0] line_word = line[req_idx];
        flash_nor #(.WORDS(WIN_WORDS), .SECTOR_WORDS(SECTOR_WORDS),
                    .MFR_ID(16'h0404), .DEV_ID(16'hADAD),
                    .BACKING_EXTERNAL(1)) cmd (
            .clk(clk), .rst(rst),
            .ce(win_sel && sel_mem),
            .we(win_we),
            .addr(win_addr[15:0]),
            .din(win_din),
            .dout(cmd_dout),
            .ext_rd_data(line_word),
            .id_read(id_read),
            .prog_now(prog_now),
            .erase_now(erase_now),
            .erase_chip(erase_chip)
        );

        // A pending array read that needs the backing store: a selected backed
        // window, a read access (not a write), not an ID read.
        wire array_read = win_sel && sel_mem && !win_we && !id_read;

        // ================= JEDEC ERASE on the SDRAM-backed path =================
        //
        // The contract this must satisfy (ddrsbm installer disasm 2026-07-02 + MAME
        // intelfsh 29F016A as oracle; docs/2026-07-01-ddrsbm-dio-i2c-result.md 4):
        //   * sector erase 0x30 names a 128 KB region of the CURRENT pair
        //     (win_addr[20:16] = sector 0..31 of the 4 MB chip-pair window). The
        //     installer erases the SAME sector index on all 4 banks back-to-back,
        //     DQ7-data-polls each bank's sector base under a 121-VBlank (~2 s)
        //     budget, then read-verifies the whole 128 KB sector expects 0xFFFF.
        //   * while a chip-pair is erasing, EVERY read of that pair returns AMD
        //     status: DQ7=0, DQ6+DQ2 toggle per read access, DQ3=1, DQ5=0 --
        //     0x4C/0x08 alternating, doubled onto both x8 lanes (MAME FM_ERASEAMD4
        //     + the maker==Fujitsu any-address-returns-status exception). Writes to
        //     a busy chip-pair are ignored, also per MAME/JEDEC.
        //   * the OTHER pairs stay fully live meanwhile: the installer runs its
        //     autoselect ID check on pair N+1 while pair N erases -- so busy state
        //     is PER-PAIR and idle-pair reads/fills must not be blocked.
        //   * completion is REAL: busy drops only when the walker has committed
        //     0xFFFF over the whole region to SDRAM (never a faked status --
        //     memory/no-mask-fault-with-fake-data.md). The erased array data then
        //     satisfies the DQ7 poll and the read-verify by itself. Walking one
        //     128 KB region takes ~ms against the ~2 s budget ("a faster chip").
        //
        // State is indexed by `pu` = {region, pair} so the onboard pairs (0-3) and
        // the card pairs (8-15) are independent -- a card erase must not make an
        // onboard bank read busy, and vice versa. Indices 4-7 are never selected
        // (internal pairs only use 0-3); Quartus prunes them.
        //
        // The walker shares the ch3 write-back port with NOR program below: a
        // pending program always outranks the next walker word, so the AMD
        // program -> data-poll serialisation is unchanged. One region walks at a
        // time; up to 12 pairs queue in er_busy.
        reg  [15:0] er_busy;              // per-chip-pair erase in progress
        reg  [4:0]  er_sector [0:15];     // captured sector index (win_addr[20:16])
        reg  [15:0] er_chip_r;            // 1 = chip erase (whole-pair span)
        reg  [15:0] er_tgl;               // per-pair DQ6/DQ2 toggle state
        reg         ehit_d;               // status-read access edge detect

        // A read of a busy pair returns status instead of array data. It must never
        // stall (the CPU is data-polling) and must never start a line fill.
        wire        erase_hit  = win_sel && sel_mem && !win_we && er_busy[pu];
        wire [7:0]  er_status8 = er_tgl[pu] ? 8'h08 : 8'h4C;

        // Next region for the walker: lowest-numbered busy pair (the installer
        // issues them in order; any order completes well inside the budget).
        reg  [3:0]  er_next;
        integer     eb;
        always @(*) begin
            er_next = 4'd0;
            for (eb = 15; eb >= 0; eb = eb - 1)
                if (er_busy[eb]) er_next = eb;      // truncates to 4 bits
        end
        localparam [20:0] CHIP_LAST = ERASE_CHIP_WORDS - 1;
        wire [20:0] er_nstart = er_chip_r[er_next] ? 21'd0
                                                   : {er_sector[er_next], 16'h0000};
        wire [20:0] er_nlast  = er_chip_r[er_next] ? CHIP_LAST
                                                   : {er_sector[er_next], 16'hFFFF};

        // Walker / write-back-port owner state.
        reg  [3:0]  wk_pu;                // {region,pair} being walked
        reg  [20:0] wk_word;              // current word within the pair window
        reg  [20:0] wk_last;              // last word of the region
        reg         wk_active;
        reg         wr_owner;             // in-flight write: 0 = program, 1 = walker
        reg         prog_pend;            // a program write-back is latched/in flight
        reg  [26:0] prog_addr_r;
        reg         prog_card_r;
        reg  [15:0] prog_data_r;

        // DEBUG: sticky observers of the trigger inputs across the whole boot, so
        // the bar-decode can pin WHY array_read never fires (req_cnt=0 in round 2).
        // NOTE: these are deliberately NOT cleared on `rst` -- the CDR-BAD failure is
        // a WATCHDOG REBOOT LOOP that pulses the core reset every iteration; a
        // reset-cleared observer would only ever show "since the last watchdog reset"
        // and could read 0 even if the flash WAS read in the prior POST. Sticky from
        // power-on (init value) gives the true "ever happened" across the whole run.
        reg        dbg_winsel_seen = 0, dbg_sel_seen = 0, dbg_winwe_seen = 0;
        reg        dbg_idread_seen = 0, dbg_arrayrd_seen = 0, dbg_taghit_seen = 0;
        reg [1:0]  dbg_fstate_max = 0;
        reg [9:0]  dbg_winaddr_last = 0;
        always @(posedge clk) begin
            if (win_sel) begin
                dbg_winsel_seen   <= 1'b1;
                dbg_winaddr_last  <= win_addr[9:0];
                if (sel_mem) dbg_sel_seen  <= 1'b1;
                if (win_we)  dbg_winwe_seen <= 1'b1;
                if (id_read) dbg_idread_seen <= 1'b1;
            end
            if (array_read) dbg_arrayrd_seen <= 1'b1;
            if (array_read && tag_hit) dbg_taghit_seen <= 1'b1;
            if (fstate > dbg_fstate_max) dbg_fstate_max <= fstate;
        end
        assign dbg_flash = {bank, dbg_winsel_seen, dbg_sel_seen, dbg_winwe_seen,
                            dbg_idread_seen, dbg_arrayrd_seen, dbg_taghit_seen,
                            dbg_fstate_max, dbg_winaddr_last};

        // Fill FSM: on a MISS, two 128-bit bursts populate the 16-word line.
        localparam F_IDLE=2'd0, F_REQ0=2'd1, F_REQ1=2'd2;
        // (fstate reg declared above with the line-buffer storage)
        reg [20:0] fill_tag;     // tag being filled ({region, unit_word[23:4]})
        integer    k;
        always @(posedge clk) begin
            if (rst) begin
                fstate        <= F_IDLE;
                line_valid    <= 1'b0;
                line_tag      <= 21'h1FFFFF;
                flash_mem_req <= 1'b0;
                flash_mem_addr<= 27'd0;
                flash_mem_card<= 1'b0;
                flash_wr_req  <= 1'b0;
                flash_wr_busy <= 1'b0;
                flash_wr_addr <= 27'd0;
                flash_wr_card <= 1'b0;
                flash_wr_data <= 16'd0;
                er_busy       <= 16'h0000;  // a reset mid-erase abandons the walk --
                er_chip_r     <= 16'h0000;  // same as cutting power to a real chip
                er_tgl        <= 16'h0000;  // mid-erase (region left part-blanked)
                ehit_d        <= 1'b0;
                wk_active     <= 1'b0;
                wr_owner      <= 1'b0;
                prog_pend     <= 1'b0;
                prog_card_r   <= 1'b0;
            end else begin
                flash_mem_req <= 1'b0;
                flash_wr_req  <= 1'b0;

                // ---- NOR program (write-through cache + latched ch3 write-back) ----
                // prog_now is a one-cycle strobe on the program data write. OVERWRITE
                // the target word with the intended data, NOT cell &= data (see the
                // write-back port header above: 0x00-filled blank images/.savs +
                // hypbbc2p's program-without-erase installer make the faithful AND a
                // corruption -- the .sav-vs-MAME-golden diff showed the signature,
                // ~38% of data WORDS a perfect bit-subset dropped to 0x0000). Write
                // the line buffer THROUGH (so the BIOS's verify read HITs the new
                // value) and LATCH one 16-bit write-back (prog_pend); the shared-port
                // logic below issues it with priority over the erase walker. Array
                // reads stall while prog_pend (flash_ready below), so the AMD
                // data-poll read serialises program -> SDRAM commit -> next program,
                // walker or not. prog_pend is 1-deep: the data-poll read blocks until
                // the commit, so the bus cannot legally issue a second program first
                // (sim warns loudly if something does). A program aimed at a busy
                // (erasing) chip-pair is ignored, like the real device. (prog_now
                // never coincides with a fill: the bus is stalled during a fill, so
                // the CPU cannot issue the program store until F_IDLE.) NOTE: the
                // SIM_BACKING=1 inline flash_nor path keeps the faithful NOR AND for
                // the unit tests; only this SDRAM-backed path overwrites.
                if (prog_now && !er_busy[pu]) begin
`ifdef S573_FLASH_OLD_AND
                    // RED reference for the FIX-2 red/green test ONLY (never synthesised
                    // -- no .sdc/.qsf define): the buggy faithful-NOR AND against stale
                    // SDRAM backing that corrupted installs (tb_s573_flash_sdram #11).
                    if (tag_hit) line[req_idx] <= line[req_idx] & win_din;
                    prog_addr_r <= {3'b000, unit_word};
                    prog_card_r <= region;
                    prog_data_r <= (tag_hit ? line[req_idx] : 16'hFFFF) & win_din;
`else
                    if (tag_hit) line[req_idx] <= win_din;          // overwrite cache
                    prog_addr_r <= {3'b000, unit_word};
                    prog_card_r <= region;
                    prog_data_r <= win_din;                         // overwrite SDRAM
`endif
                    prog_pend   <= 1'b1;
                    // synthesis translate_off
                    if (prog_pend)
                        $display("s573_flash: WARNING program while write-back pending -- prior word LOST");
                    // synthesis translate_on
                end

                // ---- JEDEC erase capture (decoded by the shared command FSM) ----
`ifndef S573_FLASH_ERASE_NOOP
                // (S573_FLASH_ERASE_NOOP is the RED reference for the erase red/green
                // test ONLY, never synthesised: it restores the pre-fix no-op erase --
                // command decoded, action dropped -- that left ddrsbm's installer
                // data-polling stale data into its ERASE TIMEOUT. tb_s573_flash_erase.)
                if (erase_now && !er_busy[pu]) begin
                    er_busy[pu]   <= 1'b1;
                    er_chip_r[pu] <= erase_chip;
                    er_sector[pu] <= win_addr[20:16];
                    er_tgl[pu]    <= 1'b0;   // first status read returns 0x4C
                    line_valid    <= 1'b0;   // cached line may die under the walk
                end
                // synthesis translate_off
                // A real 29F016A QUEUES extra sector-erase commands arriving inside
                // the 50us DQ3 window; we drop them (busy chip-pair ignores writes).
                // No 573 title batches sectors (ddrsbm: one per bank) -- warn loudly
                // in sim so a future title doing it is caught, not silently broken.
                if (erase_now && er_busy[pu])
                    $display("s573_flash: WARNING erase to busy pair %0d DROPPED (no sector batching)", pu);
                // synthesis translate_on

                // DQ6/DQ2 toggle: once per status-read ACCESS (win_sel rising edge),
                // so a multi-cycle EXP1 read strobe consumes ONE toggle per access.
                ehit_d <= erase_hit;
                if (erase_hit && !ehit_d) er_tgl[pu] <= ~er_tgl[pu];
`endif

                // ---- shared ch3 write-back port: complete, then issue ----
                if (flash_wr_ack) begin
                    flash_wr_busy <= 1'b0;
                    if (wr_owner) begin
                        // walker word committed to SDRAM
                        if (wk_word == wk_last) begin
                            er_busy[wk_pu] <= 1'b0;  // region really is 0xFF now
                            wk_active      <= 1'b0;
                        end else
                            wk_word <= wk_word + 21'd1;
                    end else
                        prog_pend <= 1'b0;
                end

                // Issue priority: pending program > next walker word > start the
                // next queued region. (An ack cycle never issues -- flash_wr_busy is
                // still high -- so these never fight the completion block above.)
                if (!flash_wr_busy) begin
                    if (prog_pend) begin
                        flash_wr_addr <= prog_addr_r;
                        flash_wr_card <= prog_card_r;
                        flash_wr_data <= prog_data_r;
                        flash_wr_req  <= 1'b1;
                        flash_wr_busy <= 1'b1;
                        wr_owner      <= 1'b0;
                    end else if (wk_active) begin
                        flash_wr_addr <= {3'b000, wk_pu[2:0], wk_word};
                        flash_wr_card <= wk_pu[3];
                        flash_wr_data <= 16'hFFFF;
                        flash_wr_req  <= 1'b1;
                        flash_wr_busy <= 1'b1;
                        wr_owner      <= 1'b1;
                    end else if (er_busy != 16'h0000) begin
                        wk_pu     <= er_next;
                        wk_word   <= er_nstart;
                        wk_last   <= er_nlast;
                        wk_active <= 1'b1;
                    end
                end

                case (fstate)
                    F_IDLE: begin
                        if (array_read && !erase_hit && !tag_hit && !prog_pend) begin
                            // start a fill of the missing line
                            fill_tag       <= req_tag;
                            line_valid     <= 1'b0;
                            // word base of the 16-word line: {req_tag[19:0], 4'b0}.
                            // First burst covers words [0..7] of the line.
                            flash_mem_addr <= {3'b000, req_tag[19:0], 4'b0000};
                            flash_mem_card <= req_tag[20];
                            flash_mem_req  <= 1'b1;
                            fstate         <= F_REQ0;
                        end
                    end
                    F_REQ0: begin
                        if (flash_mem_ready) begin
                            for (k = 0; k < 8; k = k + 1)
                                line[k] <= flash_mem_q[k*16 +: 16];
                            // second burst covers words [8..15]
                            flash_mem_addr <= {3'b000, fill_tag[19:0], 4'b1000};
                            flash_mem_card <= fill_tag[20];
                            flash_mem_req  <= 1'b1;
                            fstate         <= F_REQ1;
                        end
                    end
                    F_REQ1: begin
                        if (flash_mem_ready) begin
                            for (k = 0; k < 8; k = k + 1)
                                line[8+k] <= flash_mem_q[k*16 +: 16];
                            line_tag   <= fill_tag;
                            line_valid <= 1'b1;
                            fstate     <= F_IDLE;
                        end
                    end
                    default: fstate <= F_IDLE;
                endcase
            end
        end

        // Ready: ID reads + writes are always ready (writes cannot stall on EXP1 --
        // patch 0006 only holds READS). Erase-status reads are always ready too (the
        // CPU is data-polling a busy pair; the answer is the status word, no SDRAM).
        // A line-buffer HIT is ready unless a PROGRAM write-back is pending: while
        // prog_pend, EVERY array read stalls so the BIOS's post-program AMD data-poll
        // read blocks until this word's SDRAM commit lands -- serialising program ->
        // commit -> next program (no lost writes). Walker writes deliberately do NOT
        // stall reads: idle pairs must stay live for the installer's interleaved ID
        // checks and polls while another pair erases. An array read that misses still
        // stalls until its line fills.
        assign flash_ready = !array_read || id_read || erase_hit
                             || (tag_hit && !prog_pend);

        // Read mux: absent PCMCIA slot / unselected -> all ones (MAME
        // pccard_slot_device::read_memory with no card returns 0xffff); a busy
        // (erasing) pair -> the AMD status word on both x8 lanes (real Fujitsu parts
        // return status for ANY read of a busy chip, incl. after ignored autoselect
        // writes -- MAME intelfsh maker==Fujitsu exception); otherwise the
        // command-FSM output (the line-buffer word on array reads, MFR/DEV ID in
        // autoselect).
        always @(*) begin
            if (win_sel && sel_mem)
                win_dout = er_busy[pu] ? {er_status8, er_status8} : cmd_dout;
            else
                win_dout = 16'hFFFF;
        end
    end
    endgenerate
endmodule
