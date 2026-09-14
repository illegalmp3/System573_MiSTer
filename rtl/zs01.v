// -----------------------------------------------------------------------------
// zs01.v - Konami ZS01 (NS2K001) security-cartridge PIC, high-level model
//
// The ZS01 is a PIC microcontroller used on later System 573 security carts. It
// speaks the same CS/RST/SCL/SDA serial lines as the X76 EEPROMs but wraps every
// access in a fixed-size, obfuscated, CRC-checked packet rather than a bit-banged
// command/password handshake:
//
//   * RST 0->1 (CS low) streams a 4-byte response-to-reset (0x5A,0x53,0x00,0x01)
//     MSB-first on FALLING SCL edges, LOOPING until a start/stop condition (MAME
//     parks after one pass; see the note in the RTR block for why we do not).
//   * A start condition moves STOP -> LOAD_COMMAND; the host clocks in a 12-byte
//     packet MSB-first (device ACKs each byte on the 9th clock).
//   * The 12 bytes are descrambled with the fixed 8-byte command key; if command
//     bit2 is set the 8 data bytes get a second descramble with the per-cart data
//     key. A CRC-16/CCITT (poly 0x1021, init 0xFFFF, inverted) over bytes 0..9 is
//     checked against bytes 10..11.
//   * Packet = [command][address][8 data][crc16].  command bit0: 0=write,1=read.
//     data_offset = address*8 into 112 data bytes; addresses 0xFC/0xFD read the
//     internal DS2401, 0xFE the config registers, 0xFF sets the data key, 0xFD
//     write erases the data + data key.
//   * The device builds a 12-byte response [status][..][8 data][crc16], scrambles
//     it with the *response key* (the 8 data bytes the host sent on a read), and
//     the host clocks it back out, ACKing each byte.
//
// The scramble is a custom byte cipher (NOT DES): key[0] is an additive term and
// key[1..7] are (rotate, add) pairs, CBC-chained on the ciphertext byte. This is
// a faithful transliteration of MAME's src/mame/konami/zs01.cpp. The heavy packet
// transform is performed in a single behavioral step (the reference is itself an
// HLE of the PIC); the surrounding serial framing is a clocked FSM.
//
// SDA is split into host-driven (sda_i) and device-driven (sda_o) levels, as the
// 573 ASIC wires IO0. NOTE the real ZS01 cassette wires SDA-out on a SEPARATE line
// from the X76 carts: per k573cass.cpp the ZI cassette leaves D0 unconnected and
// drives ZS01 SDA from the CONTROL register bit 6 (write_line_zs01_sda, active-low);
// SCL/CS/RST stay on the D1/D2/D3 data-latch bits and the read-back uses the same
// secflash_sda path. The glue (s573_seccart.v) routes sda_i for type 2 accordingly;
// this module just sees sda_i/sda_o. Data, keys and config registers persist across
// the (volatile) system reset.
//
// --- boot-time NVRAM image load (the gtrfrk5m gea26jaa.u1 ZS01 dump) ---
// The .u1 is the raw MAME zs01 nvram image (machine konami/zs01.cpp nvram_read order):
//   [  0:  3] response-to-reset (4 bytes, 0x5A,0x53,0x00,0x01) -- IGNORED here (the
//             RTR constant is hard-wired in rtr_val()); accepted + dropped.
//   [  4: 11] command key  (8 bytes) -> cmdkey[0..7]  (fixed PIC key, same on all carts)
//   [ 12: 19] data key     (8 bytes) -> dkey[0..7]    (the PER-CART key -- it is IN the
//             dump, NOT set at runtime, so loading the .u1 establishes authentication)
//   [ 20: 27] config regs  (8 bytes) -> creg[0..7]    (RR=idx4, RC=idx5)
//   [ 28:139] 112 data bytes        -> data[0..111]
// gtrfrk5m's gea26jaa.u1 is 4116 bytes = this 140-byte image + zero padding (the real
// 4 KB EEPROM body; MAME only models the first 112 bytes, so we load [28:139] and drop
// the rest). load_we writes load_data at byte address load_addr; the first loaded byte
// latches `loaded`, after which the loaded NVRAM overrides the compile-time params (the
// params stay the default for sims -- e.g. tb_zs01 -- that never drive the load port).
//
// --- Synthesis note (the 112-byte data array is an M10K block RAM) ---
// data[] is accessed through a SINGLE synchronous write port and a single registered
// read port (`data_rdata <= data[rd_addr]`), the M10K-friendly template from the fixed
// rtl/x76f041.v (commit d0d9f61): one clocked block, NO combinational/computed-index
// reads and NO `initial` fill that blocks inference. The packet engine reaches data[]
// ONLY through those two ports, one byte per clock.
//
// --- The packet engine is a SEQUENTIAL FSM (2026-09-13) ---
// Until 725dc52 the whole engine (decrypt, CRC, dispatch, encrypt) lived inside a
// `synthesis translate_off` block: unrolled 12x7 cipher rounds + two 112-byte array
// clears in ONE clock edge, which cannot synthesize. Quartus deleted it, so in every
// bitstream the ZS01 was a correct response-to-reset plus a shift register that
// accepted 12 bytes and returned nothing -- ddrusa "cassette does not match this
// game". Simulation compiled the block, so `make zs01` was green against code that
// had never been on the FPGA.
//
// Now: after the 12th command byte the framing FSM parks in ST_PROC and a sub-FSM
// (pstate) does the work one BYTE per clock -- one cipher byte = 7 chained
// (subtract, rotate) rounds, one CRC byte = 8 unrolled shift/xor steps -- and data[]
// moves go through the RAM ports one byte per clock. Worst case (a 0xFD erase) is
// ~250 clocks; a normal read is ~70. The real ZS01 is a PIC that needs hundreds of
// microseconds per packet and the host waits for it, so the budget is ample; the
// sticky `overrun` flag records an SCL edge arriving mid-processing for the bench.
//
// Protocol fidelity (mame src/mame/konami/zs01.cpp): the response buffer is NOT
// cleared on a READ or on a CRC error -- only byte 0 is set -- so byte 1 keeps the
// previous response's CIPHERTEXT, and m_previous_byte (the decrypt2 chain seed for
// the next data-key-scrambled command) is taken from that stale byte. A WRITE
// clears all 12. Replicated exactly; do not "tidy" it.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module zs01 #(
    parameter [63:0] COMMAND_KEY = 64'hED68_504B_C644_483E, // fixed PIC command key
    parameter [63:0] DATA_KEY    = 64'h0000_0000_0000_0000, // per-cart (set via 0xFF)
    parameter [63:0] CONFIG_INIT = 64'h0000_0000_FF00_0000, // 8 config regs (RR=idx4)
    parameter [63:0] DS2401_ID   = 64'h0102_0304_0506_0708  // internal serial number
)(
    input  wire clk,
    input  wire rst,        // system reset: clears volatile framing state
    input  wire cs,         // chip select, active low (0 = selected)
    input  wire sec_rst,    // chip RST pin, active high (0->1 = response to reset)
    input  wire scl,
    input  wire sda_i,      // SDA driven by the host (1 = released/high)
    output reg  sda_o,      // SDA driven by the device

    // ---- boot-time NVRAM image load (the 140-byte MAME zs01 nvram image) ----
    // Streamed in byte-by-byte at boot from the security-EEPROM ioctl channel
    // (index 4). load_addr is the file byte index 0..4115 (the real .u1 may carry
    // trailing zero padding past the 140-byte image; addresses >= 140 are dropped).
    input  wire        load_we,
    input  wire [12:0] load_addr,  // 0..4115 (12-bit covers the padded .u1)
    input  wire [7:0]  load_data,

    // ---- internal DS2401 serial load (the .u6 image, file byte index 0..7) ----
    // The ZI cassette's single DS2401 is read both on D4 (the board path) AND
    // internally by the ZS01 (the 0xFC/0xFD addresses). MAME's internal read returns
    // direct_read(7-i) = file byte 7-i; our ds_byte(k) returns file byte k, so we load
    // dsid[k] = .u6 file byte k. Defaults to the DS2401_ID param when not loaded.
    input  wire        load_ds_we,
    input  wire [2:0]  load_ds_addr,  // file byte index 0..7
    input  wire [7:0]  load_ds_data,

    // ---- observability (HPS STATUS words 6/7/8; see docs 2026-09-13 ddrusa) ----
    // The engine is multi-cycle and the real host neither clock-stretches nor waits,
    // so "did the game clock the response before we finished" is a real question that
    // only the board can answer. dbg carries it, plus what the game actually asked for.
    //   [7:0] packets received   [15:8] last cmd byte   [23:16] last address byte
    //   [31:24] last PLAINTEXT status   [35:32] state   [36] overrun (sticky)
    //   [37] last CRC ok   [38] image loaded   [39] cs has been asserted (sticky)
    //   [47:40] response bytes clocked out   [55:48] RTR probes answered
    //   [61:56] I2C STARTs seen   [63:62] filled in by s573_seccart (effective type)
    output wire [63:0] dbg,
    output reg  [7:0]  rtr_edges,  // falling SCL edges serviced in ST_RTR (saturating)
    output wire        in_rtr,     // 1 while the response-to-reset is being shifted out
    output reg  [31:0] rtr_emit    // the last 32 bits we drove on RTR falling edges (MSB = first)
);
    localparam [2:0] ST_STOP = 3'd0, ST_RTR = 3'd1, ST_CMD = 3'd2, ST_PROC = 3'd3, ST_READ = 3'd4;
    // packet-engine sub-states (active while state == ST_PROC)
    localparam [3:0] P_DEC_CMD  = 4'd0,  // wbuf[11..0]  descrambled with the command key
                     P_DEC_DONE = 4'd1,  // decide on the data-key pass
                     P_DEC_DATA = 4'd2,  // wbuf[2..9]   descrambled with the data key
                     P_CRC_CMD  = 4'd3,  // CRC over wbuf[0..9]
                     P_DISPATCH = 4'd4,  // CRC compare + command dispatch
                     P_WR_DATA  = 4'd5,  // 8 bytes -> data[] via the write port
                     P_RD_DATA  = 4'd6,  // 8 bytes <- data[] via the read port
                     P_ERASE    = 4'd7,  // 112-byte clear + data-key clear
                     P_CRC_RESP = 4'd8,  // CRC over rbuf[0..9]
                     P_CRC_WR   = 4'd9,  // store CRC, seed the encrypt chain
                     P_ENC      = 4'd10; // rbuf[11..0] scrambled with the response key
    localparam [7:0] STATUS_OK = 8'h00, STATUS_ERROR = 8'h02;
    localparam integer CONFIG_RR = 4, CONFIG_RC = 5;

    // ---- image-load byte-offset map (MAME zs01.cpp nvram layout) ----
    // 4-byte RTR header at [0:3] is consumed but not stored (RTR is constant).
    localparam integer LD_CMDKEY = 4;    // command key      [4:11]
    localparam integer LD_DKEY   = 12;   // data key         [12:19]
    localparam integer LD_CREG   = 20;   // config registers [20:27]
    localparam integer LD_DATA   = 28;   // 112 data bytes   [28:139]
    localparam integer LD_DATA_END = LD_DATA + 112; // 140 (exclusive)

    // ---- NVRAM (persists across system reset) ----
    // data[] is the 112-byte EEPROM body -- single write port + registered read port
    // (see below) so it infers as one M10K block (the fixed x76f041.v pattern).
    reg [7:0] wbuf   [0:11];
    reg [7:0] rbuf   [0:11];
    reg [7:0] cmdkey [0:7];  // command key (fixed PIC key; loadable from the .u1)
    reg [7:0] dkey   [0:7];  // data key (per-cart; loaded from .u1, mutable via 0xFF)
    reg [7:0] rkey   [0:7];  // response key (set per read)
    reg [7:0] creg   [0:7];  // configuration registers
    reg [7:0] dsid   [0:7];  // internal DS2401 serial (file byte k -> dsid[k])
    reg [7:0] data   [0:111];

    // High once any image byte has been loaded (the loaded NVRAM is authoritative;
    // before that the compile-time params remain in effect so existing sims pass).
    reg loaded = 1'b0;

    integer ii;
    initial begin
        for (ii = 0; ii < 8;  ii = ii + 1) begin
            cmdkey[ii] = COMMAND_KEY[8*(7-ii) +: 8];
            dkey[ii]   = DATA_KEY   [8*(7-ii) +: 8];
            creg[ii]   = CONFIG_INIT[8*(7-ii) +: 8];
            dsid[ii]   = DS2401_ID  [8*ii     +: 8];  // ds_byte(k)=dsid[k]=file byte k
            rkey[ii]   = 8'h00;
        end
        for (ii = 0; ii < 12;  ii = ii + 1) begin wbuf[ii] = 0; rbuf[ii] = 0; end
    end

    // SIM-ONLY default ramp for data[] (data[i]=i). Kept under translate_off so it is
    // invisible to synthesis and therefore CANNOT block M10K inference; in hardware
    // data[] starts as the (uninitialized) block RAM and is filled by the load port.
    // synthesis translate_off
    integer jj;
    initial for (jj = 0; jj < 112; jj = jj + 1) data[jj] = jj[7:0];
    // synthesis translate_on

    // ---- data[] single synchronous write port + registered read (M10K template) ----
    // Writers: the boot image load and the engine's P_WR_DATA / P_ERASE states, all
    // through ram_we/ram_waddr/ram_wdata (registers set in the main always block).
    // Reader: the engine's P_RD_DATA sets rd_addr; data_rdata is valid two clocks
    // later (rd_addr registered, then the RAM's registered output).
    reg [6:0] ram_waddr;
    reg [7:0] ram_wdata;
    reg       ram_we;
    reg [6:0] rd_addr;
    reg [7:0] data_rdata;
    always @(posedge clk) begin
        data_rdata <= data[rd_addr];            // registered read port
        if (ram_we) data[ram_waddr] <= ram_wdata;
    end

    // ---- volatile framing state ----
    reg [2:0] state;
    // ---- packet-engine state ----
    reg [3:0]  pstate;
    reg [3:0]  pidx;      // byte index into wbuf/rbuf
    reg [6:0]  pcnt;      // data-move / erase counter
    reg [7:0]  pprev;     // cipher chain byte
    reg [15:0] crcv;      // running CRC
    reg        overrun;   // sticky: an SCL edge arrived while still processing (bench-visible)
    reg [7:0]  dbg_pkts, dbg_cmd, dbg_addr, dbg_status, dbg_rbytes, dbg_rtr;
    reg [5:0]  dbg_starts;
    reg        dbg_crc_ok, dbg_cs_seen;
    // [63:62] are driven by s573_seccart (the effective cart type lives there).
    assign in_rtr = (state == ST_RTR);
    assign dbg = {2'b00, dbg_starts, dbg_rtr,
                  dbg_rbytes, dbg_cs_seen, loaded, dbg_crc_ok, overrun, 1'b0, state,
                  dbg_status, dbg_addr, dbg_cmd, dbg_pkts};
    wire [7:0] rc_next = creg[CONFIG_RC] + 8'd1;
    // data_offset() = address*8; valid only below the 112-byte body (address < 14)
    wire       off_ok  = (wbuf[1] < 8'd14);
    wire [6:0] off7    = {wbuf[1][3:0], 3'b000};
    reg [3:0] bitc;
    reg [7:0] bytec;
    reg [7:0] shift;
    reg [7:0] prevbyte;     // m_previous_byte (data-key chain seed)
    reg       pscl, psda, prst;

    function [7:0] rtr_val(input [7:0] b);
        case (b[1:0])
            2'd0: rtr_val = 8'h5a;
            2'd1: rtr_val = 8'h53;
            2'd2: rtr_val = 8'h00;
            default: rtr_val = 8'h01;
        endcase
    endfunction
    function [7:0] ror8(input [7:0] x, input [2:0] r); ror8 = (x >> r) | (x << ((4'd8-r) & 3'd7)); endfunction
    function [7:0] rol8(input [7:0] x, input [2:0] r); rol8 = (x << r) | (x >> ((4'd8-r) & 3'd7)); endfunction


    // ---- the packet cipher, ONE BYTE per call (faithful to MAME decrypt/decrypt2/encrypt) ----
    // Descramble rounds k7..k1 of one byte: t = ror8(t - (k & 0x1f), k >> 5). The caller
    // finishes with (t - k0) ^ prev and chains prev <= ciphertext. keysel 0 = command
    // key (decrypt), 1 = data key (decrypt2) -- identical arithmetic, different key.
    function [7:0] dec_rounds(input [7:0] c, input keysel);
        integer kk; reg [7:0] t, kb;
        begin
            t = c;
            for (kk = 7; kk >= 1; kk = kk - 1) begin
                kb = keysel ? dkey[kk] : cmdkey[kk];
                t  = t - (kb & 8'h1f);
                t  = ror8(t, kb[7:5]);
            end
            dec_rounds = t;
        end
    endfunction
    // Scramble one byte with the response key: acc = k0 + (p ^ prev); then for k1..k7
    // acc = rol8(acc, k >> 5) + (k & 0x1f). The caller chains prev <= result.
    function [7:0] enc_byte(input [7:0] p, input [7:0] prev);
        integer kk; reg [7:0] acc, kb;
        begin
            acc = rkey[0] + (p ^ prev);
            for (kk = 1; kk <= 7; kk = kk + 1) begin
                kb  = rkey[kk];
                acc = rol8(acc, kb[7:5]);
                acc = acc + (kb & 8'h1f);
            end
            enc_byte = acc;
        end
    endfunction
    // One CRC-16/CCITT byte step (poly 0x1021, MSB-first); init 0xFFFF, final inversion
    // are the caller's.
    function [15:0] crc_step(input [15:0] v0, input [7:0] b);
        integer a2; reg [15:0] v;
        begin
            v = v0 ^ {b, 8'h00};
            for (a2 = 0; a2 < 8; a2 = a2 + 1)
                v = v[15] ? ((v << 1) ^ 16'h1021) : (v << 1);
            crc_step = v;
        end
    endfunction

    reg [7:0]  sbyte;
    reg [7:0]  encb;
    integer    i;

    always @(posedge clk) begin
        // ===== boot-time NVRAM image load (runs even while rst is asserted) =====
        // Small register files are written directly; the 112-byte body goes through
        // the single data[] write port (ram_we/ram_waddr/ram_wdata). The 4-byte RTR
        // header and any padding past byte 139 are accepted and dropped.
        ram_we <= 1'b0;                          // one-shot default
        if (load_we) begin
            loaded <= 1'b1;
            if (load_addr >= LD_DATA[12:0] && load_addr < LD_DATA_END[12:0]) begin
                ram_we    <= 1'b1;
                ram_waddr <= load_addr[6:0] - LD_DATA[6:0];   // 0..111
                ram_wdata <= load_data;
            end else if (load_addr >= LD_CREG[12:0] && load_addr < LD_DATA[12:0])
                creg[load_addr - LD_CREG[12:0]]     <= load_data;
            else if (load_addr >= LD_DKEY[12:0] && load_addr < LD_CREG[12:0])
                dkey[load_addr - LD_DKEY[12:0]]     <= load_data;
            else if (load_addr >= LD_CMDKEY[12:0] && load_addr < LD_DKEY[12:0])
                cmdkey[load_addr - LD_CMDKEY[12:0]] <= load_data;
            // load_addr < LD_CMDKEY: the 4-byte RTR header -- accepted and dropped.
            // load_addr >= LD_DATA_END: trailing .u1 padding -- accepted and dropped.
        end
        // internal DS2401 serial (.u6): file byte k -> dsid[k].
        if (load_ds_we) begin
            loaded <= 1'b1;
            dsid[load_ds_addr] <= load_ds_data;
        end

        if (rst) begin
            state <= ST_STOP; bitc <= 0; bytec <= 0; shift <= 0;
            prevbyte <= 0; sda_o <= 1'b0;
            pstate <= P_DEC_CMD; pidx <= 0; pcnt <= 0; pprev <= 0; crcv <= 16'hffff; overrun <= 1'b0;
            dbg_pkts <= 0; dbg_cmd <= 0; dbg_addr <= 0; dbg_status <= 0; dbg_rbytes <= 0; dbg_crc_ok <= 0;
            dbg_rtr <= 0; dbg_starts <= 0; dbg_cs_seen <= 1'b0; rtr_edges <= 0; rtr_emit <= 0;
        end else begin
            // ================= packet engine: one byte per clock =================
            if (state == ST_PROC) begin
                case (pstate)
                P_DEC_CMD: begin                 // decrypt(wbuf, 12, cmdkey, 0xff), descending
                    wbuf[pidx] <= (dec_rounds(wbuf[pidx], 1'b0) - cmdkey[0]) ^ pprev;
                    pprev      <= wbuf[pidx];
                    if (pidx == 4'd0) pstate <= P_DEC_DONE; else pidx <= pidx - 4'd1;
                end
                P_DEC_DONE: begin                // (write_buffer[0] & 4) -> decrypt2 with the data key
                    if (wbuf[0][2]) begin
                        pstate <= P_DEC_DATA; pidx <= 4'd2; pprev <= prevbyte;
                    end else begin
                        pstate <= P_CRC_CMD;  pidx <= 4'd0; crcv  <= 16'hffff;
                    end
                end
                P_DEC_DATA: begin                // decrypt2(wbuf+2, 8, dkey, m_previous_byte), ascending
                    wbuf[pidx] <= (dec_rounds(wbuf[pidx], 1'b1) - dkey[0]) ^ pprev;
                    pprev      <= wbuf[pidx];
                    if (pidx == 4'd9) begin pstate <= P_CRC_CMD; pidx <= 4'd0; crcv <= 16'hffff; end
                    else pidx <= pidx + 4'd1;
                end
                P_CRC_CMD: begin                 // calc_crc(wbuf, 10)
                    crcv <= crc_step(crcv, wbuf[pidx]);
                    if (pidx == 4'd9) pstate <= P_DISPATCH; else pidx <= pidx + 4'd1;
                end
                P_DISPATCH: begin
                    dbg_cmd    <= wbuf[0];                        // observability
                    dbg_addr   <= wbuf[1];
                    dbg_crc_ok <= (~crcv == {wbuf[10], wbuf[11]});
                    pcnt   <= 7'd0;
                    pstate <= P_CRC_RESP; pidx <= 4'd0; crcv <= 16'hffff;   // default next
                    if (~crcv == {wbuf[10], wbuf[11]}) begin
                        creg[CONFIG_RC] <= 8'h00;
                        rbuf[0] <= STATUS_OK;
                        if (wbuf[0][0] == 1'b0) begin
                            // ---- WRITE: MAME clears the whole response buffer ----
                            for (i = 1; i < 12; i = i + 1) rbuf[i] <= 8'h00;
                            if (wbuf[1] == 8'hfd)      pstate <= P_ERASE;
                            else if (wbuf[1] == 8'hfe) for (i = 0; i < 8; i = i + 1) creg[i] <= wbuf[2+i];
                            else if (wbuf[1] == 8'hff) for (i = 0; i < 8; i = i + 1) dkey[i] <= wbuf[2+i];
                            else if (off_ok)           pstate <= P_WR_DATA;
                        end else begin
                            // ---- READ: only byte 0 is set; bytes 1 and 10..11 stay stale ----
                            for (i = 0; i < 8; i = i + 1) rkey[i] <= wbuf[2+i];
                            if (wbuf[1] == 8'hfc || wbuf[1] == 8'hfd)
                                 for (i = 0; i < 8; i = i + 1) rbuf[2+i] <= dsid[7-i];
                            else if (wbuf[1] == 8'hfe)
                                 // RC was zeroed above IN THIS CLOCK (nonblocking): the copy must
                                 // see the new value, as MAME's memcpy does after its RC = 0.
                                 for (i = 0; i < 8; i = i + 1) rbuf[2+i] <= (i == CONFIG_RC) ? 8'h00 : creg[i];
                            else if (off_ok) pstate <= P_RD_DATA;
                        end
                    end else begin
                        // ---- bad CRC: STATUS_ERROR, retry counter, wipe at the limit ----
                        rbuf[0] <= STATUS_ERROR;
                        creg[CONFIG_RC] <= rc_next;
                        if (rc_next >= creg[CONFIG_RR]) pstate <= P_ERASE;
                    end
                end
                P_WR_DATA: begin                 // memcpy(&m_data[off], &wbuf[2], 8)
                    ram_we    <= 1'b1;
                    ram_waddr <= off7 + pcnt[2:0];
                    ram_wdata <= wbuf[2 + pcnt[2:0]];
                    if (pcnt == 7'd7) begin pstate <= P_CRC_RESP; pidx <= 4'd0; crcv <= 16'hffff; end
                    else pcnt <= pcnt + 7'd1;
                end
                P_RD_DATA: begin                 // memcpy(&rbuf[2], &m_data[off], 8): 2-clock read latency
                    if (pcnt < 7'd8) rd_addr <= off7 + pcnt[2:0];
                    if (pcnt >= 7'd2) rbuf[2 + (pcnt[3:0] - 4'd2)] <= data_rdata;
                    if (pcnt == 7'd9) begin pstate <= P_CRC_RESP; pidx <= 4'd0; crcv <= 16'hffff; end
                    else pcnt <= pcnt + 7'd1;
                end
                P_ERASE: begin                   // fill(m_data, 0); fill(m_data_key, 0)
                    ram_we    <= 1'b1;
                    ram_waddr <= pcnt;
                    ram_wdata <= 8'h00;
                    if (pcnt == 7'd0) for (i = 0; i < 8; i = i + 1) dkey[i] <= 8'h00;
                    if (pcnt == 7'd111) begin pstate <= P_CRC_RESP; pidx <= 4'd0; crcv <= 16'hffff; end
                    else pcnt <= pcnt + 7'd1;
                end
                P_CRC_RESP: begin                // m_previous_byte = read_buffer[1]; calc_crc(rbuf, 10)
                    if (pidx == 4'd0) begin prevbyte <= rbuf[1]; dbg_status <= rbuf[0]; end
                    crcv <= crc_step(crcv, rbuf[pidx]);
                    if (pidx == 4'd9) pstate <= P_CRC_WR; else pidx <= pidx + 4'd1;
                end
                P_CRC_WR: begin
                    rbuf[10] <= ~crcv[15:8];
                    rbuf[11] <= ~crcv[7:0];
                    pprev    <= 8'hff;           // encrypt() seed
                    pidx     <= 4'd11;
                    pstate   <= P_ENC;
                end
                P_ENC: begin                     // encrypt(rbuf, 12, rkey, 0xff), descending
                    encb       = enc_byte(rbuf[pidx], pprev);
                    rbuf[pidx] <= encb;
                    pprev      <= encb;
                    if (pidx == 4'd0) begin
                        state <= ST_READ; bytec <= 8'd0; bitc <= 4'd0;
                    end else pidx <= pidx - 4'd1;
                end
                default: pstate <= P_DEC_CMD;
                endcase
            end
            if (cs == 1'b0) begin
                dbg_cs_seen <= 1'b1;                 // observability: were we ever selected?
                // ----- RST pin: response to reset -----
                if (prst == 1'b0 && sec_rst != 1'b0) begin
                    state <= ST_RTR; bitc <= 0; bytec <= 0;
                    if (~&dbg_rtr) dbg_rtr <= dbg_rtr + 8'd1;
                end
                // ----- stop condition (SDA 0->1 while SCL high): back to idle, SDA released -----
                // (as x76f100.v / x76f041.v; the game's own STOP generator, PSX.EXE
                // 0x800ac77c, is exactly this edge, and it precedes every transaction)
                if (scl != 1'b0 && psda == 1'b0 && sda_i != 1'b0) begin
                    state <= ST_STOP; bitc <= 0; bytec <= 0; sda_o <= 1'b1;
                end
                // ----- start condition (SDA 1->0 while SCL high) -----
                if (scl != 1'b0 && psda != 1'b0 && sda_i == 1'b0) begin
                    if (~&dbg_starts) dbg_starts <= dbg_starts + 6'd1;
                    if (state == ST_STOP || state == ST_RTR) state <= ST_CMD;   // RTR loops until this
                    bitc <= 0; bytec <= 0; shift <= 0; sda_o <= 1'b0;
                end
                // ----- response-to-reset: FALLING edge, MSB-first -----
                if (state == ST_RTR && pscl != 1'b0 && scl == 1'b0) begin
                    if (~&rtr_edges) rtr_edges <= rtr_edges + 8'd1;   // observability
                    sbyte = (bitc == 4'd0) ? rtr_val(bytec) : shift;
                    rtr_emit <= {rtr_emit[30:0], sbyte[7]};             // what we put on SDA
                    sda_o <= sbyte[7];
                    shift <= sbyte << 1;
                    if (bitc == 4'd7) begin
                        bitc  <= 0;
                        // LOOP the four bytes until the host issues a START or STOP.
                        // MAME's zs01 parks after one pass, but both cassette chips that
                        // authenticate on this hardware (x76f100.v, x76f041.v) loop, and
                        // the one-shot form left the ZS01 idle-high when PSX.EXE's detector
                        // clocked it -- the CPU assembled 0xffffffff (docs 2026-09-14).
                        bytec <= (bytec == 8'd3) ? 8'd0 : bytec + 8'd1;
                    end else
                        bitc <= bitc + 4'd1;
                end
                // ----- SCL rising edge: command load / response read -----
                if (pscl == 1'b0 && scl != 1'b0) begin
                    if (state == ST_PROC) overrun <= 1'b1;   // host clocked before the engine finished
                    if (state == ST_CMD) begin
                        if (bitc < 4'd8) begin
                            shift <= {shift[6:0], sda_i};
                            bitc  <= bitc + 4'd1;
                        end else begin
                            sda_o <= 1'b0;
                            bitc  <= 4'd0;
                            shift <= 8'd0;
                            wbuf[bytec] <= shift;                // store byte
                            if (bytec == 8'd11) begin
                                // ===== full packet received: run the engine =====
                                state  <= ST_PROC;
                                dbg_pkts   <= dbg_pkts + 8'd1;   // observability
                                dbg_rbytes <= 8'd0;
                                pstate <= P_DEC_CMD;
                                pidx   <= 4'd11;
                                pprev  <= 8'hff;                 // decrypt() seed
                                bytec  <= 8'd0;
                            end else
                                bytec <= bytec + 8'd1;
                        end
                    end else if (state == ST_READ) begin
                        if (bitc < 4'd8) begin
                            sbyte = (bitc == 4'd0) ? rbuf[bytec] : shift;
                            sda_o <= sbyte[7];
                            shift <= sbyte << 1;
                            bitc  <= bitc + 4'd1;
                        end else begin
                            bitc  <= 4'd0;
                            sda_o <= 1'b0;
                            dbg_rbytes <= dbg_rbytes + 8'd1;         // observability
                            if (sda_i == 1'b0) begin                 // master ACK
                                if (bytec == 8'd11) begin
                                    bytec <= 8'd0; sda_o <= 1'b1; state <= ST_CMD;
                                end else
                                    bytec <= bytec + 8'd1;
                            end
                        end
                    end
                end
            end
            pscl <= scl;
            psda <= sda_i;
            prst <= sec_rst;
        end
    end
endmodule
