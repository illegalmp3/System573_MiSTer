#!/usr/bin/env python3
"""chd_extract.py -- pull the 2048-byte user data out of a MAME CD-ROM CHD.

    tools/chd_extract.py dumps/mame573/a37jaa02.chd -o /tmp/dsfdr.iso
    tools/chd_extract.py dumps/mame573/a37jaa02.chd --ls
    tools/chd_extract.py dumps/mame573/a37jaa02.chd --get PSX.EXE -o /tmp/psx.exe

Why this exists: decoding ddrusa's ERROR 121 out of the game's own binary settled
in one afternoon what four bitstreams could not. Every 573 title carries its error
table and its ATAPI command sequence in PSX.EXE, so reading the disc is cheaper
than instrumenting the fabric -- but only if extracting it is one command instead
of an afternoon. Hence a checked-in tool rather than a throwaway script.

Supports CHD v3/v4 with zlib hunks (compression 1 or 2), which is what the MAME
573 CD dumps use. v5 (cdlz/cdzl/cdfl) is not handled: those need the CD-specific
sector framing and LZMA, and no 573 dump here needs it.
"""
import struct, sys, zlib, os, argparse

SECTOR_RAW  = 2448          # 2352 data + 96 subcode, as MAME stores CD hunks
SECTOR_USER = 2048
MODE1_OFF   = 16            # sync(12) + header(4) before the user data

class Chd:
    def __init__(self, path):
        self.f = open(path, 'rb')
        if self.f.read(8) != b'MComprHD':
            raise SystemExit("%s: not a CHD" % path)
        hdrlen, ver = struct.unpack('>II', self.f.read(8))
        self.f.seek(0); hdr = self.f.read(hdrlen)
        self.ver = ver
        if ver not in (3, 4):
            raise SystemExit("CHD v%d not supported by this tool (v3/v4 zlib only)" % ver)
        self.compression, self.totalhunks = struct.unpack('>II', hdr[20:28])
        self.logicalbytes, self.metaoffset = struct.unpack('>QQ', hdr[28:44])
        if ver == 4:
            self.hunkbytes = struct.unpack('>I', hdr[44:48])[0]
        else:
            self.hunkbytes = struct.unpack('>I', hdr[84:88])[0]
        if self.compression not in (1, 2):
            raise SystemExit("CHD compression %d is not zlib" % self.compression)
        self.f.seek(hdrlen)
        self.map = self.f.read(16 * self.totalhunks)
        self.sectors = self.logicalbytes // SECTOR_RAW
        self._cache = (None, None)

    def hunk(self, n):
        if self._cache[0] == n:
            return self._cache[1]
        e = self.map[16 * n:16 * n + 16]
        off = struct.unpack('>Q', e[0:8])[0]
        length = struct.unpack('>H', e[12:14])[0] | (e[14] << 16)
        flags = e[15] & 0x0f
        if flags == 1:                                  # COMPRESSED
            self.f.seek(off); data = zlib.decompress(self.f.read(length), -15) \
                if False else zlib.decompressobj().decompress(self.f.read(0) or b'')
            # (the branch above is never taken; real read below)
        if flags == 1:
            self.f.seek(off)
            data = zlib.decompressobj(-15).decompress(self.f.read(length))
            if len(data) != self.hunkbytes:             # some writers use zlib headers
                self.f.seek(off)
                data = zlib.decompress(self.f.read(length))
        elif flags == 2:                                # UNCOMPRESSED
            self.f.seek(off); data = self.f.read(self.hunkbytes)
        elif flags == 3:                                # MINI: 8-byte pattern
            data = (e[0:8] * ((self.hunkbytes // 8) + 1))[:self.hunkbytes]
        elif flags == 4:                                # SELF_REF: a duplicate of
            # another hunk in this same file; the offset field holds its NUMBER,
            # not a file offset. Common on discs with long identical runs (the two
            # MODE1/2048 dumps here, 936eaa and 910jca02, both use it). Without
            # this the reader dies with "unhandled map type 4" partway in.
            data = self.hunk(struct.unpack('>Q', e[0:8])[0])
        else:
            raise SystemExit("hunk %d: unhandled map type %d" % (n, flags))
        if len(data) != self.hunkbytes:
            raise SystemExit("hunk %d: got %d bytes, expected %d" % (n, len(data), self.hunkbytes))
        self._cache = (n, data)
        return data

    def raw_sector(self, lba):
        pos = lba * SECTOR_RAW
        h, o = divmod(pos, self.hunkbytes)
        buf = self.hunk(h)[o:o + SECTOR_RAW]
        while len(buf) < SECTOR_RAW:                    # straddles a hunk boundary
            h += 1
            buf += self.hunk(h)[:SECTOR_RAW - len(buf)]
        return buf

    def user_sector(self, lba):
        return self.raw_sector(lba)[MODE1_OFF:MODE1_OFF + SECTOR_USER]

# ---------------- minimal ISO9660 (single extent, no Joliet needed) ----------
def iso_root(chd):
    pvd = chd.user_sector(16)
    if pvd[1:6] != b'CD001':
        raise SystemExit("no ISO9660 PVD at LBA 16 (got %r)" % pvd[1:6])
    rec = pvd[156:190]
    return struct.unpack('<I', rec[2:6])[0], struct.unpack('<I', rec[10:14])[0]

def iso_dir(chd, lba, length):
    data = b''.join(chd.user_sector(lba + i) for i in range((length + 2047) // 2048))
    out, p = [], 0
    while p < len(data):
        ln = data[p]
        if ln == 0:
            p = (p // 2048 + 1) * 2048          # pad to the next sector
            if p >= len(data): break
            continue
        r = data[p:p + ln]
        ex = struct.unpack('<I', r[2:6])[0]
        sz = struct.unpack('<I', r[10:14])[0]
        fl = r[25]
        nl = r[32]
        nm = r[33:33 + nl].decode('latin1')
        if nl == 1 and r[33] in (0, 1):
            nm = ('.', '..')[r[33]]
        out.append((nm.split(';')[0], ex, sz, bool(fl & 2)))
        p += ln
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('chd')
    ap.add_argument('-o', '--out')
    ap.add_argument('--ls', action='store_true', help="list the root directory")
    ap.add_argument('--get', help="extract one file from the root directory")
    ap.add_argument('--sectors', type=int, default=0, help="with -o and no --get: stop after N sectors")
    a = ap.parse_args()
    c = Chd(a.chd)
    print("CHD v%d  hunkbytes=%d  hunks=%d  %d sectors (%d user bytes)"
          % (c.ver, c.hunkbytes, c.totalhunks, c.sectors, c.sectors * SECTOR_USER), file=sys.stderr)

    if a.ls or a.get:
        lba, ln = iso_root(c)
        ents = iso_dir(c, lba, ln)
        if a.ls:
            for nm, ex, sz, isdir in ents:
                print("%-16s %s lba=%-8d %10d" % (nm, 'd' if isdir else '-', ex, sz))
            return
        for nm, ex, sz, isdir in ents:
            if nm.upper() == a.get.upper() and not isdir:
                data = b''.join(c.user_sector(ex + i) for i in range((sz + 2047) // 2048))[:sz]
                out = a.out or nm
                open(out, 'wb').write(data)
                print("wrote %s (%d bytes) from lba %d" % (out, sz, ex), file=sys.stderr)
                return
        raise SystemExit("%s not found in the root directory" % a.get)

    if not a.out:
        raise SystemExit("need -o, --ls or --get")
    n = a.sectors or c.sectors
    with open(a.out, 'wb') as g:
        for i in range(n):
            g.write(c.user_sector(i))
    print("wrote %s (%d sectors)" % (a.out, n), file=sys.stderr)

main()
