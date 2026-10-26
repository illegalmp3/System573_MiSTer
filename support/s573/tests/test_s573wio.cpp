/* test_s573wio.cpp -- the card reader SERVICE (s573wio.cpp) end to end on the host.
 *
 * s573wio.cpp runs here exactly as in Main: its poll is called from a "Main" loop
 * thread, it starts the board thread (the emulated White I/O board running the real
 * 885a01 boot ROM and the program a DDR game uploads) and the card file writer. What
 * is modelled instead of real hardware:
 *   - the fabric (rtl/s573_wio.v): the CMD_573_WIO words with the same answers and
 *     effects word for word, the 573's JVS MCU (rtl/s573_jvs_mcu.v, psx-spx), and
 *     the SNAC byte engine (rtl/s573_wio_port.v) driving a PS1 card model;
 *   - the game: its JVS driver as psx-spx "MCU communication protocol" gives it,
 *     sending the commands DDR's code sends (the sequence in the old HLE log and in
 *     tests/test_s573_wio.c);
 *   - Main: the OSD status bits, slots 2/3 (a real FILE*), GetIdx_S/HomeDir.
 *
 * Checks: boot (sense), reset x2 (no reply), address (sense 0), ID, program upload
 * and run (CRC), FPGA configure, read a frame from a card FILE and compare, write
 * a frame and find it IN THE FILE on disk, the same read with the slot switched to
 * SNAC (a real card through the byte engine), a core reset (re-attach), and an
 * ejected file reading as "no card".
 *
 * usage: test_s573wio 885a01.bin GAME.DAT [container_offset]
 * -DS573_MUT_NO_ESCAPE etc. are not used; RED is shown by -DTEST_RED (the fabric
 * model reports the reader as not fitted).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>
#include <atomic>
#include "host_main_stubs.h"
extern "C" {
#include "../s573_wio.h"
}

void s573wio_poll(void);

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } } while (0)

static uint64_t ms_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}
static uint64_t us_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

/* ---------------------------------------------------------------- the log */
static int verbose;
static FILE *logf_;
void s573_logf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    if (verbose) vprintf(fmt, ap);
    va_end(ap);
    if (logf_) { va_start(ap, fmt); vfprintf(logf_, fmt, ap); va_end(ap); fflush(logf_); }
}

/* ======================================================= the fabric (model) */
static pthread_mutex_t fab = PTHREAD_MUTEX_INITIALIZER;

/* -- s573_jvs_mcu -- */
enum { S_IDLE, S_RECV, S_BUSY, S_READ, S_HALT };
static int      m_st = S_IDLE, m_stat = 0, m_err = 3, m_irdy = 0;
static uint16_t m_rword;
static uint16_t m_req[256], m_resp[256];
static int      m_wcnt, m_tot, m_req_len, m_rlen, m_rptr;
static uint8_t  m_csum, m_req_seq;

static void mcu_reset(void) { m_st = S_IDLE; m_stat = 0; m_err = 3; m_rword = 0; m_wcnt = 0; }

static void mcu_wr(uint16_t w)
{
    uint8_t b0 = (uint8_t)w, b1 = (uint8_t)(w >> 8);
    if (m_st == S_IDLE || m_st == S_READ) {
        if (b0 != 0xe0) { m_st = S_HALT; m_stat = 2; m_err = 2; return; }
        m_req[0] = w; m_csum = b1; m_wcnt = 2; m_tot = 511; m_st = S_RECV; m_stat = 2; m_err = 3;
        return;
    }
    if (m_st != S_RECV) return;
    int tot = (m_wcnt == 2) ? b0 + 3 : m_tot;
    if (m_wcnt < tot - 1) m_csum = (uint8_t)(m_csum + b0);
    if (m_wcnt + 1 < tot - 1) m_csum = (uint8_t)(m_csum + b1);
    uint8_t ck = (m_wcnt == tot - 1) ? b0 : b1;
    int done = (m_wcnt + 2 >= tot);
    m_req[m_wcnt / 2] = w; m_tot = tot; m_wcnt += 2;
    if (done) {
        if (ck == m_csum) { m_st = S_BUSY; m_stat = 1; m_req_len = tot; m_req_seq++; }
        else { m_st = S_HALT; m_stat = 1; m_err = 1; }
    }
}

static void mcu_fetch(void)
{
    uint16_t q = m_resp[m_rptr];
    m_rword = (uint16_t)((2 * m_rptr + 1 < m_rlen) ? q : (q & 0xff));
    m_irdy = 1; m_rptr++;
    if (m_st == S_BUSY) { m_st = S_READ; m_stat = 0; }
}

static void mcu_clr(void)
{
    m_irdy = 0;
    if (m_st == S_READ) {
        if (2 * m_rptr < m_rlen) { m_stat = 2; mcu_fetch(); m_stat = 2; }
        else { m_stat = 0; m_st = S_IDLE; }
    }
}

/* -- s573_wio_port, driving a byte-level card per SNAC port -- */
static wio_card_t snac_card[2];
static uint8_t  p_creg = 0xff;
static int      p_latch, p_busy, p_done, p_result, p_xcnt;
static uint8_t  p_rx;
static uint64_t p_done_at;
static unsigned p_xfers;

static void port_reg(uint8_t v)
{
    int q;
    p_creg = v;
    for (q = 0; q < 2; q++) wio_card_select(&snac_card[q], !((v >> (2 + q)) & 1));
}

static void port_settle(void)
{
    if (p_busy && us_now() >= p_done_at) { p_busy = 0; p_done = 1; p_xcnt = (p_xcnt + 1) & 15; }
}

static void port_xfer(uint8_t cmd, unsigned tmo)
{
    uint64_t took = 36;
    p_done = 0; p_busy = 1; p_xfers++;
    if (p_latch) { p_result = 2; p_done_at = us_now(); return; }
    int q = !((p_creg >> 2) & 1) ? 0 : !((p_creg >> 3) & 1) ? 1 : -1;
    wio_card_t *c = q >= 0 ? &snac_card[q] : 0;
    uint8_t out = c ? wio_card_out(c) : 0xff;
    wio_card_ack_t a = c ? wio_card_byte(c, cmd) : wio_card_ack_t{ 0, 0 };
    p_rx = out;
    if (tmo == 0) { if (a.ack) p_latch = 1; p_result = 0; }
    else if (!a.ack) { took += tmo; p_result = 1; }
    else if (a.ack_delay_ns / 1000 > tmo) { took += tmo; p_latch = 1; p_result = 1; }
    else { took += a.ack_delay_ns / 1000 + 7; p_result = 0; }
    p_done_at = us_now() + took;
}

/* -- s573_wio: the CMD_573_WIO words -- */
static int      w_attached, w_sense = 1, w_osd_en = 1;
static uint8_t  w_op, w_cmd;
static int      w_raddr, w_rlen;
static uint8_t  w_rseq;
static int      w_idx;
static unsigned spi_xacts;

static uint16_t wio_word(int idx, uint16_t din)
{
    uint16_t d;
    port_settle();
    /* the answer: combinational from the state before this word */
    if (idx == 0) d = (uint16_t)((w_attached << 15) | (w_osd_en << 14) | ((m_st == S_BUSY) << 13) |
                                 (p_busy << 12) | (p_done << 11) | (p_result << 9) | m_req_seq);
    else if (idx == 1) d = (uint16_t)((p_xcnt << 12) | (p_result << 8) | p_rx);
    else if (idx == 2) d = (uint16_t)(w_op == 6 ? m_req_len : 0);
    else if (idx == 3) d = (uint16_t)(w_op == 6 ? m_req_seq : 0);
    else d = (uint16_t)(w_op == 6 ? m_req[w_raddr & 255] : 0);
    /* the effects */
    if (idx == 0) w_op = 0;
    else if (idx == 1) {
        w_op = (uint8_t)(din >> 8);
        switch (w_op) {
        case 1: w_attached = din & 1; break;
        case 2: w_sense = din & 1; break;
        case 3: if (!p_busy) port_reg((uint8_t)din); break;
        case 4: if (!p_busy) p_latch = 0; break;
        case 5: w_cmd = (uint8_t)din; break;     /* held until word 2 */
        case 6: w_raddr = 0; break;
        }
    } else if (idx == 2) {
        if (w_op == 5) port_xfer(w_cmd, din);
        if (w_op == 7) w_rlen = din & 511;
    } else if (idx == 3) {
        if (w_op == 7) w_rseq = (uint8_t)din;
    } else {
        if (w_op == 6) w_raddr++;
        if (w_op == 7) {
            int k = idx - 4, words = (w_rlen + 1) / 2;
            if (k < words) {
                m_resp[k] = din;
                if (k == words - 1 && m_st == S_BUSY && w_rseq == m_req_seq && w_rlen >= 2) {
                    m_rlen = w_rlen; m_rptr = 0; mcu_fetch();
                }
            }
        }
    }
    return d;
}

/* -- the SPI calls s573wio.cpp makes -- */
uint16_t spi_uio_cmd_cont(uint16_t cmd)
{
    pthread_mutex_lock(&fab);
    spi_xacts++;
    if (cmd != 0x6f) { printf("unexpected command %04x\n", cmd); exit(3); }
    w_idx = 1;
    return wio_word(0, cmd);
}
uint16_t spi_w(uint16_t w) { return wio_word(w_idx++, w); }
void DisableIO(void) { pthread_mutex_unlock(&fab); }

/* the core reset: the fabric forgets the HPS and the MCU restarts */
static void core_reset(void)
{
    pthread_mutex_lock(&fab);
    w_attached = 0; w_sense = 1; w_op = 0; m_req_seq = 0; mcu_reset(); m_irdy = 0;
    p_creg = 0xff; p_latch = 0; p_busy = 0; p_done = 0; p_result = 0; p_xcnt = 0;
    pthread_mutex_unlock(&fab);
}

/* ======================================================= Main (model) */
static int        osd_snac[2];
static fileTYPE   slot[6];
static char       slot_path[6][512];
static char       home[512], rom_dir[512];
uint32_t user_io_status_get(const char *opt, int) { return (!strcmp(opt, "[118]")) ? osd_snac[0] : (!strcmp(opt, "[119]")) ? osd_snac[1] : 0; }
fileTYPE *get_image(int i) { return &slot[i]; }
const char *GetIdx_S(int idx) { return slot_path[idx]; }
const char *getFullPath(const char *name) { return name; }
const char *HomeDir(void) { return rom_dir; }

static std::atomic<int> main_run{1};
static void *main_loop(void *)
{
    while (main_run) { s573wio_poll(); usleep(40); }
    return 0;
}

/* ======================================================= the game (JVS driver) */
static int jvs_xact(uint8_t addr, const uint8_t *body, int n, uint8_t *out, int ms)
{
    uint8_t pk[300];
    int i, len = n + 1, tot = n + 4;
    uint8_t sum = (uint8_t)(addr + len);
    pk[0] = 0xe0; pk[1] = addr; pk[2] = (uint8_t)len;
    for (i = 0; i < n; i++) { pk[3 + i] = body[i]; sum = (uint8_t)(sum + body[i]); }
    pk[3 + n] = sum;
    /* psx-spx steps 1-3 */
    pthread_mutex_lock(&fab);
    mcu_reset(); m_irdy = 0;
    for (i = 0; i < (tot + 1) / 2; i++) mcu_wr((uint16_t)(pk[2 * i] | ((2 * i + 1 < tot ? pk[2 * i + 1] : 0) << 8)));
    int st1 = (w_osd_en && w_attached) ? m_stat : 0;     /* en = 0: legacy constants */
    pthread_mutex_unlock(&fab);
    if (st1 != 1) { CHECK(0, "MCU status %d after the packet (want 1)", st1); return -1; }
    /* 4-5: wait for the response and read it */
    uint64_t end = ms_now() + (uint64_t)ms;
    uint8_t r[600];
    int rn = 0, want = -1;
    for (;;) {
        pthread_mutex_lock(&fab);
        if (m_irdy && w_osd_en && w_attached) {
            uint16_t w = m_rword;
            mcu_clr();
            pthread_mutex_unlock(&fab);
            r[rn++] = (uint8_t)w; r[rn++] = (uint8_t)(w >> 8);
            if (rn >= 3 && want < 0) want = 3 + r[2];
            if (want >= 0 && rn >= want) break;
            continue;
        }
        pthread_mutex_unlock(&fab);
        if (ms_now() > end) return -1;
        usleep(100);
    }
    sum = 0;
    for (i = 1; i < want - 1; i++) sum = (uint8_t)(sum + r[i]);
    CHECK(r[0] == 0xe0 && r[1] == 0x00 && sum == r[want - 1], "response framing %02x %02x sum %02x/%02x", r[0], r[1], sum, r[want - 1]);
    memcpy(out, r + 3, (size_t)(r[2] - 1));
    return r[2] - 1;
}

static unsigned board_status(void)
{
    uint8_t b[1] = { 0x71 }, r[64];
    int n = jvs_xact(0x01, b, 1, r, 1000);
    if (n < 4 || r[0] != 1 || r[1] != 1) { CHECK(0, "71 reply n=%d", n); return 0xffff; }
    return (unsigned)r[2] << 8 | r[3];
}

static unsigned wait_idle(unsigned mask, int ms)
{
    unsigned s = 0;
    uint64_t end = ms_now() + (uint64_t)ms;
    do { s = board_status(); if (!(s & mask)) break; usleep(16000); } while (ms_now() < end);
    return s;
}

static uint8_t *load(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(2); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *p = (uint8_t *)malloc((size_t)n);
    if (fread(p, 1, (size_t)n, f) != (size_t)n) { perror(path); exit(2); }
    fclose(f); *len = (size_t)n;
    return p;
}

static int read_frame_check(int port, int frame, const uint8_t *want, const char *what)
{
    uint8_t b[8] = { 0x74, (uint8_t)(port ? 0x80 : 0x00), (uint8_t)frame, 0x01, 0x00, 0x00, 0x00, 0x01 };
    uint8_t a76[1] = { 0x76 }, r[600];
    int n = jvs_xact(0x01, a76, 1, r, 1000);
    n = jvs_xact(0x01, b, 8, r, 1000);
    CHECK(n == 2 && r[1] == 1, "%s: 74 reply n=%d", what, n);
    unsigned s = wait_idle(0x0600, 5000);
    if (!want) return (int)s;
    CHECK((s & 0x061e) == 0, "%s: status %04x after the read", what, s);
    uint8_t rd[6] = { 0x70, 0x00, 0x01, 0x00, 0x00, 0x80 };
    n = jvs_xact(0x01, rd, 6, r, 1000);
    CHECK(n == 130 && !memcmp(r + 2, want, 128), "%s: frame %02x data mismatch (n=%d)", what, frame, n);
    return (int)s;
}

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: %s 885a01.bin GAME.DAT [container_offset] [-v]\n", argv[0]); return 2; }
    long coff = 0x144678;
    int i, n;
    for (i = 3; i < argc; i++) { if (!strcmp(argv[i], "-v")) verbose = 1; else coff = strtol(argv[i], 0, 0); }
    size_t romlen, gamelen;
    uint8_t *rom = load(argv[1], &romlen), *game = load(argv[2], &gamelen), r[600];
    (void)rom;
#ifdef TEST_RED
    w_osd_en = 0;
#endif

    /* the boot ROM where Main would find it, and a card file in "saves" */
    snprintf(home, sizeof home, "/tmp/test_s573wio.%d", (int)getpid());
    snprintf(rom_dir, sizeof rom_dir, "%s/games", home);
    { char cmd[1200]; snprintf(cmd, sizeof cmd, "mkdir -p %s && cp %s %s/885a01.bin", rom_dir, argv[1], rom_dir); if (system(cmd)) return 2; }
    char logp[600]; snprintf(logp, sizeof logp, "%s/service.log", home); logf_ = fopen(logp, "w");
    static uint8_t img[WIO_CARD_SIZE];
    wio_card_format(img);
    for (i = 0; i < 128; i++) img[0x45 * 128 + i] = (uint8_t)(i * 7 + 3);
    char cardp[600]; snprintf(cardp, sizeof cardp, "%s/P1.mcd", home);
    { FILE *f = fopen(cardp, "wb"); fwrite(img, 1, sizeof img, f); fclose(f); }
    slot[2].filp = fopen(cardp, "r+b");
    snprintf(slot[2].name, sizeof slot[2].name, "P1.mcd");
    snprintf(slot_path[2], sizeof slot_path[2], "saves/System573/P1.mcd");
    /* a real card for the SNAC part */
    wio_card_format(snac_card[0].data);
    for (i = 0; i < 128; i++) snac_card[0].data[0x46 * 128 + i] = (uint8_t)(0x5a ^ (i * 3));
    wio_card_insert(&snac_card[0]);

    pthread_t mt;
    pthread_create(&mt, 0, main_loop, 0);

    /* 0. the service finds the reader fitted, powers the board, attaches */
    uint64_t end = ms_now() + 3000;
    int att = 0;
    while (ms_now() < end) { pthread_mutex_lock(&fab); att = w_attached; pthread_mutex_unlock(&fab); if (att) break; usleep(10000); }
    CHECK(att, "the service never attached to the fabric");
    usleep(300000);
    CHECK(w_sense == 1, "sense after boot = %d (want 1: not addressed)", w_sense);

    /* 1. reset x2: no reply (the MCU waits forever; the game times out) */
    { uint8_t b[2] = { 0xf0, 0xd9 };
      n = jvs_xact(0xff, b, 2, r, 150); CHECK(n < 0, "reply to reset");
      n = jvs_xact(0xff, b, 2, r, 150); CHECK(n < 0, "reply to reset 2"); }
    /* 2. address */
    { uint8_t b[2] = { 0xf1, 0x01 };
      n = jvs_xact(0xff, b, 2, r, 1000);
      CHECK(n == 2 && r[0] == 1 && r[1] == 1, "F1 reply n=%d", n);
      usleep(20000);
      CHECK(w_sense == 0, "sense after addressing = %d", w_sense); }
    if (fails) { printf("FAILED early (%d failures)\n", fails); return 1; }
    /* 3. ID */
    { uint8_t b[1] = { 0x10 };
      n = jvs_xact(0x01, b, 1, r, 1000);
      CHECK(n > 2 && r[0] == 1 && r[1] == 1, "ID reply n=%d", n);
      if (n > 2) printf("ID: %.*s\n", n - 2, (char *)r + 2); }
    /* 4. upload, run */
    {
        long p = coff;
        unsigned first = 0;
        int records = 0;
        uint64_t t0 = ms_now();
        for (;;) {
            unsigned addr = (unsigned)game[p] << 24 | (unsigned)game[p + 1] << 16 | (unsigned)game[p + 2] << 8 | game[p + 3];
            unsigned size = (unsigned)game[p + 4] << 24 | (unsigned)game[p + 5] << 16 | (unsigned)game[p + 6] << 8 | game[p + 7];
            if (!size) break;
            if (!records) first = addr;
            for (unsigned off = 0; off < size; off += 0x80) {
                uint8_t b[300];
                unsigned m = size - off < 0x80 ? size - off : 0x80, a = addr + off;
                b[0] = 0x70; b[1] = 0x01; b[2] = (uint8_t)(a >> 16); b[3] = (uint8_t)(a >> 8); b[4] = (uint8_t)a; b[5] = (uint8_t)m;
                memcpy(b + 6, game + p + 8 + off, m);
                n = jvs_xact(0x01, b, (int)(6 + m), r, 1000);
                if (!(n == 2 && r[0] == 1 && r[1] == 1)) { CHECK(0, "70 01 at %06x: n=%d", a, n); break; }
            }
            p += 8 + size; records++;
        }
        printf("upload: %d records in %llu ms\n", records, (unsigned long long)(ms_now() - t0));
        uint8_t b[5] = { 0x70, 0x02, (uint8_t)(first >> 16), (uint8_t)(first >> 8), (uint8_t)first };
        n = jvs_xact(0x01, b, 5, r, 1000);
        CHECK(n >= 1 && r[0] == 1, "70 02 reply n=%d", n);
        usleep(1000000);
    }
    /* 5. ID from the program, configure the FPGA */
    { uint8_t b[1] = { 0x10 };
      n = jvs_xact(0x01, b, 1, r, 1000);
      CHECK(n > 2 && r[0] == 1, "ID from the program n=%d", n);
      b[0] = 0x73;
      n = jvs_xact(0x01, b, 1, r, 1000);
      CHECK(n == 2 && r[1] == 1, "73 reply n=%d", n);
      unsigned s = wait_idle(0x0101, 5000);
      printf("status after FPGA config: %04x\n", s);
      CHECK((s & 0x0101) == 0, "FPGA not configured (%04x)", s); }

    /* 6. a frame from the card FILE */
    read_frame_check(0, 0x45, img + 0x45 * 128, "file card");

    /* 7. write a frame; it must land in the file */
    {
        uint8_t wr[6 + 128] = { 0x70, 0x01, 0x01, 0x10, 0x00, 0x80 };
        uint8_t b[8] = { 0x75, 0x01, 0x10, 0x00, 0x00, 0x3f, 0x00, 0x01 };
        for (i = 0; i < 128; i++) wr[6 + i] = (uint8_t)(0xa5 ^ i);
        n = jvs_xact(0x01, wr, sizeof wr, r, 1000);
        CHECK(n == 2 && r[1] == 1, "70 01 data");
        n = jvs_xact(0x01, b, 8, r, 1000);
        CHECK(n == 2 && r[1] == 1, "75 reply");
        unsigned s = wait_idle(0x0600, 5000);
        CHECK((s & 0x061e) == 0, "write status %04x", s);
        uint8_t got[128] = { 0 };
        int ok = 0;
        for (int t = 0; t < 100 && !ok; t++) {
            FILE *f = fopen(cardp, "rb");
            fseek(f, 0x3f * 128, SEEK_SET);
            if (fread(got, 1, 128, f) == 128 && !memcmp(got, wr + 6, 128)) ok = 1;
            fclose(f);
            if (!ok) usleep(10000);
        }
        CHECK(ok, "frame 3f written by the game is not in the card file");
        printf("write: frame 3f %s in %s\n", ok ? "found" : "NOT found", cardp);
    }

    /* 8. the same slot on SNAC: a real card through the byte engine */
    {
        unsigned x0 = p_xfers;
        osd_snac[0] = 1;
        usleep(300000);
        read_frame_check(0, 0x46, snac_card[0].data + 0x46 * 128, "SNAC card");
        printf("SNAC: %u byte exchanges\n", p_xfers - x0);
        CHECK(p_xfers - x0 >= 140, "SNAC byte exchanges %u (a frame read is 140)", p_xfers - x0);
        osd_snac[0] = 0;
        usleep(300000);
    }

    /* 9. a core reset: the service must re-attach and the board keep answering */
    {
        core_reset();
        usleep(300000);
        CHECK(w_attached, "not re-attached after a core reset");
        uint8_t b[1] = { 0x10 };
        n = jvs_xact(0x01, b, 1, r, 1000);
        CHECK(n > 2 && r[0] == 1, "ID after a core reset n=%d", n);
    }

    /* 10. eject the file: no card */
    {
        FILE *f = slot[2].filp;
        slot[2].filp = 0;
        usleep(300000);
        fclose(f);
        unsigned s = (unsigned)read_frame_check(0, 0x45, 0, "ejected");
        CHECK(s & 0x0008, "no-card bit expected after eject (%04x)", s);
    }

    main_run = 0;
    pthread_join(mt, 0);
    printf("SPI transactions %u; log %s\n", spi_xacts, logp);
    printf("%s (%d failures)\n", fails ? "FAILED" : "PASSED", fails);
    return fails ? 1 : 0;
}
