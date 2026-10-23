/* -----------------------------------------------------------------------------
 * s573_whiteio.c - White I/O (GE885-PWB(A)) memory card reader HLE.
 *
 * Every rule below names the routine it reproduces: boot ROM addresses are the
 * byte-swapped 885a01.bin disassembled at 0xbfc00000; firmware addresses are the
 * DDR 4thMIX program as unpacked to 0x80000000. Evidence and the list of what is
 * NOT derived (timing constants) are in docs/2026-10-23-memory-card-reader.md.
 *
 * Released under the GNU GPL v2.
 * ---------------------------------------------------------------------------- */
#include <string.h>
#include "s573_whiteio.h"

/* "KONAMI CO.,LTD.;White I/O;Ver1.0;White I/O PCB" + NUL: 0x10 copies 0x2f bytes
 * (fw 0x80001934 from gp-0x7f80 = 0x80005fb0; boot ROM 0xbfc012b0 from gp-0x8000) */
static const char WIO_ID[0x2f] = "KONAMI CO.,LTD.;White I/O;Ver1.0;White I/O PCB";

/* CRC-32 of the program the ddr4m stub unpacks to 0x80000000 (24720 bytes;
 * SHA-1 1a585688e78ff513362ebf3356ecd76173bd0909). */
#define WIO_FW_DDR4M_CRC  0x08844237u
#define WIO_FW_DDR4M_LEN  24720u

uint32_t wio_crc32(const uint8_t *p, uint32_t n)
{
    uint32_t c = 0xffffffffu;
    while (n--) {
        c ^= *p++;
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320u & (0u - (c & 1u)));
    }
    return ~c;
}

/* The LZSS both the stub (0x8001c020) and the firmware's FPGA loader (0x800051e0)
 * use: flag byte LSB first, 1 = literal; else b0 b1: offset = (b0&0xf0)<<4 | b1,
 * length = (b0&0x0f)+3, offset 0 ends. Bounded here; the original is not. */
static int wio_unlz(const uint8_t *src, uint32_t srcn, uint8_t *dst, uint32_t dstn)
{
    uint32_t i = 0, o = 0;
    for (;;) {
        if (i >= srcn) return -1;
        uint8_t flags = src[i++];
        for (int b = 0; b < 8; b++, flags >>= 1) {
            if (flags & 1) {
                if (i >= srcn || o >= dstn) return -1;
                dst[o++] = src[i++];
            } else {
                if (i + 1 >= srcn) return -1;
                uint32_t off = ((uint32_t)(src[i] & 0xf0) << 4) | src[i + 1];
                uint32_t len = (src[i] & 0x0f) + 3u;
                i += 2;
                if (off == 0) return (int)o;
                if (off > o || o + len > dstn) return -1;
                while (len--) { dst[o] = dst[o - off]; o++; }
            }
        }
    }
}

void wio_init(wio_t *w, const wio_card_io_t *io)
{
    memset(w, 0, sizeof(*w));
    if (io) w->io = *io;
    wio_power_on(w);
}

/* Boot ROM state. F0 D9 in either program arms the TX3904 watchdog and spins
 * (fw 0x80003df0, boot 0xbfc01ba4), i.e. the board reboots into the boot ROM:
 * address and sense are released, the firmware is gone. */
void wio_power_on(wio_t *w)
{
    w->mode = WIO_BOOT;
    w->addr = 0xff;
    w->status = 0;
    w->fw_ok = 0;
    w->op.active = 0; w->fpga_active = 0; w->plate_active = 0;
    w->prev[0] = 1; w->prev[1] = 1; w->prev_len = 2;   /* fw 0x800033e0 */
}

int wio_sense(const wio_t *w) { return w->addr == 0xff; }

/* ---------------------------------------------------------------- packets -- */
typedef struct {
    const uint8_t *in; int n, i;     /* command bytes, length, read index */
    uint8_t *out; int o;             /* out[0] = status byte; reports from 1 */
} pkt_t;

static void rep(pkt_t *p, uint8_t b) { if (p->o < 0xfe) p->out[p->o] = b; p->o++; }
static uint32_t be24(const uint8_t *b) { return ((uint32_t)b[0] << 16) | ((uint32_t)b[1] << 8) | b[2]; }
static uint32_t be16(const uint8_t *b) { return ((uint32_t)b[0] << 8) | b[1]; }

/* 0x70 0x00 a24 n8 / 0x70 0x01 a24 n8 data: fw 0x80001a88 / 0x80001b74,
 * boot 0xbfc01398 / 0xbfc01440 (same checks): 1 <= n <= 0x80, a+n <= 0x80000. */
static void c_ram_read(wio_t *w, pkt_t *p)
{
    if (p->i + 4 > p->n) { p->i = p->n; rep(p, 2); return; }
    uint32_t a = be24(p->in + p->i); uint32_t n = p->in[p->i + 3];
    p->i += 4;
    if (n - 1u >= 0x80u || a + n > WIO_RAM_SIZE) { rep(p, 2); return; }
    rep(p, 1);
    for (uint32_t k = 0; k < n; k++) rep(p, w->ram[a + k]);
}

static void c_ram_write(wio_t *w, pkt_t *p)
{
    if (p->i + 4 > p->n) { p->i = p->n; rep(p, 2); return; }
    uint32_t a = be24(p->in + p->i); uint32_t n = p->in[p->i + 3];
    p->i += 4;
    if (n - 1u < 0x80u && a + n <= WIO_RAM_SIZE && p->i + (int)n <= p->n) {
        memcpy(w->ram + a, p->in + p->i, n);
        rep(p, 1);
    } else rep(p, 2);
    p->i += (int)n;            /* fw 0x80001c70: consumed on both paths */
}

/* What the boot ROM's 70 02 hands control to. The ddr4m container's first record
 * is a 0xb0-byte stub at 0x1c000 that unpacks 0x80020000 -> 0x80000000 and jumps
 * to 0x80000010 (a0 = the JVS address). Unpack the same way and identify it. */
static void boot_exec(wio_t *w, uint32_t a)
{
    static uint8_t tmp[WIO_RAM_SIZE];
    w->mode = WIO_FW;
    w->fw_crc = 0; w->fw_ok = 0;
    if (a == 0x1c000u) {
        int n = wio_unlz(w->ram + 0x20000u, WIO_RAM_SIZE - 0x20000u, tmp, 0x18000u);
        if (n > 0) {
            w->fw_crc = wio_crc32(tmp, (uint32_t)n);
            w->fw_ok = (w->fw_crc == WIO_FW_DDR4M_CRC && (uint32_t)n == WIO_FW_DDR4M_LEN);
        }
    }
    /* firmware init (0x8000186c): all job states idle, passwords zero, status 1 */
    w->status = WIO_ST_FPGA_NOT_READY;
    memset(w->pw, 0, sizeof(w->pw));
    w->op.active = 0; w->fpga_active = 0; w->plate_active = 0;
    w->prev[0] = 1; w->prev[1] = 1; w->prev_len = 2;
}

/* boot ROM dispatcher 0xbfc010d4 */
static int boot_cmds(wio_t *w, pkt_t *p, uint32_t *exec)
{
    while (p->i < p->n) {
        int c = p->in[p->i++];
        if (c == 0x70) {
            if (p->i >= p->n) { rep(p, 2); return 1; }        /* 0xbfc01158 */
            c = 0x7000 | p->in[p->i++];
        }
        switch (c) {
        case 0x10: rep(p, 1); for (int k = 0; k < 0x2f; k++) rep(p, (uint8_t)WIO_ID[k]); break;
        case 0x11: rep(p, 1); rep(p, 0x11); break;
        case 0x12: rep(p, 1); rep(p, 0x20); break;
        case 0x13: rep(p, 1); rep(p, 0x10); break;
        case 0x14: rep(p, 1); rep(p, 0x00); break;
        case 0x2f: return -1;
        case 0xf0:                                            /* 0xbfc0121c */
            if (p->i < p->n && p->in[p->i] == 0xd9) { wio_power_on(w); return 0; }
            return 0;
        case 0xf1:                                            /* 0xbfc01248 */
            /* needs the downstream sense high (we are the last device) and no
             * address yet; then drives our sense output low and answers 01 */
            if (p->i >= p->n || w->addr != 0xff) return 0;
            w->addr = p->in[p->i++];
            rep(p, 1);
            break;
        case 0x7000: c_ram_read(w, p); break;
        case 0x7001: c_ram_write(w, p); break;
        case 0x7002: {                                        /* 0xbfc01504 */
            if (p->i + 3 > p->n) { p->i = p->n; rep(p, 2); break; }
            uint32_t a = be24(p->in + p->i); p->i += 3;
            /* only as the packet's sole command (payload length 5) */
            if (a <= 0x7ffffu && !(a & 3u) && p->n == 5) { *exec = a; rep(p, 1); }
            else rep(p, 2);
            break;
        }
        default:                                              /* 0xbfc01588 */
            /* status 2; the ROM also bumps the length over a byte it never writes */
            if (p->o < 0xfe) p->out[p->o] = 0;
            p->o++;
            if (p->o >= 0xff) { p->out[0] = 4; return 1; }
            p->out[0] = 2; return 2;
        }
    }
    return 1;
}

/* ---- firmware jobs ---- */
static void card_start(wio_t *w, int write, int port, int frame, int count, uint32_t ram)
{
    w->op.active = 1; w->op.write = write; w->op.port = port; w->op.frame = frame;
    w->op.count = count; w->op.ram = ram; w->op.i = 0; w->op.s3 = 0; w->op.result = 0;
    w->op.done_us = w->now_us;
    w->status |= write ? WIO_ST_CARD_WRITING : WIO_ST_CARD_READING;
    w->n_card_ops++;
}

/* firmware command dispatcher 0x80002ef4 (one command after another until the
 * packet is used up; returns the body length, 0 = no answer, -1 = resend) */
static int fw_cmds(wio_t *w, pkt_t *p)
{
    while (p->i < p->n) {
        int c = p->in[p->i++];
        if (c == 0x70 || c == 0x72) {
            if (p->i >= p->n) { rep(p, 2); goto done; }       /* 0x80002fcc */
            c = (c << 8) | p->in[p->i++];
        }
        const uint8_t *a = p->in + p->i;
        int left = p->n - p->i;
        switch (c) {
        case 0xf0:                                            /* 0x800018b8 */
            if (p->i < p->n && p->in[p->i] == 0xd9) {
                p->i++;
                if (!(w->status & (WIO_ST_CARD_READING | WIO_ST_CARD_WRITING))) wio_power_on(w);
            }
            return 0;
        case 0xf1: return 0;                                  /* 0x800030d8 */
        case 0x10: rep(p, 1); for (int k = 0; k < 0x2f; k++) rep(p, (uint8_t)WIO_ID[k]); break;
        case 0x11: rep(p, 1); rep(p, 0x11); break;
        case 0x12: rep(p, 1); rep(p, 0x20); break;
        case 0x13: rep(p, 1); rep(p, 0x10); break;
        case 0x14: rep(p, 1); rep(p, 0x00); break;
        case 0x2f: return -1;
        case 0x7000: c_ram_read(w, p); break;
        case 0x7001: c_ram_write(w, p); break;
        case 0x7002:                                          /* 0x80001c80 */
            /* starts a task at the address. Only the boot ROM's 70 02 is used by
             * DDR; running uploaded code is out of an HLE's reach: logged, acked. */
            if (left < 3) { p->i = p->n; rep(p, 2); break; }
            p->i += 3;
            if (be24(a) > 0x7ffffu || (be24(a) & 3u)) rep(p, 2);
            else { w->log_unknown++; rep(p, 1); }
            break;
        case 0x71:                                            /* 0x80001d88 */
            rep(p, 1); rep(p, (uint8_t)(w->status >> 8)); rep(p, (uint8_t)w->status);
            break;
        case 0x73:                                            /* 0x80002918 */
            if ((w->status & 0x101) == 1) {
                w->fpga_active = 1;
                /* NOT DERIVED: unpacking + 95,744 bit-banged bits; see the doc */
                w->fpga_done_us = w->now_us + 20000;
                w->status |= WIO_ST_FPGA_BUSY;
                rep(p, 1);
            } else rep(p, 4);
            break;
        case 0x74: case 0x75: {                               /* 0x80002a58 / 0x80002bdc */
            if (left < 7) { p->i = p->n; rep(p, 2); break; }
            if (w->status & 0x061f) { rep(p, 4); break; }    /* params not consumed */
            p->i += 7;
            uint32_t pf, ram;
            if (c == 0x74) { pf = be16(a);     ram = be24(a + 2); }
            else           { ram = be24(a);    pf = be16(a + 3); }
            uint32_t n = be16(a + 5);
            int port = (int)(pf >> 15), frame = (int)(pf & 0x7fff);
            if (n == 0 || frame + (int)n > 0x400 || ram + n * 128u > WIO_RAM_SIZE) { rep(p, 2); break; }
            card_start(w, c == 0x75, port, frame, (int)n, ram);
            rep(p, 1);
            break;
        }
        case 0x76:                                            /* 0x80002d60 */
            if (w->status & (WIO_ST_CARD_READING | WIO_ST_CARD_WRITING)) { rep(p, 4); break; }
            w->status &= 0xffe1;
            rep(p, 1);
            break;
        /* security dongle ("plate") slots: 0x72 sub|slot. DDR 4thMIX never sends
         * these (its requests are only enqueued with types 2..4, see the doc), and
         * no dongle is fitted here: each accepted op completes with the result the
         * firmware's X76F041 probe gives when nothing answers (-2 -> 0x0020). */
        case 0x7200: case 0x7201:                             /* 0x80001de4 */
            if (w->status & WIO_ST_PLATE_BUSY) { rep(p, 4); break; }
            w->status = (uint16_t)((w->status & 0xff9f) | WIO_ST_PLATE_BUSY);
            w->plate_active = 1; w->plate_done_us = w->now_us + 1000;
            rep(p, 1);
            break;
        case 0x7210: case 0x7211:                             /* 0x80001ea8 */
            if (left < 8) { p->i = p->n; rep(p, 2); break; }
            /* busy: report 4 and leave the 8 parameter bytes UNCONSUMED -- the
             * firmware then parses them as commands (true of every 72 xx / 74 / 75
             * busy path: the index is only advanced after the busy check) */
            if (w->status & WIO_ST_PLATE_BUSY) { rep(p, 4); break; }
            memcpy(w->pw[c & 1], a, 8); p->i += 8;
            w->status &= (uint16_t)~WIO_ST_PLATE_PWERR;
            rep(p, 1);
            break;
        case 0x7220: case 0x7221: case 0x7230: case 0x7231: { /* 0x80001fe4 / 0x80002174 */
            if (left < 7) { p->i = p->n; rep(p, 2); break; }
            if (w->status & 0x7860) { rep(p, 4); break; }    /* params not consumed */
            p->i += 7;
            uint32_t off, ram, n = be16(a + 5);
            if ((c & 0xfff0) == 0x7220) { off = be16(a); ram = be24(a + 2); }
            else                        { ram = be24(a); off = be16(a + 3); }
            if (n == 0 || off + n > 0x200 || ram + n > WIO_RAM_SIZE ||
                ((c & 0xfff0) == 0x7230 && ((off | n) & 7))) { rep(p, 2); break; }
            w->status |= WIO_ST_PLATE_RW;
            w->plate_active = 1; w->plate_done_us = w->now_us + 1000;
            rep(p, 1);
            break;
        }
        case 0x7240: case 0x7241: case 0x7250: case 0x7251:  /* 0x8000231c / 0x80002474 */
            if (left < 3) { p->i = p->n; rep(p, 2); break; }
            if (w->status & 0x7860) { rep(p, 4); break; }    /* params not consumed */
            p->i += 3;
            if (be24(a) + 5 > WIO_RAM_SIZE) { rep(p, 2); break; }
            w->status |= WIO_ST_PLATE_CFG;
            w->plate_active = 1; w->plate_done_us = w->now_us + 1000;
            rep(p, 1);
            break;
        case 0x7260: case 0x7261:                             /* 0x800025cc */
            if (w->status & 0x7860) { rep(p, 4); break; }
            w->status |= WIO_ST_PLATE_MASS;
            w->plate_active = 1; w->plate_done_us = w->now_us + 1000;
            rep(p, 1);
            break;
        case 0x7270: case 0x7271:                             /* 0x8000269c */
            if (left < 8) { p->i = p->n; rep(p, 2); break; }
            if (w->status & 0x7860) { rep(p, 4); break; }    /* params not consumed */
            p->i += 8;
            w->status |= WIO_ST_PLATE_PW;
            w->plate_active = 1; w->plate_done_us = w->now_us + 1000;
            rep(p, 1);
            break;
        default:                                              /* 0x80003300 */
            if (p->o >= 0xff) { p->out[0] = 4; return 1; }
            p->out[0] = 2;
            return p->o;
        }
    }
done:
    if (p->o >= 0xff) { p->out[0] = 4; return 1; }            /* 0x8000332c */
    p->out[0] = 1;
    return p->o;
}

int wio_packet(wio_t *w, const uint8_t *req, int len, uint8_t *resp)
{
    uint8_t body[260];
    w->n_packets++;
    /* the board's receive ISR (fw 0x80003614): E0 sync, dst 0xff or ours, length
     * byte, then length bytes (payload + checksum). The 573's MCU has already
     * unescaped D0 xx. */
    if (len < 4 || req[0] != 0xe0) return 0;
    uint8_t dst = req[1], n = req[2];
    if (dst != 0xff && dst != w->addr) return 0;
    if (n < 1 || 3 + n > len) return 0;
    const uint8_t *pl = req + 3;
    int np = n - 1;
    /* checksum = dst + len + payload (fw 0x80002f1c); bad: no answer to a
     * broadcast, else status 3 */
    uint8_t s = (uint8_t)(dst + n);
    for (int k = 0; k < np; k++) s = (uint8_t)(s + pl[k]);
    int bl;
    if (s != pl[np]) {
        if (dst == 0xff) return 0;
        body[0] = 3; bl = 1;                 /* answered, and kept for a 0x2f */
        memcpy(w->prev, body, 1); w->prev_len = 1;
    } else {
        pkt_t p = { pl, np, 0, body, 1 };
        body[0] = 1;
        if (w->mode == WIO_BOOT) {
            uint32_t exec = 0xffffffffu;
            int r = boot_cmds(w, &p, &exec);
            if (r == 0) return 0;
            if (r < 0) bl = 0;           /* boot 0x2f: same resend as the firmware */
            else {
                if (p.o >= 0xff) { body[0] = 4; p.o = 1; }
                bl = p.o;
            }
            if (bl > 0) { memcpy(w->prev, body, (size_t)bl); w->prev_len = bl; }
            if (exec != 0xffffffffu) boot_exec(w, exec);   /* after the answer is out */
            if (r < 0) { memcpy(body, w->prev, (size_t)w->prev_len); bl = w->prev_len; }
        } else {
            int r = fw_cmds(w, &p);
            if (r == 0) return 0;
            if (r < 0) { memcpy(body, w->prev, (size_t)w->prev_len); bl = w->prev_len; }
            else { bl = r; memcpy(w->prev, body, (size_t)bl); w->prev_len = bl; }
        }
    }
    /* answer frame (fw 0x80003c5c): E0 00 len body sum, sum over 00 len body */
    resp[0] = 0xe0; resp[1] = 0x00; resp[2] = (uint8_t)(bl + 1);
    uint8_t c = (uint8_t)(bl + 1);
    for (int k = 0; k < bl; k++) { resp[3 + k] = body[k]; c = (uint8_t)(c + body[k]); }
    resp[3 + bl] = c;
    return bl + 4;
}

/* ------------------------------------------------------------- card algo -- */
/* one byte, fw 0x8000560c; virtual cost per byte (see .h) */
static int xb(wio_t *w, int port, uint8_t tx, int ack_mode, int *rx)
{
    uint8_t r = 0xff;
    w->cost_us += WIO_US_PER_BYTE + (ack_mode == 2 ? WIO_US_LATE_ACK : 0);
    int a = w->io.xfer ? w->io.xfer(w->io.ctx, port, tx, ack_mode, &r) : 0;
    if (a == -2) return -2;
    if (a == 0) return -1;
    *rx = r;
    return 0;
}

/* 0x800057d0 / 0x80005a24: the next transaction waits until 0x325a9 timer ticks
 * have passed since the last write finished; 12.5 ms at the inferred 16.5 MHz */
static void post_write_wait(wio_t *w)
{
    uint64_t t = w->op.done_us + w->cost_us, ready = w->last_write_us + 12500;
    if (w->last_write_us && t < ready) w->cost_us += ready - t;
}

static void sel(wio_t *w, int port, int on) { if (w->io.select) w->io.select(w->io.ctx, port, on); }

/* fw 0x8000579c: read one frame. 0 ok, -3 ok but FLAG was 04h, -1/-2 failure */
static int rd_frame(wio_t *w, int port, int frame, uint8_t *buf)
{
    int rx = 0, flag, msb = (frame >> 8) & 0xff, lsb = frame & 0xff, r;
    post_write_wait(w);
    sel(w, port, 0); sel(w, port, 1);
    if ((r = xb(w, port, 0x81, 1, &rx)) < 0) { sel(w, port, 0); return r; }
    if (xb(w, port, 0x52, 1, &flag) < 0) goto err;
    if (flag != 0x00 && flag != 0x04 && flag != 0x08) goto err;
    if (xb(w, port, 0, 1, &rx) < 0 || rx != 0x5a) goto err;
    if (xb(w, port, 0, 1, &rx) < 0 || rx != 0x5d) goto err;
    if (xb(w, port, (uint8_t)msb, 1, &rx) < 0 || rx != 0) goto err;
    if (xb(w, port, (uint8_t)lsb, 1, &rx) < 0) goto err;
    if (xb(w, port, 0, 2, &rx) < 0 || rx != 0x5c) goto err;
    if (xb(w, port, 0, 1, &rx) < 0 || rx != 0x5d) goto err;
    if (xb(w, port, 0, 1, &rx) < 0 || rx != msb) goto err;
    if (xb(w, port, 0, 1, &rx) < 0 || rx != lsb) goto err;
    for (int k = 0; k < WIO_FRAME; k++) {
        if (xb(w, port, 0, 1, &rx) < 0) goto err;
        buf[k] = (uint8_t)rx;
    }
    if (xb(w, port, 0, 1, &rx) < 0) goto err;    /* checksum: read, NOT compared */
    if (xb(w, port, 0, 0, &rx) < 0 || rx != 0x47) goto err;
    sel(w, port, 0);
    w->cflag[port] = (flag != 0x08);
    return flag == 0x04 ? -3 : 0;
err:
    sel(w, port, 0);
    return -2;
}

/* fw 0x800059f0: write one frame */
static int wr_frame(wio_t *w, int port, int frame, const uint8_t *buf)
{
    int rx = 0, flag, msb = (frame >> 8) & 0xff, lsb = frame & 0xff, r;
    uint8_t chk;
    post_write_wait(w);
    sel(w, port, 0); sel(w, port, 1);
    if ((r = xb(w, port, 0x81, 1, &rx)) < 0) { sel(w, port, 0); return r; }
    if (xb(w, port, 0x57, 1, &flag) < 0) goto err;
    if (flag != 0x00 && flag != 0x04 && flag != 0x08) goto err;
    if (xb(w, port, 0, 1, &rx) < 0 || rx != 0x5a) goto err;
    if (xb(w, port, 0, 1, &rx) < 0 || rx != 0x5d) goto err;
    if (xb(w, port, (uint8_t)msb, 1, &rx) < 0) goto err;
    if (xb(w, port, (uint8_t)lsb, 1, &rx) < 0) goto err;
    chk = (uint8_t)(msb ^ lsb);
    for (int k = 0; k < WIO_FRAME; k++) {
        if (xb(w, port, buf[k], 1, &rx) < 0) goto err;
        chk ^= buf[k];
    }
    if (xb(w, port, chk, 1, &rx) < 0) goto err;
    if (xb(w, port, 0, 1, &rx) < 0 || rx != 0x5c) goto err;
    if (xb(w, port, 0, 1, &rx) < 0 || rx != 0x5d) goto err;
    if (xb(w, port, 0, 0, &rx) < 0 || rx != 0x47) goto err;
    sel(w, port, 0);
    w->last_write_us = w->op.done_us + w->cost_us;   /* virtual clock: op step start + cost */
    w->cflag[port] = (flag != 0x08);
    return flag == 0x04 ? -3 : 0;
err:
    sel(w, port, 0);
    return -2;
}

/* fw 0x80005c24 / 0x80005cec: five tries; -1 only if every try got no /ACK on
 * the very first byte (s2 sums (result & 1)) */
static int rd_retry(wio_t *w, int port, int frame, uint8_t *buf)
{
    int nack = 0;
    for (int t = 0; t < 5; t++) {
        int r = rd_frame(w, port, frame, buf);
        if (r == 0 || r == -3) return r;
        nack += r & 1;
        w->cost_us += 30 + 50u * (unsigned)t;     /* 0x800003f0(30 + 50t) */
    }
    return nack == 5 ? -1 : -2;
}

static int wr_retry(wio_t *w, int port, int frame, const uint8_t *buf)
{
    int nack = 0;
    for (int t = 0; t < 5; t++) {
        int r = wr_frame(w, port, frame, buf);
        if (r == 0 || r == -3) return r;
        nack += r & 1;
        w->cost_us += 1000u * (13u + 3u * (unsigned)t);   /* 0x80000434(13 + 3t) */
    }
    return nack == 5 ? -1 : -2;
}

/* One frame of the current op (fw 0x80005270 read / 0x80005370 write). Returns
 * 1 while more frames remain. */
static int op_step(wio_t *w)
{
    int i = w->op.i, port = w->op.port;
    uint8_t *ram = w->ram + w->op.ram + (uint32_t)i * WIO_FRAME;
    if (!w->op.write) {
        int r = rd_retry(w, port, w->op.frame + i, ram);
        if (r == -1) { w->op.result = i ? -2 : -1; return 0; }
        if (r == -2) { w->op.result = -2; return 0; }
        if (i == 0) w->op.s3 = w->cflag[port];
        if (++w->op.i < w->op.count) return 1;
        w->op.result = w->op.s3;
        return 0;
    } else {
        if (i < w->op.count) {
            int r = wr_retry(w, port, w->op.frame + i, ram);
            if (r == -1 && i) r = -2;
            if (r < 0) { w->op.result = r; return 0; }
            if (i == 0) w->op.s3 = w->cflag[port];
            w->op.i++;
            return 1;               /* the closing frame-0 read comes next */
        }
        uint8_t tmp[WIO_FRAME];
        int r = rd_retry(w, port, 0, tmp);
        w->op.result = r >= 0 ? w->op.s3 : (r == -1 ? -2 : r);
        return 0;
    }
}

/* completion, fw 0x80002e04: status = (status & 0x79ff) | code[1 - result] */
static void op_finish(wio_t *w)
{
    static const uint16_t code[6] = { 0x8000, 0x0000, 0x0008, 0x0002, 0x0010, 0x0004 };
    int r = w->op.result;
    if (w->op.write && r == -2) r = -4;
    if (r > 1 || r < -4) r = -2;
    w->status = (uint16_t)((w->status & 0x79ff) | code[1 - r]);
    w->op.active = 0;
}

void wio_tick(wio_t *w, uint64_t now_us, int max_frames)
{
    w->now_us = now_us;
    if (w->mode != WIO_FW) return;
    if (w->fpga_active && now_us >= w->fpga_done_us) {        /* 0x800029d4, result 0 */
        w->fpga_active = 0;
        w->status &= 0xfefe;
    }
    if (w->plate_active && now_us >= w->plate_done_us) {      /* 0x800027e0, result -2 */
        w->plate_active = 0;
        w->status = (uint16_t)((w->status & 0x87ff) | WIO_ST_PLATE_NODEV);
    }
    /* op.active: 1 = frames left to run, 2 = result known, completing at done_us.
     * Frames run no earlier than the virtual clock says the previous one ended. */
    while (w->op.active == 1 && max_frames-- > 0 && w->op.done_us <= now_us) {
        w->cost_us = 0;
        int more = op_step(w);
        w->op.done_us += w->cost_us;
        if (!more) w->op.active = 2;
    }
    if (w->op.active == 2 && w->op.done_us <= now_us) op_finish(w);
}

/* -------------------------------------------------------------- vcard -- */
void wio_vcard_insert(wio_vcard_t *c, int inserted)
{
    if (inserted && !c->inserted) c->flag = 0x08;   /* psx-spx FLAG: 08h on insertion */
    c->inserted = inserted;
    c->idx = 0; c->abort = 1;
}

void wio_vcard_select(wio_vcard_t *c) { c->idx = 0; c->abort = 0; c->cmd = 0; }

/* psx-spx byte tables. Returns 1 if the card pulls /ACK after this byte. */
int wio_vcard_byte(wio_vcard_t *c, uint8_t tx, uint8_t *rx)
{
    int i = c->idx++;
    uint8_t pre = c->last_tx;
    c->last_tx = tx;
    *rx = 0xff;
    if (!c->inserted || c->abort) return 0;
    if (i == 0) {
        if (tx != 0x81) { c->abort = 1; return 0; }
        return 1;                                        /* reply N/A (Hi-Z) */
    }
    if (i == 1) {
        *rx = c->flag;
        if (tx == 0x52 || tx == 0x57 || tx == 0x53) { c->cmd = tx; return 1; }
        c->abort = 1; return 0;                          /* invalid command */
    }
    if (c->cmd == 0x52) {                                /* read */
        switch (i) {
        case 2: *rx = 0x5a; return 1;
        case 3: *rx = 0x5d; return 1;
        case 4: c->sector = (uint16_t)(tx << 8); *rx = 0x00; return 1;
        case 5: c->sector |= tx; *rx = pre; return 1;
        case 6: *rx = 0x5c; return 1;
        case 7: *rx = 0x5d; return 1;
        case 8:
            if (c->sector > 0x3ff) { *rx = 0xff; return 1; }
            *rx = (uint8_t)(c->sector >> 8); c->chk = *rx; return 1;
        case 9:
            if (c->sector > 0x3ff) { *rx = 0xff; c->abort = 1; return 0; }  /* Sony: abort */
            *rx = (uint8_t)c->sector; c->chk ^= *rx; return 1;
        default:
            if (i < 10 + WIO_FRAME) {
                *rx = c->data[(uint32_t)c->sector * WIO_FRAME + (uint32_t)(i - 10)];
                c->chk ^= *rx; return 1;
            }
            if (i == 10 + WIO_FRAME) { *rx = c->chk; return 1; }
            if (i == 11 + WIO_FRAME) { *rx = 0x47; return 0; }  /* end byte: no /ACK */
            return 0;
        }
    }
    if (c->cmd == 0x57) {                                /* write */
        switch (i) {
        case 2: *rx = 0x5a; return 1;
        case 3: *rx = 0x5d; return 1;
        case 4: c->sector = (uint16_t)(tx << 8); c->chk = tx; *rx = 0x00; return 1;
        case 5: c->sector |= tx; c->chk ^= tx; *rx = pre; return 1;
        default:
            if (i < 6 + WIO_FRAME) { c->wbuf[i - 6] = tx; c->chk ^= tx; *rx = pre; return 1; }
            if (i == 6 + WIO_FRAME) { c->chk ^= tx; *rx = pre; return 1; }  /* chk ^ CHK == 0 if good */
            if (i == 7 + WIO_FRAME) { *rx = 0x5c; return 1; }
            if (i == 8 + WIO_FRAME) { *rx = 0x5d; return 1; }
            if (i == 9 + WIO_FRAME) {
                if (c->sector > 0x3ff) { *rx = 0xff; return 0; }
                if (c->chk != 0) { *rx = 0x4e; return 0; }
                memcpy(c->data + (uint32_t)c->sector * WIO_FRAME, c->wbuf, WIO_FRAME);
                c->flag &= (uint8_t)~0x08;               /* bit3 cleared by a write */
                c->dirty = 1;
                *rx = 0x47; return 0;
            }
            return 0;
        }
    }
    if (c->cmd == 0x53) {                                /* get ID (Sony) */
        static const uint8_t id[8] = { 0x5a, 0x5d, 0x5c, 0x5d, 0x04, 0x00, 0x00, 0x80 };
        if (i - 2 < 8) { *rx = id[i - 2]; return i - 2 < 7; }
        return 0;
    }
    return 0;
}
