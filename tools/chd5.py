#!/usr/bin/env python3
"""chd5.py -- read CD-ROM CHD v5 images (cdlz / cdzl hunks) in pure Python.

Complements tools/chd_extract.py, which handles v3/v4 zlib only. The v5 layout
follows MAME src/lib/util/chd.cpp (decompress_v5_map, huffman.cpp import_tree_rle)
and chdcodec.cpp (chd_cd_compressor::decompress). cdfl (FLAC) hunks are reported,
not decoded.

    chd5.py image.chd --info
    chd5.py image.chd --ls
    chd5.py image.chd --get DATA/MOVIE/FOO.SBS -o foo.sbs
"""
import argparse, lzma, os, struct, sys, zlib

CD_FRAME = 2448          # 2352 sector + 96 subcode, as stored in a hunk
CD_SECTOR = 2352
CD_SUB = 96

# map entry compression codes (chd.h)
COMP_TYPE_0, COMP_TYPE_1, COMP_TYPE_2, COMP_TYPE_3 = 0, 1, 2, 3
COMP_NONE, COMP_SELF, COMP_PARENT, COMP_RLE_SMALL, COMP_RLE_LARGE = 4, 5, 6, 7, 8


class BitReader:
    """MSB-first bit reader (util::bitstream_in)."""
    def __init__(self, data):
        self.data = data; self.pos = 0
    def read(self, n):
        v = 0
        for _ in range(n):
            byte = self.data[self.pos >> 3]
            v = (v << 1) | ((byte >> (7 - (self.pos & 7))) & 1)
            self.pos += 1
        return v


class Huffman8:
    """huffman_decoder<16,8> (chd.cpp decompress_v5_map): import_tree_rle + canonical codes."""
    NUMCODES, MAXBITS = 16, 8

    def __init__(self, br):
        numbits = 4                      # 8 <= MAXBITS < 16 (huffman.cpp import_tree_rle)
        lengths = [0] * self.NUMCODES
        cur = 0
        while cur < self.NUMCODES:
            nb = br.read(numbits)
            if nb != 1:
                lengths[cur] = nb; cur += 1
            else:
                nb = br.read(numbits)
                if nb == 1:
                    lengths[cur] = nb; cur += 1
                else:
                    rep = br.read(numbits) + 3
                    for _ in range(rep):
                        lengths[cur] = nb; cur += 1
        # assign_canonical_codes
        histo = [0] * (self.MAXBITS + 1)
        for l in lengths:
            if l > self.MAXBITS: raise ValueError("huffman length > maxbits")
            if l: histo[l] += 1
        curstart = 0
        for codelen in range(self.MAXBITS, 0, -1):
            nextstart = (curstart + histo[codelen]) >> 1
            if codelen != 1 and nextstart * 2 != curstart + histo[codelen]:
                raise ValueError("huffman tree not canonical")
            histo[codelen] = curstart
            curstart = nextstart
        self.table = {}
        for sym, l in enumerate(lengths):
            if l:
                self.table[(l, histo[l])] = sym; histo[l] += 1

    def decode_one(self, br):
        code, l = 0, 0
        while True:
            code = (code << 1) | br.read(1); l += 1
            s = self.table.get((l, code))
            if s is not None: return s
            if l > self.MAXBITS: raise ValueError("bad huffman code")


class Chd5:
    def __init__(self, path):
        self.f = open(path, 'rb')
        h = self.f.read(124)
        if h[:8] != b'MComprHD': raise SystemExit("%s: not a CHD" % path)
        hl, ver = struct.unpack('>II', h[8:16])
        if ver != 5: raise SystemExit("CHD v%d: use tools/chd_extract.py for v3/v4" % ver)
        self.comp = [h[16 + 4 * i:20 + 4 * i] for i in range(4)]
        self.logicalbytes, self.mapoffset, self.metaoffset = struct.unpack('>QQQ', h[32:56])
        self.hunkbytes, self.unitbytes = struct.unpack('>II', h[56:64])
        self.hunkcount = (self.logicalbytes + self.hunkbytes - 1) // self.hunkbytes
        self.frames_per_hunk = self.hunkbytes // CD_FRAME
        self.sectors = self.logicalbytes // CD_FRAME
        self._read_map()
        self._cache = {}

    # -- map ---------------------------------------------------------------
    def _read_map(self):
        self.f.seek(self.mapoffset)
        if self.comp[0] == b'\0\0\0\0':            # uncompressed map: 4-byte offsets in hunks
            raw = self.f.read(4 * self.hunkcount)
            self.map = [(COMP_NONE, self.hunkbytes, struct.unpack('>I', raw[4*i:4*i+4])[0] * self.hunkbytes)
                        for i in range(self.hunkcount)]
            return
        mh = self.f.read(16)
        maplen = struct.unpack('>I', mh[0:4])[0]
        firstoff = int.from_bytes(mh[4:10], 'big')
        lengthbits, selfbits, parentbits = mh[12], mh[13], mh[14]
        comp = self.f.read(maplen)
        br = BitReader(comp)
        dec = Huffman8(br)
        codes = [0] * self.hunkcount
        last, rep = 0, 0
        for i in range(self.hunkcount):
            if rep > 0:
                codes[i] = last; rep -= 1
            else:
                v = dec.decode_one(br)
                if v == COMP_RLE_SMALL:
                    codes[i] = last; rep = 2 + dec.decode_one(br)
                elif v == COMP_RLE_LARGE:
                    codes[i] = last; rep = 2 + 16 + (dec.decode_one(br) << 4); rep += dec.decode_one(br)
                else:
                    codes[i] = last = v
        self.map = []
        cur = firstoff; last_self = 0; last_parent = 0
        for i in range(self.hunkcount):
            c = codes[i]; length = 0; off = cur
            if c in (0, 1, 2, 3):
                length = br.read(lengthbits); cur += length; br.read(16)
            elif c == COMP_NONE:
                length = self.hunkbytes; cur += length; br.read(16)
            elif c == COMP_SELF:
                off = br.read(selfbits); last_self = off
            elif c == COMP_PARENT:
                off = br.read(parentbits); last_parent = off
            else:
                raise ValueError("unexpected rle code in map pass 2")
            self.map.append((c, length, off))

    # -- hunks -------------------------------------------------------------
    def hunk(self, n):
        if n in self._cache: return self._cache[n]
        c, length, off = self.map[n]
        if c == COMP_SELF:
            data = self.hunk(off)
        elif c == COMP_PARENT:
            raise SystemExit("hunk %d needs a parent CHD" % n)
        elif c == COMP_NONE:
            self.f.seek(off); data = self.f.read(self.hunkbytes)
        else:
            codec = self.comp[c]
            self.f.seek(off); src = self.f.read(length)
            data = self._cd_decompress(codec, src)
        if len(self._cache) > 64: self._cache.clear()
        self._cache[n] = data
        return data

    def _cd_decompress(self, codec, src):
        frames = self.frames_per_hunk
        complen_bytes = 2 if self.hunkbytes < 65536 else 3
        ecc_bytes = (frames + 7) // 8
        hdr = ecc_bytes + complen_bytes
        complen_base = (src[ecc_bytes] << 8) | src[ecc_bytes + 1]
        if complen_bytes > 2: complen_base = (complen_base << 8) | src[ecc_bytes + 2]
        base_src = src[hdr:hdr + complen_base]
        if codec == b'cdlz':
            # raw LZMA1, props from LzmaEncProps_Normalize(level 9, reduceSize=hunkbytes)
            d = lzma.LZMADecompressor(format=lzma.FORMAT_RAW,
                                      filters=[{'id': lzma.FILTER_LZMA1, 'dict_size': 1 << 24,
                                                'lc': 3, 'lp': 0, 'pb': 2}])
            base = d.decompress(base_src, frames * CD_SECTOR)
        elif codec == b'cdzl':
            base = zlib.decompressobj(-15).decompress(base_src, frames * CD_SECTOR)
        elif codec == b'cdfl':
            raise SystemExit("cdfl (FLAC) hunk: not decodable here")
        else:
            raise SystemExit("unknown codec %r" % codec)
        if len(base) != frames * CD_SECTOR:
            raise SystemExit("hunk decompressed to %d bytes, expected %d" % (len(base), frames * CD_SECTOR))
        # subcode not needed by anything here; reassemble frames with zero subcode
        out = bytearray()
        for i in range(frames):
            out += base[i * CD_SECTOR:(i + 1) * CD_SECTOR] + b'\0' * CD_SUB
        return bytes(out)

    def sector(self, lba):
        """2352-byte raw sector (sync/header not reconstituted)."""
        h, i = divmod(lba, self.frames_per_hunk)
        d = self.hunk(h)
        return d[i * CD_FRAME:i * CD_FRAME + CD_SECTOR]

    def user(self, lba):
        s = self.sector(lba)
        # MODE1 raw frames carry user data at 16; MODE1/2048 hunks (unitbytes 2448
        # but data at 0 -- see tools/chd_extract.py history) are detected by sync.
        if s[:12] == b'\x00' + b'\xff' * 10 + b'\x00' or s[0:1] == b'\x00' and s[15] in (1, 2):
            return s[16:16 + 2048]
        return s[:2048]

    def codec_histogram(self):
        h = {}
        for c, _, _ in self.map:
            name = {0: self.comp[0], 1: self.comp[1], 2: self.comp[2], 3: self.comp[3],
                    COMP_NONE: b'none', COMP_SELF: b'self', COMP_PARENT: b'parent'}[c]
            h[name] = h.get(name, 0) + 1
        return h


# -- ISO9660 --------------------------------------------------------------
def iso_root(chd):
    pvd = chd.user(16)
    if pvd[1:6] != b'CD001': raise SystemExit("no ISO9660 PVD at sector 16")
    rec = pvd[156:190]
    return struct.unpack('<I', rec[2:6])[0], struct.unpack('<I', rec[10:14])[0]

def iso_dir(chd, lba, length):
    out = []
    data = b''.join(chd.user(lba + i) for i in range((length + 2047) // 2048))
    p = 0
    while p < len(data):
        rl = data[p]
        if rl == 0:
            p = (p // 2048 + 1) * 2048; continue
        r = data[p:p + rl]
        ext = struct.unpack('<I', r[2:6])[0]; sz = struct.unpack('<I', r[10:14])[0]
        flags = r[25]; nl = r[32]; name = r[33:33 + nl]
        if name not in (b'\x00', b'\x01'):
            name = name.decode('latin-1').split(';')[0]
            out.append((name, ext, sz, bool(flags & 2)))
        p += rl
    return out

def iso_walk(chd, lba, length, prefix=''):
    for name, ext, sz, isdir in iso_dir(chd, lba, length):
        path = prefix + '/' + name
        if isdir:
            yield from iso_walk(chd, ext, sz, path)
        else:
            yield path, ext, sz

def iso_read(chd, ext, sz):
    return b''.join(chd.user(ext + i) for i in range((sz + 2047) // 2048))[:sz]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('chd')
    ap.add_argument('--info', action='store_true')
    ap.add_argument('--ls', action='store_true')
    ap.add_argument('--get')
    ap.add_argument('-o', '--out')
    a = ap.parse_args()
    c = Chd5(a.chd)
    if a.info:
        print("hunks %d x %d B, %d frames/hunk, %d sectors" % (c.hunkcount, c.hunkbytes, c.frames_per_hunk, c.sectors))
        print("codecs:", {k.decode() if isinstance(k, bytes) else k: v for k, v in c.codec_histogram().items()})
    root = iso_root(c)
    if a.ls:
        for path, ext, sz in iso_walk(c, *root):
            print("%10d  lba %7d  %s" % (sz, ext, path))
    if a.get:
        for path, ext, sz in iso_walk(c, *root):
            if path.lower() == ('/' + a.get.lstrip('/')).lower():
                data = iso_read(c, ext, sz)
                open(a.out or os.path.basename(path), 'wb').write(data)
                print("wrote %s (%d bytes)" % (a.out or os.path.basename(path), len(data)))
                return
        raise SystemExit("not found: " + a.get)

if __name__ == '__main__':
    main()
