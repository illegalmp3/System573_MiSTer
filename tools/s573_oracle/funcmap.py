"""funcmap.py FILE FILEOFF BASE START END -- function starts (addiu sp,-N), jal calls with
the a0-a3 setup and delay slot, and returns; quick map of a driver region."""
import struct,sys
src=open(__import__('os').path.join(__import__('os').path.dirname(__import__('os').path.abspath(__file__)),'mipsdis.py')).read().split('def main')[0]
ns={}; exec(src,ns); dis=ns['dis']
f,foff,base,s,e=sys.argv[1],int(sys.argv[2],0),int(sys.argv[3],0),int(sys.argv[4],0),int(sys.argv[5],0)
d=open(f,'rb').read()
W=lambda a: struct.unpack_from('<I',d,foff+a-base)[0]
recent=[]
for a in range(s,e,4):
    t=dis(a,W(a))
    if t.startswith('addiu sp,sp,-'): print(f'\nFUNC {a:08x}:', end='')
    if t.startswith('jal '):
        nxt=dis(a+4,W(a+4))
        args=[x for x in recent[-4:] if len(x.split())>1 and x.split()[1].startswith(('a0','a1','a2','a3'))]
        print(f'\n  {a:08x} {t} | {"; ".join(args)} | ds: {nxt}', end='')
    if t.startswith('jr ra'): print(f'\n  {a:08x} ret', end='')
    recent.append(t)
print()
