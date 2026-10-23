"""jalref.py FILE FILEOFF BASE ADDR... -- list j/jal instructions whose target is one of ADDR."""
import struct,sys
f,foff,base=sys.argv[1],int(sys.argv[2],0),int(sys.argv[3],0)
d=open(f,'rb').read()
tg=[int(x,0) for x in sys.argv[4:]]
for i in range((len(d)-foff)//4):
    w=struct.unpack_from('<I',d,foff+i*4)[0]; pc=base+i*4
    if w>>26 in (2,3):
        t=((pc+4)&0xf0000000)|((w&0x3ffffff)<<2)
        if t in tg: print(f'{pc:08x}: {"jal" if w>>26==3 else "j"} {t:08x}')
