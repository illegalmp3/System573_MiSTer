/* -----------------------------------------------------------------------------
 * s573wio.cpp - MiSTer_System573 side of the White I/O memory card reader.
 *
 * Runs inside the s573mp3 service's poll (Main's loop), only while the OSD
 * "573 Card Reader" is not Off:
 *   - takes each JVS packet the 573 hands its MCU (fabric s573_jvs_mcu) through
 *     CMD_573_WIO, runs it through the reader HLE (s573_whiteio.c), answers;
 *   - runs the reader's card jobs: Virtual = 128 KB raw images on the SD card,
 *     SNAC = real PS1 cards through the fabric byte engine (s573_wio_snac.v);
 *   - Virtual card files: the file mounted from the OSD ("573 Card 1/2 File",
 *     CONF_STR SC2/SC3 -> Main's SD slots 2/3) if there is one, else
 *     saves/System573/memcard1.mcd / memcard2.mcd. Any raw 131,072-byte PS1 card
 *     image works: .mcd, the PSX core's .sav, .mcr. Main keeps the slot's file open
 *     read/write (user_io_file_mount, O_RDWR|O_SYNC); the card is read and written
 *     through that open file (get_image), so no path handling is needed here, and
 *     Main remembers the choice (config/System573.s2 / .s3) for the next launch.
 *   - drives the JVS sense line (addressed / not) via CMD_573_WIO op 4.
 * docs/2026-10-23-memory-card-reader.md has the protocol and the sources.
 *
 * Released under the GNU GPL v2.
 * ---------------------------------------------------------------------------- */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#include "../../spi.h"
#include "../../user_io.h"
#include "../../file_io.h"

#include "s573_whiteio.h"

#define CMD_573_WIO 0x6F

void s573_log_ext(const char *fmt, ...);   /* s573mp3.cpp */

static wio_t       W;
static wio_vcard_t vc[2];
static int         on = 0, mode = 0;       /* 1 Virtual, 2 SNAC */
static int         handled_seq = -1;
static int         flags_sent = -1;
static uint64_t    next_us = 0, dirty_since[2];
static int         loaded[2];
static const char *card_path[2] = { "saves/System573/memcard1.mcd", "saves/System573/memcard2.mcd" };
static fileTYPE   *card_img[2];            /* the OSD-mounted file backing card i, or NULL */
static char        card_key[2][300];       /* what backs card i, to notice an OSD change */

#define CARD_SLOT0 2                       /* Main SD slot of "573 Card 1 File" (SC2) */

/* The OSD-mounted file for card i, if any (opened, whatever its size). */
static fileTYPE *mounted(int i)
{
    fileTYPE *f = get_image(CARD_SLOT0 + i);
    return (f && f->opened() && f->size > 0) ? f : NULL;
}

static void backing_key(int i, char *k, size_t n)
{
    fileTYPE *f = mounted(i);
    if (f) snprintf(k, n, "img:%lld:%s", (long long)f->size, f->name);
    else   snprintf(k, n, "def:%s", card_path[i]);
}

static uint64_t mono_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)(ts.tv_nsec / 1000);
}

/* ---- mailbox ---- */
static uint16_t wio_status(uint16_t *w1)
{
    uint16_t w0 = spi_uio_cmd_cont(CMD_573_WIO);
    uint16_t x  = spi_w(0x0000);
    DisableIO();
    if (w1) *w1 = x;
    return w0;
}

static void wio_flags(int f)
{
    spi_uio_cmd_cont(CMD_573_WIO);
    spi_w((uint16_t)(0x4000 | (f & 3)));
    DisableIO();
}

/* ---- card io: virtual ---- */
static void v_select(void *ctx, int port, int on_) { (void)ctx; if (on_) wio_vcard_select(&vc[port]); }
static int v_xfer(void *ctx, int port, uint8_t tx, int ack_mode, uint8_t *rx)
{
    (void)ctx;
    int ack = wio_vcard_byte(&vc[port], tx, rx);
    if (!vc[port].inserted) *rx = 0xff;         /* nothing drives DAT: pulled up */
    return ack_mode == 0 ? 1 : ack;
}

/* ---- card io: SNAC through s573_wio_snac ---- */
static int snac_cmd(int port, int type, int am, uint8_t tx, uint8_t *rx)
{
    uint16_t w0, w1 = 0;
    spi_uio_cmd_cont(CMD_573_WIO);
    spi_w(0x3000);
    spi_w((uint16_t)(((port & 1) << 15) | ((type & 3) << 13) | ((am & 3) << 11) | tx));
    DisableIO();
    uint64_t lim = mono_us() + 5000;              /* longest primitive: 64 + 2000 + 7 us */
    do { w0 = wio_status(&w1); } while ((w0 & 0x4000) && mono_us() < lim);
    if (rx) *rx = (uint8_t)(w1 >> 8);
    if (w0 & 0x4000) return -3;                   /* engine stuck: treated as no card */
    if (w0 & 0x1000) return -2;
    return (w0 & 0x2000) ? 1 : 0;
}
static void s_select(void *ctx, int port, int on_) { (void)ctx; snac_cmd(port, on_ ? 0 : 1, 0, 0, NULL); }
static int s_xfer(void *ctx, int port, uint8_t tx, int ack_mode, uint8_t *rx)
{
    (void)ctx;
    int r = snac_cmd(port, 2, ack_mode, tx, rx);
    return r == -3 ? 0 : r;
}

static const wio_card_io_t VIO = { v_select, v_xfer, NULL };
static const wio_card_io_t SIO = { s_select, s_xfer, NULL };

/* ---- virtual card images ---- */
/* psx-spx "Memory Card Data Format": a freshly formatted card */
static void format_blank(uint8_t *d)
{
    memset(d, 0, WIO_CARD_SIZE);
    for (int f = 0; f < 64; f++) {
        uint8_t *p = d + f * WIO_FRAME;
        if (f == 0 || f == 63) { p[0] = 'M'; p[1] = 'C'; }
        else if (f <= 15)      { p[0] = 0xa0; p[8] = 0xff; p[9] = 0xff; }
        else if (f <= 35)      { p[0] = p[1] = p[2] = p[3] = 0xff; }
        else                   { memset(p, 0xff, WIO_FRAME); continue; }
        uint8_t c = 0;
        for (int k = 0; k < 127; k++) c ^= p[k];
        p[127] = c;
    }
}

static void card_load(int i)
{
    loaded[i] = 0;
    card_img[i] = NULL;
    backing_key(i, card_key[i], sizeof(card_key[i]));
    fileTYPE *f = mounted(i);
    if (f) {
        if (f->size == WIO_CARD_SIZE && FileSeek(f, 0, SEEK_SET) &&
            FileReadAdv(f, vc[i].data, WIO_CARD_SIZE) == WIO_CARD_SIZE) {
            card_img[i] = f;
            loaded[i] = 1;
            s573_log_ext("s573wio: card %d: %s (mounted from the OSD) loaded\n", i + 1, f->name);
        } else {
            s573_log_ext("s573wio: card %d: %s is %lld bytes, not a raw 131072-byte card -- card %d left out\n",
                         i + 1, f->name, (long long)f->size, i + 1);
        }
        return;
    }
    int sz = FileLoad(card_path[i], 0, 0);
    if (sz == WIO_CARD_SIZE && FileLoad(card_path[i], vc[i].data, WIO_CARD_SIZE) == WIO_CARD_SIZE) {
        loaded[i] = 1;
        s573_log_ext("s573wio: card %d: %s loaded\n", i + 1, card_path[i]);
        return;
    }
    if (sz > 0) {
        s573_log_ext("s573wio: card %d: %s is %d bytes, not 131072 -- not used\n", i + 1, card_path[i], sz);
        return;
    }
    format_blank(vc[i].data);
    FileCreatePath("saves/System573");
    if (FileSave(card_path[i], vc[i].data, WIO_CARD_SIZE)) {
        loaded[i] = 1;
        s573_log_ext("s573wio: card %d: created a formatted blank %s\n", i + 1, card_path[i]);
    }
}

static void card_flush(int i, int force)
{
    if (!vc[i].dirty || !loaded[i]) return;
    if (!force && (W.op.active || mono_us() - dirty_since[i] < 500000)) return;
    if (card_img[i]) {
        if (mounted(i) != card_img[i]) return;        /* the OSD changed it: see s573wio_poll */
        if (FileSeek(card_img[i], 0, SEEK_SET) &&
            FileWriteAdv(card_img[i], vc[i].data, WIO_CARD_SIZE) == WIO_CARD_SIZE) {
            vc[i].dirty = 0;
            s573_log_ext("s573wio: card %d saved to %s\n", i + 1, card_img[i]->name);
        }
        return;
    }
    if (FileSave(card_path[i], vc[i].data, WIO_CARD_SIZE)) {
        vc[i].dirty = 0;
        s573_log_ext("s573wio: card %d saved\n", i + 1);
    }
}

/* ---- trace (2026-10-25: a virtual card with valid link data was not used by
 * DDR Extreme; these lines show what the game asked the reader for) ---- */
static unsigned trace_lines = 0;
#define TRACE_MAX 4000

/* Every command of a request with its parameters (70 01 data omitted, a bare
 * 71 status poll not logged). */
static void trace_request(const uint8_t *req, int len)
{
    if (trace_lines >= TRACE_MAX || len < 5) return;
    char b[400]; int o = 0, only71 = 1;
    const uint8_t *c = req + 3; int n = len - 4;          /* E0 dst len | body | sum */
    for (int i = 0; i < n && o < (int)sizeof(b) - 48; ) {
        uint8_t k = c[i++];
        if (k != 0x71) only71 = 0;
        if (k == 0x70 && i < n) {
            uint8_t sub = c[i++];
            int pn = sub == 2 ? 3 : 4;
            o += snprintf(b + o, sizeof(b) - o, " 70%02x:", sub);
            for (int t = 0; t < pn && i < n; t++) o += snprintf(b + o, sizeof(b) - o, "%02x", c[i++]);
            if (sub == 1 && i <= n) { int dn = c[i - 1]; i += dn; o += snprintf(b + o, sizeof(b) - o, "+%dB", dn); }
            continue;
        }
        if (k == 0x74 || k == 0x75) {
            o += snprintf(b + o, sizeof(b) - o, " %02x:", k);
            for (int t = 0; t < 7 && i < n; t++) o += snprintf(b + o, sizeof(b) - o, "%02x", c[i++]);
            continue;
        }
        o += snprintf(b + o, sizeof(b) - o, " %02x", k);
        if (!(k == 0x71 || k == 0x73 || k == 0x76)) break;   /* anything else: rest not parsed */
    }
    if (only71) return;
    s573_log_ext("s573wio: req%s\n", b);
    trace_lines++;
}

/* The directory the game is about to see: names of the used entries in the 16
 * frames a "frame 0 x16" read put into reader RAM. */
static void trace_dir(int port, uint32_t ram)
{
    if (ram + 16 * WIO_FRAME > WIO_RAM_SIZE) return;
    const uint8_t *d = W.ram + ram;
    char b[600]; int o = 0;
    for (int f = 1; f < 16 && o < (int)sizeof(b) - 48; f++) {
        const uint8_t *e = d + f * WIO_FRAME;
        uint32_t st = (uint32_t)e[0] | ((uint32_t)e[1] << 8) | ((uint32_t)e[2] << 16) | ((uint32_t)e[3] << 24);
        if (st == 0xa0) continue;
        char nm[21]; memcpy(nm, e + 0x0a, 20); nm[20] = 0;
        for (int k = 0; nm[k]; k++) if (nm[k] < 0x20 || nm[k] > 0x7e) nm[k] = '?';
        uint8_t x = 0; for (int k = 0; k < 127; k++) x ^= e[k];
        o += snprintf(b + o, sizeof(b) - o, " [%d %02x %s%s]", f, st & 0xff, nm, x == e[127] ? "" : " BADSUM");
    }
    s573_log_ext("s573wio: card %d directory as read:%s\n", port + 1, o ? b : " (empty)");
}

/* ---- one JVS request ---- */
static void serve_request(uint16_t w0)
{
    uint8_t req[264], resp[264];
    int len = w0 & 0x1ff, nw = (len + 1) / 2;
    if (len < 4 || len > 260) return;
    spi_uio_cmd_cont(CMD_573_WIO);
    uint16_t w1 = spi_w(0x1000);
    for (int k = 0; k < nw; k++) {
        uint16_t w = spi_w(0);
        req[2 * k] = (uint8_t)w; req[2 * k + 1] = (uint8_t)(w >> 8);
    }
    DisableIO();
    int seq = w1 & 0xff;
    if (seq == handled_seq) return;           /* already answered or deliberately not */
    handled_seq = seq;
    trace_request(req, len);

    W.now_us = mono_us();
    int was = W.mode;
    int n = wio_packet(&W, req, len, resp);
    if (was != W.mode) {
        if (W.mode == WIO_FW)
            s573_log_ext("s573wio: program uploaded and started: %s (unpacked CRC-32 %08x)\n",
                         W.fw_ok ? "the ddr4m firmware this HLE models"
                                 : "NOT the modelled firmware -- ddr4m rules applied anyway",
                         (unsigned)W.fw_crc);
        else
            s573_log_ext("s573wio: F0 D9 -- reader rebooted into its boot ROM\n");
    }
    if (W.n_packets <= 8 || (W.n_packets & 1023) == 0)
        s573_log_ext("s573wio: packet %u: cmd %02x len %d -> %d bytes, status %04x\n",
                     W.n_packets, len > 3 ? req[3] : 0, len, n, W.status);
    if (n <= 0) return;                       /* the board does not answer this one */
    spi_uio_cmd_cont(CMD_573_WIO);
    spi_w((uint16_t)(0x2000 | (n & 0x1ff)));
    spi_w((uint16_t)seq);
    for (int k = 0; k < (n + 1) / 2; k++)
        spi_w((uint16_t)(resp[2 * k] | ((2 * k + 1 < n ? resp[2 * k + 1] : 0) << 8)));
    DisableIO();
}

void s573wio_poll(void)
{
    uint64_t t = mono_us();
    int m = (int)user_io_status_get("[117:116]");
    if (m == 3) m = 0;
    if (m != mode) {
        if (on) { card_flush(0, 1); card_flush(1, 1); wio_flags(0); flags_sent = 0; }
        on = 0; mode = m;
        trace_lines = 0;
        if (!m) return;
        memset(vc, 0, sizeof(vc));
        if (m == 1) { card_load(0); card_load(1); }
        wio_init(&W, m == 2 ? &SIO : &VIO);
        handled_seq = -1; flags_sent = -1;
        on = 1;
        s573_log_ext("s573wio: reader on (%s cards)\n", m == 2 ? "SNAC" : "virtual");
    }
    if (!on || t < next_us) return;
    next_us = t + 1000;

    if (mode == 1) {
        for (int i = 0; i < 2; i++) {
            /* A different file chosen (or unmounted) in the OSD = a different card in
               the slot: save what the old one still owes, load the new one, and pull
               the card out for this poll so the game sees FLAG 08h on the new one. */
            char k[sizeof(card_key[0])];
            backing_key(i, k, sizeof(k));
            if (strcmp(k, card_key[i])) {
                if (vc[i].dirty && !card_img[i]) card_flush(i, 1);
                else if (vc[i].dirty)
                    s573_log_ext("s573wio: card %d: unsaved changes to the previous file dropped "
                                 "(it was changed in the OSD within 0.5 s of a write)\n", i + 1);
                vc[i].dirty = 0; dirty_since[i] = 0;
                card_load(i);
                if (vc[i].inserted) {
                    wio_vcard_insert(&vc[i], 0);
                    s573_log_ext("s573wio: card %d ejected (file changed)\n", i + 1);
                }
                continue;
            }
            int want = loaded[i] && !user_io_status_get(i ? "[119]" : "[118]");
            if (want != vc[i].inserted) {
                wio_vcard_insert(&vc[i], want);
                s573_log_ext("s573wio: card %d %s\n", i + 1, want ? "inserted" : "ejected");
            }
            if (vc[i].dirty && !dirty_since[i]) dirty_since[i] = t;
            card_flush(i, 0);
            if (!vc[i].dirty) dirty_since[i] = 0;
        }
    }

    uint16_t w0 = wio_status(NULL);
    if (w0 & 0x8000) serve_request(w0);
    else handled_seq = -1;                    /* answered, or the MCU was reset */
    int busy0 = W.op.active;
    wio_tick(&W, mono_us(), 1);
    if (busy0 && !W.op.active) {
        s573_log_ext("s573wio: card %s port %d frame %03x x%d -> result %d, status %04x\n",
                     W.op.write ? "write" : "read", W.op.port + 1, W.op.frame, W.op.count,
                     W.op.result, W.status);
        if (!W.op.write && W.op.frame == 0 && W.op.count >= 16 && W.op.result >= 0)
            trace_dir(W.op.port, W.op.ram);
    }

    int f = 1 | (wio_sense(&W) ? 0 : 2);
    if (f != flags_sent) { wio_flags(f); flags_sent = f; }
}
