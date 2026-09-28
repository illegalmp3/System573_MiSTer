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
#include <errno.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>

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
static int   opt_cdtrace = 0;    /* cdtrace=1  log every CD sector read          */
/* Main is ONE poll loop: this service, the CD sector service the fabric asks for,
 * and USB input all take their turn in it. A decode burst here is dead time for
 * the other two. Tier-3 #1-#3 (dropped arrows, sub-60 fps scrolling, half-speed
 * background movies) are all gameplay-only -- i.e. they appear exactly when this
 * service is decoding -- so the burst length is a suspect that has to be measured
 * and then bounded, not argued about. mp3_frames caps frames per poll (the old
 * fixed 12); mp3_budget_us additionally stops the burst once it has run that long,
 * which bounds the blocking time no matter how slow a frame decodes. */
static int   opt_frames    = 12;  /* mp3_frames=N     frames per poll             */
static int   opt_log_fsync = 1;   /* log_fsync=0      do not fsync every log line  */
static uint32_t log_us_max = 0, log_us_sum = 0, log_writes = 0;
static int   opt_budget_us = 0;   /* mp3_budget_us=N  0 = no time bound           */
/* poll-loop and decode-burst timing, per heartbeat second */
static uint32_t poll_gap_max = 0, poll_gap_sum = 0, poll_gaps = 0;
/* Who owns the worst loop gap? ours_* = time spent INSIDE s573mp3_poll (this
 * service); gap_max_ours = our time in the call that PRECEDED the worst gap; hb_*
 * = the once-a-second heartbeat/dump block alone. If the loop's worst gap is
 * much larger than ours, Main (or the kernel) is stalling between our calls --
 * and a stalled Main loop coalesces a keyboard press+release into a
 * microsecond pulse the 60 Hz game never samples (2026-09-27, dropped arrows). */
static uint32_t ours_us_max = 0, ours_us_sum = 0, ours_calls = 0, ours_last_us = 0, gap_max_ours = 0;
static uint32_t hb_us_max = 0;
static uint32_t dec_us_max = 0, dec_us_sum = 0, dec_bursts = 0, dec_frames_hb = 0;
static uint64_t poll_last_us = 0;
/* CD read activity, fed by Main's block-device read path (s573_cd_trace, hooked
 * at the SD RD dispatch in user_io_poll). ddrs2k's attract demo stalled with the
 * song loader silent for 50 s (2026-09-12); whether the game stopped ASKING for
 * sectors or stopped GETTING them is the question this answers. */
static uint32_t cd_reads_hb = 0, cd_secs_hb = 0, cd_reads_total = 0;
static uint64_t cd_last_lba = 0, cd_last_us = 0;
static int      cd_last_disk = -1, cd_last_blksz = 0;
static FILE *logf      = 0;
static uint32_t probe_sum_init = 0, probe_nz_init = 0;
static int      probe_done = 0, ring_collides = 0;
static uint32_t tone_phase = 0;

static uint64_t now_us(void);   /* defined below; the log times its own commit */

/* Writes to both sinks: our SD-card log (when enabled) and stdout (which Main
 * usually has pointed at /dev/null -- harmless either way). */
static void s573_log(const char *fmt, ...)
{
    va_list ap;
    if (logf) {
        va_start(ap, fmt);
        vfprintf(logf, fmt, ap);
        va_end(ap);
        /* Unbuffered gets each line into the kernel, but on FAT32 the metadata
         * can still be uncommitted when the board is switched off at the wall --
         * and switching it off at the wall is how this board gets tested, since
         * there is no shell to reboot from. fsync per line makes the log survive
         * that. At ~1 line/s it costs nothing; a log that vanishes on power-off
         * would cost a whole test session. */
        /* MEASURED 2026-09-17: Main's poll loop shows a 13-17 ms block every
         * second (and 44-47 ms every other second) with nothing else running,
         * which is the size and cadence of these commits to a FAT SD card. The
         * log is supposed to observe the system, not perturb it, so time the
         * commit and report it, and allow it to be relaxed for a run where the
         * loop timing itself is the measurement (log_fsync=0). */
        uint64_t lt0 = now_us();
        fflush(logf);
        if (opt_log_fsync) fsync(fileno(logf));
        {
            uint32_t lus = (uint32_t)(now_us() - lt0);
            if (lus > log_us_max) log_us_max = lus;
            log_us_sum += lus;
            log_writes++;
        }
    }
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
}

/* Open the sink BEFORE anything that can fail. Appends, so a later core load
 * cannot erase a 573 run's evidence; truncates only once the file gets large. */
static void s573_open_log(void)
{
    struct stat st;
    const char *mode = "a";
    if (logf) return;
    if (!stat(S573_LOG_FILE, &st) && st.st_size > (4 << 20)) mode = "w";
    logf = fopen(S573_LOG_FILE, mode);
    if (logf) {
        setvbuf(logf, NULL, _IONBF, 0);
        fprintf(logf, "\n===== s573mp3 session start =====\n");
        fflush(logf); fsync(fileno(logf));
    }
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
        else if (sscanf(p, "cdtrace=%d", &v) == 1) opt_cdtrace = (v != 0);
        else if (sscanf(p, "mp3_frames=%d", &v) == 1) { if (v >= 1 && v <= 64) opt_frames = v; }
        else if (sscanf(p, "mp3_budget_us=%d", &v) == 1) { if (v >= 0 && v <= 50000) opt_budget_us = v; }
        else if (sscanf(p, "log_fsync=%d", &v) == 1) opt_log_fsync = (v != 0);
    }
    fclose(f);
    return 1;
}

/* one-shot warnings */
static int warned_hz = 0, warned_mono = 0, warned_odd = 0;
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

static uint16_t last_stage_dbg = 0, last_stage_dbg2 = 0, last_stage_dbg3 = 0;
/* Frame-time profile (STATUS words 17..23, rtl/s573_prof.v). Free-running
 * cumulative 16-bit fabric counters; what means anything is the DIFF between two
 * heartbeats, so keep the previous set. Tier-3 #1-#3: ddrextrm's loop halves while
 * a background movie plays and PSX Turbo (RAM waits) changed nothing on silicon,
 * so the question is whether the missing time is ours (573 bus waits, CD fetch)
 * or the PSX core's. prof[4] (watchdog kicks) is the loop-rate meter: every title
 * strobes 0x1f5c0000 once per main loop. */
static uint16_t prof[7], prof_prev[7];
/* The PSX half (STATUS words 24..29, rtl/s573_prof_gpu.v): rendered frames (GP1(05)
 * buffer flips), VBLANK irqs as the ~60/s reference, and the cycles a second spends
 * with the CPU paused for DMA, the CPU stalled on memory, the GPU drawing, and the
 * MDEC decoding. Run B showed the 573-side counters at ~0%, so the frame time is
 * being lost in here. */
static uint16_t profg[7], profg_prev[7];
static int      prof_have_prev = 0, profg_have_prev = 0;
/* zs01 packet-engine observability (STATUS words 6/7/8; rtl/zs01.v dbg). The engine
 * is multi-cycle and the real host neither clock-stretches nor waits, so 'did the
 * game clock the response before we finished' is a question only the board answers. */
static uint16_t last_sec_dbg = 0, last_sec_dbg2 = 0, last_sec_dbg3 = 0;
static uint16_t last_sec_dbg4 = 0, last_sec_size = 0;
static uint16_t last_sec_rd0 = 0, last_sec_rd1 = 0, last_sec_rd2 = 0;
static uint16_t last_sec_em0 = 0, last_sec_em1 = 0;
static uint16_t last_sec_cnt = 0;   /* word16: {0x1f400004 reads, latch writes} in the window */
#ifndef CMD_573_SECTRACE
#define CMD_573_SECTRACE 0x6D
#endif
#ifndef CMD_573_STAGETRACE
#define CMD_573_STAGETRACE 0x6C
#endif
#ifndef CMD_573_PCPROF
#define CMD_573_PCPROF 0x6E
#endif
/* gn845pwbb line-event trace: the first 128 changes of the stage-0 DO/CLK lines
 * after reset, each {dt[13:0] in 64-clk ticks, ck, do}. Dumped once, when the
 * count has stopped moving -- i.e. after the game's handshake (or the whole
 * boot) is over -- so a failed STAGE PCB INITIALIZE shows the exact waveform
 * the game put on the wire and what the multiplexor made of it. */
static uint16_t trace_dumped = 0;
static uint16_t sectrace_dumped = 0;
static void stagetrace_dump(void)
{
    /* Incremental: once a second, print every entry recorded since the last
     * dump. The fabric keeps recording until its 128-entry buffer is full, so
     * a handshake that happens 30 s into the boot is still captured -- the
     * earlier one-shot "dump when still" fired on the idle boot event alone. */
    static uint64_t next = 0;
    uint16_t cnt, base, w[10];
    int i;
    uint64_t t = now_us();
    if (t < next) return;
    next = t + 1000000ull;
    cnt = spi_uio_cmd_cont(CMD_573_STAGETRACE);
    DisableIO();
    cnt &= 0xff;
    if (cnt <= trace_dumped) return;
    if (trace_dumped == 0)
        s573_log("s573mp3: stage trace: (dt = 64-clk ticks since previous event; ck/do = the k573dio lamp bits 13/12 = the logical CLK/DO levels)\n");
    for (base = trace_dumped & ~7; base < cnt; base += 8) {
        w[0] = spi_uio_cmd_cont(CMD_573_STAGETRACE);
        w[1] = spi_w(base);
        for (i = 2; i <= 9; i++) w[i] = spi_w(0);
        DisableIO();
        for (i = 0; i < 8 && base + i < cnt; i++)
            if (base + i >= trace_dumped)
                s573_log("s573mp3: stage trace[%3u]: dt=%5u ck=%u do=%u\n", base + i,
                         (w[2 + i] >> 2) & 0x3fff, (w[2 + i] >> 1) & 1, w[2 + i] & 1);
    }
    trace_dumped = cnt;
    if (cnt >= 128) s573_log("s573mp3: stage trace: buffer full (128 events)\n");
}
/* Cassette stimulus recorder (CMD_573_SECTRACE). Every cassette latch write and
 * every read of the misc word, in order, with the fabric's view at each -- i.e. the
 * STIMULUS, not one captured value. 256 entries, ARMED (and RE-armed) by the RST
 * rising edge that starts a response-to-reset, with a first-SCL-edge fallback, then
 * frozen when full -- so the window is the detector probe and not the boot-time
 * DS2401 bit-banging that swallowed the first 128-entry attempt. Word 0 bit 9 says
 * the window ever opened; if it is 0, neither RST nor SCL ever moved with the
 * cassette selected and the game never clocked the chip at all.
 *
 * The R entries carry the bit s573_io handed the CPU, so the value PSX.EXE
 * assembled is RECONSTRUCTED here from the trace rather than captured by a
 * register whose window length had to be guessed in advance (which is how three
 * bitstreams were wasted). */
static void sectrace_dump(void)
{
    static uint64_t next = 0;
    static uint64_t asm_bits = 0;       /* running MSB-first assembly of the R entries */
    static unsigned asm_reads = 0;
    uint16_t raw, cnt, base, w[10];
    unsigned armed;
    int i;
    uint64_t t = now_us();
    if (t < next) return;
    next = t + 1000000ull;
    raw = spi_uio_cmd_cont(CMD_573_SECTRACE);
    DisableIO();
    armed = (raw >> 9) & 1;
    cnt   = raw & 0x1ff;
    /* Say the window never opened, ONCE, after the boot has had time to run. A
     * silent zero-entry trace is exactly what the last three attempts produced and
     * it must not look like "no data" again. */
    if (!armed) {
        static unsigned quiet = 0;
        if (++quiet == 30)
            s573_log("s573mp3: cassette trace: NOT ARMED after 30 s -- neither RST nor SCL has "
                     "moved with the cassette selected, so the game has not clocked the chip\n");
    }
    /* The window RE-ARMS on the RST edge that starts a response-to-reset, so the
     * count can go BACKWARDS. Without this the incremental dump would sit behind a
     * stale high-water mark and print nothing at all for the real probe -- the same
     * silent-no-data failure, moved into the service. */
    if (cnt < sectrace_dumped) {
        s573_log("s573mp3: cassette trace: window RE-ARMED (%u -> %u entries) -- restarting the dump\n",
                 sectrace_dumped, cnt);
        sectrace_dumped = 0;
        asm_bits = 0;
        asm_reads = 0;
    }
    if (cnt <= sectrace_dumped) return;
    if (sectrace_dumped == 0)
        s573_log("s573mp3: cassette trace: ARMED=%u | evt W=latch write R=misc read | rst cs scl sda = "
                 "latch lines | ds=latch D4 (1-Wire) | dir=control bit6 | io0=what the chip drives | "
                 "cpu=bit2 handed to the CPU | "
                 "st=zs01 state (0 stop 1 rtr 2 cmd 3 proc 4 read) | dt=32-clk ticks since the "
                 "previous event (15=saturated, i.e. >~14 us)\n", armed);
    for (base = sectrace_dumped & ~7; base < cnt; base += 8) {
        w[0] = spi_uio_cmd_cont(CMD_573_SECTRACE);
        w[1] = spi_w(base);
        for (i = 2; i <= 9; i++) w[i] = spi_w(0);
        DisableIO();
        for (i = 0; i < 8 && base + i < cnt; i++) {
            uint16_t e = w[2 + i];
            if (base + i < sectrace_dumped) continue;
            s573_log("s573mp3:   [%3u] %c rst=%u cs=%u scl=%u sda=%u ds=%u dir=%u io0=%u cpu=%u st=%u dt=%u\n",
                     base + i, ((e >> 15) & 1) ? 'R' : 'W',
                     (e >> 14) & 1, (e >> 13) & 1, (e >> 12) & 1, (e >> 11) & 1,
                     (e >> 10) & 1, (e >> 9) & 1, (e >> 8) & 1, (e >> 7) & 1,
                     (e >> 4) & 7, e & 15);
            if ((e >> 15) & 1) {        /* a CPU read: this is a bit of the id */
                /* FIRST 32 reads only. The game keeps polling this word for coins
                 * long after the probe, so a "last 32" window would be idle noise --
                 * the same mistake, one layer up. */
                if (asm_reads < 32) asm_bits = (asm_bits << 1) | ((e >> 7) & 1);
                asm_reads++;
            }
        }
    }
    sectrace_dumped = cnt;
    if (asm_reads)
        s573_log("s573mp3: cassette trace: %u CPU reads in the window; the FIRST 32 assemble "
                 "0x%08lx (ZS01 id = 0x5a530001)%s\n",
                 asm_reads, (unsigned long)(asm_bits & 0xfffffffful),
                 (asm_reads < 32) ? "  <== fewer than 32 reads so far" :
                 ((asm_bits & 0xfffffffful) == 0x5a530001ul) ? "  <== the CPU GOT THE ID" : "");
    if (cnt >= 256) s573_log("s573mp3: cassette trace: buffer full (256 events)\n");
}
/* PC-sampling profile (CMD_573_PCPROF, rtl/s573_prof_pc.v, psx_patches 0031).
 * The fabric samples the R3000 fetch PC every 1024 clk1x (33,075/s) into 512
 * cumulative 16-bit bins of 2 KB over the first MB of RAM -- the game executable
 * loads at 0x80010000 -- plus three class counters (RAM above 1 MB, BIOS, other).
 * Once a second this pulls all 512 bins in 32 transactions, diffs them against the
 * previous dump, and prints (a) the split and the top bins as percentages of the
 * second, for reading in the log, and (b) the whole histogram as 512 hex words for
 * tools/pcprof_map.py to lay over the disassembly. Cumulative counters, so a
 * retried or skipped dump cannot double-count; the first dump only primes. */
static uint16_t pcprof_prev[512];
static uint16_t pcprof_prev_cls[4];      /* samples, ram_hi, bios, other */
static int      pcprof_have = 0;
static void pcprof_dump(void)
{
    static uint64_t next = 0;
    uint16_t cur[512], cls[4], w0, w1;
    unsigned d[512], dc[4], total, i, base, k;
    unsigned top[8], ntop = 0;
    uint64_t t = now_us();
    if (t < next) return;
    next = t + 1000000ull;

    for (base = 0; base < 512; base += 16) {
        w0 = spi_uio_cmd_cont(CMD_573_PCPROF);       /* word0: cnt_samples + class snapshot */
        w1 = spi_w((uint16_t)base);                  /* word1: base, echoed */
        for (i = 0; i < 16; i++) cur[base + i] = spi_w(0);
        if (base == 0) {
            cls[0] = w0;
            cls[1] = spi_w(0);                       /* word18: ram_hi (snapshot) */
            cls[2] = spi_w(0);                       /* word19: bios            */
            cls[3] = spi_w(0);                       /* word20: other           */
        }
        DisableIO();
        if (w1 != base) {
            s573_log("s573mp3: pcprof: base echo %u != %u -- protocol out of step, dump dropped\n",
                     w1, base);
            return;
        }
    }
    /* An older bitstream leaves word0 at whatever the snapshot bank held: the
     * profiler is present only if the sample counter is MOVING. */
    if (!pcprof_have) {
        for (i = 0; i < 512; i++) pcprof_prev[i] = cur[i];
        for (i = 0; i < 4; i++) pcprof_prev_cls[i] = cls[i];
        pcprof_have = 1;
        return;
    }
    for (i = 0; i < 4; i++) { dc[i] = (uint16_t)(cls[i] - pcprof_prev_cls[i]); pcprof_prev_cls[i] = cls[i]; }
    total = 0;
    for (i = 0; i < 512; i++) {
        d[i] = (uint16_t)(cur[i] - pcprof_prev[i]);
        pcprof_prev[i] = cur[i];
        total += d[i];
    }
    if (dc[0] == 0) return;                          /* no samples: RTL without the profiler */

    /* top 8 bins by samples (dc[0] is the denominator: every sample lands somewhere) */
    for (k = 0; k < 8; k++) {
        unsigned best = 0, bi = 512;
        for (i = 0; i < 512; i++) {
            unsigned j, seen = 0;
            for (j = 0; j < ntop; j++) if (top[j] == i) seen = 1;
            if (!seen && d[i] > best) { best = d[i]; bi = i; }
        }
        if (bi == 512 || best == 0) break;
        top[ntop++] = bi;
    }
    {
        char line[512];
        int n = snprintf(line, sizeof line,
                         "s573mp3: pcprof: samples=%u/s | ram<1M=%.1f%% ram>1M=%.1f%% bios=%.1f%% other=%.1f%% | top",
                         dc[0], 100.0 * total / dc[0], 100.0 * dc[1] / dc[0],
                         100.0 * dc[2] / dc[0], 100.0 * dc[3] / dc[0]);
        for (k = 0; k < ntop && n < (int)sizeof line - 32; k++)
            n += snprintf(line + n, sizeof line - n, " %08x:%.1f%%", 0x80000000u + top[k] * 0x800u, 100.0 * d[top[k]] / dc[0]);
        s573_log("%s\n", line);
    }
    {
        /* the whole histogram, 512 x 4 hex digits, for tools/pcprof_map.py */
        char line[32 + 512 * 4 + 8];
        int n = snprintf(line, sizeof line, "s573mp3: pcprof-hist:");
        for (i = 0; i < 512; i++) n += snprintf(line + n, sizeof line - n, "%04x", d[i] & 0xffff);
        s573_log("%s\n", line);
    }
}

static void status_exchange(uint16_t *flags, uint16_t *underrun, uint16_t *buflvl)
{
    *flags    = spi_uio_cmd_cont(CMD_573_STATUS);
    *underrun = spi_w(0);
    *buflvl   = spi_w(0);
    last_stage_dbg  = spi_w(0);   /* word3: gn845pwbb {en, id_seen, st0, sh0[12:0]} (0 on older RTL) */
    last_stage_dbg2 = spi_w(0);   /* word4: {edges0[7:0], bit0[4:0], ck0, do0, st1} */
    last_stage_dbg3 = spi_w(0);   /* word5: last mask value that was not 0xffff (sticky) */
    last_sec_dbg    = spi_w(0);   /* word6: {last_cmd[7:0], pkts[7:0]} (0 on older RTL) */
    last_sec_dbg2   = spi_w(0);   /* word7: {status[7:0], addr[7:0]} */
    last_sec_dbg3   = spi_w(0);   /* word8: {resp_bytes[7:0], cs_seen, loaded, crc_ok, overrun, -, state[2:0]} */
    last_sec_dbg4   = spi_w(0);   /* word9: {type[1:0], starts[5:0], rtr[7:0]} */
    last_sec_size   = spi_w(0);   /* word10: {1, cart_type[1:0], eep_max[12:0]} */
    last_sec_rd0    = spi_w(0);   /* word11: captured SDA bits [15:0]  */
    last_sec_rd1    = spi_w(0);   /* word12: captured SDA bits [31:16] */
    last_sec_rd2    = spi_w(0);   /* word13: {rtr_edges[7:0], reads-in-RTR[7:0]} */
    last_sec_em0    = spi_w(0);   /* word14: bits we drove [15:0]  */
    last_sec_em1    = spi_w(0);   /* word15: bits we drove [31:16] */
    last_sec_cnt    = spi_w(0);   /* word16: {0x1f400004 reads[7:0], cassette latch writes[7:0]} */
    for (int i = 0; i < 7; i++)
        prof[i]     = spi_w(0);   /* words17..23: the 573-side profile (0 on older RTL) */
    for (int i = 0; i < 7; i++)
        profg[i]    = spi_w(0);   /* words24..30: the PSX-side profile (0 on older RTL) */
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

static void pcm_ring_collapse(const char *why, uint32_t gap)
{
    uint32_t dropped, i;
    /* The collapse parks one beat AHEAD of the fabric's read pointer (see
     * s573_core_ring_collapse for why on-it is a race). That leaves exactly one
     * beat advertised which we have not written, so zero it: the fabric will
     * read it, and 2 samples of silence beats 2 samples of whatever was there.
     * Measured on hardware: the reader does consume it (wr=1 -> rd=1, buf=2). */
    for (i = 1; i <= gap; i++)
        memset((void *)(dio_map + S573_PCM_RING_OFF
                        + s573_core_pcm_byte_off((uint16_t)(core.pcm_rd + i))),
               0, S573_BEAT_BYTES);
    __sync_synchronize();
    dropped = s573_core_ring_collapse(&core, gap);
    s573_log("s573mp3: PCM FLUSH (%s, gap %u) -- dropped %u beats (%.3f s), wr=%u rd=%u\n",
           why, gap, dropped, (double)dropped * S573_BEAT_SAMPLES / 44100.0,
           core.pcm_wr, core.pcm_rd);
}

/* ---------------------------------------------------------------- the decode -- */
static void push_frame(const int16_t *pcm, int samples, int channels, uint32_t in_bytes)
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
    if (!beats) { s573_core_carry_bytes(&core, in_bytes); return; }

    if (opt_atten != 100) {
        static int16_t scaled[S573_FRAME_SAMPLES * 2];
        uint32_t i, n = beats * S573_BEAT_SAMPLES * 2;
        for (i = 0; i < n; i++)
            scaled[i] = (int16_t)(((int32_t)pcm[i] * opt_atten) / 100);
        pcm = scaled;
    }

    pcm_write(pcm, beats);
    /* Queued, NOT credited. frame_sync_cnt and cons_bytes are paid out in
     * s573_core_advance_played() as the fabric actually drains these beats. */
    s573_core_queue_frame(&core, beats, in_bytes);
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
    s573_core_queue_frame(&core, S573_FRAME_SAMPLES / S573_BEAT_SAMPLES, 0);
    core.frames++;
}

/* When decoding stops mid-song, the question is whether the bytes are not there
 * YET (the game streams a song into DIO RAM while it plays, so we can outrun the
 * loader) or whether we are reading the right place wrongly. The raw window
 * answers it: unwritten DDR3 reads as a constant, real scrambled MP3 does not. */
static void report_decode_stall(const char *why)
{
    static uint16_t reported_epoch = 0xFFFF;
    const volatile uint8_t *w;
    uint8_t b[16];
    int i, same = 1;

    if (reported_epoch == core.cfg_epoch) return;
    reported_epoch = core.cfg_epoch;
    if (core.desc.cur + 16 > S573_DIO_SIZE) return;

    w = dio_map + core.desc.cur;
    for (i = 0; i < 16; i++) b[i] = w[i];
    for (i = 1; i < 16; i++) if (b[i] != b[0]) same = 0;

    s573_log("s573mp3: decode STALL (%s) at cur=%08x (%u of %u bytes into the "
             "window, %u played) raw:"
             " %02x%02x %02x%02x %02x%02x %02x%02x%s\n",
             why, core.desc.cur, core.desc.cur - core.desc.mp3_start,
             core.desc.mp3_end - core.desc.mp3_start, core.cons_bytes,
             b[1], b[0], b[3], b[2], b[5], b[4], b[7], b[6],
             same ? " (constant fill)" : "");
}

static void decode_some(void)
{
    int budget = opt_frames;
    uint64_t t0 = now_us();
    uint32_t took;
    int decoded_here = 0;

    static int16_t pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];

    while (budget-- > 0 && s573_core_may_decode(&core)) {
        /* Bound the blocking time, not just the frame count: Main cannot service
         * a CD sector or a USB report while we are inside this loop. */
        if (opt_budget_us && decoded_here &&
            (uint32_t)(now_us() - t0) >= (uint32_t)opt_budget_us) break;
        mp3dec_frame_info_t info;
        int samples;
        uint32_t avail;

        if (opt_tone) { push_tone(); continue; }

        avail = core.in_len - core.in_pos;
        if (avail < S573_MAX_FRAME_BYTES) {
            s573_core_refill(&core, (const uint8_t *)dio_map);
            avail = core.in_len - core.in_pos;
            if (!avail) {
                if (s573_core_window_exhausted(&core)) {
                    /* window spent. IDLE is a RECURRING per-no-frame-decode
                     * event (k573dio derives mpeg IDLE from its cadence), and
                     * it means the STREAM ENDED -- so it is only sent when the
                     * window really is exhausted, never while we are waiting
                     * for the loader or the lead bound. */
                    core.frame_idle_cnt++;
                } else {
                    report_decode_stall("input starved, waiting");
                }
                break;
            }
        }

        samples = mp3dec_decode_frame(&mp3d, core.in_buf + core.in_pos,
                                      (int)avail, pcm, &info);
        if (!info.frame_bytes) {
            report_decode_stall("no MPEG sync found");
            /* no frame header in what we hold: need more input, or the tail is
             * short. Not progress -- do not spin on it. */
            core.frame_idle_cnt++;
            /* If the window is ALREADY exhausted there will never be more
             * input, so this is the truncated final frame and the song has
             * really ended. Without this the residue holds should_stop()
             * closed forever and only an explicit fpga_ctrl bit14 clear can
             * ever stop the audio (hardware 2026-09-14, dsfdr: zero
             * EXHAUSTION events in a 589 s session). No-op mid-song. */
            s573_core_mark_tail_spent(&core);
            break;
        }
        if (!samples) {
            if (s573_core_skip_hits_new_bytes(&core, (uint32_t)info.frame_bytes)) {
                /* The scan found no frame and ran into the bytes the last pull
                 * fetched: they were NOT LOADED YET (the game streams the song
                 * in while it plays -- measured: the BIOS POST's memory-test
                 * fill was there instead). Do not skip them -- undo the pull
                 * exactly and try again next poll, when the loader has caught
                 * up. Not an idle event either: the stream has not ended. */
                report_decode_stall("bytes not loaded yet -- rewinding the pull");
                s573_core_rewind_pull(&core, (const uint8_t *)dio_map);
                break;
            }
            /* a genuine skip wholly inside old bytes (ID3 etc.): rare here */
            s573_core_carry_bytes(&core, (uint32_t)info.frame_bytes);
            core.in_pos += (uint32_t)info.frame_bytes;
            continue;
        }
        core.in_pos += (uint32_t)info.frame_bytes;

        if (info.hz != 44100 && !warned_hz) {
            warned_hz = 1;
            s573_log("s573mp3: WARNING %d Hz stream -- the fabric drain is fixed at "
                   "44100, so pitch will be wrong (no resampler)\n", info.hz);
        }
        push_frame(pcm, samples, info.channels, (uint32_t)info.frame_bytes);
        decoded_here++;
    }

    /* How long this poll blocked Main, and how many frames it bought. */
    if (decoded_here) {
        took = (uint32_t)(now_us() - t0);
        if (took > dec_us_max) dec_us_max = took;
        dec_us_sum    += took;
        dec_bursts++;
        dec_frames_hb += (uint32_t)decoded_here;
    }
}

/* ------------------------------------------------------------------- startup -- */
static int s573_init(void)
{
    int fd;
    void *m;
    const char *e;

    s573_log("s573mp3: init -- opening /dev/mem\n");
    fd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (fd < 0) {
        s573_log("s573mp3: FATAL open /dev/mem failed: %s (errno %d)\n",
                 strerror(errno), errno);
        return 0;
    }

    /* mmap ONLY -- STRICT_DEVMEM zeroes read()/dd here but allows mmap. phys is
     * 1:1 and the pointer must stay volatile: the fabric mutates underneath. */
    s573_log("s573mp3: init -- mmap 0x%08x + %u bytes\n", S573_DIO_PHYS, S573_DIO_SIZE);
    m = mmap(0, S573_DIO_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, S573_DIO_PHYS);
    close(fd);
    if (m == MAP_FAILED) {
        s573_log("s573mp3: FATAL mmap 0x%08x+%u failed: %s (errno %d)\n",
                 S573_DIO_PHYS, S573_DIO_SIZE, strerror(errno), errno);
        return 0;
    }
    s573_log("s573mp3: init -- mmap OK\n");
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
    if (dbg) s573_open_log();

    ring_probe("init", &probe_sum_init, &probe_nz_init);

    s573_log("s573mp3: init -- DIO window 0x%08x+%u mapped, PCM ring at 0x%08x "
           "(%u beats = %.3f s), hb=%d tone=%d atten=%d%%\n",
           S573_DIO_PHYS, S573_DIO_SIZE, S573_PCM_PHYS, S573_PCM_BEATS,
           (double)S573_PCM_BEATS * S573_BEAT_SAMPLES / 44100.0,
           opt_hb, opt_tone, opt_atten);

    inited = 1;
    return 1;
}

/* Until the first PCM write, re-checksum the ring region every few seconds. If
 * it moves while we have written nothing, the game owns that memory and
 * transport-design must-fix #2 is violated. This runs independently of song
 * setup on purpose: the first hardware run never got a window at all, so the
 * verdict tied to the first song could not fire, and the boot answered nothing
 * about placement. */
static void ring_watch(void)
{
    static uint64_t next = 0;
    static int reported = 0;
    uint32_t sum, nz;
    uint64_t t;

    if (reported || probe_done || core.pcm_wr != 0) return;
    t = now_us();
    if (t < next) { if (!next) next = t + 5000000ull; return; }
    next = t + 5000000ull;

    ring_probe("watch, nothing written yet", &sum, &nz);
    if (sum != probe_sum_init || nz != probe_nz_init) {
        reported = 1; ring_collides = 1;
        s573_log("s573mp3: *** RING COLLISION: 0x%08x changed while we wrote "
                 "NOTHING (init sum=%08x nz=%u, now sum=%08x nz=%u). The game "
                 "owns this memory -- must-fix #2 VIOLATED. PCM writes are "
                 "DISABLED. Move RING_OFF_BEAT in rtl/s573_pcm_ring.v, or set "
                 "ring_unsafe_ok=1 to override. ***\n",
                 S573_PCM_PHYS, probe_sum_init, probe_nz_init, sum, nz);
    }
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
           "| dec=%u played=%u q=%u idle=%u | wr=%u rd=%u free=%u "
           "| ctrl=%04x flags=%04x underrun=%u buf=%u | flush=%u drop=%u torn=%u "
           "| lead=%u stalls=%u rewinds=%u\n",
           last_rst_seen, core.rst_ack, core.cfg_epoch, core.have_cfg,
           core.in_pos, core.in_len, core.cons_bytes,
           core.frames, core.frame_sync_cnt,
           (unsigned)((uint8_t)(core.pq_tail - core.pq_head) % S573_PQ_LEN),
           core.frame_idle_cnt,
           core.pcm_wr, core.pcm_rd, s573_core_pcm_free(&core),
           core.ctrl_flags, sf, ur, bl,
           core.flushes, core.beats_dropped, core.torn_cfg,
           core.pulled_bytes - core.cons_bytes, core.pull_stalls, core.rewinds);

    /* --- Main's poll loop and our decode bursts (both in microseconds) --- */
    {
        /* Snapshot the log counters BEFORE this line is written, so the line
         * reports the second that just passed and not its own commit. */
        uint32_t lmax = log_us_max, lsum = log_us_sum, lw = log_writes;
        log_us_max = log_us_sum = log_writes = 0;
        s573_log("s573mp3: poll: loop avg=%uus max=%uus over %u polls | decode avg=%uus "
                 "max=%uus over %u bursts, %u frames | log total=%uus max=%uus over %u writes "
                 "| ours avg=%uus max=%uus (before the worst gap: %uus) hb max=%uus "
                 "| mp3_frames=%d mp3_budget_us=%d log_fsync=%d\n",
                 poll_gaps ? poll_gap_sum / poll_gaps : 0u, poll_gap_max, poll_gaps,
                 dec_bursts ? dec_us_sum / dec_bursts : 0u, dec_us_max, dec_bursts,
                 dec_frames_hb, lsum, lmax, lw,
                 ours_calls ? ours_us_sum / ours_calls : 0u, ours_us_max, gap_max_ours, hb_us_max,
                 opt_frames, opt_budget_us, opt_log_fsync);
    }
    poll_gap_max = poll_gap_sum = poll_gaps = 0;
    ours_us_max = ours_us_sum = ours_calls = gap_max_ours = 0; hb_us_max = 0;
    dec_us_max = dec_us_sum = dec_bursts = dec_frames_hb = 0;

    /* --- frame-time profile: one line per second, deltas only --- */
    {
        /* clk1x = 33.8688 MHz and the cycle counters are cycles >> 10, so one
         * second of a permanently asserted level is 33075 counts. */
        const double per_sec = 33868800.0 / 1024.0;
        unsigned d[7];
        int any = 0;
        for (int i = 0; i < 7; i++) {
            d[i] = prof_have_prev ? (unsigned)(uint16_t)(prof[i] - prof_prev[i]) : 0u;
            if (prof[i]) any = 1;
            prof_prev[i] = prof[i];
        }
        prof_have_prev = 1;
        if (any) {
            s573_log("s573mp3: prof: loop=%u/s (watchdog kicks) | flash_wait=%.1f%% dio_wait=%.1f%% "
                     "cd_fetch=%.1f%% | sectors=%u ide_acc=%u exp1_acc=%u (raw %u %u %u %u %u %u %u)\n",
                     d[4], 100.0 * d[0] / per_sec, 100.0 * d[1] / per_sec, 100.0 * d[2] / per_sec,
                     d[3], d[5] * 16u, d[6] * 64u,
                     d[0], d[1], d[2], d[3], d[4], d[5], d[6]);
        }

        {
            unsigned g[7];
            int anyg = 0;
            for (int i = 0; i < 7; i++) {
                g[i] = profg_have_prev ? (unsigned)(uint16_t)(profg[i] - profg_prev[i]) : 0u;
                if (profg[i]) anyg = 1;
                profg_prev[i] = profg[i];
            }
            profg_have_prev = 1;
            if (anyg)
                /* mdec_mb/s is the decode RATE. At the modelled 2171 clk per
                 * macroblock in 15-bit mode the ceiling is 15600/s; a rate far below
                 * that with the MDEC busy means it is waiting for its input, which
                 * is a different problem from the timing model being too slow. */
                s573_log("s573mp3: gpu: FRAMES=%u/s vblank=%u/s | dma_paused=%.1f%% cpu_stall=%.1f%% "
                         "gpu_busy=%.1f%% mdec_busy=%.1f%% mdec_mb=%u/s (%.1f%% of the 2171-clk "
                         "ceiling) (raw %u %u %u %u %u %u %u)\n",
                         g[0], g[1], 100.0 * g[2] / per_sec, 100.0 * g[3] / per_sec,
                         100.0 * g[4] / per_sec, 100.0 * g[5] / per_sec,
                         g[6], 100.0 * g[6] / (33868800.0 / 2171.0),
                         g[0], g[1], g[2], g[3], g[4], g[5], g[6]);
        }
    }

    if (sf & 0x0008) s573_log("s573mp3: *** evt_ovf: the fabric LOST frame pulses ***\n");
    /* underrun_cnt is a saturating 16-bit fabric counter: once it pins at 65535
     * it says nothing more, and it pinned within seconds of every boot. Report
     * it only while it is still counting. */
    if (ur && ur != 65535) s573_log("s573mp3: underrun_cnt=%u -- the ring is starving\n", ur);
    s573_log("s573mp3: stage: en=%u id_seen=%u st0=%u st1=%u sh0=%04x (last 13 DO bits clocked in, LSB=first) "
             "bit0=%u clk0_edges=%u ck0=%u do0=%u last_mask=%04x (raw %04x %04x %04x)\n",
             (last_stage_dbg >> 15) & 1, (last_stage_dbg >> 14) & 1, (last_stage_dbg >> 13) & 1,
             last_stage_dbg2 & 1, last_stage_dbg & 0x1fff,
             (last_stage_dbg2 >> 3) & 31, (last_stage_dbg2 >> 8) & 255,
             (last_stage_dbg2 >> 2) & 1, (last_stage_dbg2 >> 1) & 1, last_stage_dbg3,
             last_stage_dbg, last_stage_dbg2, last_stage_dbg3);
    /* Only speak up once the cassette has actually been talked to: a game with no
     * ZS01 leaves every field 0 and the line would be pure noise. */
    if (last_sec_dbg || last_sec_dbg2 || last_sec_dbg3 || last_sec_dbg4 || last_sec_size) {
        unsigned pkts = last_sec_dbg & 0xff, cmd = (last_sec_dbg >> 8) & 0xff;
        unsigned addr = last_sec_dbg2 & 0xff, st = (last_sec_dbg2 >> 8) & 0xff;
        unsigned state = last_sec_dbg3 & 7, ovr = (last_sec_dbg3 >> 4) & 1;
        unsigned crcok = (last_sec_dbg3 >> 5) & 1, ld = (last_sec_dbg3 >> 6) & 1;
        unsigned rb = (last_sec_dbg3 >> 8) & 0xff, cs = (last_sec_dbg3 >> 7) & 1;
        unsigned rtr = last_sec_dbg4 & 0xff, starts = (last_sec_dbg4 >> 8) & 0x3f;
        unsigned etype = (last_sec_dbg4 >> 14) & 3;
        unsigned emax = last_sec_size & 0x1fff, ltype = (last_sec_size >> 13) & 3;
        /* bit 15 = the RTL really drives word 10 (see emu.sv). Older bitstreams leave
         * a previous command's value in the snapshot bank; printing it would be a
         * fabricated measurement, so say the instrument is absent instead. */
        unsigned size_valid = (last_sec_size >> 15) & 1;
        static const char *tn[4] = { "X76F100", "X76F041", "ZS01", "?" };
        /* The cassette type is inferred from the loaded .u1 SIZE alone. If the image
         * arrived short, the wrong model is selected, it answers the response-to-reset
         * with the wrong chip ID, and the game rejects the cassette without ever
         * sending a command packet -- which is exactly pkts=0. */
        if (size_valid)
            s573_log("s573mp3: zs01: .u1 max_byte=%u -> latched type %u (%s), selected %u (%s)%s\n",
                     emax, ltype, tn[ltype], etype, tn[etype],
                     (emax < 560) ? "   <== TOO SMALL FOR ZS01 (needs max_byte >= 560)" : "");
        else
            s573_log("s573mp3: zs01: .u1 size/type NOT REPORTED -- this bitstream predates "
                     "STATUS word 10. Rebuild the core; ignore any size below.\n");
        s573_log("s573mp3: zs01: cs_seen=%u rtr_probes=%u i2c_starts=%u\n", cs, rtr, starts);
        {
            unsigned reads = last_sec_rd2 & 0xff, edges = (last_sec_rd2 >> 8) & 0xff;
            unsigned long bits = ((unsigned long)last_sec_rd1 << 16) | last_sec_rd0;
            /* PSX.EXE's detector reads 0x1f400006 bit 2 once per clock with CS low and
             * wants 0x5a530001. This is what it actually assembled. */
            unsigned long emit = ((unsigned long)last_sec_em1 << 16) | last_sec_em0;
            if (size_valid)
                s573_log("s573mp3: zs01: RTR: we serviced %u falling edges and drove 0x%08lx; "
                         "the CPU read the misc word %u times in the probe window and assembled 0x%08lx "
                         "(ZS01 id = 0x5a530001)%s\n",
                         edges, emit, reads, bits,
                         (reads >= 32 && bits == 0x5a530001ul) ? "  <== id read CORRECTLY" :
                         (edges >= 32 && reads == 0) ? "  <== we emitted but the CPU never read in this window" :
                         (reads >= 32 && bits == 0xa5acfffeul) ? "  <== INVERTED id" :
                         (reads >= 32 && bits == 0x2d298000ul) ? "  <== the id, sampled one clock EARLY" :
                         (reads >= 32 && bits == 0xb4a60002ul) ? "  <== the id, sampled one clock LATE" :
                         (reads > 0 && edges > 0) ? "  <== the CPU saw this, not the id -- compare against 5a530001 bit by bit" :
                         (edges == 0) ? "  <== we never emitted" : "");
        }
        {
            unsigned io4 = (last_sec_cnt >> 8) & 0xff, lw = last_sec_cnt & 0xff;
            /* Disambiguates "the detector never read" from "it read the OTHER input
             * register" -- which would otherwise have cost a whole bitstream. */
            s573_log("s573mp3: zs01: in the armed window: %u cassette latch writes, %u reads of 0x1f400004 (I0-I7)%s\n",
                     lw, io4,
                     (io4 > 0 && (last_sec_rd2 & 0xff) == 0) ? "  <== it read the OTHER register, not the misc word" : "");
        }
        s573_log("s573mp3: zs01: pkts=%u last cmd=%02x addr=%02x -> status=%02x crc_ok=%u | "
                 "resp_bytes_clocked=%u state=%u loaded=%u OVERRUN=%u%s (raw %04x %04x %04x)\n",
                 pkts, cmd, addr, st, crcok, rb, state, ld, ovr,
                 ovr ? "  <== the game clocked the response before the engine finished" : "",
                 last_sec_dbg, last_sec_dbg2, last_sec_dbg3);
    }
    s573_log("s573mp3: cd: %u reads %u sectors this second | last disk=%d lba=%llu sz=%d %.1f s ago | total %u\n",
             cd_reads_hb, cd_secs_hb, cd_last_disk, (unsigned long long)cd_last_lba,
             cd_last_blksz, cd_last_us ? (double)(t - cd_last_us) / 1e6 : -1.0, cd_reads_total);
    cd_reads_hb = 0; cd_secs_hb = 0;
}

/* Called by Main for every block-device READ the fabric requests (any slot: the
 * CD image is slot 1 at 2352 bytes/sector; the flash save is slot 4). Cheap
 * unless cdtrace=1, when every read is a log line (~100/s while a movie
 * streams -- only for a short targeted run). */
void s573_cd_trace(int disk, unsigned long long lba, int blks, int blksz)
{
    uint64_t t;
    if (!inited) return;
    t = now_us();
    if (cd_last_us && t - cd_last_us > 3000000ull)
        s573_log("s573mp3: cd: reads RESUMED after %.1f s of silence (disk=%d lba=%llu)\n",
                 (double)(t - cd_last_us) / 1e6, disk, lba);
    cd_reads_hb++; cd_secs_hb += (uint32_t)blks; cd_reads_total++;
    cd_last_lba = lba; cd_last_us = t; cd_last_disk = disk; cd_last_blksz = blksz;
    if (opt_cdtrace)
        s573_log("s573mp3: cd rd disk=%d lba=%llu n=%d sz=%d\n", disk, lba, blks, blksz);
}

/* ---------------------------------------------------------------- the hook --
 * Register next to mdplus_poll()/psx_poll() in user_io_poll(). */
static void s573mp3_poll_body(void);
void s573mp3_poll(void)
{
    uint64_t w0 = now_us();
    s573mp3_poll_body();
    ours_last_us = (uint32_t)(now_us() - w0);
    if (ours_last_us > ours_us_max) ours_us_max = ours_last_us;
    ours_us_sum += ours_last_us; ours_calls++;
}

static void s573mp3_poll_body(void)
{
    s573_ptrs_t p;
    uint64_t t;

    /* FIRST-CALL EVIDENCE, before the gate and before anything that can fail.
     * This was ordered the other way round and it cost a board cycle: the gate
     * decision and BOTH init failures went through a sink that did not exist
     * yet, so "gate missed", "open /dev/mem failed" and "mmap failed" were
     * indistinguishable from each other AND from the service not being in the
     * binary at all. Three causes, one empty file, no way to tell. */
    static int first = 0;
    if (!first) {
        const char *n  = user_io_get_core_name();
        const char *on = user_io_get_core_name(1);
        first = 1;
        (void)s573_read_debug_file();
        s573_open_log();
        s573_log("s573mp3: poll reached -- gate=%d core_name='%s' orig_name='%s'\n",
                 is_573(), n ? n : "(null)", on ? on : "(null)");
        if (!is_573())
            s573_log("s573mp3: gate MISS -- the service will stay idle for this "
                     "core. Launch via a .mgl whose <setname> is System573.\n");
    }

    if (!is_573()) return;
    if (gave_up)   return;
    if (!inited && !s573_init()) { gave_up = 1; return; }

    t = now_us();
    /* Main's loop period as seen from inside it: the worst gap is how long a CD
     * sector request or a USB report can sit unserviced. Sampled on EVERY call,
     * before the due check, because that is the loop itself, not our cadence. */
    if (poll_last_us) {
        uint32_t gap = (uint32_t)(t - poll_last_us);
        if (gap > poll_gap_max) { poll_gap_max = gap; gap_max_ours = ours_last_us; }
        poll_gap_sum += gap;
        poll_gaps++;
    }
    poll_last_us = t;

    if (t < next_due_us) return;
    next_due_us = t + S573_POLL_US;

    ptrs_exchange(&p);
    core.pcm_rd    = p.fab_pcm_rd;
    last_rst_seen  = p.rst_epoch;

    /* Pay out what the speakers have actually consumed since the last poll.
     * This is what puts the game's frame counter and stream position on the
     * drain instead of the decoder -- ~5 ms behind the audio instead of
     * ~1.5 s ahead of it. */
    s573_core_advance_played(&core, p.fab_pcm_rd);

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

        /* A null window (start == end == 0) is what the game presents before it
         * has set up a song. There is nothing buffered to discard, and parking
         * the writer one beat ahead would advertise one beat of whatever DDR3
         * happens to hold -- so skip it until there is a real window. */
        if ((act & S573_ACT_FLUSH) && f.mp3_end > f.mp3_start) {
            if (act & S573_ACT_FLUSH_DEFER) {
                /* The reader was LIVE when this window arrived (song-select scroll:
                 * the game re-arms while the previous preview still plays). MAME
                 * k573fpga.cpp update_mp3_decode_state() -> mas3507d reset_playback()
                 * discards every decoded-but-unplayed sample at that instant. The
                 * fabric can do the same, but only on a drain_en 1->0 edge
                 * (rtl/s573_mp3_pcm.v STOP FLUSH; rtl/s573_pcm_ring.v rd_en) -- so
                 * STOP IT FIRST, then read back where it actually froze, then park
                 * the writer one beat ahead of THAT. The previous scheme parked
                 * 1024 zeroed beats ahead of a stale snapshot while the reader kept
                 * running: any poll stall > 46 ms (decode bursts reach 68 ms, log
                 * fsync) let the reader overtake the park point and replay the old
                 * song; and with no stop edge the elastic buffer kept its 11.6 ms
                 * of the old preview. Both are the "previous preview plays briefly"
                 * report (2026-09-27). Cost: 2-9 extra SPI exchanges, microseconds.
                 * If the new config keeps the stream enabled, ctrl_flags still
                 * carries DRAIN_EN and the poll's closing ctrl_exchange() re-raises
                 * it AFTER decode_some() has prefilled the ring -- a clean 0->1
                 * start on fresh data, the same path a normal song start takes. */
                uint16_t want = core.ctrl_flags;
                s573_ptrs_t q;
                uint16_t rd0;
                int tries = 0;
                core.ctrl_flags = (uint16_t)(want & ~S573_CTRL_DRAIN_EN);
                ctrl_exchange();                       /* drain_en 1->0: fabric flush */
                ptrs_exchange(&q); rd0 = q.fab_pcm_rd;
                do {                                   /* one in-flight beat may land */
                    ptrs_exchange(&q);
                    if (q.fab_pcm_rd == rd0) break;
                    rd0 = q.fab_pcm_rd;
                } while (++tries < 8);
                core.pcm_rd = rd0;
                s573_core_advance_played(&core, rd0);
                pcm_ring_collapse(tries ? "re-arm, reader stopped (settled late)"
                                        : "re-arm, reader stopped", 1u);
                core.ctrl_flags = want;
            } else {
                pcm_ring_collapse("re-arm", 1u);       /* reader parked long ago */
            }
            mp3dec_init(&mp3d);
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
    if (opt_hb) {
        uint64_t h0 = now_us();
        ring_watch(); heartbeat(); stagetrace_dump(); sectrace_dump(); pcprof_dump();
        { uint32_t hus = (uint32_t)(now_us() - h0); if (hus > hb_us_max) hb_us_max = hus; }
    }
}
