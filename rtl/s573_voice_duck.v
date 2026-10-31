// -----------------------------------------------------------------------------
// s573_voice_duck.v - which SPU voices the "573 Announcer/Crowd" option turns down
//
// An OSD convenience, not a hardware model (Normal = the core exactly as before).
// Sources: MAME 0.264 reference runs of ddrextrm, ddr5m and ddrmax2 with every SPU
// key-on and Digital I/O MP3 command logged (local/mame/study.lua), and the core's
// own MP3 logs from ddrextrm / ddr3ma / ddr3mj sessions on the SuperStation One.
// docs/2026-10-30-music-level-and-announcer.md has the tables. What they show:
//
//  * A stage song is the only MP3 the games place at Digital I/O RAM address 0
//    that is long: songs 1.09-1.92 MB (start 0); menu BGM, previews and jingles
//    are elsewhere or short (3rd Mix puts its ~288 KB previews at 0 too; ddr5m's
//    longest menu file is 706 KB). So: start == 0 and length >= 0xC0000 bytes.
//  * The SPU sounds in a song are announcer + crowd only (plus a coin chime if a
//    coin goes in). The "READY / HERE WE GO" set is keyed within 0.2-2.8 s of the
//    song's play command in all three titles; the next sound comes 14+ s later.
//  * The end-of-song set (the crowd at FINISH / the wipe to the results) is keyed
//    3.4-5.6 s before the MP3 runs out (the games let the file play to its end:
//    measured byte rates 14032 / 16035 / 20035 B/s = 112/128/160 kbps CBR exactly).
//    Mid-song sounds came no later than 10.0 s before the end.
//
// So, per voice, at key-on: duck it if it is keyed more than KEEP_S seconds after
// a song's play command and while more than TAIL_S seconds of the song remain.
// Remaining time = (mp3_end - cur_pos) / byte rate, with the byte rate measured as
// the streamer's advance over the last second (the streamer is credit-paced to the
// HPS decoder, so its average rate is the MP3 bit rate; it leads the speakers by
// the PCM ring, ~1.5 s, which only adds margin to TAIL_S). Voices keyed outside
// the window are left alone, and a voice keeps its decision until it is keyed again,
// so a "HERE WE GO" still sounding when the window opens plays out at full level.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_voice_duck #(
    parameter integer CLK_HZ  = 33868800,     // clk_1x
    parameter integer KEEP_S  = 4,
    parameter integer TAIL_S  = 8,            // must be a power of two (shift)
    parameter [31:0]  MIN_LEN = 32'h000C0000
) (
    input  wire        clk,
    input  wire        rst,
    // SPU register writes (psx_patches 0035 snoop; addr = offset from 0x1f801c00)
    input  wire        spu_we,
    input  wire [9:0]  spu_addr,
    input  wire [15:0] spu_din,
    // Digital I/O MP3 state (k573dio)
    input  wire [15:0] fpga_ctrl,
    input  wire [31:0] mp3_start,
    input  wire [31:0] mp3_end,
    input  wire [24:0] cur_pos,
    output reg  [23:0] duck,                  // to spu.vhd s573_duck
    output wire        in_song,               // observability
    output wire        window                 // observability: new keys are ducked
);
    localparam [1:0] S_IDLE = 2'd0, S_KEEP = 2'd1, S_DUCK = 2'd2;
    localparam integer TAIL_SH = (TAIL_S == 16) ? 4 : (TAIL_S == 8) ? 3 : (TAIL_S == 4) ? 2 : 1;

    reg  [1:0]  st;
    reg  [3:0]  secs;                         // seconds since play (saturates)
    reg  [25:0] tick;                         // 1 s divider
    reg  [24:0] pos_prev, rate;               // bytes per second
    reg         en_q;

    wire stream_en = fpga_ctrl[14] & fpga_ctrl[13];
    wire play      = stream_en & ~en_q;
    wire [31:0] len = mp3_end - mp3_start;
    wire is_song   = (mp3_start == 32'd0) && (len >= MIN_LEN);
    wire streaming = stream_en && ({7'd0, cur_pos} < mp3_end);
    wire [24:0] remain = mp3_end[24:0] - cur_pos;
    wire [28:0] tail_bytes = {4'd0, rate} << TAIL_SH;
    wire near_end  = (rate != 25'd0) && ({4'd0, remain} < tail_bytes);
    wire sec_tick  = (tick == CLK_HZ - 1);

    assign in_song = (st != S_IDLE);
    assign window  = (st == S_DUCK) && !near_end;

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; secs <= 4'd0; tick <= 26'd0; pos_prev <= 25'd0; rate <= 25'd0;
            en_q <= 1'b0; duck <= 24'd0;
        end else begin
            en_q <= stream_en;
            tick <= sec_tick ? 26'd0 : tick + 26'd1;
            if (sec_tick) begin
                rate     <= cur_pos - pos_prev;
                pos_prev <= cur_pos;
                if (secs != 4'hF) secs <= secs + 4'd1;
            end

            if (play) begin
                st <= is_song ? S_KEEP : S_IDLE;
                secs <= 4'd0; tick <= 26'd0; pos_prev <= cur_pos; rate <= 25'd0;
            end else case (st)
                S_KEEP: if (!streaming && secs != 4'd0) st <= S_IDLE;
                        else if (secs >= KEEP_S) st <= S_DUCK;
                S_DUCK: if (!streaming) st <= S_IDLE;
                default: ;
            endcase

            // key-on: each voice takes the decision of the moment it is keyed
            if (spu_we && spu_addr == 10'h188)
                duck[15:0]  <= (duck[15:0]  & ~spu_din)      | (spu_din      & {16{window}});
            if (spu_we && spu_addr == 10'h18A)
                duck[23:16] <= (duck[23:16] & ~spu_din[7:0]) | (spu_din[7:0] & {8{window}});
        end
    end
endmodule
