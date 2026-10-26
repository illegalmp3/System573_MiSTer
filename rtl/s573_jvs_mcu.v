// -----------------------------------------------------------------------------
// s573_jvs_mcu.v - the System 573's JVS host MCU (H8/3644 at 18E), 573 side
//
// psx-spx "Konami System 573" (docs/konamisystem573.md) is the source for every
// behaviour here: registers 0x1f400004 bits 4-5 (status code) and 6-7 (error
// code), 0x1f400006 bits 3 (sense), 4 (JVSIRDY), 5 (JVSDRDY), 0x1f40000a (data
// from the MCU), 0x1f520000 (JVSIRDY clear), 0x1f680000 (data to the MCU),
// 0x1f400000 bit 8 (MCU reset, active low), and "MCU communication protocol":
//   * reset: status 0, error 3; JVSDRDY cleared, JVSIRDY NOT cleared
//   * the 573 writes the packet two bytes per word, little endian; the first
//     byte must be the 0xE0 sync, else error 2; status 2 while the packet is
//     written; the length byte says where it ends; a bad checksum is error 1;
//     a complete packet is status 1 while the MCU sends it and waits --
//     indefinitely -- for a response
//   * a valid response: status 0 with its first word in the data register and
//     JVSIRDY set; each JVSIRDY clear brings the next word; status 2 after the
//     first word is read, 0 once no more data is left
//   * after an error the MCU is unresponsive until it is reset
//   * byte escaping (D0 xx) happens on the wire; the 573 sees plain bytes
// The BIOS self-test sequence psx-spx lists -- which is exactly the expected
// {error,status} nibbles MAME keeps in h8b01.bin: 0C 0E 0A 0D x16 05 x16 --
// is what sim/tb_s573_jvs_mcu.v replays.
//
// The RS-485 side is the HPS: the White I/O reader is emulated in
// MiSTer_System573 (support/s573/wio*.c).  A complete, valid request steps
// req_seq and its bytes become readable; the HPS writes the board's response
// back and commits it with the req_seq it answers, so a response to a packet
// the 573 has since abandoned (MCU reset, newer packet) is dropped.
//
// en = 0 (OSD "573 Card Reader" Off): the bits read exactly as before this
// module existed -- nibble 0xC, JVSIRDY = JVSDRDY = 0, sense = 1, data 0 --
// so every title that ran without a reader is unchanged.
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_jvs_mcu (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,            // a reader is on the JVS bus

    // ---- 573 side ----
    input  wire        mcu_rst_n,     // 0x1f400000 bit 8
    input  wire        wr_data,       // write strobe, 0x1f680000
    input  wire [15:0] wdata,
    input  wire        clr_irdy,      // write strobe, 0x1f520000
    output wire [1:0]  status,        // -> 0x1f400004 [5:4]
    output wire [1:0]  error,         // -> 0x1f400004 [7:6]
    output wire        irdy,          // -> 0x1f400006 [4]
    output wire        drdy,          // -> 0x1f400006 [5]
    output wire        sense,         // -> 0x1f400006 [3]
    output wire [15:0] rdata,         // -> 0x1f40000a

    // ---- HPS side (CMD_573_WIO) ----
    output reg  [7:0]  req_seq,       // steps once per complete, valid request
    output reg  [8:0]  req_len,       // bytes in it (sync .. checksum)
    input  wire [7:0]  req_raddr,     // word address: bytes 2a (low) and 2a+1 (high)
    output reg  [15:0] req_rword,     // one clock later
    input  wire        resp_we,
    input  wire [7:0]  resp_waddr,    // word address, same packing
    input  wire [15:0] resp_wword,
    input  wire        resp_commit,   // resp_len bytes are in place
    input  wire [8:0]  resp_len,
    input  wire [7:0]  resp_seq,      // the req_seq it answers
    input  wire        sense_in,      // the board's sense output (PIO1 bit 29)
    output wire        waiting        // status 1: a request is out on the bus
);
    // both buffers hold the packet two bytes per word, as the 573 writes and
    // reads it (byte 2a in [7:0], 2a+1 in [15:8]); 129 words cover 258 bytes
    reg [15:0] reqbuf  [0:255];
    reg [15:0] respbuf [0:255];

    localparam S_IDLE = 3'd0,   // waiting for the first word of a packet
               S_RECV = 3'd1,   // packet partly written
               S_BUSY = 3'd2,   // sent, waiting for the response
               S_READ = 3'd3,   // response being read by the 573
               S_HALT = 3'd4;   // error: hung until reset

    reg  [2:0]  st;
    reg  [1:0]  stat, err;
    reg         irdy_r;
    reg  [15:0] rword;
    reg  [8:0]  wcnt;           // request bytes held
    reg  [8:0]  tot;            // request length incl. sync and checksum
    reg  [7:0]  csum;
    reg  [8:0]  rlen;           // response bytes
    reg  [7:0]  rptr;           // next response word
    reg         fetch;          // loading rword from respbuf
    reg         fph;

    wire [7:0] b0 = wdata[7:0];
    wire [7:0] b1 = wdata[15:8];

    reg  [15:0] resp_q;
    always @(posedge clk) resp_q <= respbuf[rptr];
    always @(posedge clk) if (resp_we) respbuf[resp_waddr] <= resp_wword;
    always @(posedge clk) req_rword <= reqbuf[req_raddr];
    // request words are written on the 573's strobe (wcnt is always even)
    always @(posedge clk) if (wr_data && (st == S_RECV || ((st == S_IDLE || st == S_READ) && b0 == 8'he0)))
        reqbuf[(st == S_RECV) ? wcnt[8:1] : 8'd0] <= wdata;

    // packet length and checksum bookkeeping for the word being written
    wire [8:0] tot_now = (wcnt == 9'd2) ? ({1'b0, b0} + 9'd3) : tot;
    wire       in0     = (wcnt          < tot_now - 9'd1);   // b0 is summed
    wire       in1     = (wcnt + 9'd1   < tot_now - 9'd1);   // b1 is summed
    wire [7:0] csum_n  = csum + (in0 ? b0 : 8'd0) + (in1 ? b1 : 8'd0);
    wire       done_w  = (wcnt + 9'd2 >= tot_now);
    wire [7:0] ckbyte  = (wcnt == tot_now - 9'd1) ? b0 : b1;

    always @(posedge clk) begin
        if (rst || !mcu_rst_n) begin
            // reset (and held in reset): status 0 / error 3 -- the 700A01 shell
            // reads 0xC throughout (MAME h8a01.bin); JVSIRDY is kept (psx-spx)
            st <= S_IDLE; stat <= 2'd0; err <= 2'd3;
            rword <= 16'h0000;
            wcnt <= 9'd0; tot <= 9'd0; csum <= 8'd0;
            fetch <= 1'b0; fph <= 1'b0;
            if (rst) begin irdy_r <= 1'b0; req_seq <= 8'd0; req_len <= 9'd0; end
        end else begin
            if (wr_data) begin
                case (st)
                S_IDLE, S_READ: begin
                    if (b0 != 8'he0) begin
                        st <= S_HALT; stat <= 2'd2; err <= 2'd2;
                    end else begin
                        csum <= b1;              // the address is summed
                        wcnt <= 9'd2;
                        tot  <= 9'd511;
                        st <= S_RECV; stat <= 2'd2; err <= 2'd3;
                        fetch <= 1'b0;
                    end
                end
                S_RECV: begin
                    tot  <= tot_now;
                    csum <= csum_n;
                    wcnt <= wcnt + 9'd2;
                    if (done_w) begin
                        if (ckbyte == csum_n) begin
                            st <= S_BUSY; stat <= 2'd1;
                            req_len <= tot_now;
                            req_seq <= req_seq + 8'd1;
                        end else begin
                            st <= S_HALT; stat <= 2'd1; err <= 2'd1;
                        end
                    end
                end
                default: ;                       // BUSY / HALT: ignored
                endcase
            end

            if (resp_commit && st == S_BUSY && resp_seq == req_seq && resp_len >= 9'd2) begin
                rlen <= resp_len;
                rptr <= 8'd0;
                fetch <= 1'b1; fph <= 1'b0;
            end

            // fph 0: respbuf[rptr] is being read; 1: it is in resp_q
            if (fetch) begin
                fph <= 1'b1;
                if (fph) begin
                    rword  <= {({rptr, 1'b1} < rlen) ? resp_q[15:8] : 8'h00, resp_q[7:0]};
                    irdy_r <= 1'b1;
                    rptr   <= rptr + 8'd1;
                    fetch  <= 1'b0; fph <= 1'b0;
                    if (st == S_BUSY) begin st <= S_READ; stat <= 2'd0; end
                end
            end

            if (clr_irdy) begin
                irdy_r <= 1'b0;
                if (st == S_READ && !fetch) begin
                    if ({rptr, 1'b0} < rlen) begin
                        stat <= 2'd2;
                        fetch <= 1'b1; fph <= 1'b0;
                    end else begin
                        stat <= 2'd0;
                        st <= S_IDLE;
                    end
                end
            end
        end
    end

    assign waiting = (st == S_BUSY);
    // JVSDRDY: the MCU takes each word on the clock it is written
    assign status  = en ? stat   : 2'd0;
    assign error   = en ? err    : 2'd3;
    assign irdy    = en ? irdy_r : 1'b0;
    assign drdy    = 1'b0;
    assign rdata   = en ? rword  : 16'h0000;
    assign sense   = en ? sense_in : 1'b1;
endmodule
