#!/usr/bin/env python3
"""cpubench_rom.py -- a tiny R3000 ROM that measures the core's cached-fetch cost.

    tools/cpubench_rom.py out.bin [--iters N]

Why. ddrextrm's DecDCTvlc runs at CPI ~3.3 on the SuperStation One (2026-09-27 profile vs. the
instruction count of the same routine on the same bitstream, tools/mips_count.py).
The suspect is psx_patches/0004, which forces an i-cache MISS on every 16-byte line
crossing. This ROM makes that cost directly measurable in the NVC full-system harness
(sim/system573/run.sh with BIOS_SRC pointing at this file, CPUBENCH=1): the tb logs the
clk1x cycle count at every non-sequential PC, so cycles per loop iteration fall out of
the trace for four loops that differ only in how they touch cache lines:

  A  64 instructions straight-line (16 lines) + branch  -> 17 line changes / iteration
  B  4 instructions inside ONE line + branch            ->  0 line changes / iteration
  C  like B plus one lw from RAM per iteration          ->  the data-load cost
  D  j-self halt

Boot: the reset vector (0xBFC00000, uncached ROM) copies the loops into RAM through
KSEG1 (0xA0010000) and jumps to the cached alias 0x80010000. No BIOS, no interrupts
(SR after reset has IEc=0), no I/O. The program is position-dependent (absolute j/bne
targets) and is laid out so every loop head sits on a 16-byte line boundary.
"""
import struct, sys, argparse

def R(n):
    return {'zero':0,'at':1,'v0':2,'v1':3,'a0':4,'a1':5,'a2':6,'a3':7,'t0':8,'t1':9,'t2':10,'t3':11,
            't4':12,'t5':13,'t6':14,'t7':15,'s0':16,'s1':17,'s2':18,'s3':19,'s4':20,'s5':21,'s6':22,'s7':23,
            't8':24,'t9':25,'k0':26,'k1':27,'gp':28,'sp':29,'fp':30,'ra':31}[n]

def lui(rt, imm):        return (0x0f << 26) | (R(rt) << 16) | (imm & 0xffff)
def ori(rt, rs, imm):    return (0x0d << 26) | (R(rs) << 21) | (R(rt) << 16) | (imm & 0xffff)
def addiu(rt, rs, imm):  return (0x09 << 26) | (R(rs) << 21) | (R(rt) << 16) | (imm & 0xffff)
def lw(rt, off, rs):     return (0x23 << 26) | (R(rs) << 21) | (R(rt) << 16) | (off & 0xffff)
def sw(rt, off, rs):     return (0x2b << 26) | (R(rs) << 21) | (R(rt) << 16) | (off & 0xffff)
def bne(rs, rt, pc, target):
    off = (target - (pc + 4)) >> 2
    return (0x05 << 26) | (R(rs) << 21) | (R(rt) << 16) | (off & 0xffff)
def j(target):           return (0x02 << 26) | ((target >> 2) & 0x3ffffff)
def jr(rs):              return (R(rs) << 21) | 0x08
NOP = 0

def build(iters):
    PROG_ROM_OFF = 0x200                 # program image lives here in the ROM
    PROG_RAM     = 0x80010000            # ...and runs here (cached alias of 0x00010000)
    prog = []                            # (built with absolute RAM addresses)
    def here(): return PROG_RAM + 4 * len(prog)
    def align16():
        while here() & 0xf: prog.append(NOP)

    # ---- phase A: 16 full lines of ALU work, then branch back (line 0 <- line 16)
    prog.append(addiu('t5', 'zero', iters))
    align16()
    A = here()
    for _ in range(62): prog.append(addiu('v0', 'v0', 1))
    prog.append(addiu('t5', 't5', -1))          # word 62
    prog.append(bne('t5', 'zero', here(), A))   # word 63: last word of line 15
    prog.append(NOP)                            # delay slot: word 0 of line 16
    # ---- phase B: the same branch structure inside a single line
    prog.append(addiu('t5', 'zero', iters))
    align16()
    B = here()
    prog.append(addiu('v0', 'v0', 1))
    prog.append(addiu('t5', 't5', -1))
    prog.append(bne('t5', 'zero', here(), B))
    prog.append(NOP)
    # ---- phase C: single line, one RAM load per iteration (t6 -> a word in RAM)
    prog.append(addiu('t5', 'zero', iters))
    prog.append(lui('t6', 0x8002))              # 0x80020000: RAM, nothing there, value irrelevant
    align16()
    C = here()
    prog.append(lw('v1', 0, 't6'))
    prog.append(addiu('t5', 't5', -1))
    prog.append(bne('t5', 'zero', here(), C))
    prog.append(NOP)
    # ---- phase D: halt
    align16()
    D = here()
    prog.append(j(D))
    prog.append(NOP)
    nwords = len(prog)

    # ---- reset code at 0xBFC00000: copy prog to RAM via KSEG1, jump to the cached alias
    boot = [
        lui('t0', 0xa001),                       # dst 0xA0010000
        lui('t1', 0xbfc0),
        ori('t1', 't1', PROG_ROM_OFF),           # src 0xBFC00200
        addiu('t2', 'zero', nwords),
    ]
    copy_pc = 0xbfc00000 + 4 * len(boot)
    boot += [
        lw('t3', 0, 't1'),
        addiu('t1', 't1', 4),
        sw('t3', 0, 't0'),
        addiu('t2', 't2', -1),
        None,                                    # bne t2,zero,copy  (filled below)
        addiu('t0', 't0', 4),
        NOP, NOP, NOP, NOP,                      # let the write FIFO drain before the jump
        lui('t0', 0x8001),                       # 0x80010000
        jr('t0'),
        NOP,
    ]
    boot[boot.index(None)] = bne('t2', 'zero', copy_pc + 4 * 4, copy_pc)

    rom = bytearray(0x1000)
    for i, w in enumerate(boot): struct.pack_into('<I', rom, 4 * i, w)
    for i, w in enumerate(prog): struct.pack_into('<I', rom, PROG_ROM_OFF + 4 * i, w)
    return rom, dict(A=A, B=B, C=C, D=D, words=nwords)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--iters', type=int, default=200)
    a = ap.parse_args()
    rom, info = build(a.iters)
    open(a.out, 'wb').write(rom)
    print("wrote %s (%d bytes): program %d words; loop heads A=%08x B=%08x C=%08x halt D=%08x, %d iterations each"
          % (a.out, len(rom), info['words'], info['A'], info['B'], info['C'], info['D'], a.iters))

if __name__ == '__main__':
    main()
