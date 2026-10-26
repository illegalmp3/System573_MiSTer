/*
 * s573_wio_card.c -- PlayStation memory card (byte level).  See wio_card.h.
 *
 * Read  (psx-spx): 81 52 00 00 MSB LSB 00 00 00 00 [128 x 00] 00 00
 *          reply: -- FL 5A 5D 00  pre 5C 5D MSB LSB [data]    CHK 47
 * Write (psx-spx): 81 57 00 00 MSB LSB [128 data] CHK 00 00 00
 *          reply: -- FL 5A 5D 00  pre [pre ...]   pre 5C 5D 47/4E/FF
 * Get ID:          81 53 00 00 00 00 00 00 00 00
 *          reply: -- FL 5A 5D 5C 5D 04 00 00 80
 * /ACK follows every byte except the last of a command.  Original Sony cards answer
 * an out-of-range Read sector with FFFF as the confirmed address and stop there.
 */
#include "s573_wio_card.h"
#include <string.h>

void wio_card_insert(wio_card_t *c)
{
    c->present = 1;
    c->flag = 0x08;           /* psx-spx FLAG Byte: 08h on power-up / insertion */
    c->selected = 0;
    c->dead = 0;
    c->idx = 0;
}

void wio_card_eject(wio_card_t *c)
{
    c->present = 0;
    c->selected = 0;
}

void wio_card_select(wio_card_t *c, int sel)
{
    if (sel && !c->selected) {
        c->idx = 0;
        c->dead = 0;
        c->out = 0xff;        /* nothing driven during the address byte */
    }
    c->selected = sel;
}

static wio_card_ack_t ack(uint32_t ns) { wio_card_ack_t a = { 1, ns }; return a; }
static wio_card_ack_t nack(void)       { wio_card_ack_t a = { 0, 0 }; return a; }

wio_card_ack_t wio_card_byte(wio_card_t *c, uint8_t in)
{
    int i;
    if (!c->present || !c->selected || c->dead) return nack();
    i = c->idx++;

    if (i == 0) {                                   /* address */
        if (in != 0x81) { c->dead = 1; return nack(); }
        c->out = c->flag;
        return ack(WIO_CARD_ACK_NS);
    }
    if (i == 1) {                                   /* command */
        if (in != 'R' && in != 'W' && in != 'S') { c->dead = 1; return nack(); }
        c->cmd = in;
        c->out = 0x5a;
        return ack(WIO_CARD_ACK_NS);
    }
    if (i == 2) { c->out = 0x5d; return ack(WIO_CARD_ACK_NS); }

    if (c->cmd == 'S') {
        static const uint8_t id[] = { 0x5c, 0x5d, 0x04, 0x00, 0x00, 0x80 };
        /* i == 3 is the byte that returned 5D; the reply list starts after it */
        if (i - 3 < (int)sizeof id) {
            c->out = id[i - 3];
            return ack(WIO_CARD_ACK_NS);
        }
        c->dead = 1;                                /* 80h was the last byte */
        return nack();
    }

    if (i == 3) { c->out = 0x00; return ack(WIO_CARD_ACK_NS); }      /* reply to MSB */
    if (i == 4) { c->msb = in; c->out = in; return ack(WIO_CARD_ACK_NS); } /* pre */
    if (i == 5) {
        c->lsb = in;
        c->chk = c->msb ^ c->lsb;
        if (c->cmd == 'R') { c->out = 0x5c; return ack(WIO_CARD_ACK_NS); }
        c->out = in;                                /* write: pre */
        return ack(WIO_CARD_ACK_NS);
    }

    if (c->cmd == 'R') {
        unsigned sector = ((unsigned)c->msb << 8) | c->lsb;
        int bad = sector > 0x3ff;
        if (i == 6) { c->out = 0x5d; return ack(WIO_CARD_ACK_LATE_NS); } /* sent 5C: Sony late /ACK */
        if (i == 7) { c->out = bad ? 0xff : c->msb; return ack(WIO_CARD_ACK_NS); }
        if (i == 8) {
            c->out = bad ? 0xff : c->lsb;
            return ack(WIO_CARD_ACK_NS);
        }
        if (bad) { c->dead = 1; return nack(); }    /* stop after FFFF */
        if (i >= 9 && i < 9 + 128) {
            uint8_t d = c->data[sector * 128 + (unsigned)(i - 9)];
            c->out = d;
            c->chk ^= d;
            if (i == 9) c->reads++;
            return ack(WIO_CARD_ACK_NS);
        }
        if (i == 9 + 128) { c->out = c->chk; return ack(WIO_CARD_ACK_NS); }
        if (i == 9 + 129) { c->out = 0x47; return ack(WIO_CARD_ACK_NS); }
        c->dead = 1;                                /* 47h sent: end, no /ACK */
        return nack();
    }

    /* write */
    if (i >= 6 && i < 6 + 128) {
        c->wbuf[i - 6] = in;
        c->chk ^= in;
        c->out = in;                                /* pre */
        return ack(WIO_CARD_ACK_NS);
    }
    if (i == 6 + 128) {                             /* checksum byte */
        c->out = 0x5c;
        c->chk ^= in;                               /* 0 if it matched */
        return ack(WIO_CARD_ACK_NS);
    }
    if (i == 6 + 129) { c->out = 0x5d; return ack(WIO_CARD_ACK_NS); }
    if (i == 6 + 130) {
        unsigned sector = ((unsigned)c->msb << 8) | c->lsb;
        if (sector > 0x3ff) c->out = 0xff;
        else if (c->chk != 0) { c->out = 0x4e; c->bad_writes++; }
        else {
            memcpy(&c->data[sector * 128], c->wbuf, 128);
            c->flag &= (uint8_t)~0x08;              /* psx-spx: bit 3 reset by a write */
            c->dirty = 1;
            c->dirty_map[sector >> 3] |= (uint8_t)(1u << (sector & 7));
            c->writes++;
            c->out = 0x47;
        }
        return ack(WIO_CARD_ACK_NS);
    }
    c->dead = 1;                                    /* end byte sent */
    return nack();
}

/* psx-spx "Memory Card Data Format": frame 0 = "MC" + checksum; frames 1..15 =
 * free directory entries (state 000000A0h, next-block FFFFh, checksum); frames
 * 16..35 = broken-sector list (FFFFFFFFh = none, the rest 00h, checksum);
 * frames 36..62 FFh-filled ("usually"); frame 63 = write-test copy of frame 0.
 * Blocks 1..15 are zero. */
void wio_card_format(uint8_t *img)
{
    int f, i;
    uint8_t x;
    memset(img, 0, WIO_CARD_SIZE);
    img[0] = 'M'; img[1] = 'C';
    for (f = 1; f <= 15; f++) {
        uint8_t *e = img + f * 128;
        e[0] = 0xa0;
        e[8] = 0xff; e[9] = 0xff;
    }
    for (f = 16; f <= 35; f++) {          /* "(usually 00h-filled)" otherwise */
        uint8_t *e = img + f * 128;
        e[0] = e[1] = e[2] = e[3] = 0xff;
    }
    memset(img + 36 * 128, 0xff, (63 - 36) * 128);
    for (f = 0; f <= 35; f++) {
        uint8_t *e = img + f * 128;
        x = 0;
        for (i = 0; i < 127; i++) x ^= e[i];
        e[127] = x;
    }
    memcpy(img + 63 * 128, img, 128);
}
