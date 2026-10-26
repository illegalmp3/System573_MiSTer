/*
 * s573_wio_card.h -- a PlayStation memory card at the byte level, as psx-spx
 * ("Controllers and Memory Cards": Memory Card Read/Write Commands, FLAG Byte,
 * Timings; Controller and Memory Card Signals) describes an original Sony card.
 *
 * The card sees one byte at a time while selected.  The byte it shifts OUT during
 * a transfer is decided before that transfer starts (psx-spx "Synchronous I/O"),
 * so the model keeps the next output byte ready and, when a transfer completes,
 * says whether it acknowledges (pulls /ACK low) and after how long.
 */
#ifndef WIO_CARD_H
#define WIO_CARD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WIO_CARD_SIZE 131072

typedef struct wio_card {
    uint8_t  data[WIO_CARD_SIZE];
    int      present;       /* inserted                                       */
    uint8_t  flag;          /* FLAG byte: 08h after power-up / insertion       */
    /* transfer state (valid while selected) */
    int      selected;
    int      idx;           /* bytes completed in this selection              */
    int      dead;          /* not addressed / aborted: ignore until deselect */
    uint8_t  cmd;           /* 'R', 'W' or 'S'                                */
    uint8_t  msb, lsb;
    uint8_t  chk;
    uint8_t  out;           /* byte driven during the next transfer           */
    uint8_t  wbuf[128];
    /* bookkeeping for the host */
    int      dirty;         /* written since the host last saved it           */
    uint8_t  dirty_map[1024 / 8];   /* ... which frames (bit f = frame f)    */
    uint32_t reads, writes, bad_writes;
} wio_card_t;

/* result of one completed byte */
typedef struct {
    int      ack;           /* 1 = the card pulls /ACK low                    */
    uint32_t ack_delay_ns;  /* from the last rising clock edge to /ACK low    */
} wio_card_ack_t;

void    wio_card_insert(wio_card_t *c);        /* FLAG = 08h, not selected     */
void    wio_card_eject(wio_card_t *c);
void    wio_card_select(wio_card_t *c, int sel);
/* the byte the card drives during the coming transfer (0xff = not driving) */
static inline uint8_t wio_card_out(const wio_card_t *c) { return (c->present && c->selected && !c->dead) ? c->out : 0xff; }
/* a full byte was clocked in */
wio_card_ack_t wio_card_byte(wio_card_t *c, uint8_t in);
/* a blank card formatted as psx-spx "Memory Card Data Format" describes */
void    wio_card_format(uint8_t *img);

/* psx-spx Timings: /ACK ~1500 SIO clocks (33.8688 MHz) after the start of a byte,
 * i.e. ~12 us after the last of its eight 4 us bits; an extra ~31000 cycles
 * (915 us) after the 7th byte of a Read on original Sony cards; /ACK low for
 * ~100 cycles (psx-spx "Sony Mouse ... around 100 clk cycles"; >= 2 us). */
#define WIO_CARD_ACK_NS       12000u
#define WIO_CARD_ACK_LATE_NS  915000u
#define WIO_CARD_ACK_WIDTH_NS 3000u

#ifdef __cplusplus
}
#endif
#endif
