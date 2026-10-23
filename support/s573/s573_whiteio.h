/* -----------------------------------------------------------------------------
 * s573_whiteio.h - Konami GE885-PWB(A) "White I/O" memory card reader, modelled
 *                  at its JVS packet interface (HLE).
 *
 * What the board is (psx-spx, arcade/konami/573/external-modules.md): a JVS device
 * with a Toshiba TMPR3904 CPU, an XCS10XL FPGA, 512 KB RAM and a 512 KB boot ROM.
 * "The ROM is only a small bootloader and the actual firmware is downloaded from
 * the 573 into RAM." Two PS1 memory card ports (and two security-dongle sockets).
 *
 * This module reproduces, command by command, the two programs that run on it:
 *   - the boot ROM 885a01.bin (SHA-1 927f62f6..., "Thu Mar 25 14:05:44 JST 1999",
 *     stored 16-bit byte-swapped), which accepts a firmware upload;
 *   - the firmware DDR 4thMIX uploads (every a33 executable carries the same
 *     container: SHA-1 of the decompressed program 1a585688e78ff513...).
 * Both were disassembled (big-endian MIPS); the findings, with addresses, are in
 * docs/2026-10-23-memory-card-reader.md. Nothing here is taken from MAME's
 * k573mcr HLE except where that document says so.
 *
 * The card algorithm (mcard.c in the firmware) runs over a byte-level card port
 * interface, so the same code drives a virtual card (wio_vcard_*) or a real PS1
 * card on the SNAC port through the fabric's byte engine.
 *
 * Pure C99, no I/O: host-testable (support/s573/tests/test_s573_whiteio.c).
 * Released under the GNU GPL v2.
 * ---------------------------------------------------------------------------- */
#ifndef S573_WHITEIO_H
#define S573_WHITEIO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WIO_RAM_SIZE   0x80000u    /* 512 KB; every RAM address check is against this */
#define WIO_FRAME      128         /* PS1 memory card sector */
#define WIO_CARD_SIZE  (1024 * WIO_FRAME)

/* Status word (0x71), firmware gp-0x7580. Card result codes from the table at
 * 0x80005f10 indexed by (1 - result). */
#define WIO_ST_FPGA_NOT_READY  0x0001   /* set at start; cleared by a successful 0x73  */
#define WIO_ST_CARD_ERR_READ   0x0002   /* read op -2                       (sticky)    */
#define WIO_ST_CARD_ERR_WRITE  0x0004   /* write op -2 (reported as -4)     (sticky)    */
#define WIO_ST_CARD_NONE       0x0008   /* op -1: no card answered          (sticky)    */
#define WIO_ST_CARD_FLAG4      0x0010   /* write op -3: card FLAG was 04h   (sticky)    */
#define WIO_ST_PLATE_NODEV     0x0020   /* dongle op -2                                 */
#define WIO_ST_PLATE_PWERR     0x0040   /* dongle op -1 / set by 0x721x clear           */
#define WIO_ST_FPGA_BUSY       0x0100
#define WIO_ST_CARD_READING    0x0200
#define WIO_ST_CARD_WRITING    0x0400
#define WIO_ST_PLATE_RW        0x0800
#define WIO_ST_PLATE_CFG       0x1000
#define WIO_ST_PLATE_MASS      0x2000
#define WIO_ST_PLATE_PW        0x4000
#define WIO_ST_PLATE_BUSY      0x7800
#define WIO_ST_CARD_SEEN       0x8000   /* op result 1: first frame's FLAG was not 08h  */

/* Card port byte interface. ack_mode: 0 = the firmware does not wait for /ACK
 * (last byte of a command), 1 = normal timeout (0x28), 2 = long (0x7d0, the
 * byte after which Sony cards ACK late). xfer returns 1 = /ACK seen (or not
 * waited for), 0 = /ACK timeout, -2 = ACK line in the wrong state (0x8000560c's
 * other failure). */
typedef struct wio_card_io {
    void (*select)(void *ctx, int port, int on);
    int  (*xfer)(void *ctx, int port, uint8_t tx, int ack_mode, uint8_t *rx);
    void *ctx;
} wio_card_io_t;

enum { WIO_BOOT = 0, WIO_FW = 1 };

typedef struct wio {
    int       mode;
    uint8_t   addr;            /* JVS address; 0xff = unassigned (sense released) */
    int       fw_ok;           /* the uploaded program is the one this HLE models */
    uint32_t  fw_crc;          /* CRC-32 of what the stub would have unpacked      */
    uint16_t  status;
    uint8_t   ram[WIO_RAM_SIZE];

    uint8_t   prev[256];       /* last response body, for 0x2f (initially 01 01)   */
    int       prev_len;

    /* firmware jobs (one card task, one FPGA task, one dongle task, as on the board) */
    struct {
        int      active, write, port, frame, count, i, s3;
        uint32_t ram;
        int      result;
        uint64_t done_us;      /* completion time (virtual) */
    } op;
    int       fpga_active;  uint64_t fpga_done_us;
    int       plate_active; uint64_t plate_done_us;
    uint8_t   pw[2][8];
    uint8_t   cflag[2];        /* firmware gp-0x7eb0: per port, card FLAG != 08h   */
    uint64_t  last_write_us;   /* firmware gp-0x7eac */

    wio_card_io_t io;
    uint64_t  now_us;
    uint64_t  cost_us;         /* time the current card transaction has taken      */
    unsigned  log_unknown;     /* counters for the service log */
    unsigned  n_packets, n_card_ops;
} wio_t;

void     wio_init(wio_t *w, const wio_card_io_t *io);
void     wio_power_on(wio_t *w);              /* boot ROM, address 0xff */
/* One request as the 573 handed it to its JVS MCU: E0 dst len payload.. sum.
 * Returns the response length (E0 00 len status reports.. sum) or 0 when the
 * board does not answer. resp must hold 260 bytes. */
int      wio_packet(wio_t *w, const uint8_t *req, int len, uint8_t *resp);
/* Advance pending jobs to now_us. max_frames bounds card frames per call (the
 * real-card path blocks the caller for one PS1 card transaction per frame). */
void     wio_tick(wio_t *w, uint64_t now_us, int max_frames);
int      wio_sense(const wio_t *w);           /* 573-side JVS sense: 1 = unaddressed */
uint32_t wio_crc32(const uint8_t *p, uint32_t n);

/* ---- virtual PS1 memory card (psx-spx "Memory Card Read/Write Commands") ---- */
typedef struct wio_vcard {
    uint8_t  data[WIO_CARD_SIZE];
    int      inserted;
    uint8_t  flag;             /* 08h at power-up/insertion, bit3 cleared by a write */
    int      dirty;
    /* transaction state */
    int      idx, cmd, abort;
    uint16_t sector;
    uint8_t  chk, last_tx;
    uint8_t  wbuf[WIO_FRAME];
} wio_vcard_t;

void wio_vcard_insert(wio_vcard_t *c, int inserted);
/* the byte the card puts on DAT for tx; returns 1 if it then pulls /ACK */
int  wio_vcard_byte(wio_vcard_t *c, uint8_t tx, uint8_t *rx);
void wio_vcard_select(wio_vcard_t *c);

/* virtual timing per byte / late ACK, see the .c (used by the virtual card io) */
#define WIO_US_PER_BYTE   72
#define WIO_US_LATE_ACK   915

#ifdef __cplusplus
}
#endif
#endif
