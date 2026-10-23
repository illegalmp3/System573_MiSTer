// -----------------------------------------------------------------------------
// s573_seccart.v - System 573 security-cartridge interface glue
//
// Connects the security devices (modeled in x76f100.v / x76f041.v / zs01.v and
// ds2401.v) to the ASIC register lines. The BIOS bit-bangs the cartridge through
// the D0-D7 output latch at 0x1f6a0000 and reads the result back through the
// 0x1f400004/06 status words. Per MAME's k573cass.cpp the cassette wires the
// latch bits to the device pins as:
//
//   D0 -> EEPROM SDA      D1 -> EEPROM SCL
//   D2 -> EEPROM CS       D3 -> EEPROM RST
//   D4 -> DS2401 (driven low when D4 = 1)
//   read-back: IO0 = EEPROM SDA (device-driven), I0 = DS2401 line
//
// SDA and the 1-Wire line are open-drain: the board drives a level and the device
// pulls low, so the read-back is the device-driven level wired-AND the latch.
//
// The EEPROM variant is chosen by CART_TYPE: 0 = X76F100 (112 B, e.g. hyperbbc-class
// carts), 1 = X76F041 (512 B + separate read/write/config passwords, e.g. pnchmn2),
// 2 = ZS01 (Konami NS2K001 PIC, packet/CRC protocol, e.g. gtrfrk5m).
//
// SDA WIRING DIFFERS by cart type (per MAME konami/k573cass.cpp):
//   * X76F100 / X76F041 cassettes (Y/X) wire EEPROM SDA-out on D0 of the data latch.
//   * the ZS01 cassette (ZI) leaves D0 UNCONNECTED and drives ZS01 SDA from the
//     CONTROL register bit 6 (write_line_zs01_sda, ACTIVE-LOW) -- a SEPARATE path.
//     SCL/CS/RST stay on D1/D2/D3, the DS2401 stays on D4, and the read-back uses the
//     same secflash_sda line (sec_io0). So for type 2 we drive ZS01 sda_i from the
//     (active-low) control bit 6 -- exposed here as io0_dir -- not from D0.
// Writing the data latch sets DRDY.
//
// A SECOND cassette (the "install" cassette of MAME's cassxzi / cassyyi configs) can
// be held alongside the game cassette and put in the slot with inst_sel -- see the
// port comments. It has its own DS2401 and its own X76F100 model; an install
// X76F041 uses eeprom041 (never the game chip in those configs).
//
// The cartridge EEPROM contents and the DS2401 serial can be LOADED at boot from the
// host ioctl stream (the real game's .u1 / .u6 dumps) instead of relying on the
// compile-time params. The EEPROM image (548 B x76f041 / 112 B x76f100 / 140 B-plus-
// padding zs01) and the 8-byte serial image are streamed in through
// (load_eep_we/addr/data) and (load_ser_we/addr/data); when nothing is loaded the
// params stay in effect, so existing sims pass unchanged.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_seccart #(
    parameter integer CART_TYPE      = 0,  // 0 = X76F100, 1 = X76F041, 2 = ZS01
    parameter [63:0]  READ_PASSWORD  = 64'h0000_0000_0000_0000,
    parameter [63:0]  WRITE_PASSWORD = 64'h0000_0000_0000_0000,
    parameter [47:0]  DS_SERIAL      = 48'h0000_0000_0001,
    parameter integer DS_CLK_HZ      = 1_000_000
)(
    input  wire        clk,
    input  wire        rst,

    // cart-type select (overrides CART_TYPE param when used; see emu.sv ioctl).
    // 0 = X76F100, 1 = X76F041, 2 = ZS01. Held stable from boot. Defaults to the param.
    input  wire [1:0]  cart_type,

    // 0x1f6a0000 D0-D7 output latch (write strobe sets DRDY)
    input  wire        latch_we,
    input  wire [7:0]  d_latch,
    input  wire        io0_dir,     // control reg bit 6: X76 = informational;
                                    // ZS01 = the SDA-out line (active-low)

    // ---- boot-time security-cart image load ----
    // EEPROM image (.u1): byte address into the image (x76f041 548 B / x76f100 112 B /
    // zs01 140 B + padding). 13-bit address covers the padded 4116-byte ZS01 .u1.
    input  wire        load_eep_we,
    input  wire [12:0] load_eep_addr,
    input  wire [7:0]  load_eep_data,
    // DS2401 serial image (.u6): 8-byte file index 0..7.
    input  wire        load_ser_we,
    input  wire [2:0]  load_ser_addr,
    input  wire [7:0]  load_ser_data,
    // 1 = this load_eep byte is the ZS01 NVRAM RESTORE from the slot-4 .sav
    // (s573_cass_nv), not the .u1 download: route it to the ZS01 ONLY. Without
    // this the restore also lands in the X76 models' low addresses, which is
    // harmless for a single cassette but would overwrite the INSTALL cassette
    // image held in eeprom041 (see the second cassette below).
    input  wire        load_eep_zs01_only,

    // ---- the SECOND (install) cassette ----
    // MAME ksys573.cpp Note 3 / cassxzi + cassyyi: some titles ship TWO cassettes
    // for ONE physical slot -- an "install" cassette used while installing from CD
    // and a "game" cassette afterwards (the operator swaps them and resets). The
    // driver's install option is always KONAMI573_CASSETTE_XI (X76F041 + DS2401) or
    // _YI (X76F100 + DS2401), never a ZS01. Both images are held here at once and
    // inst_sel says which cassette is in the slot (emu.sv derives it from the OSD
    // "573 Cassette" option). The install X76F100 has its own model (inst100); the
    // install X76F041 lives in eeprom041, which no dual-cassette config uses for its
    // GAME cassette (cassxzi = ZI game, cassyyi = YI game).
    input  wire        inst_sel,        // 1 = the INSTALL cassette is in the slot
    input  wire        inst_type,       // install EEPROM: 0 = X76F100, 1 = X76F041
    input  wire        load_ieep_we,    // install EEPROM image byte (548 B x76f041 / 132 B x76f100)
    input  wire [9:0]  load_ieep_addr,
    input  wire [7:0]  load_ieep_data,
    input  wire        load_iser_we,    // install cassette DS2401 serial (8 B)
    input  wire [2:0]  load_iser_addr,
    input  wire [7:0]  load_iser_data,

    // read-back toward the ASIC status words
    output wire [63:0] sec_dbg,     // ZS01 engine observability -> HPS STATUS 6..9
    output wire        sec_cs_n,    // live cassette chip-select (latch D2), for the read-back capture
    output wire        sec_rst_line,// live cassette RST (latch D3), for the read-back capture
    output wire        sec_scl_line,// live cassette SCL (latch D1)
    output wire        sec_sda_line,// live cassette SDA drive (latch D0)
    output wire        sec_ds_line, // live board-DS2401 drive (latch D4), 1-Wire traffic marker
    output wire [2:0]  sec_zs01_state, // ZS01 framing state, for the event trace
    output wire [7:0]  sec_rtr_edges, // RTR falling edges the ZS01 serviced
    output wire        sec_in_rtr,    // ZS01 is shifting its response-to-reset right now
    output wire [31:0] sec_rtr_emit,  // the 32 bits it drove on those edges
    output wire        sec_io0,     // IO0  = EEPROM SDA (device-driven)
    output wire [7:0]  sec_in,      // I0-I7 ; I0 = DS2401 line
    output reg         sec_drdy,
    output wire        sec_irdy,
    // ZS01 NVRAM persistence (see zs01.v): .u1-layout dump port (2-clock latency) and
    // the one-clock "a WRITE changed persisted state" strobe.
    input  wire [7:0]  zs01_dump_addr,
    output wire [7:0]  zs01_dump_data,
    output wire        zs01_nv_wr
);
    // Effective cart type: the runtime cart_type input wins; if it is left at 0 and
    // CART_TYPE param is non-zero (sim-configured), fall back to the param.
    wire [1:0] eff_type = (cart_type != 2'd0) ? cart_type : CART_TYPE[1:0];

    // ----- 0x1f6a0000 OUTPUT LATCH (MAME ksys573 security_w semantics) -----
    // The cassette pins see the REGISTERED latch, captured only on latch_we.
    // system573_top wires d_latch straight from the LIVE exp1_wdata, so without
    // this register ANY EXP1-region write (e.g. the 0x1f5c0000 watchdog kick)
    // would rewrite CS/SCL/SDA/RST mid-transaction. Hardening per the OQ3 MAME
    // run (tools/trace/sec_wd_tap.lua): the BIOS does NOT kick inside an X76
    // transaction, but the latch is the correct hardware model regardless.
    reg [7:0] d_q;
    always @(posedge clk) begin
        if (rst)           d_q <= 8'h00;
        else if (latch_we) d_q <= d_latch;
    end

    // ----- cassette SDA (cart pin 28): ONE electrical model for every cassette -----
    // GX700-PWB (NaokiS28 Konami-System-573-Documentation, Ksys573 + Security-cart
    // sheets): the 0x1f500000 bank latch 27G Q6 (bit 6) -> 74LS14 24E (pins 13->12)
    // -> /OE (pin 10) of 74LS125 gate 35H (pins 9->8). The gate's input is the cart
    // latch 35K Q0 (D0); its output is cart pin 28, which is also the net the ASIC
    // reads back as IO0 (KCUS-93 -> 0x1f400006 bit 2). So the host's level on SDA is
    //     bit6 ? D0 : released (pulled up)
    // and the read-back is that line wired-AND the device's open-drain pull-down.
    // This one equation covers all three drivers that exist:
    //   * Konami X76 driver: bit6=1 while sending, data on D0 (unchanged behaviour);
    //   * Konami ZS01 driver: D0 left at 0, SDA moved by bit6 alone (== the old
    //     zs01_sda_i = ~io0_dir, see below);
    //   * 573in1 (src/common/io.cpp CartI2CDriver::_setSDA): D0 forced 0, SDA moved by
    //     bit6 alone -- which the old X76 wiring (sda_i = D0) could never see, so every
    //     X76 command after the reset-ID probe failed (sim/tb_573in1_cart.v).
    // MAME k573cass.cpp models only the two Konami cases separately.
    wire host_sda = io0_dir ? d_q[0] : 1'b1;

    // ----- EEPROM on D0..D3 : one of X76F100 / X76F041 / ZS01, gated by eff_type -----
    // All three EEPROM models are instantiated; only the selected one's chip-select is
    // driven (the others held deselected, cs=1) and the read-back SDA is muxed.
    wire sda100_o, sda041_o, sda_zs01_o;
    // The ZS01 cannot see its own chip-select decision, and "which model is even
    // selected" is the question its dbg bus cannot answer alone. Stamp it here.
    wire [63:0] zs01_dbg;
    // The stamp is the type of the cassette IN THE SLOT (the install cassette's
    // when it is selected), so HPS STATUS word 9 says which one the game is talking to.
    wire [1:0] slot_type = inst_sel ? {1'b0, inst_type} : eff_type;
    assign sec_dbg = {slot_type, zs01_dbg[61:0]};
    wire eeprom_cs = d_q[2];
    assign sec_cs_n = eeprom_cs;   // live CS out, for the read-back capture in system573_top
    assign sec_rst_line = d_q[3];  // live RST out (same)
    assign sec_scl_line = d_q[1];
    assign sec_sda_line = d_q[0];
    assign sec_ds_line  = d_q[4];  // 1 = the host is pulling the 1-Wire line low
    assign sec_zs01_state = zs01_dbg[34:32];   // dbg[35:32] = state
    // Which model is in the slot. The GAME cassette (inst_sel=0) is eff_type as
    // before; the INSTALL cassette (inst_sel=1) is inst100 (X76F100) or eeprom041
    // (X76F041). Exactly one of the four is selected at any time.
    wire sel100    = ~inst_sel & (eff_type == 2'd0);
    wire sel041    = inst_sel ? inst_type : (eff_type == 2'd1);
    wire sel_zs01  = ~inst_sel & (eff_type == 2'd2);
    wire sel100i   = inst_sel & ~inst_type;

    // The .u1 download (not the ZS01 NVRAM restore) -- what the X76 models may take.
    wire game_eep_we = load_eep_we & ~load_eep_zs01_only;

    x76f100 #(.READ_PASSWORD(READ_PASSWORD), .WRITE_PASSWORD(WRITE_PASSWORD)) eeprom100 (
        .clk(clk), .rst(rst),
        .cs(sel100 ? eeprom_cs : 1'b1), .sec_rst(d_q[3]),
        .scl(d_q[1]), .sda_i(host_sda), .sda_o(sda100_o),
        // All three game models are loaded unconditionally (cart_type may still be
        // settling as the image streams in); each consumes only the bytes it understands.
        // The x76f100 image is <=132 B so it takes the low 10 addr bits; higher addresses
        // (a 548-B F041 / 4116-B ZS01 .u1) wrap harmlessly into its unused body and the
        // read-back mux ignores eeprom100 anyway for those cart types.
        .load_we(game_eep_we), .load_addr(load_eep_addr[9:0]), .load_data(load_eep_data)
    );

    // eeprom041 holds EITHER the game X76F041 (.u1 download, single-cassette titles
    // such as dsem / pnchmn2) OR the install X76F041 (the .cas pack). Once an install
    // image large enough to be an X76F041 (past the 132-B X76F100 size) has been
    // loaded, the .u1 stream is shut out of it -- so the result does not depend on
    // the order the two files arrive in (a later 4116-B ZS01 .u1 would otherwise
    // wrap its low 10 bits over the install image).
    reg inst041_loaded = 1'b0;
    always @(posedge clk) begin
        if (load_ieep_we && load_ieep_addr >= 10'd256) inst041_loaded <= 1'b1;
    end
    wire        e041_we   = load_ieep_we | (game_eep_we & ~inst041_loaded);
    wire [9:0]  e041_addr = load_ieep_we ? load_ieep_addr : load_eep_addr[9:0];
    wire [7:0]  e041_data = load_ieep_we ? load_ieep_data : load_eep_data;
    x76f041 eeprom041 (
        .clk(clk), .rst(rst),
        .cs(sel041 ? eeprom_cs : 1'b1), .sec_rst(d_q[3]),
        .scl(d_q[1]), .sda_i(host_sda), .sda_o(sda041_o),
        // The x76f041 takes the low 10 addr bits (its image is <=548 B); for a ZS01 .u1
        // (4116 B) the high addresses wrap harmlessly into its unused data RAM and the
        // mux ignores eeprom041 anyway.
        .load_we(e041_we), .load_addr(e041_addr), .load_data(e041_data)
    );

    // The install X76F100 (cassyyi titles: ddr3ma-class, ddrs2k, dsfdct). Loaded only
    // from the install pack; an X76F041-sized pack leaves its first 132 B here unused.
    wire sda100i_o;
    x76f100 inst100 (
        .clk(clk), .rst(rst),
        .cs(sel100i ? eeprom_cs : 1'b1), .sec_rst(d_q[3]),
        .scl(d_q[1]), .sda_i(host_sda), .sda_o(sda100i_o),
        .load_we(load_ieep_we), .load_addr(load_ieep_addr), .load_data(load_ieep_data)
    );

    // ZS01 SDA-in (host -> chip). PROVEN from the game's own code (2026-09-14):
    // PSX.EXE was extracted from the ddrusa disc (a44uaa02.chd, ISO9660 /PSX.EXE,
    // LBA 8216) and disassembled. The 573 installer carries TWO separate cassette
    // drivers:
    //   * X76  driver, 0x80323800-0x80324300: bit-bangs the data bit on LATCH D0
    //     (`andi latch,0xfffe; or data; sh 0x1f6a0000` -- 10 such sites) and uses
    //     CONTROL bit 6 only as the IO0 output ENABLE (0x803208c8(1) to drive,
    //     0x80323cd4 `andi 0xffbf` to release before a read).
    //   * ZS01 driver, 0x80325000-0x80326200: contains detector A (0x803250b8) and
    //     the packet transport. It NEVER writes latch D0 -- a scan of the whole
    //     region finds zero D0 manipulations (the only two 0x0001 immediates are
    //     detector A building the compare constant 0x5a530001 at 0x80325224 and a
    //     stack-built command byte at 0x803253ac). It drives SDA EXCLUSIVELY through
    //     CONTROL bit 6 via 0x803208f4, and SCL/CS/RST on latch D1/D2/D3. e.g. the
    //     STOP generator at 0x80325f9c is bit6=1 (SDA low) -> SCL high -> bit6=0
    //     (SDA high), and detector A calls 0x803208f4(0) to RELEASE SDA before the
    //     response-to-reset.
    // This matches MAME k573cass.cpp exactly: konami573_cassette_zi_device overrides
    // write_line_d1/d2/d3/d4 and write_line_zs01_sda, but NOT write_line_d0 -- the
    // base konami573_cassette_interface::write_line_d0 is an empty method, so D0 is
    // physically unconnected to the ZS01. ksys573.cpp wires bit 0x40 of OUT2
    // (control_w) IP_ACTIVE_LOW to write_line_zs01_sda, hence sda = ~io0_dir.
    //
    // The previous `d_q[0] & ~io0_dir` (960920a) came from disassembling 0x80323b40
    // and taking it for the ZS01 bit-bang; it is the X76's. ANDing D0 in pinned SDA
    // LOW forever (the ZS01 driver leaves D0 at 0), so the chip never saw SDA go high
    // and NO START condition (SDA 1->0 while SCL high) could ever be detected: the
    // fabric reported i2c_starts=0, pkts=0 while the response-to-reset still worked
    // (cs_seen=1, rtr_probes=1, rtr_edges=33) -- the ZS01 verify therefore failed and
    // the installer reported ERROR 121 (3). SCL/CS/RST stay on D1/D2/D3.
    // Superseded by host_sda (above), which reduces to ~io0_dir whenever D0 = 0 --
    // the state the Konami ZS01 driver always leaves it in (it never writes D0).
    wire zs01_sda_i = host_sda;
    wire zs01_nv_wr_raw;   // declared before the instance that drives it
    zs01 eeprom_zs01 (
        .clk(clk), .rst(rst),
        // ZS01 has no chip select: psx-spx "ZS01 cartridge variants" lists only
        // D0/D1/D3/IO0/DSR, and 573in1 io.cpp resetZS01() notes "CS is ignored".
        // (MAME k573cass.cpp wires D2 to write_cs; both sources above disagree.)
        .cs(sel_zs01 ? 1'b0 : 1'b1), .sec_rst(d_q[3]),
        .scl(d_q[1]), .sda_i(zs01_sda_i), .sda_o(sda_zs01_o),
        .load_we(load_eep_we), .load_addr(load_eep_addr), .load_data(load_eep_data),
        // the same .u6 serial feeds the ZS01's internal DS2401 (0xFC/0xFD reads)
        .load_ds_we(load_ser_we), .load_ds_addr(load_ser_addr), .load_ds_data(load_ser_data),
        .dbg(zs01_dbg), .rtr_edges(sec_rtr_edges), .in_rtr(sec_in_rtr), .rtr_emit(sec_rtr_emit),
        .dump_addr(zs01_dump_addr), .dump_data(zs01_dump_data), .nv_wr(zs01_nv_wr_raw)
    );
    assign zs01_nv_wr = sel_zs01 & zs01_nv_wr_raw;

    wire eeprom_sda_o = sel_zs01 ? sda_zs01_o :
                        sel041   ? sda041_o   :
                        sel100i  ? sda100i_o  : sda100_o;

    // ----- cassette DS2401 on D4 (open-drain, pulled up) -----
    // Each cassette carries its own DS2401 (MAME k573cass.cpp: the _XI/_YI/_ZI
    // devices each own one; ksys573.cpp loads "cassette:game:id" and
    // "cassette:install:id" separately -- ddr4m's gca33aa.u6 vs gea33aa.u6 differ).
    // Two slaves, both listening; only the selected cassette's pull-down reaches
    // the wire.
    // ZS01 game cassettes are the exception: psx-spx "ZS01 cartridge variants":
    // the DS2401 "is connected to a GPIO pin on the ZS01 rather than being
    // directly exposed to the 573" -- it is read through the ZS01 command set
    // (573in1 ZS01Driver::readCartID, address ZS01_ADDR_DS2401_ID; zs01.v loads
    // the same .u6 serial). Nothing answers on D4/I6 then. MAME k573cass.cpp
    // exposes it on D4 as well; the hardware sources say it is not.
    wire ds_pd_game_raw, ds_pd_inst;
    wire ds_pd_game = ds_pd_game_raw & ~sel_zs01;
    wire ds_pd   = inst_sel ? ds_pd_inst : ds_pd_game;
    wire ds_line = ~(d_q[4] | ds_pd);         // D4=1 pulls the 1-wire line low
    ds2401 #(.SERIAL(DS_SERIAL), .CLK_FREQ_HZ(DS_CLK_HZ)) board_id (
        .clk(clk), .rst(rst), .dq_in(ds_line), .dq_pd(ds_pd_game_raw),
        .load_we(load_ser_we), .load_addr(load_ser_addr), .load_data(load_ser_data)
    );
    ds2401 #(.SERIAL(DS_SERIAL), .CLK_FREQ_HZ(DS_CLK_HZ)) inst_id (
        .clk(clk), .rst(rst), .dq_in(ds_line), .dq_pd(ds_pd_inst),
        .load_we(load_iser_we), .load_addr(load_iser_addr), .load_data(load_iser_data)
    );

    assign sec_io0  = eeprom_sda_o & host_sda;   // pin 28 = host drive wired-AND device
    assign sec_in   = {7'b0, ds_line};
    assign sec_irdy = 1'b1;                   // bit-banged device is always ready

    // writing the latch raises DRDY (cleared on reset)
    always @(posedge clk) begin
        if (rst)            sec_drdy <= 1'b0;
        else if (latch_we)  sec_drdy <= 1'b1;
    end
endmodule
