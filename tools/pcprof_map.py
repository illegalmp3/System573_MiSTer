#!/usr/bin/env python3
"""pcprof_map.py -- read the PC-sampling profile out of s573mp3.log.

    tools/pcprof_map.py /Volumes/MiSTer_Data/s573mp3.log            # whole log
    tools/pcprof_map.py s573mp3.log --from 120 --to 180              # seconds 120..180 of the log
    tools/pcprof_map.py s573mp3.log --top 24 --exe out/re/ddrextrm_game.bin

The fabric (rtl/s573_prof_pc.v) samples the R3000 fetch PC every 1024 clk1x and
bins it 2 KB at a time over the first MB of RAM; the HPS (support/s573/s573mp3.cpp)
prints one "s573mp3: pcprof-hist:" line per second with all 512 bins as 4-digit hex
deltas, and one "s573mp3: pcprof:" line with the class split. This sums the hist
lines in the chosen window and prints the bins as percentages of the samples,
annotated with the landmarks known from the ddrextrm disassembly
(docs/2026-09-18-ddrextrm-video-path-from-sources.md). Landmarks are per-title:
extend LANDMARKS when another game is profiled.

Every 'pcprof-hist' line is one second (the HPS dumps at 1 Hz), so --from/--to
count those lines, not wall-clock -- a log with gaps still indexes cleanly.
"""
import argparse, re, sys

BIN_BYTES = 0x800
RAM_BASE  = 0x80000000

# (start, end, label) -- addresses are KSEG0; end exclusive. ddrextrm main exe.
LANDMARKS = [
    (0x80000000, 0x80010000, "PS1 kernel (BIOS in RAM: exceptions, syscalls, events)"),
    (0x8001a800, 0x8001b000, "libgpu: DrawSync / GPU queue (\"GPU timeout\" string user at 0x8001a8f8)"),
    (0x8001b000, 0x8001b800, "libgpu: VSync (\"VSync: timeout\" string user at 0x8001b0fc)"),
    (0x80070800, 0x80071000, "game: movie player init / config (0x80070f40 sets 304x176)"),
    (0x80071000, 0x80072000, "game: movie slot loader / scheduler"),
    (0x80072000, 0x80072800, "game: movie decode kick + DecDCTReset-on-busy (0x80072110..0x800721d8)"),
    (0x80073000, 0x80073800, "libpress: DecDCTReset/in/out + BLOCKING in/outSync spins (0x80073610, 0x800736a4)"),
    (0x80073800, 0x80074000, "libpress: DecDCTvlc (CPU bitstream expansion, 0x80073804)"),
    (0x800db000, 0x800db800, "libpress I/O address table (data)"),
]

def landmark(addr):
    out = []
    for s, e, l in LANDMARKS:
        if s < addr + BIN_BYTES and e > addr:
            out.append(l)
    return "; ".join(out)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--from", dest="t0", type=int, default=0, help="first hist line (second) to include")
    ap.add_argument("--to", dest="t1", type=int, default=1 << 30, help="last hist line (second), exclusive")
    ap.add_argument("--top", type=int, default=32)
    ap.add_argument("--all", action="store_true", help="print every non-zero bin, not just the top N")
    a = ap.parse_args()

    hist = [0] * 512
    n_lines = 0
    cls = {"samples": 0, "ram_lo": 0.0, "ram_hi": 0.0, "bios": 0.0, "other": 0.0}
    n_cls = 0
    rx_hist = re.compile(r"pcprof-hist:([0-9a-f]{2048})")
    rx_cls = re.compile(r"pcprof: samples=(\d+)/s \| ram<1M=([\d.]+)% ram>1M=([\d.]+)% bios=([\d.]+)% other=([\d.]+)%")
    with open(a.log, "r", errors="replace") as f:
        for line in f:
            m = rx_hist.search(line)
            if m:
                if a.t0 <= n_lines < a.t1:
                    h = m.group(1)
                    for i in range(512):
                        hist[i] += int(h[4 * i:4 * i + 4], 16)
                n_lines += 1
                continue
            m = rx_cls.search(line)
            # the split line precedes its hist line, so it belongs to second n_lines
            if m and a.t0 <= n_lines < a.t1:
                cls["samples"] += int(m.group(1))
                cls["ram_lo"] += float(m.group(2)); cls["ram_hi"] += float(m.group(3))
                cls["bios"] += float(m.group(4)); cls["other"] += float(m.group(5))
                n_cls += 1

    total = sum(hist)
    if n_lines == 0:
        sys.exit("no pcprof-hist lines in %s -- is the profiler bitstream + firmware deployed and s573mp3.debug present?" % a.log)
    used = min(n_lines, a.t1) - a.t0
    print("%d hist lines in the log, %d in the window [%d, %d); %d samples in RAM<1M" % (n_lines, used, a.t0, min(n_lines, a.t1), total))
    if n_cls:
        print("class split (avg of %d lines): samples/s=%.0f ram<1M=%.1f%% ram>1M=%.1f%% bios=%.1f%% other=%.1f%%" % (
            n_cls, cls["samples"] / n_cls, cls["ram_lo"] / n_cls, cls["ram_hi"] / n_cls, cls["bios"] / n_cls, cls["other"] / n_cls))
    if total == 0:
        sys.exit("window has no samples")
    order = sorted(range(512), key=lambda i: -hist[i])
    shown = 0
    print("%-6s %-21s %8s %7s  %s" % ("bin", "address", "samples", "%", "landmark"))
    for i in order:
        if hist[i] == 0: break
        if not a.all and shown >= a.top: break
        addr = RAM_BASE + i * BIN_BYTES
        print("0x%03x  %08x-%08x %8d %6.1f%%  %s" % (i, addr, addr + BIN_BYTES - 1, hist[i], 100.0 * hist[i] / total, landmark(addr)))
        shown += 1
    # coarse view: the same data folded onto the landmarks, so the question
    # "spin-wait or work" is answered in one block
    print()
    print("by landmark:")
    for s, e, l in LANDMARKS:
        n = sum(hist[i] for i in range(512) if s <= RAM_BASE + i * BIN_BYTES < e)
        if n: print("  %6.1f%%  %s" % (100.0 * n / total, l))
    rest = total - sum(sum(hist[i] for i in range(512) if s <= RAM_BASE + i * BIN_BYTES < e) for s, e, _ in LANDMARKS)
    print("  %6.1f%%  everything else (game code without a landmark yet)" % (100.0 * rest / total))

if __name__ == "__main__":
    main()
