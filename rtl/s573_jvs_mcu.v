// -----------------------------------------------------------------------------
// s573_jvs_mcu.v - the 573's JVS host MCU (H8/3644), modelled at its 573-side
//                  interface; the JVS bus side is handed to the HPS.
//
// Sources (docs/2026-10-23-memory-card-reader.md):
//  * psx-spx "Konami System 573" builtin-io.md:
//      0x1f400004 [5:4] MCU status: 0 = waiting for the 573 to read or write the
//        first word of a packet, 1 = busy (sending / waiting for a response),
//        2 = waiting for the 573 to finish reading or writing a packet;
//        [7:6] error: 1 = bad checksum, 2 = no 0xe0 sync, 3 = no error. After an
//        error the MCU "enters an endless loop and becomes unresponsive" until reset.
//      0x1f400006 [3] JVS sense, [4] JVSIRDY, [5] JVSDRDY.
//      0x1f680000 w  data word to the MCU, sets JVSDRDY; only written when it is 0.
//      0x1f40000a r  data word from the MCU, valid while JVSIRDY; 0x1f520000 w
//        clears JVSIRDY, after which the MCU loads the next word.
//      0x1f400000 bit 8 = MCU /RESET; "Resetting the MCU will clear JVSDRDY but
//        not JVSIRDY".
//      Transaction: write the packet as little-endian words (odd tail upper byte
//      zero); status -> 1 while it is sent and a response awaited (forever if none
//      comes -- including after a broadcast reset, which nothing answers); status
//      -> 0 when a response can be read; 2 after its first word is read; 0 when
//      no more data. The MCU validates sync + checksum and uses the length field.
//      It escapes/unescapes 0xd0/0xe0 on the wire, so both sides here are raw.
//  * ddr4m game exe (S5): reset 0x800ac5fc (bit 8 low 2 frames, high, poll
//      [7:4] == 0xC, drain JVSIRDY with 0xffff writes to 0x1f520000), send
//      0x800ac924 (require status 0; per word: delay, write, poll JVSDRDY low up
//      to 48 reads), receive 0x800aca6c (JVSIRDY clear: error bits 3 -> "busy",
//      0 -> -2, else -4; first word must be 0x00e0; then len from byte 2).
//
// HPS side: a validated request sits in req[] with req_ready; the HPS reads it
// (req_raddr -> req_rdata one clock later, words) and answers by writing resp[]
// then pulsing resp_commit with the byte count and the request's sequence number.
// A commit for any other sequence number (a request the 573 has since abandoned by
// resetting the MCU) is ignored. No answer = busy forever, exactly as with an
// empty bus.
//
// Both buffers are simple dual-port RAMs with registered reads (M10K, not LABs:
// the design is at ~99 % LABs).
//
// Verilog-2005. Released under the GNU GPL v2.
// -----------------------------------------------------------------------------
module s573_jvs_mcu #(
    parameter integer CONSUME_CLKS = 64   // MCU takes a written word / loads the next
                                          // read word (~2 us); ddr4m polls <= 48 reads
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        mcu_rst_n,          // 0x1f400000 bit 8

    // 573 side
    input  wire        wr_data,            // write strobe 0x1f680000
    input  wire [15:0] wdata,
    input  wire        clr_irdy,           // write strobe 0x1f520000
    output wire [15:0] rdata,              // 0x1f40000a
    output reg         irdy,
    output reg         drdy,
    output reg  [1:0]  status,
    output reg  [1:0]  err,

    // HPS side (JVS bus)
    output reg         req_ready,
    output reg  [8:0]  req_len,            // bytes incl. sync and checksum
    output reg  [7:0]  req_seq,
    input  wire [7:0]  req_raddr,          // word index
    output reg  [15:0] req_rdata,          // registered: valid the clock after req_raddr
    input  wire        resp_we,
    input  wire [7:0]  resp_waddr,
    input  wire [15:0] resp_wdata,
    input  wire        resp_commit,
    input  wire [8:0]  resp_len,           // bytes incl. sync and checksum
    input  wire [7:0]  resp_seq
);
    // ---- the two buffers (registered-read RAMs) ----
    reg [15:0] req  [0:131];
    reg [15:0] resp [0:131];
    reg        req_we;  reg [7:0] req_wa;  reg [15:0] req_wd;
    reg [7:0]  resp_ra; reg [15:0] resp_q;
    always @(posedge clk) begin
        if (req_we) req[req_wa] <= req_wd;
        req_rdata <= req[req_raddr];
    end
    always @(posedge clk) begin
        if (resp_we) resp[resp_waddr] <= resp_wdata;
        resp_q <= resp[resp_ra];
    end
    assign rdata = resp_q;                 // resp_ra is held while JVSIRDY is up

    localparam [2:0] S_IDLE = 3'd0,   // status 0, waiting for a first word (or a response)
                     S_WR   = 3'd1,   // status 2, collecting the packet
                     S_BUSY = 3'd2,   // status 1, request out, waiting for the bus
                     S_RD   = 3'd3,   // status 0/2, response being read
                     S_DEAD = 3'd4;   // error: unresponsive until reset
    reg [2:0]  st;
    reg [7:0]  widx;                  // words written / read so far
    reg [8:0]  total;                 // bytes expected / available
    reg [7:0]  csum;
    reg [12:0] dly;                   // consume / reload delay
    reg        pend_w;                // a written word waits to be consumed
    reg [15:0] wbuf;
    reg        pend_r;                // next read word being loaded

    wire [7:0] lo = wbuf[7:0], hi = wbuf[15:8];

    always @(posedge clk) begin
        req_we <= 1'b0;
        if (rst || !mcu_rst_n) begin
            st <= S_IDLE; status <= 2'd0; err <= 2'd3;
            drdy <= 1'b0; pend_w <= 1'b0; pend_r <= 1'b0;
            widx <= 8'd0; total <= 9'd0; csum <= 8'd0; dly <= 13'd0;
            req_ready <= 1'b0;
            if (rst) begin irdy <= 1'b0; resp_ra <= 8'd0; req_seq <= 8'd0; req_len <= 9'd0; end
            // MCU reset leaves JVSIRDY as it is (psx-spx)
        end else begin
            if (clr_irdy) irdy <= 1'b0;

            // ---- 573 writes a word ----
            if (wr_data && !pend_w) begin
                wbuf <= wdata; pend_w <= 1'b1; drdy <= 1'b1; dly <= CONSUME_CLKS[12:0];
            end

            case (st)
            S_IDLE, S_WR: if (pend_w) begin
                if (dly != 13'd0) dly <= dly - 13'd1;
                else begin
                    pend_w <= 1'b0; drdy <= 1'b0;
                    req_we <= 1'b1; req_wa <= widx; req_wd <= wbuf;
                    if (widx == 8'd0) begin
                        if (lo != 8'he0) begin st <= S_DEAD; err <= 2'd2; end
                        else begin
                            csum <= hi; st <= S_WR; status <= 2'd2; widx <= 8'd1;
                        end
                    end else begin
                        // byte 2 (= word 1 low) is the length: payload + checksum
                        if (widx == 8'd1) total <= {1'b0, lo} + 9'd3;
                        begin : acc
                            reg [8:0] t, b0, b1; reg [7:0] c;
                            t  = (widx == 8'd1) ? ({1'b0, lo} + 9'd3) : total;
                            b0 = {widx, 1'b0}; b1 = b0 + 9'd1;      // byte indices of lo / hi
                            c  = csum;
                            if (b0 < t - 9'd1) c = c + lo;
                            if (b1 < t - 9'd1) c = c + hi;
                            csum <= c;
                            if (b1 >= t - 9'd1) begin               // the checksum byte arrived
                                if (((b0 == t - 9'd1) ? lo : hi) != c) begin
                                    st <= S_DEAD; err <= 2'd1;
                                end else begin
                                    st <= S_BUSY; status <= 2'd1;
                                    req_len <= t; req_seq <= req_seq + 8'd1; req_ready <= 1'b1;
                                end
                            end
                        end
                        widx <= widx + 8'd1;
                    end
                end
            end
            S_BUSY: if (resp_commit && resp_seq == req_seq) begin
                req_ready <= 1'b0;
                st <= S_RD; status <= 2'd0; widx <= 8'd1;
                total <= resp_len;
                resp_ra <= 8'd0; pend_r <= 1'b1; dly <= 13'd2;   // resp_q valid in 2 clocks
            end
            S_RD: begin
                if (!irdy && !pend_r && !clr_irdy) begin
                    if ({widx, 1'b0} >= total) begin       // everything read
                        st <= S_IDLE; status <= 2'd0; widx <= 8'd0;
                    end else begin
                        pend_r <= 1'b1; dly <= CONSUME_CLKS[12:0]; status <= 2'd2;
                        resp_ra <= widx; widx <= widx + 8'd1;
                    end
                end
                if (pend_r) begin
                    if (dly != 13'd0) dly <= dly - 13'd1;
                    else begin pend_r <= 1'b0; irdy <= 1'b1; end
                end
            end
            default: ;   // S_DEAD: a written word is never taken (JVSDRDY stays up)
            endcase
        end
    end
endmodule
