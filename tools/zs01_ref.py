#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# zs01_ref.py - independent reference model of the ZS01 (NS2K001) security
# cassette, transcribed from MAME src/mame/konami/zs01.cpp (device side), plus
# the host side that a System 573 game implements, and a golden-vector generator.
#
# WHY: sim/tb_zs01.v round-trips the RTL against its own transliteration of the
# cipher, so a self-consistently WRONG algorithm passes it. This model shares no
# code with rtl/zs01.v: it is the C, line for line, in Python. The vectors it emits
# are raw CIPHERTEXT bytes on the wire -- what the host sends and what the device
# must answer -- so sim/tb_zs01_golden.v compares bytes and never runs an RTL
# cipher on the checking side.
#
#   python3 tools/zs01_ref.py --u1hex sim/secdata/ddrusa_u1.hex \
#                             --u6hex sim/secdata/ddrusa_u6.hex \
#                             --out   sim/secdata/ddrusa_zs01_vectors.hex
#
# Fidelity notes (all from zs01.cpp, all replicated in rtl/zs01.v):
#   * decrypt(): descending over the 12 bytes, chain seed 0xff, prev = ciphertext.
#   * decrypt2(): ascending over bytes 2..9 with the DATA key, seed m_previous_byte.
#   * The response buffer persists across commands. A WRITE zeroes all 12; a READ
#     or a CRC error sets ONLY byte 0. So byte 1 (and, on a READ with an invalid
#     address, bytes 2..9) keep the previous response's CIPHERTEXT, and
#     m_previous_byte = read_buffer[1] takes that stale byte.
#   * m_response_key is set from the (descrambled) data bytes of a READ, before
#     that same READ's response is encrypted. A WRITE leaves it unchanged.
#   * CRC-16/CCITT poly 0x1021 init 0xffff, inverted; standard pre-shift bit-15 test.
# -----------------------------------------------------------------------------
import argparse, sys

SIZE_DATA = 8
STATUS_OK, STATUS_ERROR = 0x00, 0x02
CONFIG_RR, CONFIG_RC = 4, 5

def calc_crc(buf):
    v1 = 0xffff
    for b in buf:
        v1 ^= (b << 8)
        for _ in range(8):
            v0 = v1 & 0x8000
            v1 = (v1 << 1) & 0xffff
            if v0: v1 ^= 0x1021
    return (~v1) & 0xffff

def _dec_byte(t0, key):
    for a1 in range(7, 0, -1):
        k = key[a1]
        t0 = (t0 - (k & 0x1f)) & 0xff
        r = k >> 5
        t0 = ((t0 >> r) | (t0 << ((8 - r) & 7))) & 0xff
    return t0

def decrypt(src, key, prev):            # zs01_device::decrypt -- descending
    dst = list(src)
    for i in range(len(src) - 1, -1, -1):
        t1 = src[i]
        dst[i] = ((_dec_byte(t1, key) - key[0]) ^ prev) & 0xff
        prev = t1
    return dst

def decrypt2(src, key, prev):           # zs01_device::decrypt2 -- ascending
    dst = list(src)
    for i in range(len(src)):
        t1 = src[i]
        dst[i] = ((_dec_byte(t1, key) - key[0]) ^ prev) & 0xff
        prev = t1
    return dst

def _enc_byte(p, key, prev):
    a0 = (key[0] + (p ^ prev)) & 0xff
    for t in range(1, 8):
        k = key[t]
        r = k >> 5
        a0 = ((a0 << r) | (a0 >> ((8 - r) & 7))) & 0xff
        a0 = (a0 + (k & 0x1f)) & 0xff
    return a0

def encrypt(src, key, prev):            # zs01_device::encrypt -- descending
    dst = list(src)
    for i in range(len(src) - 1, -1, -1):
        dst[i] = _enc_byte(src[i], key, prev)
        prev = dst[i]
    return dst

def encrypt2(src, key, prev):           # host-side inverse of decrypt2 -- ascending
    dst = list(src)
    for i in range(len(src)):
        dst[i] = _enc_byte(src[i], key, prev)
        prev = dst[i]
    return dst

# ---- self-check of the primitives: encrypt/decrypt must be exact inverses ----
def _selfcheck():
    import random
    rnd = random.Random(1)
    for _ in range(200):
        key = [rnd.randrange(256) for _ in range(8)]
        msg = [rnd.randrange(256) for _ in range(12)]
        assert decrypt(encrypt(msg, key, 0xff), key, 0xff) == msg
        seed = rnd.randrange(256)
        assert decrypt2(encrypt2(msg[2:10], key, seed), key, seed) == msg[2:10]

class ZS01:
    """Device model. Image layout: [0:4] RtR, [4:12] cmd key, [12:20] data key,
    [20:28] config, [28:140] data. ds = the 8-byte DS2401 file (.u6)."""
    def __init__(self, image, ds):
        assert len(image) >= 140 and image[0:4] == bytes([0x5a, 0x53, 0x00, 0x01])
        self.cmdkey = list(image[4:12]);  self.dkey = list(image[12:20])
        self.creg   = list(image[20:28]); self.data = list(image[28:140])
        self.ds     = list(ds)
        self.rbuf   = [0] * 12            # memset(m_read_buffer, 0)
        self.rkey   = [0] * 8             # memset(m_response_key, 0)
        self.prev   = 0                   # m_previous_byte = 0 (device_reset)

    def command(self, wire12):
        wb = decrypt(list(wire12), self.cmdkey, 0xff)
        if wb[0] & 4:
            wb[2:10] = decrypt2(wb[2:10], self.dkey, self.prev)
        crc = calc_crc(wb[:10]); msg_crc = (wb[10] << 8) | wb[11]
        off = wb[1] * SIZE_DATA
        if crc == msg_crc:
            self.creg[CONFIG_RC] = 0
            if (wb[0] & 1) == 0:                                   # COMMAND_WRITE
                self.rbuf = [0] * 12
                self.rbuf[0] = STATUS_OK
                if   wb[1] == 0xfd: self.data = [0] * 112; self.dkey = [0] * 8
                elif wb[1] == 0xfe: self.creg = wb[2:10]
                elif wb[1] == 0xff: self.dkey = wb[2:10]
                elif off < 112:     self.data[off:off + 8] = wb[2:10]
            else:                                                  # COMMAND_READ
                self.rbuf[0] = STATUS_OK
                if wb[1] in (0xfc, 0xfd):
                    for i in range(8): self.rbuf[2 + i] = self.ds[7 - i]   # direct_read(7-i)
                elif wb[1] == 0xfe: self.rbuf[2:10] = self.creg
                elif off < 112:     self.rbuf[2:10] = self.data[off:off + 8]
                self.rkey = wb[2:10]
        else:
            self.rbuf[0] = STATUS_ERROR
            self.creg[CONFIG_RC] = (self.creg[CONFIG_RC] + 1) & 0xff
            if self.creg[CONFIG_RC] >= self.creg[CONFIG_RR]:
                self.data = [0] * 112; self.dkey = [0] * 8
        self.prev = self.rbuf[1]
        crc = calc_crc(self.rbuf[:10])
        self.rbuf[10] = crc >> 8; self.rbuf[11] = crc & 0xff
        self.rbuf = encrypt(self.rbuf, self.rkey, 0xff)
        return list(self.rbuf)

def host_packet(cmd, addr, payload, cmdkey, dkey, prev, bad_crc=False):
    """What a 573 game puts on the wire for one command."""
    pkt = [cmd, addr] + list(payload)
    crc = calc_crc(pkt[:10])
    if bad_crc: crc ^= 0xffff
    pkt += [crc >> 8, crc & 0xff]
    if cmd & 4:
        pkt[2:10] = encrypt2(pkt[2:10], dkey, prev)
    return encrypt(pkt, cmdkey, 0xff)

def host_decode(resp, rkey):
    return decrypt(resp, rkey, 0xff)

def read_hex_bytes(path):
    out = []
    for line in open(path):
        line = line.split('//')[0].strip()
        if line: out.append(int(line, 16))
    return bytes(out)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--u1hex', required=True, help='140-byte (or padded) .u1 as one hex byte per line')
    ap.add_argument('--u6hex', required=True, help='8-byte .u6 as one hex byte per line')
    ap.add_argument('--out', required=True, help='golden vectors for sim/tb_zs01_golden.v')
    a = ap.parse_args()
    _selfcheck()
    img = read_hex_bytes(a.u1hex); ds = read_hex_bytes(a.u6hex)
    dev = ZS01(img, ds)
    cmdkey, dkey0 = list(img[4:12]), list(img[12:20])
    dkey = list(dkey0)

    vectors = []   # (label, wire_cmd, wire_resp, expect_status, expect_data_or_None)
    def run(label, cmd, addr, payload, bad_crc=False, expect=None):
        nonlocal dkey
        wire = host_packet(cmd, addr, payload, cmdkey, dkey, dev.prev, bad_crc)
        resp = dev.command(wire)
        plain = host_decode(resp, dev.rkey)
        st = plain[0]
        # model self-check: the host must be able to read what the device meant
        if bad_crc:
            assert st == STATUS_ERROR, (label, plain)
        else:
            assert st == STATUS_OK, (label, plain)
            if expect is not None:
                assert plain[2:10] == list(expect), (label, plain[2:10], list(expect))
        if not bad_crc and (cmd & 1) == 0 and addr == 0xff: dkey = list(payload)
        vectors.append((label, wire, resp, st, None if bad_crc else plain[2:10]))
        return plain

    data = list(img[28:140])
    # 1. the game's first authenticated read: the game code lives at data[0..7]
    run('READ 0x00 (game code)',        0x01, 0x00, [0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88], expect=data[0:8])
    # 2. read with a data-key-scrambled payload (cmd bit 2): exercises decrypt2 + the
    #    stale-byte-1 m_previous_byte seed after a READ. data[40..47] = DS2401 reversed.
    run('READ 0x05 cmd|4 (dkey pass)',  0x05, 0x05, [0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff,0x00], expect=data[40:48])
    # 3. internal DS2401 via both addresses
    run('READ 0xfc (DS2401)',           0x01, 0xfc, [0xc0,0xc1,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7], expect=[ds[7-i] for i in range(8)])
    run('READ 0xfd (DS2401)',           0x01, 0xfd, [0xd0,0xd1,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7], expect=[ds[7-i] for i in range(8)])
    # 4. config registers (RC must read 0 after good CRCs)
    run('READ 0xfe (config)',           0x01, 0xfe, [0xe0,0xe1,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7], expect=list(img[20:28]))
    # 5. plain write then read back (data[104..111])
    run('WRITE 0x0d',                   0x00, 0x0d, [0xa0,0xa1,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7])
    run('READ 0x0d (readback)',         0x01, 0x0d, [0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08], expect=[0xa0,0xa1,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7])
    # 6. data-key-scrambled write (seed = 0 after the previous... no: after a READ it is
    #    the stale byte) then read back (data[96..103])
    run('WRITE 0x0c cmd|4',             0x04, 0x0c, [0xb0,0xb1,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7])
    run('READ 0x0c cmd|4 (readback)',   0x05, 0x0c, [0x10,0x20,0x30,0x40,0x50,0x60,0x70,0x80], expect=[0xb0,0xb1,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7])
    # 7. bad CRC -> STATUS_ERROR and RC increments. The next GOOD command zeroes RC
    #    again before a config read copies it (zs01.cpp: RC=0 on every good CRC), so the
    #    readback shows RC=0 -- the increment is only observable through the response
    #    key staying unchanged and, at the RR limit, the wipe. RR=9 here, so no wipe.
    run('BAD CRC',                      0x01, 0x00, [0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88], bad_crc=True)
    assert dev.creg[CONFIG_RC] == 1
    run('READ 0xfe (after bad CRC)',    0x01, 0xfe, [0xe0,0xe1,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7], expect=list(img[20:28]))
    # 8. change the data key, then a cmd|4 read must use the new key
    run('WRITE 0xff (new data key)',    0x00, 0xff, [0x0f,0x1e,0x2d,0x3c,0x4b,0x5a,0x69,0x78])
    run('READ 0x00 cmd|4 (new dkey)',   0x05, 0x00, [0x8f,0x9e,0xad,0xbc,0xcb,0xda,0xe9,0xf8], expect=data[0:8])

    with open(a.out, 'w') as f:
        f.write('// golden ZS01 wire vectors -- generated by tools/zs01_ref.py from the ddrusa dump.\n')
        f.write('// byte 0 = vector count; then per vector 24 bytes: 12 host->device, 12 device->host.\n')
        f.write('// ALL bytes are ciphertext as seen on SDA. Regenerate with sim/gen_secdata.sh.\n')
        f.write('%02x\n' % len(vectors))
        for label, wire, resp, st, plain in vectors:
            f.write('// %s : status %02x%s\n' % (label, st, ('' if plain is None else ' data ' + ' '.join('%02x' % x for x in plain))))
            f.write(' '.join('%02x' % x for x in wire) + '\n')
            f.write(' '.join('%02x' % x for x in resp) + '\n')
        used = 1 + 24 * len(vectors)
        f.write('// zero padding to 1024 entries so $readmemh fills the bench array without a range warning\n')
        for _ in range(used, 1024): f.write('00\n')
    print('wrote %s: %d vectors, model self-checks pass' % (a.out, len(vectors)))

if __name__ == '__main__':
    main()
