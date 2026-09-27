#!/usr/bin/env python3
"""mips_count.py -- run one game routine (R3000 user code, no exceptions/COP) from the
extracted ddrextrm executable on real movie data and COUNT what it executes.

    mips_count.py out/re/ddrextrm_game.bin local/re/JBAACF.SBS [--frames N] [--slices]

Purpose: DecDCTvlc's cost per frame measured on the cabinet (PC-sampling profile) has
to be compared against SOMETHING that is not a guess. The instruction count of the
game's own routine on the game's own bitstream is the floor: an R3000 issues at most
one instruction per cycle, so cycles >= instructions, and every cycle above that is a
memory/pipeline stall. Loads and stores are counted separately because on a PSX they
are what the memory system charges for.

Model: the executable image is RAM at 0x80010000; scratch buffers are placed in free RAM
above the image; DecDCTvlc(bs, buf) is called exactly as the game does, optionally
preceded by DecDCTvlcSize((mdec_len+2)/2) and followed by DecDCTvlc(0,0) continuation
calls, mirroring 0x80071e9c..0x80071ef0 of the game.
"""
import struct, sys, argparse

BASE      = 0x80010000
VLC       = 0x80073804
VLCSIZE   = 0x800737d4
RET       = 0x8fff0000           # sentinel return address (never fetched)
RAM_BYTES = 4 << 20

class CPU:
    def __init__(self, image):
        self.ram = bytearray(RAM_BYTES)
        self.ram[BASE & 0x3fffff: (BASE & 0x3fffff) + len(image)] = image
        self.r = [0] * 32
        self.hi = self.lo = 0
        self.pc = 0
        self.n = 0; self.loads = 0; self.stores = 0; self.branches = 0
        self.lo_hist = {}   # load kinds
        self.pc_hist = {}

    # -- memory (little endian, physical = addr & 0x3fffff; game only touches RAM here)
    def lw(self, a):  return struct.unpack_from('<I', self.ram, a & 0x3ffffc)[0]
    def lh(self, a):  return struct.unpack_from('<H', self.ram, a & 0x3ffffe)[0]
    def lb(self, a):  return self.ram[a & 0x3fffff]
    def sw(self, a, v): struct.pack_into('<I', self.ram, a & 0x3ffffc, v & 0xffffffff)
    def sh(self, a, v): struct.pack_into('<H', self.ram, a & 0x3ffffe, v & 0xffff)
    def sb(self, a, v): self.ram[a & 0x3fffff] = v & 0xff

    def call(self, addr, args, limit=50_000_000):
        r = self.r
        for i, a in enumerate(args): r[4 + i] = a & 0xffffffff
        r[29] = 0x801ffff0            # stack near top of RAM
        r[31] = RET
        self.pc = addr
        while self.pc != RET:
            if self.n > limit: raise RuntimeError("runaway")
            self.step()
        return r[2]

    def step(self):
        pc = self.pc
        w = self.lw(pc)
        self.n += 1
        self.pc_hist[pc] = self.pc_hist.get(pc, 0) + 1
        npc = self.exec1(pc, w)
        if npc is None:
            self.pc = pc + 4
        else:
            self.branches += 1
            w2 = self.lw(pc + 4)
            self.n += 1
            self.pc_hist[pc + 4] = self.pc_hist.get(pc + 4, 0) + 1
            n2 = self.exec1(pc + 4, w2)
            if n2 is not None:
                raise RuntimeError("branch in delay slot at %08x" % (pc + 4))
            self.pc = npc

    def exec1(self, pc, w):
        r = self.r
        op = w >> 26; rs = (w >> 21) & 31; rt = (w >> 16) & 31; rd = (w >> 11) & 31
        sa = (w >> 6) & 31; fn = w & 63
        imm = w & 0xffff; simm = imm - 0x10000 if imm & 0x8000 else imm
        M = 0xffffffff
        def s32(x):
            x &= M
            return x - (1 << 32) if x & 0x80000000 else x
        if op == 0:
            if fn == 0:   r[rd] = (r[rt] << sa) & M
            elif fn == 2: r[rd] = r[rt] >> sa
            elif fn == 3: r[rd] = s32(r[rt]) >> sa & M
            elif fn == 4: r[rd] = (r[rt] << (r[rs] & 31)) & M
            elif fn == 6: r[rd] = r[rt] >> (r[rs] & 31)
            elif fn == 7: r[rd] = (s32(r[rt]) >> (r[rs] & 31)) & M
            elif fn == 8: return r[rs]
            elif fn == 9: t = r[rs]; r[rd] = pc + 8; return t
            elif fn == 16: r[rd] = self.hi
            elif fn == 18: r[rd] = self.lo
            elif fn == 17: self.hi = r[rs]
            elif fn == 19: self.lo = r[rs]
            elif fn == 24: p = s32(r[rs]) * s32(r[rt]); self.lo = p & M; self.hi = (p >> 32) & M
            elif fn == 25: p = r[rs] * r[rt]; self.lo = p & M; self.hi = (p >> 32) & M
            elif fn == 26:
                a, b = s32(r[rs]), s32(r[rt])
                if b: q = abs(a) // abs(b); q = -q if (a < 0) != (b < 0) else q; self.lo = q & M; self.hi = (a - q * b) & M
            elif fn == 27:
                a, b = r[rs], r[rt]
                if b: self.lo = a // b; self.hi = a % b
            elif fn in (32, 33): r[rd] = (r[rs] + r[rt]) & M
            elif fn in (34, 35): r[rd] = (r[rs] - r[rt]) & M
            elif fn == 36: r[rd] = r[rs] & r[rt]
            elif fn == 37: r[rd] = r[rs] | r[rt]
            elif fn == 38: r[rd] = r[rs] ^ r[rt]
            elif fn == 39: r[rd] = (~(r[rs] | r[rt])) & M
            elif fn == 42: r[rd] = 1 if s32(r[rs]) < s32(r[rt]) else 0
            elif fn == 43: r[rd] = 1 if r[rs] < r[rt] else 0
            else: raise RuntimeError("special %d at %08x" % (fn, pc))
            r[0] = 0
            return None
        br = pc + 4 + simm * 4
        if op == 1:
            if rt in (0, 16):
                if rt == 16: r[31] = pc + 8
                return br if s32(r[rs]) < 0 else None
            if rt in (1, 17):
                if rt == 17: r[31] = pc + 8
                return br if s32(r[rs]) >= 0 else None
            raise RuntimeError("regimm")
        if op == 2: return ((pc + 4) & 0xf0000000) | ((w & 0x3ffffff) << 2)
        if op == 3: r[31] = pc + 8; return ((pc + 4) & 0xf0000000) | ((w & 0x3ffffff) << 2)
        if op == 4: return br if r[rs] == r[rt] else None
        if op == 5: return br if r[rs] != r[rt] else None
        if op == 6: return br if s32(r[rs]) <= 0 else None
        if op == 7: return br if s32(r[rs]) > 0 else None
        if op in (8, 9): r[rt] = (r[rs] + simm) & M
        elif op == 10: r[rt] = 1 if s32(r[rs]) < simm else 0
        elif op == 11: r[rt] = 1 if r[rs] < (simm & M) else 0
        elif op == 12: r[rt] = r[rs] & imm
        elif op == 13: r[rt] = r[rs] | imm
        elif op == 14: r[rt] = r[rs] ^ imm
        elif op == 15: r[rt] = (imm << 16) & M
        elif op in (32, 33, 35, 36, 37):
            a = (r[rs] + simm) & M
            self.loads += 1
            self.lo_hist[op] = self.lo_hist.get(op, 0) + 1
            if op == 32: v = self.lb(a); r[rt] = (v - 256 if v & 0x80 else v) & M
            elif op == 33: v = self.lh(a); r[rt] = (v - 65536 if v & 0x8000 else v) & M
            elif op == 35: r[rt] = self.lw(a)
            elif op == 36: r[rt] = self.lb(a)
            elif op == 37: r[rt] = self.lh(a)
        elif op in (40, 41, 43):
            a = (r[rs] + simm) & M
            self.stores += 1
            if op == 40: self.sb(a, r[rt])
            elif op == 41: self.sh(a, r[rt])
            else: self.sw(a, r[rt])
        else:
            raise RuntimeError("op %d at %08x (%08x)" % (op, pc, w))
        r[0] = 0
        return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("exe"); ap.add_argument("sbs")
    ap.add_argument("--frames", type=int, default=8)
    ap.add_argument("--slices", action="store_true", help="mirror the game: DecDCTvlcSize((len+2)/2) then continuation calls")
    a = ap.parse_args()
    img = open(a.exe, "rb").read()
    sbs = open(a.sbs, "rb").read()
    BS  = 0x80100000            # bitstream copy (8 KB slot) above the image
    OUT = 0x80110000            # VLC output buffer (mdec_len words + header)
    tot = dict(n=0, loads=0, stores=0, codes=0, calls=0)
    print("%-6s %6s %9s %8s %8s %6s  %s" % ("frame", "codes", "instr", "loads", "stores", "calls", "instr/code  loads/code  stores/code"))
    for f in range(a.frames):
        slot = sbs[f * 8192:(f + 1) * 8192]
        mdec_len = struct.unpack_from("<H", slot, 0)[0]
        codes = mdec_len * 2
        cpu = CPU(img)
        cpu.ram[BS & 0x3fffff: (BS & 0x3fffff) + 8192] = slot
        calls = 0
        if a.slices:
            cpu.call(VLCSIZE, [(mdec_len + 2) >> 1])
            n0 = cpu.n
            rv = cpu.call(VLC, [BS, OUT]); calls += 1
            per = [cpu.n - n0]
            while rv > 0:
                n1 = cpu.n
                rv = cpu.call(VLC, [0, 0]); calls += 1
                per.append(cpu.n - n1)
            if rv < 0: print("frame %d: VLC error %d" % (f, rv))
            extra = "  per call: " + " ".join(str(p) for p in per)
        else:
            cpu.call(VLCSIZE, [0])
            rv = cpu.call(VLC, [BS, OUT]); calls = 1
            extra = "" if rv == 0 else "  rv=%d" % rv
        n = cpu.n
        print("%-6d %6d %9d %8d %8d %6d  %6.1f  %6.2f  %6.2f%s" % (f, codes, n, cpu.loads, cpu.stores, calls,
              n / codes, cpu.loads / codes, cpu.stores / codes, extra))
        tot["n"] += n; tot["loads"] += cpu.loads; tot["stores"] += cpu.stores; tot["codes"] += codes; tot["calls"] += calls
    print("total  %6d %9d %8d %8d %6d  %6.1f  %6.2f  %6.2f" % (tot["codes"], tot["n"], tot["loads"], tot["stores"], tot["calls"],
          tot["n"] / tot["codes"], tot["loads"] / tot["codes"], tot["stores"] / tot["codes"]))
    print("at 33.8688 MHz, %d instructions = %.2f ms per frame if one instruction per cycle" % (
          tot["n"] / a.frames, tot["n"] / a.frames / 33868.8))

if __name__ == "__main__":
    main()
