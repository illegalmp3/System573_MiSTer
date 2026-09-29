// -----------------------------------------------------------------------------
// s573_cass_pack.v - route the ioctl index-5 byte stream (.u6 OR .cas pack)
//
// WHY. MAME's ksys573.cpp (header Note 3; cassxzi / cassyyi machine configs) gives
// some titles TWO security cassettes for ONE physical slot: an "install" cassette
// while installing from CD, a "game" cassette afterwards. Holding both in the core
// needs the second cassette's image (EEPROM + DS2401 serial) delivered at launch,
// but MiSTer Main parses at most SIX .mgl items (mra_loader.h item[6]) and the
// launchers already use all six. So the second cassette rides in the index-5
// file, which is otherwise the 8-byte .u6 (tools/stage_573.py writes the pack):
//
//   byte  [0:7]    game cassette DS2401 serial  (== the .u6 -- unchanged)
//   byte  [8:15]   install cassette DS2401 serial (cassette:install:id)
//   byte  [16:..]  install cassette EEPROM image  (cassette:install:eeprom, as
//                  dumped: 548 B X76F041 for cassxzi, 132 B X76F100 for cassyyi)
//
// An 8-byte .u6 never reaches byte 8, so single-cassette titles behave exactly as
// before. The install chip type is inferred from the file SIZE exactly the way
// emu.sv infers the game chip from the .u1 (highest byte index written):
//   >= 16+256 (past any X76F100 image) -> X76F041, else >= 16+8 -> X76F100.
// Both are latched when the download ends, like sec_cart_type.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_cass_pack (
    input  wire        clk,
    input  wire        download,      // secser_download: the index-5 stream is active
    // the unpacked byte stream from s573_seccart_loader (AW=10)
    input  wire        byte_we,
    input  wire [9:0]  byte_addr,
    input  wire [7:0]  byte_data,
    input  wire [9:0]  max_addr,      // highest byte index seen so far
    // game cassette DS2401 serial (bytes 0..7)
    output wire        ser_we,
    output wire [2:0]  ser_addr,
    output wire [7:0]  ser_data,
    // install cassette DS2401 serial (bytes 8..15)
    output wire        iser_we,
    output wire [2:0]  iser_addr,
    output wire [7:0]  iser_data,
    // install cassette EEPROM image (bytes 16..)
    output wire        ieep_we,
    output wire [9:0]  ieep_addr,
    output wire [7:0]  ieep_data,
    // latched when the download ends
    output reg         inst_present,  // the pack carried an install cassette
    output reg         inst_type      // 0 = X76F100, 1 = X76F041
);
    localparam [9:0] SER_END  = 10'd8;    // game serial  [0:7]
    localparam [9:0] ISER_END = 10'd16;   // install serial [8:15]
    localparam [9:0] MIN_PACK = 10'd24;   // 16 + at least 8 image bytes
    localparam [9:0] F041_MIN = 10'd272;  // 16 + 256: bigger than any X76F100 image (132 B)

    assign ser_we    = byte_we & (byte_addr < SER_END);
    assign ser_addr  = byte_addr[2:0];
    assign ser_data  = byte_data;
    assign iser_we   = byte_we & (byte_addr >= SER_END) & (byte_addr < ISER_END);
    assign iser_addr = byte_addr[2:0];
    assign iser_data = byte_data;
    assign ieep_we   = byte_we & (byte_addr >= ISER_END);
    assign ieep_addr = byte_addr - ISER_END;
    assign ieep_data = byte_data;

    initial begin
        inst_present = 1'b0;
        inst_type    = 1'b0;
    end
    reg download_1 = 1'b0;
    always @(posedge clk) begin
        download_1 <= download;
        if (download_1 && !download) begin       // download just finished
            inst_present <= (max_addr >= MIN_PACK);
            inst_type    <= (max_addr >= F041_MIN);
        end
    end
endmodule
