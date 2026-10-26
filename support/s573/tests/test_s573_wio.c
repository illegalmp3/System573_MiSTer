/*
 * wio_test.c -- host test for the White I/O emulation.  Plays the 573's side of
 * the JVS bus (the sequence DDR uses, from its reader driver and the 2026-10-24
 * cabinet log) against the real boot ROM and the firmware DDR uploads.
 *
 * usage: wio_test 885a01.bin GAME.DAT [container_offset]
 */
#include "../s573_wio.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define CYC_PER_BYTE 5729u   /* 10 bits at 115200 baud, 66 MHz cycles */
#define MS(x) ((uint64_t)(x) * 66000u)

static uint8_t rx[4096];
static int rxn;
static int sense = -1;
static int fails;
static int verbose;

static void on_tx(void *u, uint8_t b, uint64_t cyc) { (void)u; if (verbose) printf("  [tx %02x at %.3f ms]\n", b, cyc / 66000.0); if (rxn < (int)sizeof rx) rx[rxn++] = b; }
static void on_sense(void *u, int lv, uint64_t cyc) { (void)u; if (verbose) printf("  [sense %d at %.3f ms]\n", lv, cyc / 66000.0); sense = lv; }
static void on_log(void *u, const char *s) { (void)u; printf("  [wio] %s\n", s); }

static wio_t *w;

/* ---- a stand-in for the FPGA's real-card byte engine (what rtl/s573_wio_port.v
 *      does on the SNAC pins), driving a byte-level card model ---- */
static wio_card_t ext_card;
static int ext_latch;
static unsigned ext_xfers;
static void ext_reg(void *u, uint8_t v, uint64_t cyc)
{
    (void)u; (void)cyc;
    wio_card_select(&ext_card, !((v >> 2) & 1));
}
static void ext_latch_clr(void *u, uint64_t cyc) { (void)u; (void)cyc; ext_latch = 0; }
static int ext_res;
static uint64_t ext_done;
static void ext_start(void *u, uint8_t reg, uint8_t cmd, unsigned to_us, uint64_t cyc)
{
    uint8_t out;
    wio_card_ack_t a;
    uint64_t took = 8 * 4 * 66;               /* eight 4 us bits */
    (void)u;
    ext_xfers++;
    wio_card_select(&ext_card, !((reg >> 2) & 1));
    if (ext_latch) { ext_res = WIO_XFER_ERROR; ext_done = cyc + took; return; }
    out = wio_card_out(&ext_card);
    a = wio_card_byte(&ext_card, cmd);
    if (to_us == 0) { if (a.ack) ext_latch = 1; ext_res = out; }
    else if (!a.ack) { took += (uint64_t)to_us * 66; ext_res = WIO_XFER_NOACK; }
    else if (a.ack_delay_ns / 1000 > to_us) { took += (uint64_t)to_us * 66; ext_latch = 1; ext_res = WIO_XFER_NOACK; }
    else { took += a.ack_delay_ns * 66 / 1000 + 7 * 66; ext_res = out; }
    ext_done = cyc + took;
}
static int ext_poll(void *u, int *res, uint64_t *done)
{
    (void)u;
    *res = ext_res;
    *done = ext_done;
    return 1;                                 /* result known; it lands at ext_done */
}

#ifdef WIO_PROFILE
static uint32_t prof[65536];
void wio_prof(uint32_t pc) { if ((pc >> 16) == 0x8000) prof[(pc & 0xffff) >> 2]++; else if ((pc>>16)==0x8007) prof[0x3c00 + ((pc & 0xfff) >> 2)]++; }
static void prof_dump(void)
{
    int i, k;
    for (k = 0; k < 25; k++) {
        int best = 0; uint32_t bv = 0;
        for (i = 0; i < 16384; i++) if (prof[i] > bv) { bv = prof[i]; best = i; }
        if (!bv) break;
        printf("  %08x %u\n", best < 0x3c00 ? 0x80000000u + best * 4 : 0x80070000u + (best - 0x3c00) * 4, bv);
        prof[best] = 0;
    }
}
#else
static void prof_dump(void) {}
#endif

#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

/* send one JVS packet (escaped), starting now; returns the cycle the last byte lands */
static uint64_t send(uint8_t addr, const uint8_t *body, int n)
{
    uint8_t raw[600];
    int k = 0, i;
    uint8_t sum;
    uint64_t t = wio_now(w) + 100;
    rxn = 0;
    raw[k++] = 0xe0;
    {
        uint8_t hdr[2] = { addr, (uint8_t)(n + 1) };
        uint8_t all[300];
        memcpy(all, hdr, 2);
        memcpy(all + 2, body, (size_t)n);
        sum = 0;
        for (i = 0; i < n + 2; i++) sum += all[i];
        all[n + 2] = sum;
        for (i = 0; i < n + 3; i++) {
            uint8_t b = all[i];
            if (b == 0xe0 || b == 0xd0) { raw[k++] = 0xd0; raw[k++] = (uint8_t)(b - 1); }
            else raw[k++] = b;
        }
    }
    for (i = 0; i < k; i++) { wio_bus_rx(w, raw[i], t); t += CYC_PER_BYTE; }
    return t;
}

/* collect one response packet (unescaped) within 'ms'; returns payload length or -1 */
static int recv(uint8_t *out, int ms)
{
    uint64_t end = wio_now(w) + MS(ms);
    uint8_t u[600];
    int un = 0, i, esc = 0, start = -1;
    while (wio_now(w) < end) {
        wio_run(w, wio_now(w) + MS(1));
        un = 0; esc = 0; start = -1;
        for (i = 0; i < rxn; i++) {
            uint8_t b = rx[i];
            if (b == 0xe0) { start = 0; un = 0; esc = 0; u[un++] = b; continue; }
            if (start < 0) continue;
            if (esc) { u[un++] = (uint8_t)(b + 1); esc = 0; continue; }
            if (b == 0xd0) { esc = 1; continue; }
            u[un++] = b;
        }
        if (start == 0 && un >= 3 && un >= 3 + u[2]) {
            uint8_t sum = 0;
            for (i = 1; i < 2 + u[2]; i++) sum += u[i];
            CHECK(sum == u[2 + u[2]], "response checksum %02x vs %02x", sum, u[2 + u[2]]);
            CHECK(u[1] == 0x00, "response address %02x", u[1]);
            memcpy(out, u + 3, (size_t)(u[2] - 1));
            if (verbose) {
                printf("  <-");
                for (i = 0; i < un; i++) printf(" %02x", u[i]);
                printf("\n");
            }
            return u[2] - 1;
        }
    }
    return -1;
}

static int xact(uint8_t addr, const uint8_t *body, int n, uint8_t *resp, int ms)
{
    uint64_t t = send(addr, body, n);
    wio_run(w, t);
    return recv(resp, ms);
}

static uint8_t *load(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    uint8_t *p;
    long n;
    if (!f) { perror(path); exit(2); }
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
    p = (uint8_t *)malloc((size_t)n);
    if (fread(p, 1, (size_t)n, f) != (size_t)n) { perror(path); exit(2); }
    fclose(f);
    *len = (size_t)n;
    return p;
}

static unsigned status(void)
{
    uint8_t b[1] = { 0x71 }, r[64];
    int n = xact(0x01, b, 1, r, 20);
    if (n < 4 || r[0] != 1 || r[1] != 1) { CHECK(0, "71 status reply (n=%d)", n); return 0xffff; }
    return (unsigned)r[2] << 8 | r[3];
}

static unsigned wait_idle(unsigned mask, int ms)
{
    unsigned s = 0;
    int i;
    for (i = 0; i < ms / 16; i++) {
        s = status();
        if (!(s & mask)) break;
        wio_run(w, wio_now(w) + MS(16));
    }
    return s;
}

int main(int argc, char **argv)
{
    size_t romlen, gamelen;
    uint8_t *rom, *game, resp[600];
    long coff = 0x144678;
    wio_host_t h;
    int n, i;
    const wio_stats_t *st;
    wio_card_t *c0;

    if (argc < 3) { fprintf(stderr, "usage: %s 885a01.bin GAME.DAT [container_offset] [-v]\n", argv[0]); return 2; }
    if (argc > 3 && argv[3][0] != '-') coff = strtol(argv[3], NULL, 0);
    for (i = 3; i < argc; i++) if (!strcmp(argv[i], "-v")) verbose = 1;
    rom = load(argv[1], &romlen);
    game = load(argv[2], &gamelen);

    memset(&h, 0, sizeof h);
    h.bus_tx = on_tx; h.sense = on_sense; h.log = on_log;
    h.card_reg = ext_reg; h.card_latch_clr = ext_latch_clr; h.card_xfer_start = ext_start; h.card_xfer_done = ext_poll;
    w = wio_create(&h);
    CHECK(wio_load_rom(w, rom, romlen) == 0, "rom");
    {
        int ext = 0;
        for (i = 3; i < argc; i++) if (!strcmp(argv[i], "-ext")) ext = 1;
        wio_port_mode(w, 0, ext ? WIO_PORT_EXTERNAL : WIO_PORT_VIRTUAL);
        c0 = ext ? &ext_card : wio_port_card(w, 0);
        printf("port 0: %s card\n", ext ? "external (byte engine stand-in)" : "virtual");
    }
    wio_card_format(c0->data);
    for (i = 0; i < 128; i++) c0->data[0x45 * 128 + i] = (uint8_t)(i * 7 + 3);
    wio_card_insert(c0);

    wio_power_on(w);
    wio_run(w, MS(100));
    st = wio_stats(w);
    printf("boot: %llu insns, pc %08x, sense %d\n", (unsigned long long)st->insns, wio_cpu(w)->pc, sense);
    CHECK(sense == 1, "sense out after reset = %d (want 1, unaddressed)", sense);

    /* 1. reset twice (broadcast F0 D9): no reply */
    {
        uint8_t b[2] = { 0xf0, 0xd9 };
        wio_run(w, send(0xff, b, 2));
        n = recv(resp, 30);
        CHECK(n < 0, "reply to reset");
        wio_run(w, send(0xff, b, 2));
        n = recv(resp, 30);
        CHECK(n < 0, "reply to reset 2");
        printf("reset x2: watchdog resets %u\n", st->wd_resets);
        CHECK(st->wd_resets == 2, "watchdog resets %u", st->wd_resets);
    }
    /* 2. address assignment */
    {
        uint8_t b[2] = { 0xf1, 0x01 };
        n = xact(0xff, b, 2, resp, 20);
        CHECK(n == 2 && resp[0] == 1 && resp[1] == 1, "F1 reply n=%d %02x %02x", n, resp[0], resp[1]);
        CHECK(sense == 0, "sense after addressing = %d", sense);
    }
    /* 3. identification */
    {
        uint8_t b[1] = { 0x10 };
        n = xact(0x01, b, 1, resp, 20);
        CHECK(n > 2 && resp[0] == 1 && resp[1] == 1, "ID reply");
        if (n > 2) printf("ID: %.*s\n", n - 2, (char *)resp + 2);
    }
    /* 4. upload the container records with 70 01 (<= 0x80 bytes each) */
    {
        long p = coff;
        int records = 0;
        unsigned first = 0;
        for (;;) {
            unsigned addr = (unsigned)game[p] << 24 | (unsigned)game[p + 1] << 16 | (unsigned)game[p + 2] << 8 | game[p + 3];
            unsigned size = (unsigned)game[p + 4] << 24 | (unsigned)game[p + 5] << 16 | (unsigned)game[p + 6] << 8 | game[p + 7];
            unsigned off;
            if (size == 0) break;
            if (!records) first = addr;
            for (off = 0; off < size; off += 0x80) {
                uint8_t b[300];
                unsigned m = size - off < 0x80 ? size - off : 0x80;
                unsigned a = addr + off;
                b[0] = 0x70; b[1] = 0x01; b[2] = (uint8_t)(a >> 16); b[3] = (uint8_t)(a >> 8); b[4] = (uint8_t)a; b[5] = (uint8_t)m;
                memcpy(b + 6, game + p + 8 + off, m);
                n = xact(0x01, b, (int)(6 + m), resp, 30);
                if (!(n == 2 && resp[0] == 1 && resp[1] == 1)) { CHECK(0, "70 01 at %06x: n=%d %02x %02x", a, n, resp[0], resp[1]); break; }
            }
            p += 8 + size;
            records++;
        }
        printf("upload: %d records\n", records);
        {
            uint8_t b[5] = { 0x70, 0x02, (uint8_t)(first >> 16), (uint8_t)(first >> 8), (uint8_t)first };
            n = xact(0x01, b, 5, resp, 30);
            CHECK(n >= 1 && resp[0] == 1, "70 02 reply n=%d", n);
        }
        wio_run(w, wio_now(w) + MS(1000));       /* the game waits 60 frames */
        printf("firmware CRC %08x after %llu insns, idle-skipped %llu cycles\n", wio_fw_crc(w),
               (unsigned long long)st->insns, (unsigned long long)st->idle_skipped);
    }
    /* 5. ID again from the firmware, then 73 (configure the FPGA) */
    {
        uint8_t b[1] = { 0x10 };
        n = xact(0x01, b, 1, resp, 20);
        CHECK(n > 2 && resp[0] == 1, "ID from firmware");
        printf("status before 73: %04x\n", status());
        b[0] = 0x73;
        n = xact(0x01, b, 1, resp, 20);
        CHECK(n == 2 && resp[0] == 1 && resp[1] == 1, "73 reply n=%d %02x %02x", n, resp[0], resp[1]);
        printf("status after FPGA config: %04x (configs %u)\n", wait_idle(0x0101, 3000), st->fpga_configs);
        CHECK(st->fpga_configs == 1, "FPGA configured %u times", st->fpga_configs);
    }
    /* 6. read frame 0x45 of port 0 into board RAM 0x010000, read it back with 70 00 */
    {
        uint8_t b[8] = { 0x74, 0x00, 0x45, 0x01, 0x00, 0x00, 0x00, 0x01 };
        unsigned s;
        uint8_t a76[1] = { 0x76 };
        n = xact(0x01, a76, 1, resp, 20);
        if (getenv("WIO_TRACE")) wio_trace(w, 1);
        n = xact(0x01, b, 8, resp, 20);
        CHECK(n == 2 && resp[1] == 1, "74 reply n=%d %02x", n, resp[1]);
        s = wait_idle(0x0600, 2000);
        wio_trace(w, 0);
        printf("status after read: %04x (card reads %u)\n", s, c0->reads);
        CHECK((s & 0x061e) == 0, "read status %04x", s);
        /* 0x8000 = the first frame's FLAG was not 08h (fw table 0x80005f10, set from
         * 0x80005984); a freshly inserted card answers 08h, so the bit must be clear */
        CHECK(!(s & 0x8000), "fresh card: FLAG 08h -> 0x8000 clear (status %04x)", s);
        {
            uint8_t rd[6] = { 0x70, 0x00, 0x01, 0x00, 0x00, 0x80 };
            n = xact(0x01, rd, 6, resp, 30);
            CHECK(n == 2 + 128, "70 00 reply n=%d", n);
            CHECK(n == 2 + 128 && !memcmp(resp + 2, c0->data + 0x45 * 128, 128), "frame data mismatch");
        }
    }
    /* 7. write frame 0x3f from RAM 0x011000 (pattern), then read card */
    {
        uint8_t wr[6 + 128] = { 0x70, 0x01, 0x01, 0x10, 0x00, 0x80 };
        uint8_t b[8] = { 0x75, 0x01, 0x10, 0x00, 0x00, 0x3f, 0x00, 0x01 };
        unsigned s;
        for (i = 0; i < 128; i++) wr[6 + i] = (uint8_t)(0xa5 ^ i);
        n = xact(0x01, wr, sizeof wr, resp, 30);
        CHECK(n == 2 && resp[1] == 1, "70 01 data");
        n = xact(0x01, b, 8, resp, 20);
        CHECK(n == 2 && resp[1] == 1, "75 reply");
        s = wait_idle(0x0600, 2000);
        printf("status after write: %04x (card writes %u, flag %02x)\n", s, c0->writes, c0->flag);
        CHECK((s & 0x061e) == 0, "write status %04x", s);
        CHECK(c0->writes == 1 && !memcmp(c0->data + 0x3f * 128, wr + 6, 128), "card frame 3f not written");
        CHECK(c0->flag == 0x00, "FLAG after write %02x", c0->flag);
        {
            uint8_t b2[8] = { 0x74, 0x00, 0x00, 0x01, 0x20, 0x00, 0x00, 0x10 };
            n = xact(0x01, b2, 8, resp, 20);
            s = wait_idle(0x0600, 3000);
            printf("status after 16-frame read: %04x (card reads %u)\n", s, c0->reads);
            CHECK((s & 0x061e) == 0 && (s & 0x8000), "16-frame read status %04x (FLAG now 00h -> 0x8000)", s);
            {
                int k, ok = 1;
                for (k = 0; k < 16; k++) {
                    uint8_t rd[6] = { 0x70, 0x00, 0x01, 0x20, (uint8_t)(k * 0x80), 0x80 };
                    rd[3] = (uint8_t)(0x20 + (k * 0x80 >> 8));
                    rd[4] = (uint8_t)(k * 0x80);
                    n = xact(0x01, rd, 6, resp, 30);
                    if (n != 130 || memcmp(resp + 2, c0->data + k * 128, 128)) ok = 0;
                }
                CHECK(ok, "16-frame read data mismatch");
            }
        }
    }
    /* 8. empty port 1: read must fail with 'no card' */
    {
        uint8_t b[8] = { 0x74, 0x80, 0x00, 0x01, 0x30, 0x00, 0x00, 0x01 };
        uint8_t a76[1] = { 0x76 };
        unsigned s;
        n = xact(0x01, b, 8, resp, 20);
        s = wait_idle(0x0600, 2000);
        printf("status after read of empty port: %04x\n", s);
        CHECK(s & 0x0008, "no-card bit expected (%04x)", s);
        n = xact(0x01, a76, 1, resp, 20);
        s = status();
        CHECK((s & 0x001e) == 0, "76 clears errors (%04x)", s);
    }

    printf("interpreted %llu, external byte exchanges %u, ", (unsigned long long)st->interp, ext_xfers);
    printf("insns %llu, idle-skipped %llu cycles of %llu, unmapped %u, rx dropped %u\n",
           (unsigned long long)st->insns, (unsigned long long)st->idle_skipped,
           (unsigned long long)wio_now(w), st->unmapped, st->rx_dropped);
    if (getenv("WIO_PROF")) prof_dump();
    printf("%s (%d failures)\n", fails ? "FAILED" : "PASSED", fails);
    wio_destroy(w);
    return fails ? 1 : 0;
}
