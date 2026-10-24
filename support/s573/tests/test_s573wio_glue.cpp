/* -----------------------------------------------------------------------------
 * test_s573wio_glue.cpp - s573wio.cpp (the MiSTer_System573 side of the White I/O
 * reader) against a mock of the fabric's CMD_573_WIO mailbox.
 *
 * The mock implements the mailbox exactly as rtl/s573_hps_ext.v documents it
 * (word0 {req_ready, snac_busy, snac_ack, snac_err, 3'b0, len}; op 1 read, op 2
 * write+commit, op 3 card primitive, op 4 flags), the HPS half of s573_jvs_mcu
 * (request latched with a sequence number, stale commits ignored) and an
 * instant s573_wio_snac with a psx-spx card behind it. tb_s573_wio_path checks
 * the RTL against the same word protocol.
 *
 * Runs in real time (the glue uses CLOCK_MONOTONIC): about a second.
 * Released under the GNU GPL v2.
 * ---------------------------------------------------------------------------- */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdarg.h>
#include "spi.h"
#include "user_io.h"
#include "file_io.h"
#include "../s573_whiteio.h"

void s573wio_poll(void);

static int fails = 0;
#define CHECK(c, m) do { if (!(c)) { printf("   FAIL: %s  (%s:%d)\n", m, __FILE__, __LINE__); fails++; } else printf("   ok  %s\n", m); } while (0)

/* ---- stubs ---- */
static uint32_t st_mode = 0, st_ej1 = 0, st_ej2 = 0;
uint32_t user_io_status_get(const char *opt, int)
{
    if (!strcmp(opt, "[117:116]")) return st_mode;
    if (!strcmp(opt, "[118]")) return st_ej1;
    if (!strcmp(opt, "[119]")) return st_ej2;
    return 0;
}
static uint8_t sd_file[2][WIO_CARD_SIZE]; static int sd_size[2] = { 0, 0 }, sd_saves[2] = { 0, 0 };
static int fidx(const char *n) { return strstr(n, "memcard2") ? 1 : 0; }
int FileCreatePath(const char *) { return 1; }
int FileSave(const char *n, void *b, int s) { int i = fidx(n); memcpy(sd_file[i], b, (size_t)s); sd_size[i] = s; sd_saves[i]++; return 1; }
int FileLoad(const char *n, void *b, int s) { int i = fidx(n); if (!b) return sd_size[i]; if (s > sd_size[i]) return 0; memcpy(b, sd_file[i], (size_t)s); return s; }
void s573_log_ext(const char *fmt, ...) { va_list ap; va_start(ap, fmt); printf("      | "); vprintf(fmt, ap); va_end(ap); }

/* ---- mock fabric ---- */
static uint16_t req[132]; static int req_ready = 0, req_len = 0; static uint8_t req_seq = 0;
static uint8_t resp[264]; static int resp_len = 0, resp_got = 0;
static uint16_t rbuf[132];
static int flags = 0;
static int s_busy = 0, s_ack = 0, s_err = 0; static uint8_t s_rx = 0xff;
static wio_vcard_t mcard[2];
static int cmd = -1, widx = 0, op = 0, arg = 0, raddr = 0;
static uint8_t r_seq = 0;

static uint16_t word0(void) { return (uint16_t)((req_ready << 15) | (s_busy << 14) | (s_ack << 13) | (s_err << 12) | (req_len & 0x1ff)); }
uint16_t spi_uio_cmd_cont(uint16_t c) { cmd = c; widx = 1; op = 0; return c == 0x6f ? word0() : 0; }
uint16_t spi_w(uint16_t x)
{
    uint16_t r = 0;
    if (cmd != 0x6f) return 0;
    if (widx == 1) {
        op = x >> 12; arg = x & 0x1ff; r = (uint16_t)((s_rx << 8) | req_seq);
        if (op == 1) raddr = 0;
        if (op == 4) flags = x & 3;
    } else if (op == 1) {
        r = req[raddr++ & 0xff];
    } else if (op == 2) {
        if (widx == 2) r_seq = (uint8_t)x;
        else {
            int k = widx - 3;
            if (k < 132) rbuf[k] = x;
            if (k == (arg + 1) / 2 - 1 && req_ready && r_seq == req_seq) {   /* commit */
                for (int j = 0; j < arg; j++) resp[j] = (uint8_t)(rbuf[j / 2] >> (8 * (j & 1)));
                resp_len = arg; resp_got = 1; req_ready = 0;
            }
        }
    } else if (op == 3 && widx == 2) {
        int port = x >> 15, type = (x >> 13) & 3, am = (x >> 11) & 3; uint8_t tx = (uint8_t)x;
        s_busy = 0;
        if (type == 0) wio_vcard_select(&mcard[port]);
        else if (type == 2) {
            int a = wio_vcard_byte(&mcard[port], tx, &s_rx);
            if (!mcard[port].inserted) s_rx = 0xff;
            s_ack = (am == 0) ? 1 : a; s_err = 0;
        }
    }
    widx++;
    return r;
}
void DisableIO() { cmd = -1; }

/* ---- the 573 side ---- */
static int xact(uint8_t dst, const uint8_t *pl, int n, int max_ms)
{
    uint8_t p[264]; p[0] = 0xe0; p[1] = dst; p[2] = (uint8_t)(n + 1);
    uint8_t s = (uint8_t)(dst + n + 1);
    for (int k = 0; k < n; k++) { p[3 + k] = pl[k]; s = (uint8_t)(s + pl[k]); }
    p[3 + n] = s;
    int len = n + 4;
    memset(req, 0, sizeof(req));
    for (int k = 0; k < len; k++) req[k / 2] |= (uint16_t)(p[k] << (8 * (k & 1)));
    req_len = len; req_seq++; req_ready = 1; resp_got = 0;
    for (int t = 0; t < max_ms * 5 && !resp_got; t++) { s573wio_poll(); usleep(200); }
    if (!resp_got) { req_ready = 0; return 0; }     /* the game would reset the MCU */
    return resp_len;
}
#define X(dst, ...) ({ const uint8_t pl_[] = { __VA_ARGS__ }; xact(dst, pl_, (int)sizeof(pl_), 50); })
static uint16_t st71(void) { X(1, 0x71); return (uint16_t)(resp[5] << 8 | resp[6]); }   /* E0 00 len st 01 hi lo */
static void idle(int ms) { for (int t = 0; t < ms * 5; t++) { s573wio_poll(); usleep(200); } }

static void boot(void)
{
    int n = X(0xff, 0xf1, 0x01);
    CHECK(n == 6 && resp[3] == 1 && resp[4] == 1, "F1 answered 01 01 through the mailbox");
    idle(5);
    CHECK(flags == 3, "flags: service on + addressed (sense low)");
    n = X(1, 0x70, 0x02, 0x01, 0xc0, 0x00);
    CHECK(n == 6 && resp[4] == 1, "70 02 -> 01 01");
    X(1, 0x73); idle(30);
    CHECK(st71() == 0x0000, "73 + 25 ms -> status 0000");
}

int main(void)
{
    for (int i = 0; i < WIO_CARD_SIZE; i++) mcard[0].data[i] = (uint8_t)(i * 13 + 5);
    wio_vcard_insert(&mcard[0], 1);

    printf("-- G1 off: nothing on the mailbox\n");
    idle(5);
    CHECK(flags == 0, "flags untouched while Off");

    printf("-- G2 SNAC: real-card path through op 3\n");
    st_mode = 2; idle(5);
    CHECK(flags == 1, "flags: service on, unaddressed");
    int n = X(0xff, 0x10);
    CHECK(n == 4 + 49 && !memcmp(resp + 5, "KONAMI CO.,LTD.;White I/O;Ver1.0;White I/O PCB", 46), "ID through the mailbox");
    boot();
    X(1, 0x76, 0x74, 0x00, 0x05, 0x02, 0x00, 0x00, 0x00, 0x01);
    CHECK(resp[3] == 1 && resp[4] == 1 && resp[5] == 1, "76 74 accepted");
    idle(40);
    CHECK(st71() == 0x0000, "read done (FLAG 08h)");
    X(1, 0x70, 0x00, 0x02, 0x00, 0x00, 0x80);
    CHECK(resp_len == 4 + 130 && !memcmp(resp + 5, mcard[0].data + 5 * 128, 128), "frame 5 of the SNAC card in reader RAM");
    X(1, 0x74, 0x80, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01); idle(40);
    CHECK(st71() == 0x0008, "port 2 empty -> 0008");

    printf("-- G3 virtual: blank card created, written, saved\n");
    st_mode = 1; idle(5);
    CHECK(sd_saves[0] == 1 && sd_size[0] == WIO_CARD_SIZE && sd_file[0][0] == 'M' && sd_file[0][1] == 'C' &&
          sd_file[0][127] == 0x0e && sd_file[0][128] == 0xa0, "formatted blank memcard1.mcd (MC, 0Eh, A0h)");
    CHECK(flags == 1, "re-init: unaddressed");
    boot();
    for (int k = 0; k < 128; k++) {
        uint8_t pl[6 + 128] = { 0x70, 0x01, 0x03, 0x00, 0x00, 0x80 };
        (void)k; for (int j = 0; j < 128; j++) pl[6 + j] = (uint8_t)(0x40 + j);
        xact(1, pl, sizeof(pl), 50);
        break;
    }
    CHECK(resp[4] == 1, "70 01 data into reader RAM");
    X(1, 0x75, 0x03, 0x00, 0x00, 0x00, 0x3f, 0x00, 0x01); idle(60);
    CHECK(st71() == 0x0000, "write done");
    idle(700);
    CHECK(sd_saves[0] == 2 && sd_file[0][0x3f * 128] == 0x40 && sd_file[0][0x3f * 128 + 127] == 0x40 + 127, "flushed to memcard1.mcd after 0.5 s");
    st_ej1 = 1; idle(5);
    X(1, 0x74, 0x00, 0x3f, 0x02, 0x00, 0x00, 0x00, 0x01); idle(40);
    CHECK(st71() == 0x0008, "OSD eject -> no card");
    X(1, 0x76); st_ej1 = 0; idle(5);
    X(1, 0x74, 0x00, 0x3f, 0x02, 0x00, 0x00, 0x00, 0x01); idle(40);
    CHECK(st71() == 0x0000, "re-inserted: FLAG back to 08h -> 0000 (a game sees the card change)");

    printf("-- G4 off again: flags cleared\n");
    st_mode = 0; idle(5);
    CHECK(flags == 0, "flags 0 (sense released)");

    printf(fails ? "GLUE: FAIL (%d)\n" : "GLUE: PASS\n", fails);
    return fails != 0;
}
