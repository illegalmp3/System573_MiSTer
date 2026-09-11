/* -----------------------------------------------------------------------------
 * s573mp3.cpp - Konami System 573 HPS-side MP3 service for Main_MiSTer
 *
 * The 573's digital-audio board streams scrambled MP3 out of its sample RAM to a
 * MAS3507D. In this core the fabric owns the streamer, the descramble window and
 * the PCM ring, but NOT the decoder: decision B option (c) puts descramble +
 * minimp3 on the HPS, so this service is what turns a booting DDR title from
 * silent into playable. Gameplay, not just audio, depends on it -- ddrsbm's
 * `ready` loop reads the decoded-frame and sample counters as timing feedback.
 *
 * Shape is a near-verbatim clone of the shipping MegaDrive MD+ CDDA path
 * (support/megadrive/mdplus.cpp): a DDR3 ring + an SPI pointer exchange + a
 * core-name-gated poll hook, so ring coherence, lifecycle and deploy are all
 * solved precedent. Lifecycle in particular: core unload is a full Main process
 * teardown, so this service dies with the core and needs no explicit shutdown.
 *
 * Wire protocol: rtl/s573_hps_ext.v (CMD_573_PTRS / STATUS / CTRL / MP3CFG).
 * Ring geometry: rtl/s573_pcm_ring.v.  Pacing: rtl/s573_mp3_credit.v.
 * Decisions and risks: docs/2026-07-03-p4b-mp3-transport-design.md and
 * docs/2026-07-29-p4b-decision-b-spike-result.md.
 *
 * FOUR DEFECTS ARE PRE-CLEARED HERE. Each cost a hardware session upstream:
 *  1. THE CORE-NAME GATE. This core's CONF_STR still begins "PSX;..." because it
 *     is a PSX derivative, so Main's `orig_name` is "PSX" and a gate written
 *     against "Konami_System_573" can NEVER match. The name that is 573-specific
 *     is the .mgl <setname>, "System573". Consequence, and it is not subtle:
 *     LAUNCHING THE BARE .rbf GIVES NO MP3 AUDIO. Launch via one of the .mgl
 *     files. (docs/2026-07-31-mp3-audio-WORKING.md)
 *  2. cfg_epoch is compared as 16 bits but MP3CFG word0 carries only the low 8
 *     by design; adopting the echo makes the two permanently unequal past 255
 *     and re-applies a stale config on every poll forever.
 *     (docs/2026-08-02-mp3-stop-cfg-epoch-truncation.md)
 *  3. The ring pointer is [15:0] INCLUDING the wrap MSB, which the fabric's
 *     empty test compares; masking it to 15 bits replays up to 1.49 s of already
 *     drained PCM with underrun_cnt reading a clean zero.
 *  4. A re-arm must discard already-decoded PCM, or the previous song bleeds
 *     into the next one. (both: docs/2026-08-02-mp3-stale-pcm-residue.md)
 *
 * AND ONE TRAP THAT IS NOT A BUG IN THIS FILE: Main's stdout is /dev/null unless
 * MiSTer.ini has `debug=1` under [MiSTer] (cfg.cpp reassigns the global stdout
 * while parsing the INI). An empty log is NOT evidence that this service did not
 * run. Set debug=1 before believing any absence of output.
 *
 * Released under the GNU GPL v2.
 * ---------------------------------------------------------------------------- */
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <time.h>

#include "../../spi.h"
#include "../../user_io.h"

#include "s573mp3_core.h"

#define MINIMP3_IMPLEMENTATION
#define MINIMP3_ONLY_MP3          /* Layer III only: smaller and faster */
#define MINIMP3_NO_STDIO
#include "../../lib/minimp3/minimp3.h"

/* Work bound per poll. The decode gate itself is free-space only (never a
 * timer -- that is the MP3_UNPACED flood relocated into C), but Main is a
 * single-threaded poll loop, so one poll must not run away with 1.3 s of audio
 * and stall input handling. 12 frames is ~0.31 s of audio for ~3 ms of decode.
 */
#define S573_FRAMES_PER_POLL   12
#define S573_POLL_US           5000       /* ~5 ms, as MD+ */
#define S573_MAX_FRAME_BYTES   1441       /* MPEG-1 L3 worst case */

static int                 inited      = 0;
static int                 gave_up     = 0;
static volatile uint8_t   *dio_map     = 0;
static s573_core_t         core;
static mp3dec_t            mp3d;
static uint64_t            next_due_us = 0;

/* Opt-in diagnostics. Two switches, because on a console with no SSH the
 * environment is not reachable: Main is started from /etc/inittab, so nobody
 * can export a variable for it. The switch that actually works on such a board
 * is a FILE on the SD card, which is writable by plugging the card into a
 * computer -- so S573_DEBUG_FILE below is the primary control and the env vars
 * are kept for a board you can get a shell on.
 *
 * And the output has to land somewhere retrievable for the same reason:
 * `debug=1` in MiSTer.ini only stops Main from sending stdout to /dev/null, and
 * `debug=2` writes /tmp/debug.txt, which is tmpfs -- gone on reboot and
 * unreadable without a shell. So the service keeps its OWN log on the SD card,
 * unbuffered, independent of Main's debug setting. "An empty log is not
 * evidence" has burned this project three times; this is what makes the log
 * exist at all. */
#define S573_DEBUG_FILE  "/media/fat/s573mp3.debug"
#define S573_LOG_FILE    "/media/fat/s573mp3.log"

static int   opt_hb    = 0;      /* hb=1     state line per second            */
static int   opt_tone  = 0;      /* tone=1   440 Hz instead of decode          */
static int   opt_atten = 100;    /* atten=0..100  MP3 channel percent          */
static int   opt_dump  = 0;      /* dump=1   write the raw window to the SD card */
static int   opt_unsafe_ring = 0;/* ring_unsafe_ok=1  write PCM anyway           */
static FILE *logf      = 0;
static uint32_t probe_sum_init = 0, probe_nz_init = 0;
static int      probe_done = 0, ring_collides = 0;
static uint32_t tone_phase = 0;

/* Writes to both sinks: our SD-card log (when enabled) and stdout (which Main
 * usually has pointed at /dev/null -- harmless either way). */
static void s573_log(const char *fmt, ...)
{
    va_list ap;
    if (logf) {
        va_start(ap, fmt);
        vfprintf(logf, fmt, ap);
        va_end(ap);
    }
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
}

/* key=value lines, '#' comments. Absent file = diagnostics off. */
static int s573_read_debug_file(void)
{
    char line[128];
    FILE *f = fopen(S573_DEBUG_FILE, "r");
    if (!f) return 0;
    while (fgets(line, sizeof(line), f)) {
        char *p = line;
        int v;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\r' || !*p) continue;
        if      (sscanf(p, "hb=%d", &v)    == 1) opt_hb   = (v != 0);
        else if (sscanf(p, "tone=%d", &v)  == 1) opt_tone = (v != 0);
        else if (sscanf(p, "atten=%d", &v) == 1) { if (v >= 0 && v <= 100) opt_atten = v; }
        else if (sscanf(p, "dump=%d", &v)  == 1) opt_dump = (v != 0);
        else if (sscanf(p, "ring_unsafe_ok=%d", &v) == 1) opt_unsafe_ring = (v != 0);
    }
    fclose(f);
    return 1;
}

/* one-shot warnings */
static int warned_hz = 0, warned_mono = 0, warned_odd = 0, warned_defer = 0;
static uint8_t last_rst_seen = 0;

static uint64_t now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)(ts.tv_nsec / 1000);
}

/* ---------------------------------------------------------------- the gate --
 * See defect 1 above. Accept EITHER name: "System573" is what the .mgl
 * <setname> yields and is 573-specific; "Konami_System_573" keeps working if
 * the CONF_STR is ever renamed away from "PSX". */
static int is_573(void)
{
    const char *n  = user_io_get_core_name();
    const char *on = user_io_get_core_name(1);
    int hit = 0;

    if (n  && (!strncasecmp(n,  "System573", 9) ||
               !strncasecmp(n,  "Konami_System_573", 17))) hit = 1;
    if (on && (!strncasecmp(on, "System573", 9) ||
               !strncasecmp(on, "Konami_System_573", 17))) hit = 1;

    /* Log the gate ONCE per decision. Design risk #6 is "a stale binary
     * silently disables MP3"; this line plus an advancing 0xa8 on hardware is
     * how we prove the HPS half is actually live. */
    static int logged = -1;
    if (logged != hit) {
        logged = hit;
        s573_log("s573mp3: gate %s -- core_name='%s' orig_name='%s'\n",
               hit ? "HIT" : "miss", n ? n : "(null)", on ? on : "(null)");
    }
    return hit;
}

/* ------------------------------------------------------------- SPI mailbox -- */
static void ptrs_exchange(s573_ptrs_t *p)
{
    /* Same-word response semantics: the word returned by the call that sends X
     * is the fabric's answer TO X (rtl/s573_hps_ext.v header). */
    uint16_t w0 = spi_uio_cmd_cont(CMD_573_PTRS);
    uint16_t w1 = spi_w(core.pcm_wr);              /* down: our ring writer     */
    uint16_t w2 = spi_w(s573_core_cons_word(&core));/* down: consumption credit */
    uint16_t w3 = spi_w(core.rst_ack);             /* down: reset-epoch ack     */
    DisableIO();

    p->fab_pcm_rd = w0;
    p->fab_pos_lo = w1;
    p->cfg_epoch  = w2;      /* the AUTHORITATIVE 16-bit epoch -- see defect 2 */
    p->rst_epoch  = (uint8_t)(w3 & 0xFF);
}

static void mp3cfg_exchange(s573_cfg_t *f)
{
    uint16_t w[12];
    int i;
    w[0] = spi_uio_cmd_cont(CMD_573_MP3CFG);
    for (i = 1; i <= 11; i++) w[i] = spi_w(0);
    DisableIO();

    memset(f, 0, sizeof(*f));
    f->epoch8    = (uint16_t)(w[0] & 0xFF);
    f->mp3_start = (uint32_t)w[1] | ((uint32_t)(w[2] & 0x01FF) << 16);
    f->mp3_end   = (uint32_t)w[3] | ((uint32_t)(w[4] & 0x01FF) << 16);
    f->key1      = w[5];
    f->key2      = w[6];
    f->key3      = w[7];
    f->flags     = w[8];
    f->gain_ll   = (uint32_t)w[9]  | ((uint32_t)(w[11] & 0x000F) << 16);
    f->gain_rr   = (uint32_t)w[10] | ((uint32_t)((w[11] >> 4) & 0x000F) << 16);
    f->gain_seen = (uint8_t)((w[11] >> 8) & 1);
}

static void ctrl_exchange(void)
{
    uint16_t base = spi_uio_cmd_cont(CMD_573_CTRL);

    /* word0 up carries the fabric's CURRENT cumulative baselines. If we have not
     * primed, adopt them and echo them straight back: the delta is then exactly
     * zero and no frame pulses are fabricated. Needed because the fabric's own
     * `rebaseline` covers its reset, not a bare Main restart. */
    if (!core.ctrl_primed) s573_core_adopt_ctrl_baseline(&core, base);

    spi_w(s573_core_ctrl_word1(&core));   /* down: {sync, idle} CUMULATIVE */
    spi_w(core.ctrl_flags);               /* down: bit1 = drain enable     */
    DisableIO();
}

static void status_exchange(uint16_t *flags, uint16_t *underrun, uint16_t *buflvl)
{
    *flags    = spi_uio_cmd_cont(CMD_573_STATUS);
    *underrun = spi_w(0);
    *buflvl   = spi_w(0);
    DisableIO();
}


/* ---------------------------------------------------------- ring placement --
 * transport-design must-fix #2 is STILL OPEN: rtl/s573_pcm_ring.v calls
 * RING_OFF_BEAT "PROVISIONAL" and nobody has confirmed 0x33F10000 is clear of
 * the game's actual top-of-window sample-RAM usage. Getting that wrong means
 * writing 256 KiB of PCM over live game data -- silent corruption that would
 * present as a crash or a failed POST, i.e. as anything but itself.
 *
 * The design said to zero the ring at init. That is the single most destructive
 * thing this service can do while #2 is open, and it is NOT NEEDED: the fabric
 * reads only beats we advertise through hps_wr_ptr, which starts equal to
 * fab_rd_ptr, so nothing is read until we write. So instead of zeroing, PROBE:
 * checksum the region at init and again on the first config adoption, before we
 * have written a single byte. If it changed in between, the game owns that
 * memory and we must not touch it.
 *
 * Encouraging but not proof, so worth measuring rather than assuming: the MP3
 * windows observed on silicon top out at 0x00BE271A (11.9 MB) against a ring at
 * 31.1 MB -- 19.2 MB of headroom. Those are the MP3 windows only, not the
 * game's whole sample-RAM footprint. */
static void ring_probe(const char *when, uint32_t *sum_out, uint32_t *nz_out)
{
    const volatile uint32_t *w = (const volatile uint32_t *)(dio_map + S573_PCM_RING_OFF);
    uint32_t i, n = S573_PCM_BYTES / 4, sum = 2166136261u, nz = 0;
    for (i = 0; i < n; i++) {
        uint32_t v = w[i];
        if (v) nz++;
        sum = (sum ^ v) * 16777619u;
    }
    *sum_out = sum; *nz_out = nz;
    s573_log("s573mp3: ring probe (%s) at 0x%08x: sum=%08x nonzero_words=%u/%u\n",
             when, S573_PCM_PHYS, sum, nz, n);
}

static void ring_probe_verdict(void)
{
    uint32_t sum, nz;
    if (probe_done) return;
    probe_done = 1;
    ring_probe("first song, before we write", &sum, &nz);
    if (sum != probe_sum_init || nz != probe_nz_init) {
        ring_collides = 1;
        s573_log("s573mp3: *** RING COLLISION: 0x%08x changed while we wrote "
                 "NOTHING (init sum=%08x nz=%u, now sum=%08x nz=%u). The game "
                 "owns this memory -- transport-design must-fix #2 is VIOLATED. "
                 "PCM writes are DISABLED so the game is not corrupted. Move "
                 "RING_OFF_BEAT in rtl/s573_pcm_ring.v, or set "
                 "ring_unsafe_ok=1 to override. ***\n",
                 S573_PCM_PHYS, probe_sum_init, probe_nz_init, sum, nz);
    } else {
        s573_log("s573mp3: ring placement looks CLEAR (unchanged across boot and "
                 "the first song) -- must-fix #2 has an answer for this title\n");
    }
}

/* The decisive, build-free visibility check (transport-design plan step 7), run
 * from inside the service because this console has no shell to run
 * tools/mister_vram_dump.sh from. Dumps the RAW, still-scrambled window as the
 * HPS sees it; comparing it byte-for-byte against the scrambled MP3 in the disc
 * image proves the write path, the address contract AND word alignment in one
 * shot, and needs no keys. Alignment matters most: the key schedule is per-word
 * stateful with no resync point, so one skipped or duplicated word yields
 * plausible-but-wrong audio while 0xa8/0xca/0xcc all read GREEN. */
static void dump_window(const s573_cfg_t *f)
{
    static int dumped = 0;
    uint32_t len;
    FILE *g;
    if (dumped || !opt_dump) return;
    if (f->mp3_end <= f->mp3_start) return;
    dumped = 1;

    len = f->mp3_end - f->mp3_start;
    if (len > 65536u) len = 65536u;
    if ((uint64_t)f->mp3_start + len > S573_DIO_SIZE) {
        s573_log("s573mp3: dump SKIPPED -- window 0x%08x+%u runs past the "
                 "32 MiB window\n", f->mp3_start, len);
        return;
    }

    g = fopen("/media/fat/s573mp3_dump.bin", "wb");
    if (!g) { s573_log("s573mp3: dump FAILED to open the output file\n"); return; }
    fwrite((const void *)(dio_map + f->mp3_start), 1, len, g);
    fclose(g);

    g = fopen("/media/fat/s573mp3_dump.txt", "w");
    if (g) {
        fprintf(g, "phys      0x%08x\n", S573_DIO_PHYS + f->mp3_start);
        fprintf(g, "mp3_start 0x%08x\nmp3_end   0x%08x\nlength    %u of %u\n",
                f->mp3_start, f->mp3_end, len, f->mp3_end - f->mp3_start);
        fprintf(g, "key1      0x%04x\nkey2      0x%04x\nkey3      0x%04x\n",
                f->key1, f->key2, f->key3);
        fprintf(g, "ddrsbm    %u\nflags     0x%04x\n",
                (f->flags & S573_CFG_DDRSBM) ? 1u : 0u, f->flags);
        fclose(g);
    }
    s573_log("s573mp3: dumped %u raw scrambled bytes from 0x%08x to "
             "/media/fat/s573mp3_dump.bin\n", len, S573_DIO_PHYS + f->mp3_start);
}

/* ----------------------------------------------------------------- the ring -- */
static void pcm_write(const int16_t *src, uint32_t beats)
{
    uint32_t off;
    if (ring_collides && !opt_unsafe_ring) return;   /* see ring_probe_verdict */
    off = s573_core_pcm_byte_off(core.pcm_wr);
    uint32_t bytes = beats * S573_BEAT_BYTES;
    uint32_t first = S573_PCM_BYTES - off;   /* cannot underflow: byte_off masks */

    if (first > bytes) first = bytes;
    memcpy((void *)(dio_map + S573_PCM_RING_OFF + off), src, first);
    if (bytes > first)
        memcpy((void *)(dio_map + S573_PCM_RING_OFF),
               (const uint8_t *)src + first, bytes - first);

    /* Payload before pointer. The mapping is uncached, and the pointer does not
     * leave for the fabric until the next PTRS exchange, so this barrier is
     * belt-and-braces -- but the ordering is the whole reason pointers ride SPI
     * and not DDR3, and it should not depend on the poll happening to be later. */
    __sync_synchronize();

    s573_core_wrote_pcm(&core, beats);
}

static void pcm_ring_collapse(const char *why)
{
    uint32_t dropped = s573_core_ring_collapse(&core);
    s573_log("s573mp3: PCM FLUSH (%s) -- dropped %u beats (%.3f s), wr=%u rd=%u\n",
           why, dropped, (double)dropped * S573_BEAT_SAMPLES / 44100.0,
           core.pcm_wr, core.pcm_rd);
}

/* ---------------------------------------------------------------- the decode -- */
static void push_frame(const int16_t *pcm, int samples, int channels)
{
    static int16_t stereo[S573_FRAME_SAMPLES * 2];
    uint32_t beats;

    if (channels == 1) {
        int i;
        if (!warned_mono) { warned_mono = 1;
            s573_log("s573mp3: WARNING mono frame -- duplicating to stereo\n"); }
        if (samples > (int)S573_FRAME_SAMPLES) samples = (int)S573_FRAME_SAMPLES;
        for (i = 0; i < samples; i++) { stereo[2*i] = pcm[i]; stereo[2*i+1] = pcm[i]; }
        pcm = stereo;
    }

    if ((samples & 1) && !warned_odd) { warned_odd = 1;
        s573_log("s573mp3: WARNING odd sample count %d -- dropping the spare\n", samples); }

    beats = (uint32_t)samples / S573_BEAT_SAMPLES;
    if (!beats) return;

    if (opt_atten != 100) {
        static int16_t scaled[S573_FRAME_SAMPLES * 2];
        uint32_t i, n = beats * S573_BEAT_SAMPLES * 2;
        for (i = 0; i < n; i++)
            scaled[i] = (int16_t)(((int32_t)pcm[i] * opt_atten) / 100);
        pcm = scaled;
    }

    pcm_write(pcm, beats);
    core.frame_sync_cnt++;     /* CUMULATIVE: the fabric diffs and pulses */
    core.frames++;
}

static void push_tone(void)
{
    /* S573MP3_TONE=1: bisect DELIVERY from DECODE by pushing a known 440 Hz
     * sine through the identical ring path. First instrument to reach for if
     * the audio ever goes silent again. */
    static int16_t buf[S573_FRAME_SAMPLES * 2];
    uint32_t i;
    for (i = 0; i < S573_FRAME_SAMPLES; i++) {
        /* crude but dependency-free: a 100-step triangle at ~441 Hz */
        int32_t t = (int32_t)(tone_phase % 100);
        int16_t v = (int16_t)(((t < 50 ? t : 100 - t) - 25) * 500);
        buf[2*i] = v; buf[2*i+1] = v;
        tone_phase++;
    }
    pcm_write(buf, S573_FRAME_SAMPLES / S573_BEAT_SAMPLES);
    core.frame_sync_cnt++;
    core.frames++;
}

static void decode_some(void)
{
    int budget = S573_FRAMES_PER_POLL;

    static int16_t pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];

    while (budget-- > 0 && s573_core_may_decode(&core)) {
        mp3dec_frame_info_t info;
        int samples;
        uint32_t avail;

        if (opt_tone) { push_tone(); continue; }

        avail = core.in_len - core.in_pos;
        if (avail < S573_MAX_FRAME_BYTES) {
            s573_core_refill(&core, (const uint8_t *)dio_map);
            avail = core.in_len - core.in_pos;
            if (!avail) {
                /* window spent. IDLE is a RECURRING per-no-frame-decode event
                 * (k573dio derives mpeg IDLE from its cadence), not a one-shot,
                 * and it is NOT the same thing as a transient buffer underrun. */
                core.frame_idle_cnt++;
                break;
            }
        }

        samples = mp3dec_decode_frame(&mp3d, core.in_buf + core.in_pos,
                                      (int)avail, pcm, &info);
        if (!info.frame_bytes) {
            /* no frame header in what we hold: need more input, or the tail is
             * short. Not progress -- do not spin on it. */
            core.frame_idle_cnt++;
            break;
        }
        core.in_pos += (uint32_t)info.frame_bytes;
        if (!samples) continue;            /* skipped/ID3 frame, not an idle event */

        if (info.hz != 44100 && !warned_hz) {
            warned_hz = 1;
            s573_log("s573mp3: WARNING %d Hz stream -- the fabric drain is fixed at "
                   "44100, so pitch will be wrong (no resampler)\n", info.hz);
        }
        push_frame(pcm, samples, info.channels);
    }
}

/* ------------------------------------------------------------------- startup -- */
static int s573_init(void)
{
    int fd;
    void *m;
    const char *e;

    fd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (fd < 0) { s573_log("s573mp3: FATAL open /dev/mem failed\n"); return 0; }

    /* mmap ONLY -- STRICT_DEVMEM zeroes read()/dd here but allows mmap. phys is
     * 1:1 and the pointer must stay volatile: the fabric mutates underneath. */
    m = mmap(0, S573_DIO_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, S573_DIO_PHYS);
    close(fd);
    if (m == MAP_FAILED) {
        s573_log("s573mp3: FATAL mmap 0x%08x+%u failed\n", S573_DIO_PHYS, S573_DIO_SIZE);
        return 0;
    }
    dio_map = (volatile uint8_t *)m;

    s573_core_init(&core);
    mp3dec_init(&mp3d);

    /* the SD-card switch first, then let the environment override it */
    int dbg = s573_read_debug_file();
    if ((e = getenv("S573MP3_HB"))   && *e == '1') { opt_hb = 1; dbg = 1; }
    if ((e = getenv("S573MP3_TONE")) && *e == '1') { opt_tone = 1; dbg = 1; }
    if ((e = getenv("S573MP3_ATTEN"))) {
        int v = atoi(e);
        if (v >= 0 && v <= 100) opt_atten = v;
    }
    if (dbg) {
        logf = fopen(S573_LOG_FILE, "w");
        /* UNBUFFERED: with stdout on a plain file glibc block-buffers it, which
         * silently swallowed an earlier capture attempt on this project. */
        if (logf) setvbuf(logf, NULL, _IONBF, 0);
    }

    ring_probe("init", &probe_sum_init, &probe_nz_init);

    s573_log("s573mp3: init -- DIO window 0x%08x+%u mapped, PCM ring at 0x%08x "
           "(%u beats = %.3f s), hb=%d tone=%d atten=%d%%\n",
           S573_DIO_PHYS, S573_DIO_SIZE, S573_PCM_PHYS, S573_PCM_BEATS,
           (double)S573_PCM_BEATS * S573_BEAT_SAMPLES / 44100.0,
           opt_hb, opt_tone, opt_atten);

    inited = 1;
    return 1;
}

static void heartbeat(void)
{
    static uint64_t next = 0;
    uint16_t sf, ur, bl;
    uint64_t t = now_us();

    if (t < next) return;
    next = t + 1000000ull;

    status_exchange(&sf, &ur, &bl);
    s573_log("s573mp3: rst=%u ack=%u cfg=%u have=%u | in=%u/%u cons=%u "
           "| frames=%u sync=%u idle=%u | wr=%u rd=%u free=%u "
           "| ctrl=%04x flags=%04x underrun=%u buf=%u | flush=%u drop=%u torn=%u\n",
           last_rst_seen, core.rst_ack, core.cfg_epoch, core.have_cfg,
           core.in_pos, core.in_len, core.cons_bytes,
           core.frames, core.frame_sync_cnt, core.frame_idle_cnt,
           core.pcm_wr, core.pcm_rd, s573_core_pcm_free(&core),
           core.ctrl_flags, sf, ur, bl,
           core.flushes, core.beats_dropped, core.torn_cfg);

    if (sf & 0x0008) s573_log("s573mp3: *** evt_ovf: the fabric LOST frame pulses ***\n");
    if (ur)          s573_log("s573mp3: underrun_cnt=%u -- the ring is starving\n", ur);
}

/* ---------------------------------------------------------------- the hook --
 * Register next to mdplus_poll()/psx_poll() in user_io_poll(). */
void s573mp3_poll(void)
{
    s573_ptrs_t p;
    uint64_t t;

    if (!is_573()) return;
    if (gave_up)   return;
    if (!inited && !s573_init()) { gave_up = 1; return; }

    t = now_us();
    if (t < next_due_us) return;
    next_due_us = t + S573_POLL_US;

    ptrs_exchange(&p);
    core.pcm_rd    = p.fab_pcm_rd;
    last_rst_seen  = p.rst_epoch;

    /* A core soft reset zeroes every fabric consumer while we keep running with
     * stale pointers. The fabric IGNORES our pointer words until we ack, so
     * rebaseline the writer, then ack immediately with a second exchange rather
     * than leaving the ring frozen for an extra poll. */
    if (p.rst_epoch != core.rst_ack || !core.ptrs_thawed) {
        if (s573_core_on_core_reset(&core, p.rst_epoch)) {
            mp3dec_init(&mp3d);
            s573_log("s573mp3: core reset -- rst_epoch=%u acked, writer rebaselined\n",
                   p.rst_epoch);
            ctrl_exchange();          /* re-prime baselines, push cleared flags */
            ptrs_exchange(&p);        /* deliver the ack now */
            core.pcm_rd = p.fab_pcm_rd;
            return;                   /* pointers thaw on the next poll */
        }
    }

    if (!core.have_cfg || p.cfg_epoch != core.cfg_epoch) {
        s573_cfg_t f;
        int drain_before = (core.ctrl_flags & S573_CTRL_DRAIN_EN) ? 1 : 0;
        int act;

        mp3cfg_exchange(&f);
        act = s573_core_apply_cfg(&core, &f, p.cfg_epoch, drain_before);

        s573_log("s573mp3: CFG epoch=%u flags=%04x start=%08x end=%08x "
               "keys=%04x/%04x/%04x ddrsbm=%u gain=%05x/%05x seen=%u%s%s\n",
               p.cfg_epoch, f.flags, f.mp3_start, f.mp3_end,
               f.key1, f.key2, f.key3, core.ddrsbm,
               f.gain_ll, f.gain_rr, f.gain_seen,
               (act & S573_ACT_DRAIN_ON)  ? " DRAIN ON"  : "",
               (act & S573_ACT_DRAIN_OFF) ? " DRAIN OFF via ENABLES" : "");

        if (f.mp3_end > f.mp3_start) { ring_probe_verdict(); dump_window(&f); }

        if (act & S573_ACT_FLUSH) { pcm_ring_collapse("re-arm"); mp3dec_init(&mp3d); }
        if (act & S573_ACT_FLUSH_DEFER) {
            /* Says so rather than failing silently: the first implementation of
             * this deferred unconditionally and measured INERT, because ddrsbm
             * delivers the new window and stream_en=1 in ONE adoption. */
            if (!warned_defer) { warned_defer = 1;
                s573_log("s573mp3: flush DEFERRED (drain was on at the re-arm)\n"); }
        }
        if (act & S573_ACT_SCHEME_BAD)
            s573_log("s573mp3: *** descramble scheme disagrees with the fabric ***\n");
    }

    if (core.have_cfg && (core.ctrl_flags & S573_CTRL_DRAIN_EN)) decode_some();

    /* The honest song end. The enables are a START gate only: ddrsbm asserts
     * fpga_ctrl[14:13] once and never clears them for a song change, so waiting
     * on an enable edge here would mean the music never stops. */
    if (s573_core_should_stop(&core)) {
        core.ctrl_flags &= (uint16_t)~S573_CTRL_DRAIN_EN;
        s573_log("s573mp3: song end -- window exhausted (cur=%08x end=%08x) and "
               "ring drained, DRAIN OFF via EXHAUSTION\n",
               core.desc.cur, core.desc.mp3_end);
    }

    ctrl_exchange();
    if (opt_hb) heartbeat();
}
