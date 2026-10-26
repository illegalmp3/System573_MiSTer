/*
 * s573_wio.h -- emulation of Konami's GE885-PWB(A) "White I/O" JVS board (the PS1
 * memory card reader of System 573 DDR cabinets).
 *
 * The board is emulated at the hardware level: its Toshiba TMPR3904F CPU runs the
 * real boot ROM (885a01) and whatever program the game uploads over JVS, with the
 * TX3904 peripherals the code touches (IRC, SIO, DMAC, timers, PIO, CConR) built
 * from the TMPR3904F user's manual, and the board's FPGA registers built from how
 * Konami's code uses them (docs/2026-10-26-white-io-reader.md lists every source).
 *
 * Time is counted in CPU cycles at WIO_FC_HZ.  The host feeds JVS bytes in with
 * their arrival time and runs the board up to a target time; everything the board
 * emits (JVS bytes on the RS-485 bus, the JVS sense line, card port traffic for a
 * real card) comes back through the callbacks in wio_host_t, stamped with the
 * cycle at which it happened.
 */
#ifndef WIO_H
#define WIO_H

#include <stdint.h>
#include <stddef.h>
#include "s573_wio_cpu.h"
#include "s573_wio_card.h"

#ifdef __cplusplus
extern "C" {
#endif

#define WIO_FC_HZ        66000000u      /* see the doc: SIO baud, TX timeouts, FPGA counter */
#define WIO_RAM_SIZE     0x80000u
#define WIO_ROM_SIZE     0x80000u
#define WIO_CYC_PER_US   66u

enum { WIO_PORT_NONE = 0, WIO_PORT_VIRTUAL = 1, WIO_PORT_EXTERNAL = 2 };

/* result codes of the card byte exchange, as the firmware's routine returns them */
#define WIO_XFER_NOACK   (-1)
#define WIO_XFER_ERROR   (-2)

typedef struct wio_host {
    void *user;
    /* one byte left SIO1 with the RS-485 driver enabled (end of its stop bit) */
    void (*bus_tx)(void *user, uint8_t b, uint64_t cyc);
    /* JVS sense output to the host (PIO1 bit 29) changed */
    void (*sense)(void *user, int level, uint64_t cyc);
    /* EXTERNAL card port: a write of the card register (select/clock/command
     * levels) outside the byte exchange routine; posted, in order */
    void (*card_reg)(void *user, uint8_t v, uint64_t cyc);
    /* EXTERNAL card port: a write of the /ACK latch clear (FPGA +05) outside the
     * byte exchange routine (fw 0x80005804 / 0x80005a58 clear it before each
     * command); posted, in order with card_reg */
    void (*card_latch_clr)(void *user, uint64_t cyc);
    /* EXTERNAL card port: start the firmware's byte exchange routine
     * (fw 0x8000560c, see wio.c) on real hardware.  'reg' is the card register
     * as the routine finds it (selects), 'cmd' the byte to send, ack_timeout_us
     * its /ACK timeout (0 = last byte, no /ACK wait).  The board keeps running
     * (interrupts are taken) until card_xfer_done reports the result. */
    void (*card_xfer_start)(void *user, uint8_t reg, uint8_t cmd, unsigned ack_timeout_us, uint64_t cyc);
    /* returns 1 once the exchange finished: *result = 0..255, WIO_XFER_NOACK or
     * WIO_XFER_ERROR, *done_cyc = when it finished (<= the current cycle is fine);
     * returns 0 while it is still running, *done_cyc = earliest completion
     * estimate or UINT64_MAX if unknown */
    int  (*card_xfer_done)(void *user, int *result, uint64_t *done_cyc);
    /* free-form log line (no newline) */
    void (*log)(void *user, const char *line);
} wio_host_t;

typedef struct wio_stats {
    uint64_t insns, idle_skipped;
    uint64_t interp;            /* instructions actually interpreted (insns includes shortcuts) */
    uint32_t resets, wd_resets;
    uint32_t rx_bytes, tx_bytes, rx_dropped;
    uint32_t fpga_configs, card_xfers_ext;
    uint32_t unmapped;
    uint32_t fatal;             /* firmware reached its fatal-error loop */
} wio_stats_t;

typedef struct wio wio_t;

wio_t   *wio_create(const wio_host_t *host);
void     wio_destroy(wio_t *w);
/* boot ROM image as stored in MAME's 885a01.bin (16-bit byte-swapped), 512 KB */
int      wio_load_rom(wio_t *w, const uint8_t *img, size_t len);
/* power-on reset of the whole board */
void     wio_power_on(wio_t *w);

/* JVS byte arriving at the board's receiver at cycle 'cyc' (must be >= now) */
void     wio_bus_rx(wio_t *w, uint8_t b, uint64_t cyc);
/* run until 'until' cycles; returns the cycle reached */
uint64_t wio_run(wio_t *w, uint64_t until);
uint64_t wio_now(const wio_t *w);
/* earliest cycle at which something inside the board will happen by itself
 * (a timer, a byte finishing, a card /ACK); UINT64_MAX if the CPU is busy */
uint64_t wio_next_event(const wio_t *w);
/* 1 if the CPU is parked in a recognised idle loop (nothing to do until an event) */
int      wio_idle(const wio_t *w);

/* card ports 0 and 1 (port 0 = cabinet player 1 side) */
void     wio_port_mode(wio_t *w, int port, int mode);
wio_card_t *wio_port_card(wio_t *w, int port);   /* the virtual card of a port */

int      wio_sense_out(const wio_t *w);           /* current PIO1 bit 29 level */
const wio_stats_t *wio_stats(const wio_t *w);
/* firmware identity: CRC-32 of 0x80000000..0x8000608f taken when the CPU first
 * executes there (the uploaded program, as unpacked; 0 if it has not run) */
uint32_t wio_fw_crc(const wio_t *w);
const wio_cpu_t *wio_cpu(const wio_t *w);
/* debug: read board memory (virtual address) */
int      wio_peek(wio_t *w, uint32_t va, int size, uint32_t *v);
void     wio_trace(wio_t *w, int on);

#ifdef __cplusplus
}
#endif
#endif
