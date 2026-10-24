// -----------------------------------------------------------------------------
// s573_cfg_trailer.v - per-title settings carried at the end of the index-5 file
//
// WHY. Some per-title settings cannot be guessed by the core and should not be
// left to the user: the control layout (DDR standard cabinet / DDR Solo /
// DrumMania / Guitar Freaks -- MAME gives each its own INPUT_PORTS) and which
// PCMCIA slot the game's card sits in (DDR: slot 2, Guitar Freaks: slot 1). An
// .mgl has no room for another item (Main parses at most six, the launchers use
// all six), so tools/s573_stage.py appends an 8-byte trailer to the file that is
// already loaded at index 5 (the .u6, or the .cas pack):
//
//     [0..3] "S573"   [4] 'C'   [5] profile   [6] card   [7] XOR of bytes 0..6
//
// The trailer is the LAST 8 bytes of the file. This module sits between the
// index-5 byte unpacker and s573_cass_pack and holds every byte back by eight
// positions, so when the download ends the last eight are still here: if they
// are a valid trailer they are swallowed (the cassette path never sees them),
// otherwise they are flushed out unchanged, one per clock, before `busy` drops.
// A file without a trailer -- every file staged before this existed -- therefore
// reaches s573_cass_pack byte-for-byte as before, and `valid` stays 0.
//
// `busy` replaces the raw download strobe for s573_cass_pack's end-of-load latch,
// and `max_addr` is the highest index actually passed on, so the pack's size
// rule (install cassette present / chip type) sees the file WITHOUT the trailer.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_cfg_trailer (
    input  wire       clk,
    input  wire       download,      // the index-5 download is active
    input  wire       in_we,         // unpacked bytes, ascending address
    input  wire [9:0] in_addr,
    input  wire [7:0] in_data,
    output reg        out_we,        // the same stream, eight bytes late
    output reg  [9:0] out_addr,
    output reg  [7:0] out_data,
    output reg  [9:0] max_addr,      // highest index passed on this load
    output wire       busy,          // download active or still flushing
    output reg        valid,         // a trailer was found on the last load
    output reg  [7:0] profile,
    output reg  [7:0] card
);
    reg [7:0] bd [0:7];              // bd[0] = oldest held byte
    reg [9:0] ba [0:7];
    reg [3:0] cnt = 4'd0;            // bytes held (0..8)
    reg       dl_1 = 1'b0, dl_2 = 1'b0;
    reg       flushing = 1'b0;
    integer i;

    // s573_seccart_loader registers its byte strobe, so the last byte can arrive
    // one clock after the download flag drops: accept bytes through dl_1 and look
    // at the held bytes one clock later.
    wire accept = download | dl_1;
    wire ended  = dl_2 & ~dl_1 & ~download;
    assign busy = download | dl_1 | dl_2 | flushing;

    wire [7:0] chk = bd[0] ^ bd[1] ^ bd[2] ^ bd[3] ^ bd[4] ^ bd[5] ^ bd[6];
    wire is_trailer = (cnt == 4'd8) && bd[0] == "S" && bd[1] == "5" && bd[2] == "7"
                      && bd[3] == "3" && bd[4] == "C" && bd[7] == chk;

    initial begin
        out_we = 1'b0; out_addr = 10'd0; out_data = 8'd0; max_addr = 10'd0;
        valid = 1'b0; profile = 8'd0; card = 8'd0;
    end

    always @(posedge clk) begin
        dl_1   <= download;
        dl_2   <= dl_1;
        out_we <= 1'b0;
        if (download && !dl_1) begin                 // a new load starts
            cnt <= 4'd0; valid <= 1'b0; max_addr <= 10'd0; flushing <= 1'b0;
        end else if (accept) begin
            if (in_we) begin
                if (cnt == 4'd8) begin               // pass the oldest on
                    out_we <= 1'b1; out_addr <= ba[0]; out_data <= bd[0];
                    if (ba[0] > max_addr) max_addr <= ba[0];
                    for (i = 0; i < 7; i = i + 1) begin bd[i] <= bd[i+1]; ba[i] <= ba[i+1]; end
                    bd[7] <= in_data; ba[7] <= in_addr;
                end else begin
                    bd[cnt[2:0]] <= in_data; ba[cnt[2:0]] <= in_addr;
                    cnt <= cnt + 4'd1;
                end
            end
        end else if (ended) begin                    // the load is over
            if (is_trailer) begin
                valid <= 1'b1; profile <= bd[5]; card <= bd[6];
                cnt <= 4'd0;
            end else begin
                flushing <= (cnt != 4'd0);
            end
        end else if (flushing) begin                 // not a trailer: hand them on
            out_we <= 1'b1; out_addr <= ba[0]; out_data <= bd[0];
            if (ba[0] > max_addr) max_addr <= ba[0];
            for (i = 0; i < 7; i = i + 1) begin bd[i] <= bd[i+1]; ba[i] <= ba[i+1]; end
            cnt <= cnt - 4'd1;
            if (cnt == 4'd1) flushing <= 1'b0;
        end
    end
endmodule
