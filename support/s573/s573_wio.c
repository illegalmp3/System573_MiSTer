/*
 * s573_wio.c -- GE885-PWB(A) "White I/O" board: TMPR3904F peripherals + board logic.
 *
 * Sources, by block (details in docs/2026-10-26-white-io-reader.md):
 *  - TMPR3904F user's manual Rev 2.0: register map (ch.5), CConR (5.3), DMAC (ch.10),
 *    IRC (ch.11), SIO (ch.12), timers (ch.13), PIO (ch.14).
 *  - GDB sim/mips dv-tx3904{irc,tmr,sio}.c (Cygnus' models of the same chip) where
 *    the manual leaves behaviour implicit.
 *  - The board wiring (PIO pins, FPGA registers, clock) from Konami's boot ROM
 *    885a01 and the program DDR uploads (CRC-32 08844237); each item below names
 *    the code address it was read from.
 */
#include "s573_wio.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

/* ---------------------------------------------------------------- helpers */

static uint32_t crc32_buf(const uint8_t *p, size_t n)
{
    uint32_t c = 0xffffffffu;
    size_t i;
    int k;
    for (i = 0; i < n; i++) {
        c ^= p[i];
        for (k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320u & (0u - (c & 1)));
    }
    return ~c;
}

#define NSRC 16
/* IRC source numbers (manual table 11-1) */
#define SRC_INT7  6
#define SRC_DMA3  7
#define SRC_DMA2  8
#define SRC_DMA1  9
#define SRC_DMA0  10
#define SRC_SIO0  11
#define SRC_SIO1  12
#define SRC_TMR0  13

typedef struct {
    uint32_t tcr, tisr, cpra, cprb, itmr, ccdr, pgmr, wtmr;
    uint32_t cnt;          /* counter value at 'base'                    */
    uint64_t base;         /* cycle the counter value was captured       */
    uint64_t ev;           /* next compare match (UINT64_MAX = none)     */
} tmr_t;

typedef struct {
    uint32_t lcr, lsr, dicr, disr, fcr, bgr;
    uint8_t  rxf[8]; int rxn, rxr;      /* receive FIFO                */
    uint8_t  txf[8]; int txn, txr;      /* transmit FIFO               */
    int      tx_busy; uint8_t tx_byte;  /* transmit shift register     */
    uint64_t tx_done;                   /* stop bit end                */
} sio_t;

typedef struct {
    uint32_t ccr, csr, sar, dar, bcr, ncr;
} dma_t;

#define RXQ 2048

struct wio {
    wio_host_t h;
    wio_cpu_t  cpu;
    uint8_t    ram[WIO_RAM_SIZE];
    uint8_t    rom[WIO_ROM_SIZE];
    int        rom_ok;
    wio_stats_t st;

    /* IRC */
    uint32_t ilr[4], imr;
    uint32_t req;            /* bit n: source n requesting */
    int      cur;            /* source being informed, -1 none */

    /* chip configuration + bus controller registers kept as storage */
    uint32_t ccfg;
    struct { uint32_t a, v; } store[96];
    int      nstore;

    uint32_t pdat[3], pdir[3];
    tmr_t    tmr[3];
    sio_t    sio[2];
    dma_t    dma[4];

    /* FPGA */
    struct {
        int      state;      /* 0 cleared, 1 loading, 2 configured */
        uint32_t bits, sr, lc;
        int      pre_at;     /* bit index where the preamble begins, -1 unknown */
        int      prev_cclk;
        uint8_t  scratch, reg, latch;
        uint32_t cnt_latch;
        uint8_t  cd[3];
        int      cd_armed, irq;
        uint64_t cd_end;
    } f;

    /* card ports */
    int        pmode[2];
    wio_card_t card[2];
    int        bitn[2];
    uint8_t    inb[2], outb[2];
    uint64_t   ack_start[2], ack_end[2];
    int        ack_pending[2];
    int        clk_prev;

    /* JVS receive queue (bytes on the RS-485 bus, with arrival cycle) */
    struct { uint8_t b; uint64_t t; } rxq[RXQ];
    int rxq_h, rxq_t;

    int      sense_last;
    uint32_t fw_crc;
    int      slow;          /* wio_set_slow: no program-specific loop shortcuts */
    uint64_t fast_cycles[4];/* cycles covered by each of them (stats)          */
    int      hook_state;     /* 0 unchecked, 1 ok, -1 not this firmware */
    struct { int active, virt, vres; uint32_t sp, ra, a0, a1; uint64_t vdone; } hk;
    uint64_t next_ev;
    int      io;             /* the last instruction touched a device */
    int      dma_busy;
    int      trace;
    /* spin detection: a polling loop that comes back to the same backward branch
     * with identical registers, no stores, no device change and no read of a
     * time-dependent register cannot do anything new until a device event */
    uint32_t spin_pc, spin_r[34];
    uint64_t spin_stores, spin_dev;
    int      spin_valid;
    uint64_t stores, devver;
    int      timeread;
    int      idle;
    uint32_t idle_pc;
};

static void logf_(wio_t *w, const char *fmt, ...)
{
    char buf[256];
    va_list ap;
    if (!w->h.log) return;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    w->h.log(w->h.user, buf);
}

static inline uint64_t now(const wio_t *w) { return w->cpu.cycles; }

/* ---------------------------------------------------------------- IRC */

static void irc_update(wio_t *w)
{
    int n, best = -1, bestlv = 0;
    uint32_t iml = w->imr & 7;
    if (w->cur >= 0 && (w->req & (1u << w->cur))) {
        /* manual 11.3.3: the informed number does not change until its request ends */
        best = w->cur;
    } else {
        for (n = 0; n < NSRC; n++) {
            uint32_t lv;
            if (!(w->req & (1u << n))) continue;
            lv = (w->ilr[n >> 2] >> ((n & 3) * 8)) & 7;
            if (lv == 0 || lv <= iml) continue;
            if ((int)lv >= bestlv) { bestlv = (int)lv; best = n; }  /* equal level: higher number */
        }
    }
    w->cur = best;
    w->cpu.hw_ip = (best >= 0) ? (0x10u | (uint32_t)best) : 0;
}

static void set_req(wio_t *w, int src, int on)
{
    uint32_t b = 1u << src;
    uint32_t old = w->req;
    if (on) w->req |= b; else w->req &= ~b;
    if (w->req != old) irc_update(w);
}

/* ---------------------------------------------------------------- PIO */

/* pin level seen on PIO port p bit b: driven if output, else the board's input */
static int pio_in_bit(const wio_t *w, int p, int b)
{
    if (p == 1 && b == 31) return w->f.state == 2;     /* FPGA DONE (fw 0x800050b8) */
    if (p == 1 && b == 30) return 1;                   /* JVS sense from downstream: nothing attached */
    return 1;                                          /* other inputs: pulled up (dongle SDA etc.) */
}

static uint32_t pio_read(const wio_t *w, int p)
{
    uint32_t v = 0;
    int b;
    for (b = 0; b < 32; b++) {
        int bit = (w->pdir[p] >> b) & 1 ? (int)((w->pdat[p] >> b) & 1) : pio_in_bit(w, p, b);
        v |= (uint32_t)bit << b;
    }
    return v;
}

static int pio_out_bit(const wio_t *w, int p, int b)
{
    if ((w->pdir[p] >> b) & 1) return (int)((w->pdat[p] >> b) & 1);
    return 1;
}

static void fpga_pins(wio_t *w);
static int has_ext(const wio_t *w);
static void sio_kick(wio_t *w, int n);

static void pio_changed(wio_t *w)
{
    int s = pio_out_bit(w, 1, 29);
    if (s != w->sense_last) {
        w->sense_last = s;
        if (w->h.sense) w->h.sense(w->h.user, s, now(w));
    }
    fpga_pins(w);
}

/* ---------------------------------------------------------------- FPGA */

static void fpga_clear(wio_t *w)
{
    w->f.state = 0;
    w->f.bits = 0; w->f.sr = 0; w->f.lc = 0; w->f.pre_at = -1;
    w->f.irq = 0; w->f.cd_armed = 0; w->f.latch = 0;
    set_req(w, SRC_INT7, 0);
}

/* PIO0 b26 /PROGRAM, b25 CCLK, b24 DIN (fw 0x80004f50..0x80005110) */
static void fpga_pins(wio_t *w)
{
    int prog = pio_out_bit(w, 0, 26);
    int cclk = pio_out_bit(w, 0, 25);
    int din  = pio_out_bit(w, 0, 24);
    if (!prog) {
        if (w->f.state != 0) fpga_clear(w);
        w->f.prev_cclk = cclk;
        return;
    }
    if (w->f.state == 0) { w->f.state = 1; w->f.bits = 0; w->f.pre_at = -1; }
    if (w->f.state == 1 && cclk && !w->f.prev_cclk) {
        /* Spartan-XL serial stream: 1s, preamble 0010, 24-bit length count */
        w->f.sr = (w->f.sr << 1) | (uint32_t)din;
        w->f.bits++;
        if (w->f.pre_at < 0) {
            if ((w->f.sr & 0xf) == 0x2 && w->f.bits >= 8) w->f.pre_at = (int)w->f.bits - 4;
        } else if (w->f.lc == 0 && (int)w->f.bits == w->f.pre_at + 28) {
            w->f.lc = w->f.sr & 0xffffff;
            logf_(w, "fpga: length count %u", w->f.lc);
        }
        if (w->f.lc && w->f.bits >= w->f.lc) {
            w->f.state = 2;
            w->f.reg = 0x02;     /* clock idle high until the code writes it */
            w->f.latch = 0;
            w->st.fpga_configs++;
            logf_(w, "fpga: configured after %u bits", w->f.bits);
        }
    }
    w->f.prev_cclk = cclk;
}

static uint32_t fpga_counter(const wio_t *w)
{
    return (uint32_t)(now(w) / 4) & 0xffffff;   /* fc/4 = 16.5 MHz (see doc) */
}

/* ---- card ports (FPGA register +03) ---- */

static void ack_sync(wio_t *w)
{
    int p;
    for (p = 0; p < 2; p++) {
        if (w->ack_pending[p] && now(w) >= w->ack_start[p]) {
            w->f.latch = 1;
            w->ack_pending[p] = 0;
        }
    }
}

static int ack_active(const wio_t *w)
{
    int p;
    for (p = 0; p < 2; p++)
        if (!w->ack_pending[p] && w->ack_end[p] > now(w) && w->ack_start[p] <= now(w)) return 1;
    return 0;
}

static int card_dat(const wio_t *w)
{
    int p;
    for (p = 0; p < 2; p++) {
        if (w->pmode[p] != WIO_PORT_VIRTUAL || !w->card[p].selected) continue;
        if (w->bitn[p] < 8 && !((w->outb[p] >> w->bitn[p]) & 1)) return 0;  /* card pulls DAT low */
    }
    return 1;                                                                /* pull-up */
}

static void card_reg_write(wio_t *w, uint8_t v)
{
    int p;
    int clk = (v >> 1) & 1, cmd = v & 1;
    ack_sync(w);
    for (p = 0; p < 2; p++) {
        int sel = !((v >> (2 + p)) & 1);    /* bits 2/3 are the /SEL pins: 0 = selected
                                               (fw 0x8000579c: 0x5580(port,1) before and
                                               after a frame, 0x5580(port,0) to start) */
        wio_card_t *c = &w->card[p];
        if (w->pmode[p] != WIO_PORT_VIRTUAL) continue;
        if (sel != c->selected) {
            wio_card_select(c, sel);
            w->bitn[p] = 0;
            w->outb[p] = 0xff;
            if (!sel) w->ack_pending[p] = 0;
        }
        if (!sel) continue;
        if (!clk && w->clk_prev) {
            /* falling edge: the card puts out the next bit; latch the byte at bit 0 */
            if (w->bitn[p] == 0) w->outb[p] = wio_card_out(c);
        } else if (clk && !w->clk_prev) {
            /* rising edge: the card samples CMD */
            if (w->bitn[p] < 8) {
                w->inb[p] = (uint8_t)((w->inb[p] >> 1) | (cmd << 7));
                w->bitn[p]++;
                if (w->bitn[p] == 8) {
                    wio_card_ack_t a = wio_card_byte(c, w->inb[p]);
                    w->bitn[p] = 0;
                    if (a.ack) {
                        uint64_t d = (uint64_t)a.ack_delay_ns * WIO_CYC_PER_US / 1000u;
                        w->ack_start[p] = now(w) + d;
                        w->ack_end[p] = w->ack_start[p] +
                            (uint64_t)WIO_CARD_ACK_WIDTH_NS * WIO_CYC_PER_US / 1000u;
                        w->ack_pending[p] = 1;
                    }
                }
            }
        }
    }
    w->clk_prev = clk;
    w->f.reg = v;
    if ((w->pmode[0] == WIO_PORT_EXTERNAL || w->pmode[1] == WIO_PORT_EXTERNAL) && w->h.card_reg) {
        uint8_t m = v;
        int q;
        for (q = 0; q < 2; q++)
            if (w->pmode[q] != WIO_PORT_EXTERNAL) m |= (uint8_t)(4u << q);   /* keep it deselected */
        w->h.card_reg(w->h.user, m, now(w));
    }
}

static uint8_t card_reg_read(wio_t *w)
{
    ack_sync(w);
    return (uint8_t)(card_dat(w) | (w->f.latch << 1) | (ack_active(w) << 2));
}

/* FPGA register space at phys 0x10000000 (8-bit, byte lanes) */
static uint8_t fpga_rd8(wio_t *w, uint32_t off)
{
    if (w->f.state != 2) return 0xff;
    switch (off) {
    case 0x01: return w->f.scratch;
    case 0x03: { uint8_t r;
        w->timeread = 1;
        r = card_reg_read(w);
        if (w->trace) logf_(w, "fpga rd 03 = %02x  pc %08x t %llu", r, w->cpu.pc, (unsigned long long)now(w));
        return r; }
    case 0x10: case 0x12: case 0x14: case 0x16: return 0xff;
    case 0x11: w->timeread = 1; w->f.cnt_latch = fpga_counter(w); return 0xff;
    case 0x13: return (uint8_t)(w->f.cnt_latch >> 16);
    case 0x15: return (uint8_t)(w->f.cnt_latch >> 8);
    case 0x17: return (uint8_t)w->f.cnt_latch;
    default:
        w->st.unmapped++;
        return 0xff;
    }
}

static void fpga_wr8(wio_t *w, uint32_t off, uint8_t v)
{
    if (w->trace) logf_(w, "fpga wr %02x = %02x  pc %08x t %llu", off, v, w->cpu.pc, (unsigned long long)now(w));
    if (w->f.state != 2) return;
    switch (off) {
    case 0x01: w->f.scratch = v; break;
    case 0x03: card_reg_write(w, v); break;
    case 0x05:
        ack_sync(w); w->f.latch = 0;
        if (has_ext(w) && w->h.card_latch_clr) w->h.card_latch_clr(w->h.user, now(w));
        break;
    case 0x21: /* acknowledge the countdown interrupt (fw 0x800016d0) */
        w->f.irq = 0; w->f.cd_armed = 0; set_req(w, SRC_INT7, 0); break;
    case 0x23: w->f.cd[0] = v;
        w->f.cd_end = now(w) + 4ull * (((uint32_t)w->f.cd[0] << 16) | ((uint32_t)w->f.cd[1] << 8) | w->f.cd[2]);
        w->f.cd_armed = 1; w->f.irq = 0; set_req(w, SRC_INT7, 0);
        break;
    case 0x25: w->f.cd[1] = v; break;
    case 0x27: w->f.cd[2] = v; break;
    default: w->st.unmapped++; break;
    }
}

/* ---------------------------------------------------------------- timers */

static uint64_t tmr_div(const tmr_t *t)
{
    /* internal system clock = IMCLK = fc/2; CCDE divides it by 2^(CCD+1) */
    uint64_t d = 2;
    if (t->tcr & 0x40) d <<= ((t->ccdr & 7) + 1);
    return d;
}

static uint32_t tmr_count(const wio_t *w, const tmr_t *t)
{
    if (!(t->tcr & 0x80) || (t->tcr & 0x04)) return t->cnt;
    return (uint32_t)((t->cnt + (now(w) - t->base) / tmr_div(t)) & 0xffffff);
}

static void tmr_schedule(wio_t *w, int n)
{
    tmr_t *t = &w->tmr[n];
    t->cnt = tmr_count(w, t);
    t->base = now(w);
    t->ev = UINT64_MAX;
    if (!(t->tcr & 0x80) || (t->tcr & 0x04)) return;   /* stopped or external clock */
    if ((t->tcr & 3) == 0 || (t->tcr & 3) == 2) {
        uint32_t left = (t->cpra - t->cnt) & 0xffffff;
        if (left == 0) left = 0x1000000;
        t->ev = now(w) + (uint64_t)left * tmr_div(t);
    }
}

static void chip_reset(wio_t *w);

static void tmr_event(wio_t *w, int n)
{
    tmr_t *t = &w->tmr[n];
    t->cnt = t->cpra;
    t->base = now(w);
    if ((t->tcr & 3) == 2 && n == 2) {
        /* watchdog: chip reset if CConR.WR (bit 27), else NMI (manual 11.3.1) */
        t->tisr |= 0x08;
        if (w->ccfg & (1u << 27)) {
            w->st.wd_resets++;
            chip_reset(w);
            return;
        }
        if (t->wtmr & 0x8000) logf_(w, "tx3904: watchdog NMI (not modelled)");
        t->cnt = 0;
    } else {
        t->tisr |= 0x01;
        if (t->itmr & 1) t->cnt = 0;
        else { t->tcr &= ~0x80u; }
        if (t->itmr & 0x8000) set_req(w, SRC_TMR0 + n, 1);
    }
    tmr_schedule(w, n);
}

/* ---------------------------------------------------------------- SIO */

static uint64_t sio_frame_cycles(const sio_t *s)
{
    /* SIOCLK = T0 (fc/4) when SCS=00, else BRG: prescaler (fc/4,16,64,256) / BRD.
     * One bit = 16 SIOCLK.  Frame = start + data + parity + stop(s). */
    uint64_t sioclk;
    int bits = 1 + (((s->lcr >> 16) & 3) == 1 ? 7 : 8) + ((s->lcr >> 19) & 1) + (((s->lcr >> 18) & 1) ? 2 : 1);
    if (((s->lcr >> 16) & 3) >= 2) bits = 1 + 9 + (((s->lcr >> 18) & 1) ? 2 : 1);
    if (((s->lcr >> 21) & 3) == 1) {
        static const unsigned pre[4] = { 4, 16, 64, 256 };
        uint32_t brd = (s->bgr >> 16) & 0xff;
        if (brd == 0) brd = 256;
        sioclk = (uint64_t)pre[(s->bgr >> 24) & 3] * brd;
    } else {
        sioclk = 4;
    }
    return sioclk * 16 * (uint64_t)bits;
}


static void sio_status(wio_t *w, int n)
{
    sio_t *s = &w->sio[n];
    int free_ = 8 - s->txn;
    int intreq;
    if (!(s->dicr & 0x80000)) {
        /* interrupt mode: TDIS while the TX FIFO is EMPTY, RDIS while data waits
         * (set continuously by the hardware; a 0 write clears it only until the
         * next clock).  "Empty", not "has room": GDB's model (dv-tx3904sio.c sets
         * TDIS when the FIFO is empty) and the boot program agree -- it polls TDIS
         * before each byte (0x800707e8) and then waits only 3 byte times before
         * dropping the RS-485 driver (0x80070af4), which is right only if at most
         * one byte waits behind the one shifting out.  The firmware's burst of up
         * to 8 bytes without polling (0x800039a4) needs the 8-deep FIFO. */
        if (s->txn == 0) s->disr |= 0x20000;
        if (s->rxn > 0) s->disr |= 0x10000;
        s->disr &= ~0x80000u;
        intreq = ((s->disr & s->dicr) & 0x70000) != 0;
    } else {
        /* DMA mode, table 12-4: one direction by DMA, the other by interrupt */
        int ttrig = (s->fcr & 0x80000) ? 8 : 4, rtrig = (s->fcr & 0x100000) ? 8 : 4;
        int dreq = 0;
        intreq = 0;
        if ((s->dicr & 0x20000) && !(s->dicr & 0x10000)) {          /* write DMA, RX interrupt */
            if (free_ >= ttrig) { s->disr |= 0x20000; dreq = 1; }
            if (s->rxn > 0) s->disr |= 0x10000;
            intreq = (s->disr & 0x10000) != 0;
        } else if ((s->dicr & 0x10000) && !(s->dicr & 0x20000)) {   /* read DMA, TX interrupt */
            if (s->rxn >= rtrig) { s->disr |= 0x10000; dreq = 1; }
            if (free_ > 0) s->disr |= 0x20000;
            intreq = (s->disr & 0x20000) != 0;
        }
        if ((s->disr & 0x40000) && (s->dicr & 0x40000)) intreq = 1;
        s->disr = (s->disr & ~0x80000u) | (dreq ? 0x80000u : 0);
    }
    set_req(w, n ? SRC_SIO1 : SRC_SIO0, intreq);
}

static void dma_run(wio_t *w);

static void sio_tx_start(wio_t *w, int n)
{
    sio_t *s = &w->sio[n];
    if (s->tx_busy || s->txn == 0) return;
    s->tx_byte = s->txf[s->txr];
    s->txr = (s->txr + 1) & 7;
    s->txn--;
    s->tx_busy = 1;
    s->tx_done = now(w) + sio_frame_cycles(s);
}

static void sio_kick(wio_t *w, int n)
{
    sio_tx_start(w, n);
    sio_status(w, n);
    dma_run(w);
}

static void sio_tx_done(wio_t *w, int n)
{
    sio_t *s = &w->sio[n];
    s->tx_busy = 0;
    if (n == 1) {
        /* PIO1 b28 = RS-485 driver enable, active low (boot 0x80070b70) */
        if (pio_out_bit(w, 1, 28) == 0) {
            w->st.tx_bytes++;
            if (w->h.bus_tx) w->h.bus_tx(w->h.user, s->tx_byte, now(w));
        }
    }
    sio_kick(w, n);
}

static void sio_rx_byte(wio_t *w, int n, uint8_t b)
{
    sio_t *s = &w->sio[n];
    int cap = (s->dicr & 0x80000) ? 8 : 2;   /* interrupt mode: 1-stage FIFO + read buffer */
    if (s->rxn >= cap) {
        s->lsr |= 0x20000;                    /* UOER */
        s->disr |= 0x40000;                   /* ERI */
        w->st.rx_dropped++;
    } else {
        s->rxf[(s->rxr + s->rxn) & 7] = b;
        s->rxn++;
        w->st.rx_bytes++;
    }
    sio_status(w, n);
    dma_run(w);
}

static uint32_t sio_read(wio_t *w, int n, uint32_t off)
{
    sio_t *s = &w->sio[n];
    switch (off) {
    case 0x00: return s->lcr;
    case 0x04: return s->lsr;
    case 0x08: return s->dicr;
    case 0x0c: sio_status(w, n); return s->disr;
    case 0x10: return s->fcr;
    case 0x14: return s->bgr;
    case 0x30: {
        uint8_t b = 0;
        if (s->rxn) { b = s->rxf[s->rxr]; s->rxr = (s->rxr + 1) & 7; s->rxn--; }
        sio_status(w, n);
        return (uint32_t)b << 24;
    }
    default: return 0;
    }
}

static void sio_write(wio_t *w, int n, uint32_t off, uint32_t v)
{
    sio_t *s = &w->sio[n];
    switch (off) {
    case 0x00: s->lcr = v & 0xe17f0000u; break;
    case 0x04: s->lsr &= v | ~0x000e0000u; break;           /* write 0 clears */
    case 0x08: s->dicr = v & 0x000f0000u; break;
    case 0x0c: s->disr &= v | ~0x00070000u; break;          /* ERI/TDIS/RDIS: write 0 clears */
    case 0x10:
        s->fcr = v & 0x001f0000u;
        if (v & 0x10000) {                                   /* FRSTE */
            if (v & 0x40000) { s->txn = 0; s->txr = 0; }
            if (v & 0x20000) { s->rxn = 0; s->rxr = 0; }
        }
        break;
    case 0x14: s->bgr = v & 0x03ff0000u; break;
    case 0x20:
        if (s->txn < 8) { s->txf[(s->txr + s->txn) & 7] = (uint8_t)(v >> 24); s->txn++; }
        break;
    default: break;
    }
    sio_kick(w, n);
}

/* ---------------------------------------------------------------- DMAC */

static int dma_src_irq(int ch) { return ch == 0 ? SRC_DMA0 : ch == 1 ? SRC_DMA1 : ch == 2 ? SRC_DMA2 : SRC_DMA3; }

static void dma_irq(wio_t *w, int ch)
{
    dma_t *d = &w->dma[ch];
    int on = ((d->csr & 0x800000) && (d->ccr & 0x800000)) || ((d->csr & 0x400000) && (d->ccr & 0x400000));
    set_req(w, dma_src_irq(ch), on);
}

static int bus_read(wio_t *w, uint32_t pa, int size, uint32_t *v);
static int bus_write(wio_t *w, uint32_t pa, int size, uint32_t v);

/* channel 2 <-> SIO1 when CConR.S1D, channel 1 <-> SIO0 when S0D (manual 5.3.1) */
static int dma_sio_req(const wio_t *w, int ch)
{
    if (ch == 2 && (w->ccfg & 0x80000000u)) return (w->sio[1].disr & 0x80000) != 0;
    if (ch == 1 && (w->ccfg & 0x40000000u)) return (w->sio[0].disr & 0x80000) != 0;
    return 0;
}

static void dma_run(wio_t *w)
{
    int ch, guard = 0;
    if (w->dma_busy) return;            /* a unit in flight writes the SIO, which kicks us */
    w->dma_busy = 1;
    for (ch = 0; ch < 4; ch++) {
        dma_t *d = &w->dma[ch];
        while ((d->csr & 0x80000000u) && dma_sio_req(w, ch) && guard++ < 64) {
            /* dual address, memory -> I/O, TrSiz 32 bits, DPS 8 bits: one request
             * moves one 32-bit unit as four byte writes (the firmware's set-up,
             * fw 0x80003aa4: CCR2 = 0x80c25863) */
            unsigned unit = ((d->ccr >> 2) & 3) == 3 ? 1 : ((d->ccr >> 2) & 3) == 2 ? 2 : 4;
            unsigned port = (d->ccr & 3) == 3 ? 1 : (d->ccr & 3) == 2 ? 2 : 4;
            uint32_t val = 0, i;
            int sio_n = (ch == 2) ? 1 : 0;
            if (unit > d->bcr) unit = d->bcr;
            if (!(d->ccr & 0x40) || (d->ccr & 0x200)) {
                logf_(w, "dmac: ch%d mode %08x not modelled", ch, d->ccr);
                d->csr &= ~0x80000000u;
                d->csr |= 0x440000u;   /* AbC + Conf */
                dma_irq(w, ch);
                break;
            }
            bus_read(w, d->sar, (int)unit, &val);
            for (i = 0; i < unit; i += port) {
                uint32_t part = (port == 4) ? val : (val >> ((unit - i - port) * 8)) & ((1u << (port * 8)) - 1);
                bus_write(w, d->dar, (int)port, part);
            }
            if (((d->ccr >> 7) & 3) == 0) d->sar += unit;
            else if (((d->ccr >> 7) & 3) == 1) d->sar -= unit;
            d->bcr -= unit;
            /* the SIO acknowledges: TDIS drops until the FIFO has room again */
            w->sio[sio_n].disr &= ~0x20000u;
            sio_tx_start(w, sio_n);
            if (d->bcr == 0) {
                d->csr &= ~0x80000000u;
                d->csr |= 0x800000u;   /* NC */
                dma_irq(w, ch);
            }
            sio_status(w, sio_n);
        }
    }
    w->dma_busy = 0;
}

static uint32_t dma_read(wio_t *w, uint32_t off)
{
    int ch = ((off >> 12) & 1) ? 2 : 0;    /* A000 -> ch0/1, B000 -> ch2/3 */
    uint32_t o = off & 0xfff;
    dma_t *d;
    if (o >= 0x80) return 0;
    ch += (o >> 5) & 1;
    d = &w->dma[ch];
    switch (o & 0x1f) {
    case 0x00: return d->ccr & 0x00ffffffu;
    case 0x04: return d->csr;
    case 0x08: return d->sar;
    case 0x0c: return d->dar;
    case 0x10: return d->bcr;
    case 0x14: return d->ncr;
    default: return 0;
    }
}

static void dma_write(wio_t *w, uint32_t off, uint32_t v)
{
    int ch = ((off >> 12) & 1) ? 2 : 0;
    uint32_t o = off & 0xfff;
    dma_t *d;
    if (o == 0x80) {                      /* DCR: Rst */
        if (v & 0x80000000u) {
            int c;
            for (c = ch; c < ch + 2; c++) {
                memset(&w->dma[c], 0, sizeof w->dma[c]);
                w->dma[c].ccr = 0x00e20000u;
                dma_irq(w, c);
            }
        }
        return;
    }
    if (o >= 0x80) return;
    ch += (o >> 5) & 1;
    d = &w->dma[ch];
    switch (o & 0x1f) {
    case 0x00:
        d->ccr = v & 0x00efffffu;
        if (v & 0x01000000u) d->csr &= ~0x80000000u;          /* Stop */
        if (v & 0x80000000u) {                                  /* Str */
            if (d->csr & 0xc00000u) { d->csr |= 0x440000u; }   /* NC/AbC still set: configuration error */
            else d->csr |= 0x80000000u;
        }
        break;
    case 0x04:
        d->csr = (d->csr & ~0x00e00007u) | (d->csr & v & 0x00e00000u) | (v & 7);
        if (!(d->csr & 0x400000)) d->csr &= ~0x1c0000u;       /* AbC cleared -> BES/BED/Conf */
        break;
    case 0x08: d->sar = v; break;
    case 0x0c: d->dar = v; break;
    case 0x10: d->bcr = v & 0xffffff; break;
    case 0x14: d->ncr = v & 0xffffff; break;
    default: break;
    }
    dma_irq(w, ch);
    dma_run(w);
}

/* ---------------------------------------------------------------- internal register file */

static uint32_t *store_slot(wio_t *w, uint32_t a)
{
    int i;
    for (i = 0; i < w->nstore; i++) if (w->store[i].a == a) return &w->store[i].v;
    if (w->nstore < (int)(sizeof w->store / sizeof w->store[0])) {
        w->store[w->nstore].a = a;
        w->store[w->nstore].v = 0;
        return &w->store[w->nstore++].v;
    }
    return NULL;
}

static uint32_t tmr_read(wio_t *w, int n, uint32_t off)
{
    tmr_t *t = &w->tmr[n];
    switch (off) {
    case 0x00: return t->tcr;
    case 0x04: return t->tisr;
    case 0x08: return t->cpra;
    case 0x0c: return t->cprb;
    case 0x10: return t->itmr;
    case 0x20: return t->ccdr;
    case 0x30: return t->pgmr;
    case 0x40: return t->wtmr;
    case 0xf0: w->timeread = 1; return tmr_count(w, t);
    default: return 0;
    }
}

static void tmr_write(wio_t *w, int n, uint32_t off, uint32_t v)
{
    tmr_t *t = &w->tmr[n];
    t->cnt = tmr_count(w, t);
    t->base = now(w);
    switch (off) {
    case 0x00:
        if (((t->tcr & 3) == 2) && !(v & 0x80) && (t->wtmr & 0x80)) { t->wtmr &= ~0x80u; }
        t->tcr = v & 0xef;
        if (!(v & 0x80) && (v & 0x20)) t->cnt = 0;              /* CRE */
        break;
    case 0x04:
        if (!(v & 0xff)) { t->tisr = 0; set_req(w, SRC_TMR0 + n, 0); }
        break;
    case 0x08: t->cpra = v & 0xffffff; break;
    case 0x0c: t->cprb = v & 0xffffff; break;
    case 0x10: t->itmr = v & 0x8001; break;
    case 0x20: t->ccdr = v & 7; break;
    case 0x30: t->pgmr = v & 0xc001; break;
    case 0x40:
        t->wtmr = v & 0x8081;
        if (v & 1) { t->cnt = 0; t->wtmr &= ~1u; }              /* TWC */
        break;
    default: break;
    }
    tmr_schedule(w, n);
}

static uint32_t internal_read_(wio_t *w, uint32_t pa);
static uint32_t internal_read(wio_t *w, uint32_t pa)
{
    uint32_t v = internal_read_(w, pa);
    if (w->trace && (pa & 0xffff) != 0xf40c) logf_(w, "rd %08x = %08x  pc %08x", pa, v, w->cpu.pc);
    return v;
}
static uint32_t internal_read_(wio_t *w, uint32_t pa)
{
    uint32_t o = pa & 0xffff, *s;
    if (o >= 0xf000 && o < 0xf300) return tmr_read(w, (int)((o >> 8) & 3), o & 0xff);
    if (o >= 0xf300 && o < 0xf500) return sio_read(w, (int)((o >> 8) - 0xf3), o & 0xff);
    if (o >= 0xf500 && o < 0xf800) {
        int p = (int)((o >> 8) - 0xf5);
        if ((o & 0xff) == 0x00) return w->pdir[p];
        if ((o & 0xff) == 0x04) return pio_read(w, p);
        return 0;
    }
    if (o >= 0xa000 && o < 0xc000) return dma_read(w, o);
    if (o >= 0xc000 && o < 0xc020) {
        switch (o) {
        case 0xc000: return ~w->req & 0xffff;                       /* ISR: 0 = request */
        case 0xc004: return w->imr;
        case 0xc010: return w->ilr[0];
        case 0xc014: return w->ilr[1];
        case 0xc018: return w->ilr[2];
        case 0xc01c: return w->ilr[3];
        default: return 0;
        }
    }
    if (o == 0xe000) return w->ccfg;
    s = store_slot(w, pa & ~3u);
    return s ? *s : 0;
}

static void internal_write_(wio_t *w, uint32_t pa, uint32_t v);
static void internal_write(wio_t *w, uint32_t pa, uint32_t v)
{
    if (w->trace) logf_(w, "wr %08x = %08x  pc %08x", pa, v, w->cpu.pc);
    internal_write_(w, pa, v);
}
static void internal_write_(wio_t *w, uint32_t pa, uint32_t v)
{
    uint32_t o = pa & 0xffff, *s;
    if (o >= 0xf000 && o < 0xf300) { tmr_write(w, (int)((o >> 8) & 3), o & 0xff, v); return; }
    if (o >= 0xf300 && o < 0xf500) { sio_write(w, (int)((o >> 8) - 0xf3), o & 0xff, v); return; }
    if (o >= 0xf500 && o < 0xf800) {
        int p = (int)((o >> 8) - 0xf5);
        if ((o & 0xff) == 0x00) w->pdir[p] = v;
        else if ((o & 0xff) == 0x04) w->pdat[p] = v;
        pio_changed(w);
        return;
    }
    if (o >= 0xa000 && o < 0xc000) { dma_write(w, o, v); return; }
    if (o >= 0xc000 && o < 0xc020) {
        switch (o) {
        case 0xc004: w->imr = v & 7; break;
        case 0xc010: w->ilr[0] = v & 0x07070707u; break;
        case 0xc014: w->ilr[1] = v & 0x07070707u; break;
        case 0xc018: w->ilr[2] = v & 0x07070707u; break;
        case 0xc01c: w->ilr[3] = v & 0x07070707u; break;
        default: break;
        }
        irc_update(w);
        return;
    }
    if (o == 0xe000) {
        /* CConR: EIClr (23:21) write-only, BEOW read-only */
        w->ccfg = (v & ~0x00e10000u) | (w->ccfg & 0x00010000u);
        dma_run(w);
        return;
    }
    s = store_slot(w, pa & ~3u);
    if (s) *s = v;
}

/* ---------------------------------------------------------------- bus */

/* sub-word access to a 32-bit big-endian register: read-modify-write */
static int bus_read(wio_t *w, uint32_t pa, int size, uint32_t *v)
{
    if (pa < WIO_RAM_SIZE) {
        const uint8_t *p = &w->ram[pa];
        *v = size == 1 ? p[0] : size == 2 ? (uint32_t)(p[0] << 8 | p[1])
                       : ((uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]);
        return 0;
    }
    if (pa >= 0x1fc00000u && pa < 0x1fc00000u + WIO_ROM_SIZE) {
        const uint8_t *p = &w->rom[pa - 0x1fc00000u];
        *v = size == 1 ? p[0] : size == 2 ? (uint32_t)(p[0] << 8 | p[1])
                       : ((uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]);
        return 0;
    }
    w->io = 1;
    if (pa >= 0x10000000u && pa < 0x10000100u) {
        /* 8-bit device: a wider access is split into byte cycles, MSB first */
        uint32_t r = 0;
        int i;
        for (i = 0; i < size; i++) r = (r << 8) | fpga_rd8(w, (pa & 0xff) + (uint32_t)i);
        *v = r;
        return 0;
    }
    if (pa >= 0xffff0000u) {
        uint32_t r = internal_read(w, pa & ~3u);
        int sh = (int)(3 - (pa & 3) - (size - 1)) * 8;
        *v = size == 4 ? r : (r >> sh) & (size == 1 ? 0xffu : 0xffffu);
        return 0;
    }
    if (w->st.unmapped++ < 16) logf_(w, "bus: read of unmapped %08x (pc %08x)", pa, w->cpu.pc);
    *v = 0;
    return 0;
}

static int bus_write(wio_t *w, uint32_t pa, int size, uint32_t v)
{
    w->stores++;
    if (pa < WIO_RAM_SIZE) {
        uint8_t *p = &w->ram[pa];
        if (size == 1) p[0] = (uint8_t)v;
        else if (size == 2) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
        else { p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v; }
        return 0;
    }
    if (pa >= 0x1fc00000u && pa < 0x1fc00000u + WIO_ROM_SIZE) return 0;
    w->io = 1;
    w->devver++;
    if (pa >= 0x10000000u && pa < 0x10000100u) {
        int i;
        for (i = 0; i < size; i++)
            fpga_wr8(w, (pa & 0xff) + (uint32_t)i, (uint8_t)(v >> ((size - 1 - i) * 8)));
        return 0;
    }
    if (pa >= 0xffff0000u) {
        uint32_t a = pa & ~3u;
        if (size == 4) internal_write(w, a, v);
        else {
            /* read-modify-write of the containing register, so a byte write to
             * the top byte (bits 31:24) of a SIO/PIO register lands correctly;
             * write-to-clear status bits are written back as 1 (no effect) */
            int sh = (int)(3 - (pa & 3) - (size - 1)) * 8;
            uint32_t m = (size == 1 ? 0xffu : 0xffffu) << sh;
            uint32_t cur;
            if ((a & 0xff0f) == 0xf00c && a >= 0xfffff300u && a < 0xfffff500u) cur = 0xffffffffu; /* SDISR */
            else if ((a & 0xff0f) == 0xf004 && a >= 0xfffff300u && a < 0xfffff500u) cur = 0xffffffffu; /* SLSR */
            else if (a == 0xfffff320u || a == 0xfffff420u) cur = 0;
            else cur = internal_read(w, a);
            internal_write(w, a, (cur & ~m) | ((v << sh) & m));
        }
        return 0;
    }
    if (w->st.unmapped++ < 16) logf_(w, "bus: write of unmapped %08x = %08x (pc %08x)", pa, v, w->cpu.pc);
    return 0;
}

static int cb_read(void *ctx, uint32_t pa, int size, uint32_t *v) { return bus_read((wio_t *)ctx, pa, size, v); }
static int cb_write(void *ctx, uint32_t pa, int size, uint32_t v) { return bus_write((wio_t *)ctx, pa, size, v); }
static int cb_fetch(void *ctx, uint32_t pa, uint32_t *insn)
{
    wio_t *w = (wio_t *)ctx;
    if (pa < WIO_RAM_SIZE) {
        const uint8_t *p = &w->ram[pa];
        *insn = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
        return 0;
    }
    if (pa >= 0x1fc00000u && pa < 0x1fc00000u + WIO_ROM_SIZE) {
        const uint8_t *p = &w->rom[pa - 0x1fc00000u];
        *insn = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
        return 0;
    }
    return 1;
}

/* ---------------------------------------------------------------- reset */

static void chip_reset(wio_t *w)
{
    int i;
    w->st.resets++;
    wio_cpu_reset(&w->cpu);
    w->ilr[0] = w->ilr[1] = w->ilr[2] = w->ilr[3] = 0;
    w->imr = 0;
    w->req = 0;
    w->cur = -1;
    w->ccfg = 0;
    w->nstore = 0;
    for (i = 0; i < 3; i++) { w->pdat[i] = 0; w->pdir[i] = 0; }
    memset(w->tmr, 0, sizeof w->tmr);
    for (i = 0; i < 3; i++) { w->tmr[i].ev = UINT64_MAX; w->tmr[i].base = now(w); }
    memset(w->sio, 0, sizeof w->sio);
    for (i = 0; i < 2; i++) { w->sio[i].lcr = 0x40000000u; w->sio[i].bgr = 0x03ff0000u; }
    memset(w->dma, 0, sizeof w->dma);
    for (i = 0; i < 4; i++) w->dma[i].ccr = 0x00e20000u;
    w->hook_state = 0;
    w->hk.active = 0;
    w->fw_crc = 0;
    w->idle = 0;
    /* PIO pins float to their pull-ups: the FPGA sees /PROGRAM high until the boot
     * ROM drives it low (bfc0001c), so its configuration survives only that long */
    pio_changed(w);
    irc_update(w);
}

/* ---------------------------------------------------------------- public API */

wio_t *wio_create(const wio_host_t *host)
{
    wio_t *w = (wio_t *)calloc(1, sizeof *w);
    if (!w) return NULL;
    if (host) w->h = *host;
    w->cpu.mem_ctx = w;
    w->cpu.read = cb_read;
    w->cpu.write = cb_write;
    w->cpu.fetch = cb_fetch;
    w->cpu.ram = w->ram;
    w->cpu.ram_size = WIO_RAM_SIZE;
    w->sense_last = -1;
    w->f.prev_cclk = 1;
    w->clk_prev = 1;
    return w;
}

void wio_destroy(wio_t *w) { free(w); }

int wio_load_rom(wio_t *w, const uint8_t *img, size_t len)
{
    size_t i;
    if (len != WIO_ROM_SIZE) return -1;
    for (i = 0; i < len; i += 2) { w->rom[i] = img[i + 1]; w->rom[i + 1] = img[i]; }
    w->rom_ok = 1;
    return 0;
}

void wio_power_on(wio_t *w)
{
    memset(w->ram, 0, sizeof w->ram);
    fpga_clear(w);
    w->f.prev_cclk = 1;
    w->rxq_h = w->rxq_t = 0;
    chip_reset(w);
    w->st.resets = 0;
}

void wio_bus_rx(wio_t *w, uint8_t b, uint64_t cyc)
{
    int nt = (w->rxq_t + 1) % RXQ;
    if (nt == w->rxq_h) { w->st.rx_dropped++; return; }
    if (cyc < now(w)) cyc = now(w);
    w->rxq[w->rxq_t].b = b;
    w->rxq[w->rxq_t].t = cyc;
    w->rxq_t = nt;
}

uint64_t wio_now(const wio_t *w) { return now(w); }

static uint64_t next_event(const wio_t *w)
{
    uint64_t e = UINT64_MAX;
    int i;
    for (i = 0; i < 3; i++) if (w->tmr[i].ev < e) e = w->tmr[i].ev;
    for (i = 0; i < 2; i++) if (w->sio[i].tx_busy && w->sio[i].tx_done < e) e = w->sio[i].tx_done;
    if (w->rxq_h != w->rxq_t && w->rxq[w->rxq_h].t < e) e = w->rxq[w->rxq_h].t;
    if (w->f.cd_armed && w->f.cd_end < e) e = w->f.cd_end;
    for (i = 0; i < 2; i++) {
        if (w->ack_pending[i] && w->ack_start[i] < e) e = w->ack_start[i];
        if (!w->ack_pending[i] && w->ack_end[i] > now(w) && w->ack_end[i] < e) e = w->ack_end[i];
    }
    return e;
}

uint64_t wio_next_event(const wio_t *w) { return next_event(w); }

static void devices(wio_t *w)
{
    uint64_t t = now(w);
    int i;
    if (w->next_ev <= t) w->devver++;
    for (i = 0; i < 3; i++) if (w->tmr[i].ev <= t) tmr_event(w, i);
    for (i = 0; i < 2; i++) if (w->sio[i].tx_busy && w->sio[i].tx_done <= t) sio_tx_done(w, i);
    while (w->rxq_h != w->rxq_t && w->rxq[w->rxq_h].t <= t) {
        uint8_t b = w->rxq[w->rxq_h].b;
        w->rxq_h = (w->rxq_h + 1) % RXQ;
        /* half duplex: nothing is received while our own driver is on */
        if (pio_out_bit(w, 1, 28) == 0) { w->st.rx_dropped++; continue; }
        sio_rx_byte(w, 1, b);
    }
    if (w->f.cd_armed && w->f.cd_end <= t) {
        w->f.cd_armed = 0;
        w->f.irq = 1;
        set_req(w, SRC_INT7, 1);   /* INT[7] (fw: IRC source 6 handler 0x800016c0) */
    }
    ack_sync(w);
    w->next_ev = next_event(w);
}

/* ---- the firmware's card byte exchange, performed by real hardware ---- */
#define FW_LEN       24720u        /* the unpacked reader program (doc) */
#define FW_CRC_KNOWN 0x08844237u   /* ... on every card-capable DDR disc checked */
#define HOOK_PC      0x8000560cu
#define HOOK_LEN     0x190u
#define HOOK_CRC     0xdde28caau   /* fw 0x8000560c..0x8000579b of CRC 08844237 */

static int hook_check(wio_t *w)
{
    if (w->hook_state == 0) {
        uint32_t c = crc32_buf(&w->ram[HOOK_PC & 0x1fffffff], HOOK_LEN);
        w->hook_state = (c == HOOK_CRC) ? 1 : -1;
        logf_(w, "card routine %s", w->hook_state > 0 ? "recognised" : "NOT recognised (real cards unavailable)");
    }
    return w->hook_state > 0;
}

/* The firmware's card byte exchange (fw 0x8000560c, a0 = byte, a1 = /ACK timeout
 * in us) runs on real hardware for an EXTERNAL port.  The CPU parks at the
 * routine's first instruction until the hardware finishes; interrupts are taken
 * normally while it waits (EPC = the routine entry), and the call resumes when
 * the CPU comes back to it with the same stack, return address and arguments --
 * so the kernel's other tasks and the JVS interrupts keep running just as they
 * would around the bit-banged loop on the real board. */
static int hook_ext_selected(const wio_t *w, uint8_t reg)
{
    int q;
    for (q = 0; q < 2; q++)
        if (!((reg >> (2 + q)) & 1) && w->pmode[q] == WIO_PORT_EXTERNAL) return 1;
    return 0;
}

/* The same routine for a VIRTUAL port (a card file), done here instead of
 * interpreting its bit loop (~400 instructions a byte, the cost the cabinet logs
 * showed while a card file was read). It is the routine's algorithm with the card
 * model of s573_wio_card.c, step for step as rtl/s573_wio_port.v does it at the
 * SNAC pins: latch already set -> -2; eight bits out, the card's byte in; timeout
 * 0 -> the byte; /ACK within the timeout -> wait 7 us, the byte; else -1, and a
 * late /ACK still sets the latch when it comes. The durations are the routine's
 * own as the interpreter runs it (tests/test_s573_wio.c, -slow, measured
 * 2026-10-29): 2354 cycles to the end of the last bit with timeout 0; +/ACK delay
 * +481 (the 7 us wait and the latch clear); +timeout +11 with no /ACK. */
#define VX_BITS   2354u
#define VX_ACKED  481u
#define VX_NOACK  11u
#define VX_LATCH  20u
static void virt_xfer(wio_t *w, uint8_t reg, uint8_t cmd, unsigned tmo, int *res, uint64_t *done)
{
    uint64_t t = now(w);
    wio_card_t *c = NULL;
    wio_card_ack_t a = { 0, 0 };
    uint8_t out = 0xff;                      /* DAT pull-up: no card driving it */
    int p = -1, q;
    ack_sync(w);
    w->st.card_xfers_virt++;
    if (w->f.latch) { *res = WIO_XFER_ERROR; *done = t + VX_LATCH; return; }
    for (q = 0; q < 2; q++)
        if (!((reg >> (2 + q)) & 1) && w->pmode[q] == WIO_PORT_VIRTUAL) { p = q; break; }
    if (p >= 0) {
        c = &w->card[p];
        out = wio_card_out(c);
        a = wio_card_byte(c, cmd);
        w->bitn[p] = 0;
    }
    w->clk_prev = 1;
    if (tmo == 0) {                          /* last byte of a command */
        *res = out; *done = t + VX_BITS;
    } else if (a.ack && a.ack_delay_ns <= (uint32_t)tmo * 1000u) {
        uint64_t ad = (uint64_t)a.ack_delay_ns * WIO_CYC_PER_US / 1000u;
        *res = out; *done = t + VX_BITS + ad + VX_ACKED;
        return;                              /* /ACK seen, latch cleared */
    } else {
        *res = WIO_XFER_NOACK; *done = t + VX_BITS + (uint64_t)tmo * WIO_CYC_PER_US + VX_NOACK;
    }
    if (a.ack && p >= 0) {                   /* an /ACK nobody waited for: it still comes */
        w->ack_start[p] = t + VX_BITS + (uint64_t)a.ack_delay_ns * WIO_CYC_PER_US / 1000u;
        w->ack_end[p] = w->ack_start[p] + (uint64_t)WIO_CARD_ACK_WIDTH_NS * WIO_CYC_PER_US / 1000u;
        w->ack_pending[p] = 1;
        w->next_ev = next_event(w);
    }
}

static int hook_virt_selected(const wio_t *w, uint8_t reg)
{
    int q;
    if (w->slow || w->fw_crc != FW_CRC_KNOWN) return 0;
    for (q = 0; q < 2; q++)
        if (!((reg >> (2 + q)) & 1) && w->pmode[q] == WIO_PORT_VIRTUAL) return 1;
    return 0;
}

/* returns 1 if the CPU must not execute the instruction at pc this time round */
static int hook(wio_t *w, uint64_t until, uint64_t *wake)
{
    int r;
    uint64_t done;
    (void)until;
    *wake = UINT64_MAX;
    if (!w->hk.active ||
        w->hk.sp != w->cpu.r[29] || w->hk.ra != w->cpu.r[31] ||
        w->hk.a0 != w->cpu.r[4] || w->hk.a1 != w->cpu.r[5]) {
        uint8_t m;
        int q;
        if (!hook_ext_selected(w, w->f.reg) && hook_virt_selected(w, w->f.reg)) {
            if (!hook_check(w)) return 0;
            w->hk.active = 1; w->hk.virt = 1;
            w->hk.sp = w->cpu.r[29]; w->hk.ra = w->cpu.r[31];
            w->hk.a0 = w->cpu.r[4];  w->hk.a1 = w->cpu.r[5];
            virt_xfer(w, w->f.reg, (uint8_t)w->cpu.r[4], w->cpu.r[5], &w->hk.vres, &w->hk.vdone);
            goto check;
        }
        if (!hook_ext_selected(w, w->f.reg) || !w->h.card_xfer_start || !w->h.card_xfer_done) return 0;
        if (!hook_check(w)) return 0;
        w->hk.virt = 0;
        m = w->f.reg;
        for (q = 0; q < 2; q++) if (w->pmode[q] != WIO_PORT_EXTERNAL) m |= (uint8_t)(4u << q);
        w->hk.active = 1;
        w->hk.sp = w->cpu.r[29]; w->hk.ra = w->cpu.r[31];
        w->hk.a0 = w->cpu.r[4];  w->hk.a1 = w->cpu.r[5];
        w->st.card_xfers_ext++;
        w->h.card_xfer_start(w->h.user, m, (uint8_t)w->cpu.r[4], w->cpu.r[5], now(w));
    }
check:
    if (wio_cpu_irq_pending(&w->cpu)) return 0;      /* let the interrupt in (EPC = here) */
    done = UINT64_MAX;
    if (w->hk.virt ? (r = w->hk.vres, done = w->hk.vdone, 1) : w->h.card_xfer_done(w->h.user, &r, &done)) {
        uint32_t reg = w->f.reg;
        if (done > now(w)) { *wake = done; return 1; }                   /* finishes later */
        w->hk.active = 0;
        w->cpu.r[2] = (uint32_t)(int32_t)r;
        /* the routine leaves CLK high and CMD = bit 7 of the byte */
        w->f.reg = (uint8_t)((reg & ~3u) | 2u | ((w->cpu.r[4] >> 7) & 1));
        w->cpu.pc = w->cpu.r[31];
        w->cpu.npc = w->cpu.pc + 4;
        w->cpu.in_delay = 0;
        w->cpu.cycles++;
        return 1;
    }
    *wake = done;
    return 1;
}

/* ---- shortcuts for four loops of the reader program (CRC 08844237 only) ----
 * Each is a loop whose outcome is fixed by time alone (or, for the FPGA one, by
 * data), so it is jumped over instead of interpreted. Measured on the cabinet
 * (2026-10-28 logs): without them the ARM fell up to ~1 s behind the board's
 * clock while the program configured the FPGA and while it read 16-20 frames from
 * a card file -- the two places these loops dominate (WIO_PROFILE: the counter
 * read 0x800003b4 x218k, the FPGA bit routines x191k, the /ACK wait 0x80005714).
 * Never across the next device event or the run deadline (lim), and only with no
 * interrupt pending, exactly like the other shortcuts. */
#define FAST_DELAY 0
#define FAST_ACK   1
#define FAST_FPGA  2
#define FAST_GAP   3

/* delay(us), fw 0x800003f0: t0 = counter(); do t = counter(); while
 * (us*33/2 - ((t - t0) & 0xffffff) > 0). At the loop head 0x80000410: r6 = t0,
 * r7 = us*33/2, r5 = 0xffffff. Jump to a little before the counter reaches
 * t0 + r7, then let the loop's own last iteration read it and leave. */
static int fast_delay(wio_t *w, uint64_t lim)
{
    uint32_t diff = (fpga_counter(w) - w->cpu.r[6]) & 0xffffffu, need = w->cpu.r[7];
    uint64_t s;
    if (w->cpu.r[5] != 0xffffffu || need > 0x800000u || diff >= need) return 0;
    s = (uint64_t)(need - diff) * 4u;
    if (s <= 48) return 0;
    s -= 48;                                         /* one iteration's worth short */
    if (now(w) + s > lim) s = lim > now(w) ? lim - now(w) : 0;
    if (s < 8) return 0;
    w->cpu.cycles += s;
    w->st.idle_skipped += s;
    w->fast_cycles[FAST_DELAY] += s;
    return 1;
}

/* the card byte routine's /ACK wait, fw 0x80005714..0x8000573c: loop until the
 * /ACK latch (FPGA +03 bit 1) is set or sext24(counter - r19) > r18 (unsigned).
 * The latch is set only at a device event (a card's /ACK, in next_event()), so
 * nothing can end the loop early inside [now, lim). */
static int fast_ackwait(wio_t *w, uint64_t lim)
{
    int32_t diff;
    uint64_t s;
    if (w->cpu.r[16] != 0xb0000003u) return 0;
    ack_sync(w);
    if (w->f.latch) return 0;
    diff = (int32_t)(((fpga_counter(w) - w->cpu.r[19]) & 0xffffffu) << 8) >> 8;
    if (diff < 0 || (uint32_t)diff > w->cpu.r[18] || w->cpu.r[18] > 0x800000u) return 0;
    s = (uint64_t)(w->cpu.r[18] + 1u - (uint32_t)diff) * 4u;
    if (s <= 48) return 0;
    s -= 48;
    if (now(w) + s > lim) s = lim > now(w) ? lim - now(w) : 0;
    if (s < 8) return 0;
    w->cpu.cycles += s;
    w->st.idle_skipped += s;
    w->fast_cycles[FAST_ACK] += s;
    return 1;
}

/* the FPGA bitstream loop, fw 0x800050ec..0x8000512c: for each byte r17 < r20 of
 * the image at r19, for each bit LSB first: DIN = bit (0x80004fb8), CCLK = 1,
 * CCLK = 0 (0x80004f98), each a read-modify-write of the PIO0 data byte. Done
 * here with the same bus accesses and the same 270 cycles per byte the
 * interpreter takes (measured: 0x800050ec is reached every 270 cycles); the
 * registers are left as the loop leaves them at its head. The last byte is left
 * to the interpreter, so the loop exits through its own instructions. The test
 * (tests/test_s573_wio.c -slow) checks cycles and registers match exactly. */
static int fast_fpga(wio_t *w, uint64_t lim)
{
    wio_cpu_t *c = &w->cpu;
    int done = 0;
    if (c->r[16] != 0) return 0;
    while (c->r[17] + 1u < c->r[20] && now(w) + 270u <= lim) {
        uint32_t pa = wio_vtop(c->r[19] + c->r[17]), b, cur;
        int i;
        if (pa >= WIO_RAM_SIZE) break;
        b = w->ram[pa];
        for (i = 0; i < 8; i++) {
            bus_read(w, 0xfffff504u, 1, &cur);
            bus_write(w, 0xfffff504u, 1, (cur & 0xfeu) | ((b >> i) & 1u));
            bus_read(w, 0xfffff504u, 1, &cur);
            bus_write(w, 0xfffff504u, 1, (cur & 0xfdu) | 2u);
            bus_read(w, 0xfffff504u, 1, &cur);
            cur &= 0xfdu;
            bus_write(w, 0xfffff504u, 1, cur);
        }
        c->r[2] = 1; c->r[3] = cur; c->r[4] = 0; c->r[18] = b; c->r[31] = 0x80005110u;
        c->r[17]++;
        c->cycles += 270;
        w->st.insns += 270;
        w->fast_cycles[FAST_FPGA] += 270;
        done = 1;
    }
    if (done) w->next_ev = next_event(w);
    return done;
}

/* the card command's guard time, fw 0x800057d0..0x800057ec: loop until
 * sext24(counter - [gp-0x7eac]) > r16 (unsigned; r16 = 0x325a9 = 12.5 ms of fc/4
 * ticks since the previous command ended) -- the same shape as the /ACK wait,
 * with the start time in memory and nothing but time to end it. */
static int fast_gap(wio_t *w, uint64_t lim)
{
    uint32_t pa = wio_vtop(w->cpu.r[28] - 0x7eacu), t0;
    int32_t diff;
    uint64_t s;
    if (pa + 4 > WIO_RAM_SIZE || w->cpu.r[16] > 0x800000u) return 0;
    t0 = (uint32_t)w->ram[pa] << 24 | (uint32_t)w->ram[pa + 1] << 16 | (uint32_t)w->ram[pa + 2] << 8 | w->ram[pa + 3];
    diff = (int32_t)(((fpga_counter(w) - t0) & 0xffffffu) << 8) >> 8;
    if (diff < 0 || (uint32_t)diff > w->cpu.r[16]) return 0;
    s = (uint64_t)(w->cpu.r[16] + 1u - (uint32_t)diff) * 4u;
    if (s <= 48) return 0;
    s -= 48;
    if (now(w) + s > lim) s = lim > now(w) ? lim - now(w) : 0;
    if (s < 8) return 0;
    w->cpu.cycles += s;
    w->st.idle_skipped += s;
    w->fast_cycles[FAST_GAP] += s;
    return 1;
}

static int fast_loops(wio_t *w, uint64_t until)
{
    uint64_t lim = w->next_ev < until ? w->next_ev : until;
    if (w->slow || w->fw_crc != FW_CRC_KNOWN || w->cpu.in_delay || wio_cpu_irq_pending(&w->cpu)) return 0;
    switch (w->cpu.pc) {
    case 0x80000410u: return fast_delay(w, lim);
    case 0x80005714u: return fast_ackwait(w, lim);
    case 0x800050ecu: return fast_fpga(w, lim);
    case 0x800057d0u: return fast_gap(w, lim);
    default: return 0;
    }
}

/* idle: the firmware's idle task is `j .` (fw 0x80000d78, task created at 0x80000650) */
static int at_idle(wio_t *w, uint32_t insn)
{
    uint32_t pc = w->cpu.pc, ds;
    if (w->cpu.in_delay) return 0;
    if (cb_fetch(w, wio_vtop(pc + 4), &ds)) return 0;
    if (ds != 0) return 0;
    if ((insn >> 26) == 0x02 && ((insn & 0x03ffffffu) << 2) == (pc & 0x0ffffffcu)) return 1; /* j . */
    if (insn == 0x1000ffffu) return 1;                                                       /* b . */
    return 0;
}

/* Exact shortcuts for loops whose outcome is known without running them.
 *  1. count-down delay: `bnez rX, .` with `addiu rX, rX, -1` in the delay slot
 *     (fw 0x8000566c/0x80005694 card bit timing, boot 0x800704fc etc.): runs
 *     2*(rX+1) cycles and leaves rX = -1.  Never crosses the next device event.
 *  2. a polling loop seen to come round with nothing changed (see wio_t). */
static int accelerate(wio_t *w, uint64_t until, uint32_t insn)
{
    uint32_t pc = w->cpu.pc, ds;
    uint64_t lim = w->next_ev < until ? w->next_ev : until;
    if (w->cpu.in_delay || wio_cpu_irq_pending(&w->cpu)) return 0;
    if ((insn & 0xfc1f8000u) == 0x14008000u) {          /* bne rX, $zero, <back> */
        int rx = (int)((insn >> 21) & 31);
        uint32_t target = pc + 4 + (uint32_t)((int32_t)(int16_t)(insn & 0xffff) << 2);
        uint32_t m = (pc - target) / 4, k, word;
        int ok = rx != 0 && m < 8 && target <= pc;
        /* the loop body between the target and the branch must be all NOPs */
        for (k = 0; ok && k < m; k++)
            if (cb_fetch(w, wio_vtop(target + 4 * k), &word) || word != 0) ok = 0;
        if (ok && !cb_fetch(w, wio_vtop(pc + 4), &ds) &&
            ds == (0x24000000u | ((uint32_t)rx << 21) | ((uint32_t)rx << 16) | 0xffffu)) {
            /* at the branch with rX = v: taken v times (each: branch, delay slot,
             * m nops), then once not taken (branch + delay slot) -> rX = -1 */
            uint32_t v = w->cpu.r[rx];
            uint64_t per = 2 + m, total, room;
            if (v > 10000000u) return 0;
            room = (lim > now(w)) ? lim - now(w) : 0;
            total = (uint64_t)v * per + 2;
            if (total <= room) {
                w->cpu.r[rx] = 0xffffffffu;
                w->cpu.cycles += total;
                w->st.insns += total;
                w->cpu.pc = pc + 8;
                w->cpu.npc = pc + 12;
                return 1;
            }
            if (room >= per) {
                uint64_t it = room / per;
                if (it > v) it = v;
                w->cpu.r[rx] = v - (uint32_t)it;
                w->cpu.cycles += it * per;
                w->st.insns += it * per;
                return 1;                                /* back at the branch */
            }
            return 0;
        }
    }
    /* spin detection at backward branches / jumps */
    {
        uint32_t op = insn >> 26;
        int back = 0;
        if ((op >= 0x04 && op <= 0x07) || (op >= 0x14 && op <= 0x17) || op == 0x01)
            back = (insn & 0x8000u) != 0;
        else if (op == 0x02)           /* J only: a JAL to a lower address is a call */
            back = (((insn & 0x03ffffffu) << 2) | (pc & 0xf0000000u)) <= pc;
        if (!back) return 0;
#ifdef SPINDBG
        if (pc == 0x80070870u) { static int n; if (n++ < 6) fprintf(stderr, "spin pc %08x valid %d spc %08x st %d dev %d tr %d regs %d lim>now %d\n", pc, w->spin_valid, w->spin_pc, w->spin_stores == w->stores, w->spin_dev == w->devver, w->timeread, !memcmp(w->spin_r, w->cpu.r, sizeof w->cpu.r), lim > now(w)); }
#endif
        if (w->spin_valid && w->spin_pc == pc && w->spin_stores == w->stores + w->cpu.ram_stores && w->spin_dev == w->devver &&
            !w->timeread && !memcmp(w->spin_r, w->cpu.r, sizeof w->cpu.r) &&
            w->spin_r[32] == w->cpu.hi && w->spin_r[33] == w->cpu.lo && lim > now(w)) {
            w->idle = 1;
            w->st.idle_skipped += lim - now(w);
            w->cpu.cycles = lim;
            return 1;
        }
        w->spin_valid = 1;
        w->spin_pc = pc;
        memcpy(w->spin_r, w->cpu.r, sizeof w->cpu.r);
        w->spin_r[32] = w->cpu.hi;
        w->spin_r[33] = w->cpu.lo;
        w->spin_stores = w->stores + w->cpu.ram_stores;
        w->spin_dev = w->devver;
        w->timeread = 0;
    }
    return 0;
}

static int has_ext(const wio_t *w)
{
    return w->pmode[0] == WIO_PORT_EXTERNAL || w->pmode[1] == WIO_PORT_EXTERNAL;
}

uint64_t wio_run(wio_t *w, uint64_t until)
{
    uint32_t insn;
    int is_br;
    if (!w->rom_ok) { w->cpu.cycles = until; return until; }
    devices(w);
    while (now(w) < until) {
        if (now(w) >= w->next_ev) devices(w);
        if (w->cpu.pc == HOOK_PC && (has_ext(w) || (!w->slow && w->fw_crc == FW_CRC_KNOWN))) {
            uint64_t wake;
            if (hook(w, until, &wake)) {
                if (w->cpu.pc == HOOK_PC) {
                    /* waiting for the hardware: idle until it, an event or the deadline */
                    uint64_t stop = w->next_ev < until ? w->next_ev : until;
                    if (wake < stop) stop = wake;
                    if (stop > now(w)) { w->st.idle_skipped += stop - now(w); w->cpu.cycles = stop; }
                    else w->cpu.cycles++;
                }
                continue;
            }
        }
        /* the instruction about to run: the loop shortcuts below look only at
         * jumps and branches (J/JAL/branch opcodes 01, 02, 04-07, 14-17) */
        {
            uint32_t pa = wio_vtop(w->cpu.pc), op;
            if (pa < WIO_RAM_SIZE) {
                const uint8_t *p = &w->ram[pa];
                insn = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
            } else if (cb_fetch(w, pa, &insn)) insn = 0;
            op = insn >> 26;
            is_br = op == 0x01 || op == 0x02 || (op >= 0x04 && op <= 0x07) || (op >= 0x14 && op <= 0x17);
        }
        if (is_br && !wio_cpu_irq_pending(&w->cpu) && at_idle(w, insn)) {
            /* nothing changes until the next device event or the deadline */
            uint64_t stop = w->next_ev < until ? w->next_ev : until;
            w->idle = 1;
            w->st.idle_skipped += stop - now(w);
            w->cpu.cycles = stop;
            continue;
        }
        w->idle = 0;
        w->io = 0;
        if (!w->fw_crc && w->cpu.pc - 0x80000000u < FW_LEN) {
            w->fw_crc = crc32_buf(&w->ram[0], FW_LEN);
            if (!w->fw_crc) w->fw_crc = 1;
            logf_(w, "uploaded program running: CRC-32 %08x%s", w->fw_crc,
                  w->fw_crc == FW_CRC_KNOWN ? " (the DDR card reader program)" : " (not the known program)");
        }
        if (is_br && accelerate(w, until, insn)) continue;
        if (fast_loops(w, until)) continue;
#ifdef WIO_PROFILE
        { extern void wio_prof(uint32_t pc); wio_prof(w->cpu.pc); }
#endif
        wio_cpu_step(&w->cpu);
        w->st.insns++;
        w->st.interp++;
        if (w->io) w->next_ev = next_event(w);   /* the access may have scheduled something */
    }
    devices(w);
    return now(w);
}

int wio_idle(const wio_t *w) { return w->idle; }
void wio_trace(wio_t *w, int on) { w->trace = on; }
void wio_set_slow(wio_t *w, int on) { w->slow = on; }
uint64_t wio_fast_cycles(const wio_t *w, int which) { return (which >= 0 && which < 4) ? w->fast_cycles[which] : 0; }

void wio_port_mode(wio_t *w, int port, int mode)
{
    if (port < 0 || port > 1) return;
    if (w->pmode[port] == WIO_PORT_VIRTUAL && mode != WIO_PORT_VIRTUAL) wio_card_select(&w->card[port], 0);
    w->pmode[port] = mode;
}

wio_card_t *wio_port_card(wio_t *w, int port) { return (port >= 0 && port < 2) ? &w->card[port] : NULL; }
int wio_sense_out(const wio_t *w) { return pio_out_bit(w, 1, 29); }
const wio_stats_t *wio_stats(const wio_t *w) { return &w->st; }
uint32_t wio_fw_crc(const wio_t *w) { return w->fw_crc; }
const wio_cpu_t *wio_cpu(const wio_t *w) { return &w->cpu; }

int wio_peek(wio_t *w, uint32_t va, int size, uint32_t *v)
{
    uint32_t pa = wio_vtop(va);
    if (pa < WIO_RAM_SIZE || (pa >= 0x1fc00000u && pa < 0x1fc00000u + WIO_ROM_SIZE))
        return bus_read(w, pa, size, v);
    return -1;
}
