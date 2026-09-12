#!/usr/bin/env python3
"""Minimal MIPS I (R3000, PSX) disassembler for locating code paths.
usage: mipsdis.py FILE FILEOFF BASE START END  -- disassemble RAM range [START,END)
       mipsdis.py FILE FILEOFF BASE xref ADDR ... -- find lui/addiu(ori) refs to ADDR
"""
import struct, sys

R = ['zero','at','v0','v1','a0','a1','a2','a3','t0','t1','t2','t3','t4','t5','t6','t7',
     's0','s1','s2','s3','s4','s5','s6','s7','t8','t9','k0','k1','gp','sp','fp','ra']

def dis(pc, w):
    op = w >> 26; rs=(w>>21)&31; rt=(w>>16)&31; rd=(w>>11)&31; sa=(w>>6)&31; fn=w&63
    imm = w & 0xffff; simm = imm-0x10000 if imm & 0x8000 else imm
    tgt = ((pc+4)&0xf0000000) | ((w&0x3ffffff)<<2)
    br = pc+4+simm*4
    if w == 0: return 'nop'
    if op == 0:
        sp = {0:'sll',2:'srl',3:'sra'}
        if fn in sp: return f'{sp[fn]} {R[rd]},{R[rt]},{sa}'
        sp = {4:'sllv',6:'srlv',7:'srav'}
        if fn in sp: return f'{sp[fn]} {R[rd]},{R[rt]},{R[rs]}'
        if fn == 8: return f'jr {R[rs]}'
        if fn == 9: return f'jalr {R[rd]},{R[rs]}'
        if fn == 12: return 'syscall'
        if fn == 13: return 'break'
        sp = {16:'mfhi',18:'mflo'}
        if fn in sp: return f'{sp[fn]} {R[rd]}'
        sp = {17:'mthi',19:'mtlo'}
        if fn in sp: return f'{sp[fn]} {R[rs]}'
        sp = {24:'mult',25:'multu',26:'div',27:'divu'}
        if fn in sp: return f'{sp[fn]} {R[rs]},{R[rt]}'
        sp = {32:'add',33:'addu',34:'sub',35:'subu',36:'and',37:'or',38:'xor',39:'nor',42:'slt',43:'sltu'}
        if fn in sp: return f'{sp[fn]} {R[rd]},{R[rs]},{R[rt]}'
        return f'.word 0x{w:08x}'
    if op == 1:
        sp = {0:'bltz',1:'bgez',16:'bltzal',17:'bgezal'}
        return f'{sp.get(rt,"regimm?")} {R[rs]},0x{br:08x}'
    if op == 2: return f'j 0x{tgt:08x}'
    if op == 3: return f'jal 0x{tgt:08x}'
    if op == 4: return f'beq {R[rs]},{R[rt]},0x{br:08x}'
    if op == 5: return f'bne {R[rs]},{R[rt]},0x{br:08x}'
    if op == 6: return f'blez {R[rs]},0x{br:08x}'
    if op == 7: return f'bgtz {R[rs]},0x{br:08x}'
    sp = {8:'addi',9:'addiu',10:'slti',11:'sltiu'}
    if op in sp: return f'{sp[op]} {R[rt]},{R[rs]},{simm:#x}' if simm<0 else f'{sp[op]} {R[rt]},{R[rs]},0x{imm:x}'
    sp = {12:'andi',13:'ori',14:'xori'}
    if op in sp: return f'{sp[op]} {R[rt]},{R[rs]},0x{imm:x}'
    if op == 15: return f'lui {R[rt]},0x{imm:x}'
    if op in (16,18):
        c = op-16
        if rs == 0: return f'mfc{c} {R[rt]},${rd}'
        if rs == 2: return f'cfc{c} {R[rt]},${rd}'
        if rs == 4: return f'mtc{c} {R[rt]},${rd}'
        if rs == 6: return f'ctc{c} {R[rt]},${rd}'
        if op == 16 and fn == 16: return 'rfe'
        return f'cop{c} 0x{w&0x1ffffff:07x}'
    sp = {32:'lb',33:'lh',34:'lwl',35:'lw',36:'lbu',37:'lhu',38:'lwr',40:'sb',41:'sh',42:'swl',43:'sw',46:'swr',50:'lwc2',58:'swc2'}
    if op in sp: return f'{sp[op]} {R[rt]},{simm:#x}({R[rs]})' if simm<0 else f'{sp[op]} {R[rt]},0x{imm:x}({R[rs]})'
    return f'.word 0x{w:08x}'

def main():
    f, foff, base = sys.argv[1], int(sys.argv[2],0), int(sys.argv[3],0)
    d = open(f,'rb').read()
    def word(a):
        o = foff + (a-base)
        return struct.unpack_from('<I', d, o)[0]
    if sys.argv[4] == 'xref':
        targets = [int(x,0) for x in sys.argv[5:]]
        size = int(sys.argv[-1],0) if False else None
        # scan whole text: find lui then addiu/ori within 8 instrs matching each target
        n = (len(d)-foff)//4
        luis = {}
        for i in range(n):
            w = struct.unpack_from('<I', d, foff+i*4)[0]
            pc = base+i*4
            op = w>>26
            if op == 15:
                luis[(w>>16)&31] = (pc, w&0xffff)
            elif op in (9,13):  # addiu/ori
                rs=(w>>21)&31; imm=w&0xffff
                if rs in luis:
                    lpc, hi = luis[rs]
                    if pc - lpc <= 64:
                        if op == 9:
                            simm = imm-0x10000 if imm&0x8000 else imm
                            val = ((hi<<16)+simm)&0xffffffff
                        else:
                            val = (hi<<16)|imm
                        if val in targets:
                            print(f'{pc:08x}: ref 0x{val:08x}  (lui @ {lpc:08x})')
            elif op in (32,33,35,36,37,40,41,43):  # loads/stores with lui base
                rs=(w>>21)&31; imm=w&0xffff
                if rs in luis:
                    lpc, hi = luis[rs]
                    simm = imm-0x10000 if imm&0x8000 else imm
                    val = ((hi<<16)+simm)&0xffffffff
                    if val in targets and pc-lpc <= 64:
                        print(f'{pc:08x}: memref 0x{val:08x}  {dis(pc,w)}')
        return
    s, e = int(sys.argv[4],0), int(sys.argv[5],0)
    for a in range(s, e, 4):
        w = word(a)
        print(f'{a:08x}: {w:08x}  {dis(a,w)}')

main()
