/* -----------------------------------------------------------------------------
 * s573wio.cpp - the DDR memory card reader (Konami GE885-PWB(A), "White I/O")
 *
 * A DDR cabinet's card reader is a board of its own on the 573's JVS port: a
 * Toshiba TMPR3904F CPU running a boot ROM (885a01) and a program the game
 * uploads, an FPGA it configures, and two PS1 memory card slots. The 573 talks
 * to it through its JVS MCU. This service is the board:
 *
 *   - the board itself is emulated at the hardware level by s573_wio.c (CPU,
 *     TX3904 peripherals, the board's FPGA registers, PS1 cards at the byte
 *     level), running in its own thread on core 0, in step with the wall clock;
 *   - the fabric (rtl/s573_wio.v) is the 573's JVS MCU and, for real cards on
 *     SNAC, the reader program's card byte exchange done at the pins. Main's
 *     thread talks to it over CMD_573_WIO (0x6F) once per Main loop pass:
 *     requests the 573 sent come up, the board's responses, its sense line and
 *     its card port traffic go down.
 *   - card files: OSD slots S2 (player 1) and S3 (player 2) hold raw 128 KB
 *     card images (.mcd / .mcr / .sav: psx-spx "Memory Card Images"). The
 *     service reads the image the moment it is mounted and writes every frame
 *     the game changes back to the file, from a writer thread.
 *
 * Nothing here runs unless the fabric says a reader is fitted (OSD "573 Card
 * Reader": Auto = the DDR control profiles) -- status word bit 14.
 *
 * Docs: docs/2026-10-26-white-io-reader.md (sources, register maps, protocol).
 * Released under the GNU GPL v2.
 * ---------------------------------------------------------------------------- */
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <pthread.h>
#include <sched.h>
#include <sys/stat.h>

#ifdef S573_HOST_TEST
#include "tests/host_main_stubs.h"   /* tests/test_s573wio.cpp: a model of the fabric */
#else
#include "../../spi.h"
#include "../../user_io.h"
#include "../../menu.h"
#include "../../file_io.h"
#endif

#include "s573_wio.h"

/* s573mp3.cpp: the shared session log */
extern void s573_logf(const char *fmt, ...);

#define CMD_573_WIO  0x6F
enum { OP_NOP = 0, OP_ATTACH = 1, OP_SENSE = 2, OP_CARDREG = 3, OP_LATCHCLR = 4,
       OP_XFER = 5, OP_GETREQ = 6, OP_PUTRESP = 7 };

/* status word (word 0 of every CMD_573_WIO) */
#define ST_ATTACHED  0x8000
#define ST_OSD_EN    0x4000
#define ST_WAITING   0x2000
#define ST_BUSY      0x1000
#define ST_DONE      0x0800

#define BOOT_ROM_NAME   "885a01.bin"
#define BOOT_ROM_CRC    0xe22d093fu          /* MAME k573mcr.cpp ROM_LOAD */
#define CARD_SLOT0      2                    /* OSD S2 = player 1, S3 = player 2 */
#define JVS_BYTE_CYC    5729u                /* 10 bits at 115200 Bd, 66 MHz board clock */
#define JVS_GAP_CYC     (200u * WIO_CYC_PER_US) /* psx-spx: the MCU's 200 us gap */

static uint64_t mono_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static uint32_t crc32_of(const uint8_t *p, size_t n)
{
    uint32_t c = 0xffffffffu;
    size_t i;
    int k;
    for (i = 0; i < n; i++) {
        c ^= p[i];
        for (k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320u & (0u - (c & 1u)));
    }
    return ~c;
}

/* ===================================================================== queues
 * Main -> board (inbox) and board -> fabric (two outboxes: the JVS side and the
 * card port side are independent; each keeps its own order). All three are
 * small and protected by one mutex; nothing holds it for more than a copy. */

enum { M_REQ = 1, M_XFER_DONE, M_CARD, M_MODE, M_POWER, M_PULL };

typedef struct {
    int      type;
    int      port;              /* M_CARD / M_MODE                       */
    int      a, b;              /* M_XFER_DONE: result; M_CARD: fd, writable; M_MODE: mode; M_POWER: on;
                                   M_PULL: 1 = the card is out of the slot */
    uint8_t  seq;               /* M_REQ                                  */
    uint16_t len;
    uint8_t  data[264];
    char     name[96];          /* M_CARD: for the log                    */
} msg_t;

typedef struct {
    uint8_t  op, arg;
    uint16_t w2;                /* XFER timeout / PUTRESP length          */
    uint8_t  seq;               /* PUTRESP                                */
    uint8_t  data[264];
} op_t;

#define INBOX_N   32
#define JVSQ_N    16
#define CARDQ_N   64

static pthread_mutex_t q_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  q_cv = PTHREAD_COND_INITIALIZER;
static msg_t   inbox[INBOX_N];  static unsigned in_h, in_t;
static op_t    jvsq[JVSQ_N];    static unsigned jq_h, jq_t;
static op_t    cardq[CARDQ_N];  static unsigned cq_h, cq_t;
static uint32_t q_overflow;

static int post_msg(const msg_t *m)
{
    int ok = 0;
    pthread_mutex_lock(&q_mx);
    if (in_h - in_t < INBOX_N) { inbox[in_h++ % INBOX_N] = *m; ok = 1; } else q_overflow++;
    pthread_cond_signal(&q_cv);
    pthread_mutex_unlock(&q_mx);
    return ok;
}

static void post_op(int jvs, const op_t *o)
{
    pthread_mutex_lock(&q_mx);
    if (jvs) { if (jq_h - jq_t < JVSQ_N)  jvsq[jq_h++ % JVSQ_N] = *o;   else q_overflow++; }
    else     { if (cq_h - cq_t < CARDQ_N) cardq[cq_h++ % CARDQ_N] = *o; else q_overflow++; }
    pthread_mutex_unlock(&q_mx);
}

static int take_op(int jvs, op_t *o)
{
    int ok = 0;
    pthread_mutex_lock(&q_mx);
    if (jvs) { if (jq_h != jq_t) { *o = jvsq[jq_t++ % JVSQ_N];  ok = 1; } }
    else     { if (cq_h != cq_t) { *o = cardq[cq_t++ % CARDQ_N]; ok = 1; } }
    pthread_mutex_unlock(&q_mx);
    return ok;
}

/* ===================================================================== writer
 * Card frames the game wrote go back to the card file from here, so a slow SD
 * card never holds up the board (Main opens images O_SYNC). Each job carries its
 * own dup() of the file, so an eject meanwhile cannot redirect it. */
typedef struct { int fd; uint32_t off; uint8_t d[128]; } wjob_t;
#define WQ_N 2048
static wjob_t          wq[WQ_N];
static unsigned        wq_h, wq_t;
static pthread_mutex_t wq_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  wq_cv = PTHREAD_COND_INITIALIZER;
static uint32_t        w_frames, w_errors, w_dropped;

static void *writer_main(void *arg)
{
    (void)arg;
    for (;;) {
        wjob_t j;
        ssize_t r;
        pthread_mutex_lock(&wq_mx);
        while (wq_h == wq_t) pthread_cond_wait(&wq_cv, &wq_mx);
        j = wq[wq_t++ % WQ_N];
        pthread_mutex_unlock(&wq_mx);
        r = pwrite(j.fd, j.d, 128, j.off);
        if (r != 128) {
            w_errors++;
            s573_logf("s573wio: card file write at %06x FAILED: %s\n", j.off,
                      r < 0 ? strerror(errno) : "short write");
        } else w_frames++;
        close(j.fd);
    }
    return 0;
}

static void queue_write(int fd, uint32_t off, const uint8_t *d)
{
    int nfd = dup(fd);
    if (nfd < 0) { w_errors++; return; }
    pthread_mutex_lock(&wq_mx);
    if (wq_h - wq_t < WQ_N) {
        wjob_t *j = &wq[wq_h++ % WQ_N];
        j->fd = nfd; j->off = off; memcpy(j->d, d, 128);
        pthread_cond_signal(&wq_cv);
        nfd = -1;
    } else w_dropped++;
    pthread_mutex_unlock(&wq_mx);
    if (nfd >= 0) close(nfd);
}

/* ===================================================================== the board
 * Everything below up to the Main side runs in the board thread only. */

static wio_t     *brd;
static uint8_t   *boot_rom;          /* 512 KB, as MAME stores it              */
static uint64_t   t0_ns, t0_cyc;     /* wall clock <-> board cycles            */
static int        powered;
static int        port_mode[2];      /* 0 = file, 1 = SNAC                     */
static int        card_fd[2] = { -1, -1 };
static int        card_wr[2];
static char       card_name[2][96];
static int        card_out[2];       /* "Card In/Out": the file's card is out of its slot */

/* JVS: the request being answered and the response being collected */
static int        req_open;          /* a request went to the board            */
static uint8_t    req_seq;
static uint64_t   last_rx_end;       /* when the board's last response ended   */
static uint8_t    rsp[264];
static int        rsp_n, rsp_esc, rsp_in;
static uint32_t   n_req, n_rsp, n_rsp_bad, n_rsp_orphan;
static uint8_t    req_cmd;
static int        quiet;
static uint32_t   ram_writes, ram_bytes, ram_lo, ram_hi;
static unsigned   last_status71 = 0xffffffffu;

/* card port (SNAC) */
static int        xfer_wait;         /* the routine is parked on the hardware  */
static int        xfer_have;
static int        xfer_result;
static uint32_t   n_xfer;
static uint64_t   lag_max;           /* the board behind the wall clock, worst, per 10 s */

static uint64_t wall_cyc(void)
{
    return t0_cyc + (mono_ns() - t0_ns) * WIO_CYC_PER_US / 1000u;
}

static void cb_log(void *u, const char *s) { (void)u; s573_logf("s573wio: board: %s\n", s); }

static void cb_sense(void *u, int level, uint64_t cyc)
{
    op_t o;
    (void)u; (void)cyc;
    memset(&o, 0, sizeof o);
    o.op = OP_SENSE; o.arg = (uint8_t)(level ? 1 : 0);
    post_op(1, &o);
    s573_logf("s573wio: JVS sense -> %d\n", level);
}

static const char *jvs_cmd_name(uint8_t c)
{
    switch (c) {
    case 0x10: return "ID";
    case 0x70: return "RAM";
    case 0x71: return "status";
    case 0x73: return "configure FPGA";
    case 0x74: return "card read";
    case 0x75: return "card write";
    case 0x76: return "clear errors";
    case 0xf0: return "reset";
    case 0xf1: return "set address";
    default:   return "?";
    }
}

/* The game polls: with no card in it sends "76 + 74" and "71" about three times a
 * second for as long as the slot stays empty. A request, response or status the
 * log has shown in the last 5 s is counted instead of shown again. */
static uint32_t log_suppressed;
static int recently(uint32_t key)
{
    static struct { uint32_t key; uint64_t ns; } tab[32];
    static unsigned next;
    uint64_t now = mono_ns();
    unsigned i;
    for (i = 0; i < 32; i++)
        if (tab[i].ns && tab[i].key == key && now - tab[i].ns < 5000000000ull) { log_suppressed++; return 1; }
    for (i = 0; i < 32; i++) if (tab[i].ns && tab[i].key == key) break;
    if (i == 32) i = next++ % 32;
    tab[i].key = key; tab[i].ns = now;
    return 0;
}

/* one line for a request: every command in the packet (the game sends several
 * at once, e.g. 76 + 74), with the arguments of the card commands decoded */
static void log_request(const uint8_t *pk, int len, uint8_t seq)
{
    char line[400];
    int n = 0, i = 3, end = len - 1;      /* payload: after E0 dst len, before the sum */
    n += snprintf(line + n, sizeof line - n, "s573wio: JVS -> %02x:", pk[1]);
    while (i < end && n < (int)sizeof line - 80) {
        uint8_t c = pk[i];
        int k;
        switch (c) {
        case 0x74: case 0x75:
            if (i + 8 > end) goto raw;
            {
                unsigned pf = c == 0x74 ? ((unsigned)pk[i + 1] << 8 | pk[i + 2]) : ((unsigned)pk[i + 4] << 8 | pk[i + 5]);
                unsigned ra = c == 0x74 ? ((unsigned)pk[i + 3] << 16 | pk[i + 4] << 8 | pk[i + 5])
                                        : ((unsigned)pk[i + 1] << 16 | pk[i + 2] << 8 | pk[i + 3]);
                unsigned cnt = (unsigned)pk[i + 6] << 8 | pk[i + 7];
                n += snprintf(line + n, sizeof line - n, " [%s player %u frame %03x x%u %s RAM %06x]",
                              c == 0x74 ? "74 card read" : "75 card write", (pf >> 15) + 1, pf & 0x3ff, cnt,
                              c == 0x74 ? "->" : "<-", ra);
            }
            i += 8; break;
        case 0x70:
            if (i + 2 > end) goto raw;
            if (pk[i + 1] == 0x00 && i + 6 <= end) {
                n += snprintf(line + n, sizeof line - n, " [70 RAM read %02x%02x%02x x%u]", pk[i + 2], pk[i + 3], pk[i + 4], pk[i + 5]);
                i += 6;
            } else if (pk[i + 1] == 0x01 && i + 6 <= end) {
                n += snprintf(line + n, sizeof line - n, " [70 RAM write %02x%02x%02x x%u]", pk[i + 2], pk[i + 3], pk[i + 4], pk[i + 5]);
                i += 6 + pk[i + 5];
            } else if (pk[i + 1] == 0x02 && i + 5 <= end) {
                n += snprintf(line + n, sizeof line - n, " [70 run at %02x%02x%02x]", pk[i + 2], pk[i + 3], pk[i + 4]);
                i += 5;
            } else goto raw;
            break;
        case 0xf0: case 0xf1:
            if (i + 2 > end) goto raw;
            n += snprintf(line + n, sizeof line - n, " [%02x %02x %s]", c, pk[i + 1], jvs_cmd_name(c));
            i += 2; break;
        case 0x10: case 0x11: case 0x12: case 0x13: case 0x14: case 0x15:
        case 0x71: case 0x73: case 0x76:
            n += snprintf(line + n, sizeof line - n, " [%02x %s]", c, jvs_cmd_name(c));
            i += 1; break;
        default:
        raw:
            for (k = i; k < end && n < (int)sizeof line - 8; k++) n += snprintf(line + n, sizeof line - n, " %02x", pk[k]);
            i = end; break;
        }
    }
    snprintf(line + n, sizeof line - n, " (seq %u)\n", seq);
    s573_logf("%s", line);
}

static void response_done(void)
{
    uint8_t sum = 0;
    int i, len = rsp[2];
    op_t o;
    for (i = 1; i < 3 + len - 1; i++) sum = (uint8_t)(sum + rsp[i]);
    if (sum != rsp[3 + len - 1]) n_rsp_bad++;
    last_rx_end = wio_now(brd);
    if (rsp[1] != 0x00) return;                  /* not for the host */
    if (!req_open) { n_rsp_orphan++; return; }
    memset(&o, 0, sizeof o);
    o.op = OP_PUTRESP; o.w2 = (uint16_t)(3 + len); o.seq = req_seq;
    memcpy(o.data, rsp, 3 + len);
    post_op(1, &o);
    req_open = 0;
    n_rsp++;
    /* the game asks for the board status (71) many times a second: log it only
     * when the answer changes */
    if (quiet && req_cmd != 0x71) return;            /* (71: by its answer, below) */
    if (req_cmd == 0x71 && len == 5) {
        unsigned v = (unsigned)rsp[5] << 8 | rsp[6];
        if (v == last_status71) return;
        last_status71 = v;
        if (recently(0x71000000u | v)) return;
        s573_logf("s573wio: board status %04x%s%s%s%s%s%s%s\n", v, v & 0x0001 ? " FPGA-unconfigured" : "",
                  v & 0x0008 ? " no-card" : "", v & 0x0006 ? " card-error" : "", v & 0x0100 ? " configuring" : "",
                  v & 0x0200 ? " reading" : "", v & 0x0400 ? " writing" : "", v & 0x8000 ? " flag" : "");
        return;
    }
    if (recently(0x52000000u ^ crc32_of(rsp, (size_t)(3 + len)))) return;
    s573_logf("s573wio: JVS <- %d bytes: %02x %02x%s\n", 3 + len, len > 1 ? rsp[3] : 0, len > 2 ? rsp[4] : 0,
              sum == rsp[3 + len - 1] ? "" : " (BAD CHECKSUM)");
}

/* one byte left the board's RS-485 driver */
static void cb_bus_tx(void *u, uint8_t b, uint64_t cyc)
{
    (void)u; (void)cyc;
    if (b == 0xe0) { rsp_in = 1; rsp_n = 0; rsp_esc = 0; rsp[rsp_n++] = b; return; }
    if (!rsp_in) return;
    if (b == 0xd0 && !rsp_esc) { rsp_esc = 1; return; }
    if (rsp_esc) { b = (uint8_t)(b + 1); rsp_esc = 0; }   /* psx-spx: D0 CF / D0 DF */
    if (rsp_n < (int)sizeof rsp) rsp[rsp_n++] = b;
    if (rsp_n >= 3 && rsp_n == 3 + rsp[2]) { rsp_in = 0; response_done(); }
}

static uint8_t last_reg = 0xff;
static void cb_card_reg(void *u, uint8_t v, uint64_t cyc)
{
    op_t o;
    (void)u; (void)cyc;
    last_reg = v;
    memset(&o, 0, sizeof o);
    o.op = OP_CARDREG; o.arg = v;
    post_op(0, &o);
}

static void cb_card_latch_clr(void *u, uint64_t cyc)
{
    op_t o;
    (void)u; (void)cyc;
    memset(&o, 0, sizeof o);
    o.op = OP_LATCHCLR;
    post_op(0, &o);
}

static void cb_xfer_start(void *u, uint8_t reg, uint8_t cmd, unsigned to_us, uint64_t cyc)
{
    op_t o;
    (void)u; (void)cyc;
    if (reg != last_reg) cb_card_reg(u, reg, cyc);
    memset(&o, 0, sizeof o);
    o.op = OP_XFER; o.arg = cmd; o.w2 = (uint16_t)(to_us > 0xffff ? 0xffff : to_us);
    post_op(0, &o);
    xfer_wait = 1; xfer_have = 0;
    n_xfer++;
}

static int cb_xfer_done(void *u, int *result, uint64_t *done_cyc)
{
    (void)u;
    if (xfer_have) {
        *result = xfer_result;
        *done_cyc = wio_now(brd);
        xfer_have = 0; xfer_wait = 0;
        return 1;
    }
    *done_cyc = UINT64_MAX;
    return 0;
}

static void board_power(int on)
{
    if (on && !powered) {
        wio_power_on(brd);
        t0_ns = mono_ns(); t0_cyc = wio_now(brd);
        last_rx_end = 0; req_open = 0; rsp_in = 0; xfer_wait = 0; xfer_have = 0;
        powered = 1;
        s573_logf("s573wio: board powered on\n");
    } else if (!on && powered) {
        powered = 0;
        s573_logf("s573wio: board powered off\n");
    }
}

static void apply_port(int p)
{
    wio_card_t *c = wio_port_card(brd, p);
    if (port_mode[p]) {
        wio_port_mode(brd, p, WIO_PORT_EXTERNAL);
        return;
    }
    wio_port_mode(brd, p, WIO_PORT_VIRTUAL);
    if (card_fd[p] >= 0 && !card_out[p]) { if (!c->present) wio_card_insert(c); }   /* FLAG 08h again */
    else if (c->present) wio_card_eject(c);
}

static void handle_msg(const msg_t *m)
{
    int i;
    switch (m->type) {
    case M_POWER:
        board_power(m->a);
        break;
    case M_REQ: {
        /* the 573's MCU puts the packet on the bus, escaped (psx-spx JVS Packet
         * format), at least 200 us after the last packet it received */
        uint64_t t = wio_now(brd), w = wall_cyc();
        if (w > t) t = w;
        if (last_rx_end && t < last_rx_end + JVS_GAP_CYC) t = last_rx_end + JVS_GAP_CYC;
        for (i = 0; i < m->len; i++) {
            uint8_t b = m->data[i];
            if (i > 0 && (b == 0xe0 || b == 0xd0)) {
                t += JVS_BYTE_CYC; wio_bus_rx(brd, 0xd0, t);
                b = (uint8_t)(b - 1);
            }
            t += JVS_BYTE_CYC; wio_bus_rx(brd, b, t);
        }
        req_open = 1; req_seq = m->seq;
        req_cmd = m->len > 3 ? m->data[3] : 0;
        quiet = (req_cmd == 0x71) || (req_cmd == 0x70 && m->len > 9 && m->data[4] == 0x01);
        n_req++;
        if (quiet && req_cmd == 0x70) {          /* the program upload: summarised */
            uint32_t a = (uint32_t)m->data[5] << 16 | (uint32_t)m->data[6] << 8 | m->data[7];
            if (!ram_writes || a < ram_lo) ram_lo = a;
            if (!ram_writes || a + m->data[8] > ram_hi) ram_hi = a + m->data[8];
            ram_writes++; ram_bytes += m->data[8];
        } else if (ram_writes) {
            s573_logf("s573wio: JVS -> 70 01 x%u: %u bytes written to board RAM %06x..%06x\n",
                      ram_writes, ram_bytes, ram_lo, ram_hi);
            ram_writes = 0; ram_bytes = 0;
        }
        if (!quiet && recently(0x51000000u ^ crc32_of(m->data, m->len))) quiet = 1;
        if (!quiet) log_request(m->data, m->len, m->seq);
        break; }
    case M_XFER_DONE:
        xfer_result = m->a; xfer_have = 1;
        break;
    case M_PULL:
        card_out[m->port] = m->a;
        apply_port(m->port);
        s573_logf("s573wio: player %d card %s (Card In/Out button)\n", m->port + 1, m->a ? "pulled out" : "pushed back in");
        break;
    case M_MODE:
        port_mode[m->port] = m->a;
        apply_port(m->port);
        s573_logf("s573wio: player %d slot: %s\n", m->port + 1, m->a ? "real card on SNAC" : "card file");
        break;
    case M_CARD: {
        int p = m->port;
        wio_card_t *c = wio_port_card(brd, p);
        if (card_fd[p] >= 0) { close(card_fd[p]); card_fd[p] = -1; }
        if (c->present) wio_card_eject(c);
        if (m->a >= 0) {
            ssize_t r = pread(m->a, c->data, WIO_CARD_SIZE, 0);
            if (r != WIO_CARD_SIZE) {
                s573_logf("s573wio: player %d card file %s: read failed (%s) -- no card\n", p + 1, m->name,
                          r < 0 ? strerror(errno) : "short");
                close(m->a);
            } else {
                card_fd[p] = m->a; card_wr[p] = m->b;
                card_out[p] = 0;                   /* a newly chosen card goes in */
                memset(c->dirty_map, 0, sizeof c->dirty_map); c->dirty = 0;
                snprintf(card_name[p], sizeof card_name[p], "%s", m->name);
                s573_logf("s573wio: player %d card inserted: %s%s (\"%c%c\" header)\n", p + 1, m->name,
                          m->b ? "" : " READ-ONLY: writes stay in memory", c->data[0], c->data[1]);
            }
        } else s573_logf("s573wio: player %d card file removed\n", p + 1);
        apply_port(p);
        break; }
    }
}

static void save_dirty(void)
{
    int p, f;
    for (p = 0; p < 2; p++) {
        wio_card_t *c = wio_port_card(brd, p);
        int n = 0, lo = -1, hi = -1;
        if (!c->dirty) continue;
        c->dirty = 0;
        for (f = 0; f < 1024; f++) {
            if (!(c->dirty_map[f >> 3] & (1u << (f & 7)))) continue;
            c->dirty_map[f >> 3] &= (uint8_t)~(1u << (f & 7));
            if (card_fd[p] >= 0 && card_wr[p]) queue_write(card_fd[p], (uint32_t)f * 128u, &c->data[f * 128]);
            if (lo < 0) lo = f;
            hi = f; n++;
        }
        s573_logf("s573wio: player %d card: %d frame(s) %03x..%03x written%s\n", p + 1, n, lo, hi,
                  card_fd[p] < 0 ? " (no file: kept in memory)" : !card_wr[p] ? " (read-only file: kept in memory)"
                  : ", saving to the file");
    }
}

static void *board_main(void *arg)
{
    (void)arg;
    uint64_t last_stat = mono_ns();
    for (;;) {
        msg_t m;
        int got;
        /* everything Main sent, in order */
        for (;;) {
            pthread_mutex_lock(&q_mx);
            got = (in_h != in_t);
            if (got) m = inbox[in_t++ % INBOX_N];
            pthread_mutex_unlock(&q_mx);
            if (!got) break;
            handle_msg(&m);
        }
        if (!powered) {
            pthread_mutex_lock(&q_mx);
            while (in_h == in_t) pthread_cond_wait(&q_cv, &q_mx);
            pthread_mutex_unlock(&q_mx);
            continue;
        }

        {
            uint64_t target = wall_cyc(), now = wio_now(brd);
            /* far behind (the thread was starved): let the board skip ahead rather
             * than replay seconds of timer interrupts in a burst */
            if (target > now + 66000000ull) { t0_ns = mono_ns(); t0_cyc = now; target = now; }
            /* run in slices of at most 2 ms so Main's messages are seen promptly */
            if (target > now + 132000u) target = now + 132000u;
            if (target > now) wio_run(brd, target);
            now = wio_now(brd);
            if (wall_cyc() > now && wall_cyc() - now > lag_max) lag_max = wall_cyc() - now;
        }
        save_dirty();

        /* wait for the next thing to do: a message, or the board's next event */
        {
            uint64_t now = wio_now(brd), wall = wall_cyc();
            uint64_t ev = wio_next_event(brd);
            if (now + 66 < wall && !wio_idle(brd) && !xfer_wait) continue;   /* busy and behind */
            uint64_t wake_cyc = ev;
            if (wake_cyc > now + 66000u) wake_cyc = now + 66000u;             /* 1 ms at most */
            if (xfer_wait && wake_cyc > now + 3300u) wake_cyc = now + 3300u;  /* 50 us */
            if (wake_cyc > wall) {
                uint64_t ns = (wake_cyc - wall) * 1000u / WIO_CYC_PER_US;
                struct timespec ts;
                clock_gettime(CLOCK_REALTIME, &ts);
                ts.tv_nsec += (long)ns;
                while (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
                pthread_mutex_lock(&q_mx);
                if (in_h == in_t) pthread_cond_timedwait(&q_cv, &q_mx, &ts);
                pthread_mutex_unlock(&q_mx);
            }
        }

        if (mono_ns() - last_stat > 10000000000ull) {
            const wio_stats_t *st = wio_stats(brd);
            last_stat = mono_ns();
            if (log_suppressed) {
                s573_logf("s573wio: (%u repeated JVS lines not shown)\n", log_suppressed);
                log_suppressed = 0;
            }
            s573_logf("s573wio: 10 s: board %.3f s (worst lag %.1f ms), insns %llu (interpreted %llu), resets %u (watchdog %u), "
                      "JVS req %u rsp %u (bad sum %u, unanswered %u), rx dropped %u, FPGA configs %u, "
                      "card xfers SNAC %u, frames saved %u (errors %u, dropped %u), program crc %08x%s\n",
                      (double)wio_now(brd) / WIO_FC_HZ, (double)lag_max / 66000.0, (unsigned long long)st->insns,
                      (unsigned long long)st->interp, st->resets, st->wd_resets, n_req, n_rsp, n_rsp_bad,
                      n_rsp_orphan, st->rx_dropped, st->fpga_configs, st->card_xfers_ext, w_frames, w_errors,
                      w_dropped, wio_fw_crc(brd), st->fatal ? " FIRMWARE FATAL" : "");
            lag_max = 0;
        }
    }
    return 0;
}

/* ===================================================================== Main side */

static int       started;           /* threads exist                          */
static int       gave_up;
static int       want_on;           /* the fabric says a reader is fitted     */
static int       attached;          /* we told the fabric so                  */
static uint8_t   seen_seq;
static int       sense_level = 1;
static uint8_t   reg_now = 0xff;
static uint64_t  next_slow_ns;
static int       mode_sent[2] = { -1, -1 };
static struct { int open; dev_t dev; ino_t ino; off_t size; FILE *filp; } card_seen[2];
static int       sw_seen = -1;
static uint64_t  last_reattach_ns;      /* the fabric's card_sw bits as last seen      */
static int       out_main[2];       /* Main's copy of card_out                     */

/* card port: one op in flight at a time */
static int       xf_busy;
static uint8_t   xf_cnt;
static uint64_t  xf_t0;
static uint32_t  xf_slow;

static uint16_t wio_nop(uint16_t *w1)
{
    uint16_t s = spi_uio_cmd_cont(CMD_573_WIO);
    uint16_t a = spi_w((uint16_t)(OP_NOP << 8));
    DisableIO();
    if (w1) *w1 = a;
    return s;
}

static void wio_op(uint8_t op, uint8_t arg)
{
    spi_uio_cmd_cont(CMD_573_WIO);
    spi_w((uint16_t)((op << 8) | arg));
    DisableIO();
}

static int load_boot_rom(void)
{
    /* next to the CD image, then the core's games folder (USB or SD, as Main
     * resolves it), then the SD card's */
    const char *dirs[] = { NULL, HomeDir(), "games/System573" };
    char path[1024];
    unsigned i;
    const char *cd = GetIdx_S(1);
    boot_rom = (uint8_t *)malloc(WIO_ROM_SIZE);
    if (!boot_rom) return 0;
    for (i = 0; i < sizeof dirs / sizeof dirs[0]; i++) {
        FILE *f;
        size_t n;
        if (!dirs[i]) {
            const char *sl;
            if (!cd || !cd[0] || !(sl = strrchr(cd, '/'))) continue;
            snprintf(path, sizeof path, "%.*s/%s", (int)(sl - cd), cd, BOOT_ROM_NAME);
        } else if (dirs[i] && dirs[i][0]) snprintf(path, sizeof path, "%s/%s", dirs[i], BOOT_ROM_NAME);
        else continue;
        f = fopen(getFullPath(path), "rb");
        if (!f) continue;
        n = fread(boot_rom, 1, WIO_ROM_SIZE, f);
        fclose(f);
        if (n != WIO_ROM_SIZE) { s573_logf("s573wio: %s: %u bytes, not 512 KB -- skipped\n", path, (unsigned)n); continue; }
        if (crc32_of(boot_rom, WIO_ROM_SIZE) != BOOT_ROM_CRC) {
            s573_logf("s573wio: %s: CRC-32 %08x, not 885a01's %08x -- skipped\n", path,
                      crc32_of(boot_rom, WIO_ROM_SIZE), BOOT_ROM_CRC);
            continue;
        }
        s573_logf("s573wio: boot ROM %s (CRC-32 %08x)\n", getFullPath(path), BOOT_ROM_CRC);
        return 1;
    }
    s573_logf("s573wio: *** no card reader boot ROM: put %s (from MAME's ddr3ma.zip etc.) next to the CD "
              "image or in games/System573 -- the reader stays absent ***\n", BOOT_ROM_NAME);
    free(boot_rom); boot_rom = 0;
    return 0;
}

static int start_threads(void)
{
    static wio_host_t h;
    pthread_attr_t attr;
    cpu_set_t set;
    pthread_t t;
    if (!load_boot_rom()) return 0;
    memset(&h, 0, sizeof h);
    h.bus_tx = cb_bus_tx; h.sense = cb_sense; h.log = cb_log;
    h.card_reg = cb_card_reg; h.card_latch_clr = cb_card_latch_clr;
    h.card_xfer_start = cb_xfer_start; h.card_xfer_done = cb_xfer_done;
    brd = wio_create(&h);
    if (!brd || wio_load_rom(brd, boot_rom, WIO_ROM_SIZE)) { s573_logf("s573wio: board create failed\n"); return 0; }
    /* core #0, as s573mp3's logger: Main pins itself to core #1 */
    pthread_attr_init(&attr);
    CPU_ZERO(&set); CPU_SET(0, &set);
    pthread_attr_setaffinity_np(&attr, sizeof set, &set);
    if (pthread_create(&t, &attr, board_main, NULL)) { pthread_attr_destroy(&attr); return 0; }
    pthread_detach(t);
    if (pthread_create(&t, &attr, writer_main, NULL)) { pthread_attr_destroy(&attr); return 0; }
    pthread_detach(t);
    pthread_attr_destroy(&attr);
    s573_logf("s573wio: card reader service started\n");
    return 1;
}

/* OSD slots S2/S3: which file is in each, and the File / SNAC switch */
static void watch_cards(void)
{
    int p;
    for (p = 0; p < 2; p++) {
        char opt[8];
        int mode;
        fileTYPE *f = get_image(CARD_SLOT0 + p);
        struct stat st;
        int open_now = (f && f->filp && fstat(fileno(f->filp), &st) == 0);
        msg_t m;

        snprintf(opt, sizeof opt, "[%d]", 118 + p);
        mode = user_io_status_get(opt) ? 1 : 0;
        if (mode != mode_sent[p]) {
            memset(&m, 0, sizeof m);
            m.type = M_MODE; m.port = p; m.a = mode;
            if (post_msg(&m)) mode_sent[p] = mode;
        }

        if (open_now == card_seen[p].open && (!open_now ||
            (st.st_dev == card_seen[p].dev && st.st_ino == card_seen[p].ino &&
             f->filp == card_seen[p].filp && st.st_size == card_seen[p].size))) continue;

        memset(&m, 0, sizeof m);
        m.type = M_CARD; m.port = p; m.a = -1;
        if (open_now) {
            const char *nm = GetIdx_S(CARD_SLOT0 + p);
            const char *sl = nm ? strrchr(nm, '/') : 0;
            snprintf(m.name, sizeof m.name, "%s", sl ? sl + 1 : (nm && nm[0] ? nm : f->name));
            if (st.st_size != WIO_CARD_SIZE) {
                s573_logf("s573wio: player %d: %s is %lld bytes, not a 128 KB card image -- no card\n",
                          p + 1, m.name, (long long)st.st_size);
            } else {
                int fl = fcntl(fileno(f->filp), F_GETFL);
                m.a = dup(fileno(f->filp));
                m.b = (fl >= 0 && (fl & O_ACCMODE) != O_RDONLY);
            }
        }
        if (!post_msg(&m)) { if (m.a >= 0) close(m.a); continue; }
        if (m.a >= 0) out_main[p] = 0;
        card_seen[p].open = open_now;
        if (open_now) {
            card_seen[p].dev = st.st_dev; card_seen[p].ino = st.st_ino;
            card_seen[p].size = st.st_size; card_seen[p].filp = f->filp;
        }
    }
}

/* the card port: one op at a time, an exchange waited for briefly in place */
static void run_card_ops(void)
{
    for (;;) {
        op_t o;
        if (xf_busy) {
            uint16_t w1, s = wio_nop(&w1);
            if ((s & ST_DONE) && (uint8_t)(w1 >> 12) == (uint8_t)((xf_cnt + 1) & 15)) {
                int res = (s >> 9) & 3;
                msg_t m;
                memset(&m, 0, sizeof m);
                m.type = M_XFER_DONE;
                m.a = res == 0 ? (int)(w1 & 0xff) : res == 1 ? WIO_XFER_NOACK : WIO_XFER_ERROR;
                post_msg(&m);
                xf_cnt = (uint8_t)((xf_cnt + 1) & 15);
                xf_busy = 0;
                continue;
            }
            /* the routine's worst case is ~36 us of bits + the /ACK timeout + 7 us;
             * wait in place a little, then come back on the next pass */
            if (mono_ns() - xf_t0 < 150000u) continue;
            xf_slow++;
            return;
        }
        if (!take_op(0, &o)) return;
        if (o.op == OP_XFER) {
            spi_uio_cmd_cont(CMD_573_WIO);
            spi_w((uint16_t)((OP_XFER << 8) | o.arg));
            spi_w(o.w2);
            DisableIO();
            xf_busy = 1; xf_t0 = mono_ns();
        } else {
            if (o.op == OP_CARDREG) reg_now = o.arg;
            wio_op(o.op, o.arg);
        }
    }
}

static void run_jvs_ops(void)
{
    op_t o;
    while (take_op(1, &o)) {
        if (o.op == OP_PUTRESP) {
            int i, words = (o.w2 + 1) / 2;
            spi_uio_cmd_cont(CMD_573_WIO);
            spi_w((uint16_t)(OP_PUTRESP << 8));
            spi_w(o.w2);
            spi_w(o.seq);
            for (i = 0; i < words; i++)
                spi_w((uint16_t)(o.data[2 * i] | ((2 * i + 1 < o.w2 ? o.data[2 * i + 1] : 0) << 8)));
            DisableIO();
        } else {
            if (o.op == OP_SENSE) sense_level = o.arg;
            wio_op(o.op, o.arg);
        }
    }
}

static void fetch_request(void)
{
    msg_t m;
    int i, words;
    uint16_t len, seq;
    memset(&m, 0, sizeof m);
    spi_uio_cmd_cont(CMD_573_WIO);
    spi_w((uint16_t)(OP_GETREQ << 8));
    len = spi_w(0);
    seq = spi_w(0);
    if (len > 258) len = 258;
    words = (len + 1) / 2;
    for (i = 0; i < words; i++) {
        uint16_t w = spi_w(0);
        m.data[2 * i] = (uint8_t)w;
        m.data[2 * i + 1] = (uint8_t)(w >> 8);
    }
    DisableIO();
    m.type = M_REQ; m.len = len; m.seq = (uint8_t)seq;
    post_msg(&m);
}

/* a press of a player's "Card In/Out" button (J1 position 17): DDR asks the
 * player to pull the card out after saving, and a card FILE has no other way out */
static void card_button(int p)
{
    char msg[64];
    msg_t m;
    if (mode_sent[p] == 1) {
        snprintf(msg, sizeof msg, "P%d card: real card (SNAC)", p + 1);
    } else if (!card_seen[p].open) {
        snprintf(msg, sizeof msg, "P%d: no card file chosen", p + 1);
    } else {
        out_main[p] = !out_main[p];
        memset(&m, 0, sizeof m);
        m.type = M_PULL; m.port = p; m.a = out_main[p];
        post_msg(&m);
        snprintf(msg, sizeof msg, "P%d card %s", p + 1, out_main[p] ? "removed" : "inserted");
    }
    Info(msg);
    s573_logf("s573wio: Card In/Out pressed: %s\n", msg);
}

void s573wio_poll(void)
{
    uint64_t now;
    uint16_t s, w1 = 0;

    if (gave_up) return;
    now = mono_ns();

    if (!want_on) {
        /* nothing fitted: look again every 250 ms */
        if (now < next_slow_ns) return;
        next_slow_ns = now + 250000000ull;
        s = wio_nop(0);
        if (!(s & ST_OSD_EN)) return;
        if (!started) {
            if (!start_threads()) { gave_up = 1; return; }
            started = 1;
        }
        want_on = 1;
        { msg_t m; memset(&m, 0, sizeof m); m.type = M_POWER; m.a = 1; post_msg(&m); }
        mode_sent[0] = mode_sent[1] = -1;
        memset(card_seen, 0, sizeof card_seen);
        watch_cards();
        attached = 0;
        s573_logf("s573wio: reader fitted (OSD) -- board on\n");
    }

    s = wio_nop(&w1);
    if (!(s & ST_OSD_EN)) {
        msg_t m;
        op_t o;
        wio_op(OP_ATTACH, 0);
        memset(&m, 0, sizeof m); m.type = M_POWER; m.a = 0; post_msg(&m);
        while (take_op(0, &o) || take_op(1, &o)) ;          /* the old board's traffic */
        want_on = 0; attached = 0; xf_busy = 0;
        s573_logf("s573wio: reader removed (OSD) -- board off\n");
        return;
    }
    if (!(s & ST_ATTACHED)) {
        /* first time, or the core was reset (the fabric forgot us): bring the
         * fabric's copy of the board's lines back, then attach */
        wio_op(OP_SENSE, (uint8_t)sense_level);
        wio_op(OP_CARDREG, reg_now);
        wio_op(OP_ATTACH, 1);
        /* the core holds reset for a while (Main's downloads): the fabric forgets
         * us on every pass of it, so say so once per reset */
        if (attached) {
            if (now - last_reattach_ns > 2000000000ull) s573_logf("s573wio: core reset seen -- re-attached\n");
            last_reattach_ns = now;
        }
        attached = 1;
        seen_seq = 0;
        if (xf_busy) {                          /* the exchange died with the reset */
            msg_t m;
            memset(&m, 0, sizeof m); m.type = M_XFER_DONE; m.a = WIO_XFER_ERROR; post_msg(&m);
            xf_busy = 0;
        }
        s = wio_nop(&w1);
        xf_cnt = (uint8_t)(w1 >> 12);
    }

    /* the Card In/Out buttons: each flip of a card_sw bit is one press */
    {
        int sw, p;
        sw = (w1 >> 10) & 3;
        if (sw_seen < 0) sw_seen = sw;
        for (p = 0; p < 2; p++) if ((sw ^ sw_seen) & (1 << p)) card_button(p);
        sw_seen = sw;
    }

    /* a request the 573 sent */
    if ((s & ST_WAITING) && (uint8_t)s != seen_seq) {
        seen_seq = (uint8_t)s;
        fetch_request();
    }

    run_jvs_ops();
    run_card_ops();

    if (now >= next_slow_ns) {
        next_slow_ns = now + 100000000ull;
        watch_cards();
        if (q_overflow) { s573_logf("s573wio: *** %u queue overflows ***\n", q_overflow); q_overflow = 0; }
        if (xf_slow) { s573_logf("s573wio: %u SNAC byte exchanges outlasted one Main pass\n", xf_slow); xf_slow = 0; }
    }
}
