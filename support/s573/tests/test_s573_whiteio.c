/* -----------------------------------------------------------------------------
 * test_s573_whiteio.c - host tests for the White I/O HLE (s573_whiteio.c).
 *
 * Expected values come from the disassembled boot ROM / ddr4m firmware (addresses
 * in docs/2026-10-23-memory-card-reader.md) and psx-spx's memory card tables --
 * not from running the code under test. With WIO_DDR4M_EXE=<ddr4m game exe> the
 * real upload container is replayed exactly as the game sends it.
 *
 * Released under the GNU GPL v2.
 * ---------------------------------------------------------------------------- */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../s573_whiteio.h"

static int fails = 0, groups = 0;
#define GROUP(n) do { groups++; printf("-- W%-2d %s\n", groups, n); } while (0)
#define CHECK(c, m) do { if (!(c)) { printf("   FAIL: %s  (%s:%d)\n", m, __FILE__, __LINE__); fails++; } } while (0)
#define CHECKEQ(g, w_, m) do { unsigned long g_=(unsigned long)(g), w__=(unsigned long)(w_); \
    if (g_ != w__) { printf("   FAIL: %s  got 0x%lx want 0x%lx  (%s:%d)\n", m, g_, w__, __FILE__, __LINE__); fails++; } } while (0)

/* ---- virtual card io on two vcards ---- */
static wio_vcard_t vc[2];
static int nsel = 0;
static void v_select(void *ctx, int port, int on) { (void)ctx; if (on) { wio_vcard_select(&vc[port]); nsel++; } }
static int v_xfer(void *ctx, int port, uint8_t tx, int ack_mode, uint8_t *rx)
{
    (void)ctx;
    int ack = wio_vcard_byte(&vc[port], tx, rx);
    if (!vc[port].inserted) *rx = 0xff;
    return ack_mode == 0 ? 1 : ack;
}
static const wio_card_io_t vio = { v_select, v_xfer, NULL };

static wio_t W;
static uint8_t rsp[300];
static int rlen;

/* send E0 dst len payload sum; returns response length */
static int tx(uint8_t dst, const uint8_t *pl, int n)
{
    uint8_t p[300];
    p[0] = 0xe0; p[1] = dst; p[2] = (uint8_t)(n + 1);
    uint8_t s = (uint8_t)(dst + n + 1);
    for (int k = 0; k < n; k++) { p[3 + k] = pl[k]; s = (uint8_t)(s + pl[k]); }
    p[3 + n] = s;
    rlen = wio_packet(&W, p, n + 4, rsp);
    return rlen;
}
#define TX(dst, ...) do { const uint8_t pl_[] = { __VA_ARGS__ }; tx(dst, pl_, (int)sizeof(pl_)); } while (0)

static int resp_ok(void)
{
    if (rlen < 4 || rsp[0] != 0xe0 || rsp[1] != 0x00 || rsp[2] != rlen - 3) return 0;
    uint8_t s = 0;
    for (int k = 1; k < rlen - 1; k++) s = (uint8_t)(s + rsp[k]);
    return s == rsp[rlen - 1];
}
#define BODY(k) rsp[3 + (k)]
#define BLEN (rlen - 4)

static uint64_t T = 1000;
static void run(uint64_t us) { uint64_t end = T + us; while (T < end) { T += 100; wio_tick(&W, T, 1); } }
static uint16_t status(void) { TX(1, 0x71); return (uint16_t)(BODY(2) << 8 | BODY(3)); }

static void boot_to_fw_synthetic(void)
{
    wio_init(&W, &vio);
    TX(0xff, 0xf1, 0x01);
    /* fake a program: any exec address -> firmware mode (fw_ok stays 0) */
    TX(1, 0x70, 0x02, 0x01, 0xc0, 0x00);
}

static uint8_t *load(const char *path, long *n)
{
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)*n);
    if (fread(b, 1, (size_t)*n, f) != (size_t)*n) { free(b); fclose(f); return NULL; }
    fclose(f); return b;
}

int main(void)
{
    memset(vc, 0, sizeof(vc));
    for (int k = 0; k < WIO_CARD_SIZE; k++) vc[0].data[k] = (uint8_t)(k * 7 + (k >> 7));
    wio_vcard_insert(&vc[0], 1);

    GROUP("boot ROM: identity, address assignment, sense, reset");
    wio_init(&W, &vio);
    CHECK(wio_sense(&W) == 1, "unaddressed after power-on");
    TX(0xff, 0x10); CHECK(resp_ok() && BODY(1) == 1, "0x10 broadcast answered (the ISR accepts dst 0xff)");
    TX(0xff, 0xf1, 0x05); CHECK(resp_ok() && BLEN == 2 && BODY(0) == 1 && BODY(1) == 1, "F1 -> 01 01");
    CHECKEQ(W.addr, 5, "address 5");
    CHECK(wio_sense(&W) == 0, "addressed: sense low");
    TX(0xff, 0xf1, 0x06); CHECKEQ(rlen, 0, "second F1 unanswered (address already set)");
    TX(5, 0x10); CHECK(resp_ok() && BODY(1) == 1 && !memcmp(&BODY(2), "KONAMI CO.,LTD.;White I/O;Ver1.0;White I/O PCB", 47) && BLEN == 49, "ID string + NUL");
    TX(5, 0x11, 0x12, 0x13, 0x14);
    CHECK(resp_ok() && BLEN == 9 && BODY(1)==1 && BODY(2)==0x11 && BODY(3)==1 && BODY(4)==0x20 &&
          BODY(5)==1 && BODY(6)==0x10 && BODY(7)==1 && BODY(8)==0x00, "11/12/13/14 -> 11 20 10 00");
    TX(6, 0x10); CHECKEQ(rlen, 0, "other address ignored");
    TX(0xff, 0xf0, 0xd9); CHECKEQ(rlen, 0, "F0 D9 unanswered");
    CHECK(wio_sense(&W) == 1 && W.addr == 0xff, "F0 D9 releases the address");

    GROUP("boot ROM: 70 00/01 RAM access limits, 70 02 only alone");
    wio_init(&W, &vio); TX(0xff, 0xf1, 1);
    TX(1, 0x70, 0x01, 0x07, 0xff, 0xfe, 0x02, 0xaa, 0xbb); CHECK(resp_ok() && BODY(1) == 1, "write at top-2");
    TX(1, 0x70, 0x00, 0x07, 0xff, 0xfe, 0x02); CHECK(BLEN == 4 && BODY(1) == 1 && BODY(2) == 0xaa && BODY(3) == 0xbb, "read back");
    TX(1, 0x70, 0x00, 0x07, 0xff, 0xff, 0x02); CHECK(BLEN == 2 && BODY(1) == 2, "a+n > 0x80000 -> 2");
    TX(1, 0x70, 0x00, 0x00, 0x00, 0x00, 0x81); CHECK(BODY(1) == 2, "n = 0x81 -> 2");
    TX(1, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00); CHECK(BODY(1) == 2, "n = 0 -> 2");
    TX(1, 0x70, 0x02, 0x01, 0xc0, 0x00, 0x11); CHECK(BODY(1) == 2 && W.mode == WIO_BOOT, "70 02 with another command -> 2, no exec");
    TX(1, 0x70, 0x02, 0x01, 0xc0, 0x02); CHECK(BODY(1) == 2 && W.mode == WIO_BOOT, "unaligned -> 2");
    TX(1, 0x70, 0x02, 0x01, 0xc0, 0x00); CHECK(resp_ok() && BLEN == 2 && BODY(1) == 1, "70 02 alone -> 01 01");
    CHECK(W.mode == WIO_FW && W.fw_ok == 0 && W.addr == 1, "firmware mode, unknown program, address carried");
    CHECKEQ(status(), 0x0001, "firmware status starts 0x0001");

    const char *exe = getenv("WIO_DDR4M_EXE");
    if (exe && *exe) {
        GROUP("ddr4m: replay the real upload container (records 1c000/20000/18000)");
        long n; uint8_t *b = load(exe, &n);
        CHECK(b != NULL, "read WIO_DDR4M_EXE");
        static const uint8_t sig[8] = { 0, 1, 0xc0, 0, 0, 0, 0, 0xb0 };
        long o = -1;
        for (long k = 0; b && k + 8 < n; k++) if (!memcmp(b + k, sig, 8)) { o = k; break; }
        CHECK(o >= 0, "container found");
        wio_init(&W, &vio); TX(0xff, 0xf1, 1);
        uint32_t first = 0; int recs = 0, bad = 0;
        while (o >= 0) {
            uint32_t a = (uint32_t)b[o] << 24 | b[o+1] << 16 | b[o+2] << 8 | b[o+3];
            uint32_t len = (uint32_t)b[o+4] << 24 | b[o+5] << 16 | b[o+6] << 8 | b[o+7];
            if (!len) break;
            if (!recs) first = a;
            recs++;
            for (uint32_t k = 0; k < len; k += 0x80) {     /* 0x800b2714: 70 01 chunks */
                uint32_t c = len - k < 0x80 ? len - k : 0x80;
                uint8_t pl[0x90]; pl[0] = 0x70; pl[1] = 0x01;
                pl[2] = (uint8_t)((a + k) >> 16); pl[3] = (uint8_t)((a + k) >> 8); pl[4] = (uint8_t)(a + k); pl[5] = (uint8_t)c;
                memcpy(pl + 6, b + o + 8 + k, c);
                tx(1, pl, (int)c + 6);
                if (!(resp_ok() && BODY(1) == 1)) bad++;
            }
            o += 8 + (long)len;
        }
        CHECKEQ(recs, 3, "three records"); CHECKEQ(bad, 0, "every chunk acknowledged"); CHECKEQ(first, 0x1c000, "exec = first record");
        TX(1, 0x70, 0x02, (uint8_t)(first >> 16), (uint8_t)(first >> 8), (uint8_t)first);
        CHECK(BODY(1) == 1 && W.mode == WIO_FW, "exec");
        CHECK(W.fw_ok == 1, "unpacked program is the modelled ddr4m firmware (CRC 08844237)");
        free(b);
    } else printf("   (WIO_DDR4M_EXE not set: real-container replay skipped)\n");

    GROUP("firmware: 0x73 FPGA configure gates the card commands");
    boot_to_fw_synthetic(); W.now_us = T;
    TX(1, 0x74, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01);
    CHECK(BODY(1) == 4, "74 before 73: 4 (status bit 0)");
    TX(1, 0x73); CHECK(BODY(1) == 1, "73 -> 1");
    CHECKEQ(status(), 0x0101, "configuring");
    TX(1, 0x73); CHECK(BODY(1) == 4, "73 while busy -> 4");
    run(25000);
    CHECKEQ(status(), 0x0000, "configured");
    TX(1, 0x73); CHECK(BODY(1) == 4, "73 when configured -> 4 ((status & 0x101) != 1)");

    GROUP("card read: fresh card FLAG 08h -> status 0, data in RAM; timing");
    TX(1, 0x76, 0x74, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02);  /* MAME-logged form: 76 then 74 */
    CHECK(resp_ok() && BLEN == 3 && BODY(1) == 1 && BODY(2) == 1, "76 74 -> 01 01 01 (two reports)");
    CHECKEQ(status(), 0x0200, "reading");
    run(5000); CHECKEQ(status() & 0x0200, 0x0200, "still reading after 5 ms (2 frames ~ 21 ms virtual)");
    run(30000); CHECKEQ(status(), 0x0000, "done: FLAG was 08h -> result 0");
    CHECK(!memcmp(W.ram + 0x20000, vc[0].data, 256), "two frames copied");

    GROUP("card write: FLAG bit3 cleared; next read reports 0x8000; frame-0 re-read");
    for (int k = 0; k < 128; k++) W.ram[0x30000 + k] = (uint8_t)(0xa5 ^ k);
    int sel0 = nsel;
    TX(1, 0x75, 0x03, 0x00, 0x00, 0x00, 0x3f, 0x00, 0x01);
    CHECK(BODY(1) == 1, "75 -> 1"); CHECKEQ(status(), 0x0400, "writing");
    run(60000);
    CHECKEQ(status(), 0x0000, "write done; first frame FLAG was 08h -> 0");
    CHECKEQ(nsel - sel0, 2, "one write transaction + the closing frame-0 read");
    CHECK(!memcmp(vc[0].data + 0x3f * 128, W.ram + 0x30000, 128), "frame 0x3f on the card");
    CHECKEQ(vc[0].flag, 0x00, "card FLAG now 00h");
    TX(1, 0x74, 0x00, 0x3f, 0x04, 0x00, 0x00, 0x00, 0x01); run(30000);
    CHECKEQ(status(), 0x8000, "read after write: FLAG 00h -> 0x8000");
    CHECK(!memcmp(W.ram + 0x40000, W.ram + 0x30000, 128), "read back");

    GROUP("no card: 0x0008 sticky, busy-path leaves params unconsumed, 76 clears");
    TX(1, 0x74, 0x80, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01);  /* port 2 (bit 15): empty */
    run(30000);
    CHECKEQ(status(), 0x0008, "no card -> 0x0008 (0x8000 cleared by the completion mask)");
    TX(1, 0x74, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01);
    CHECK(resp_ok() && BODY(0) == 2 && BLEN == 2 && BODY(1) == 4, "74 while error set: report 4, then 0x00 parsed as a command -> status 2");
    TX(1, 0x76); CHECK(BODY(1) == 1, "76 -> 1"); CHECKEQ(status(), 0x0000, "error bits cleared");

    GROUP("busy rules: 74/76/F0 while reading");
    TX(1, 0x74, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x08);
    TX(1, 0x76); CHECK(BODY(1) == 4, "76 while reading -> 4");
    TX(0xff, 0xf0, 0xd9); CHECK(rlen == 0 && W.mode == WIO_FW, "F0 D9 ignored while a card op runs");
    run(200000); CHECKEQ(status(), 0x8000, "8 frames done (card FLAG is 00h since the write)");
    TX(0xff, 0xf0, 0xd9); CHECK(W.mode == WIO_BOOT && W.addr == 0xff, "F0 D9 when idle reboots to the boot ROM");

    GROUP("limits: frame+count <= 0x400, RAM, count 0");
    boot_to_fw_synthetic(); TX(1, 0x73); run(25000);
    TX(1, 0x74, 0x03, 0xff, 0x02, 0x00, 0x00, 0x00, 0x02); CHECK(BODY(1) == 2, "0x3ff + 2 frames -> 2");
    TX(1, 0x74, 0x00, 0x00, 0x07, 0xff, 0x81, 0x00, 0x01); CHECK(BODY(1) == 2, "RAM overrun -> 2");
    TX(1, 0x74, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00); CHECK(BODY(1) == 2, "count 0 -> 2");
    TX(1, 0x74, 0x00, 0x00); CHECK(BODY(1) == 2 && BLEN == 2, "short -> 2, rest consumed");
    CHECKEQ(status(), 0x0000, "nothing started");

    GROUP("write with card FLAG 04h -> -3 -> 0x0010");
    vc[0].flag = 0x04;
    TX(1, 0x75, 0x03, 0x00, 0x00, 0x00, 0x10, 0x00, 0x01); run(60000);
    CHECKEQ(status(), 0x0010, "0x0010");
    TX(1, 0x76); vc[0].flag = 0x00;
    TX(1, 0x74, 0x00, 0x10, 0x02, 0x00, 0x00, 0x00, 0x01); run(30000);
    CHECKEQ(status(), 0x8000, "read OK again");

    GROUP("framing: checksum, 0x2f resend, unknown command, overflow");
    {
        uint8_t p[] = { 0xe0, 1, 2, 0x71, 0x00 };
        rlen = wio_packet(&W, p, 5, rsp); CHECK(resp_ok() && BLEN == 1 && BODY(0) == 3, "bad sum -> status 3");
        p[1] = 0xff; rlen = wio_packet(&W, p, 5, rsp); CHECKEQ(rlen, 0, "bad sum broadcast -> none");
    }
    TX(1, 0x71); int l1 = rlen; uint8_t r1[300]; memcpy(r1, rsp, (size_t)rlen);
    TX(1, 0x2f); CHECK(rlen == l1 && !memcmp(rsp, r1, (size_t)l1), "2f resends the last answer");
    TX(1, 0x71, 0x99, 0x71); CHECK(BODY(0) == 2 && BLEN == 4, "unknown stops: status 2, earlier reports kept");
    TX(1, 0x70, 0x00, 0, 0, 0, 0x80, 0x70, 0x00, 0, 0, 0, 0x80);
    CHECK(resp_ok() && BLEN == 1 && BODY(0) == 4, "> 0xfe body bytes -> status 4 alone");

    GROUP("dongle slots (absent): 72 00 -> 0x7800 then 0x0020; 72 2x refused while set");
    TX(1, 0x72, 0x00); CHECK(BODY(1) == 1, "72 00 -> 1"); CHECKEQ(status() & 0x7800, 0x7800, "busy");
    run(5000); CHECKEQ(status() & 0x7860, 0x0020, "no device -> 0x0020");
    TX(1, 0x72, 0x20, 0, 0, 0x02, 0, 0, 0, 8); CHECK(BODY(1) == 4, "72 20 refused while 0x20");
    TX(1, 0x72); CHECK(BLEN == 2 && BODY(1) == 2 && BODY(0) == 1, "72 without sub -> report 2");

    GROUP("vcard: psx-spx protocol edges");
    {
        wio_vcard_t *c = &vc[1]; uint8_t r;
        memset(c, 0, sizeof(*c)); wio_vcard_insert(c, 1);
        CHECKEQ(c->flag, 0x08, "FLAG 08h on insertion");
        wio_vcard_select(c);
        CHECK(wio_vcard_byte(c, 0x81, &r) == 1, "81 acked");
        wio_vcard_byte(c, 0x57, &r); CHECKEQ(r, 0x08, "FLAG");
        wio_vcard_byte(c, 0, &r); CHECKEQ(r, 0x5a, "5A"); wio_vcard_byte(c, 0, &r); CHECKEQ(r, 0x5d, "5D");
        wio_vcard_byte(c, 0x00, &r); wio_vcard_byte(c, 0x05, &r);
        for (int k = 0; k < 128; k++) wio_vcard_byte(c, 0x11, &r);
        wio_vcard_byte(c, 0x12, &r);             /* wrong checksum */
        wio_vcard_byte(c, 0, &r); CHECKEQ(r, 0x5c, "5C"); wio_vcard_byte(c, 0, &r); CHECKEQ(r, 0x5d, "5D");
        CHECK(wio_vcard_byte(c, 0, &r) == 0 && r == 0x4e, "bad checksum -> 4E, no ACK");
        CHECKEQ(c->flag, 0x08, "FLAG unchanged by a failed write");
        wio_vcard_select(c); wio_vcard_byte(c, 0x81, &r); wio_vcard_byte(c, 0x52, &r);
        wio_vcard_byte(c, 0, &r); wio_vcard_byte(c, 0, &r); wio_vcard_byte(c, 0x04, &r); wio_vcard_byte(c, 0x00, &r);
        wio_vcard_byte(c, 0, &r); wio_vcard_byte(c, 0, &r);
        wio_vcard_byte(c, 0, &r); CHECKEQ(r, 0xff, "invalid sector: confirmed MSB FFh");
        CHECK(wio_vcard_byte(c, 0, &r) == 0 && r == 0xff, "then Sony card aborts");
        wio_vcard_select(c); CHECK(wio_vcard_byte(c, 0x01, &r) == 0, "not 81: no ACK");
        wio_vcard_insert(c, 0); wio_vcard_select(c); CHECK(wio_vcard_byte(c, 0x81, &r) == 0, "ejected: no ACK");
    }

    printf("%d groups, %d failures\n", groups, fails);
    printf(fails ? "WHITEIO: FAIL\n" : "WHITEIO: PASS\n");
    return fails != 0;
}
