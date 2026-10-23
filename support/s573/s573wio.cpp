/* -----------------------------------------------------------------------------
 * s573wio.cpp - MiSTer_System573 side of the White I/O memory card reader.
 *
 * Runs inside the s573mp3 service's poll (Main's loop), only while the OSD
 * "573 Card Reader" is not Off:
 *   - takes each JVS packet the 573 hands its MCU (fabric s573_jvs_mcu) through
 *     CMD_573_WIO, runs it through the reader HLE (s573_whiteio.c), answers;
 *   - runs the reader's card jobs: Virtual = 128 KB raw images on the SD card,
 *     SNAC = real PS1 cards through the fabric byte engine (s573_wio_snac.v);
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
    if (FileSave(card_path[i], vc[i].data, WIO_CARD_SIZE)) {
        vc[i].dirty = 0;
        s573_log_ext("s573wio: card %d saved\n", i + 1);
    }
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

    W.now_us = mono_us();
    int n = wio_packet(&W, req, len, resp);
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
    int m = (int)user_io_status_get("[112:111]");
    if (m == 3) m = 0;
    if (m != mode) {
        if (on) { card_flush(0, 1); card_flush(1, 1); wio_flags(0); flags_sent = 0; }
        on = 0; mode = m;
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
            int want = loaded[i] && !user_io_status_get(i ? "[114]" : "[113]");
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
    wio_tick(&W, mono_us(), 1);

    int f = 1 | (wio_sense(&W) ? 0 : 2);
    if (f != flags_sent) { wio_flags(f); flags_sent = f; }
}
