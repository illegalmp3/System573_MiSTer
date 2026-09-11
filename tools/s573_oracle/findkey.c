/* findkey.c - recover ddrsbm's 16-bit key1 from a scrambled song file, offline.
 *
 * Why this is possible at all: the ddrsbm descramble scheme uses ONLY key1
 * (rotl 1 per word) -- see s573_desc_step(). 65,536 seeds is nothing, so the
 * key can be recovered from the data itself by looking for an MPEG-1 Layer III
 * frame header in the plaintext.
 *
 * Why it is worth doing: the decision-B spike proved the C descrambler agrees
 * with the RTL bit-for-bit, but BOTH could be wrong about the real game -- the
 * spike doc says so itself ("the existing tb_k573_mp3dec reference model is a
 * transliteration of the RTL's own functions, so 44/44 never tested fidelity").
 * If a key makes real ddrsbm disc data decode as real MP3 frames, that whole
 * class of doubt closes without a board.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static inline uint16_t dec_common(uint16_t data, uint16_t key)
{
    const uint16_t swapped = (uint16_t)(((data & 0x5555u) << 1) | ((data >> 1) & 0x5555u));
    const uint16_t odd     = (uint16_t)(key & 0xAAAAu);
    const uint16_t pair    = (uint16_t)(odd | (odd >> 1));
    return (uint16_t)((((swapped & pair) | (data & (uint16_t)~pair)) ^ (key & 0x5555u)));
}
#define ROTL1(k) ((uint16_t)(((k) << 1) | ((k) >> 15)))

static const int brate[16] = {0,32,40,48,56,64,80,96,112,128,160,192,224,256,320,0};
static const int srate[4]  = {44100,48000,32000,0};

/* descramble n bytes starting at word offset, high byte first */
static void descramble(const uint8_t *p, uint32_t nwords, uint16_t key, uint8_t *out)
{
    uint32_t i;
    for (i = 0; i < nwords; i++) {
        uint16_t src = (uint16_t)(p[2*i] | (p[2*i+1] << 8));
        uint16_t v   = dec_common(src, key);
        out[2*i]   = (uint8_t)(v >> 8);
        out[2*i+1] = (uint8_t)(v & 0xFF);
        key = ROTL1(key);
    }
}

/* a real MPEG-1 Layer III header, strictly checked */
static int frame_len(const uint8_t *h, int *hz, int *kbps)
{
    int ver, layer, bi, si, pad;
    if (h[0] != 0xFF || (h[1] & 0xE0) != 0xE0) return 0;
    ver   = (h[1] >> 3) & 3;      /* 3 = MPEG-1 */
    layer = (h[1] >> 1) & 3;      /* 1 = Layer III */
    if (ver != 3 || layer != 1) return 0;
    bi = (h[2] >> 4) & 15; si = (h[2] >> 2) & 3; pad = (h[2] >> 1) & 1;
    if (!brate[bi] || !srate[si]) return 0;
    *hz = srate[si]; *kbps = brate[bi];
    return 144000 * brate[bi] / srate[si] + pad;
}

int main(int argc, char **argv)
{
    const char *path = argv[1];
    uint32_t max_off = (argc > 2) ? (uint32_t)strtoul(argv[2], 0, 0) : 0x1000;
    FILE *f = fopen(path, "rb");
    uint8_t *buf, plain[32768];
    long sz;
    uint32_t off;
    int hits = 0;

    if (!f) { fprintf(stderr, "open %s failed\n", path); return 2; }
    fseek(f, 0, SEEK_END); sz = ftell(f); fseek(f, 0, SEEK_SET);
    buf = (uint8_t *)malloc(sz);
    if (fread(buf, 1, sz, f) != (size_t)sz) { fprintf(stderr, "read failed\n"); return 2; }
    fclose(f);

    for (off = 0; off + 32768 < (uint32_t)sz && off <= max_off; off += 2) {
        uint32_t k;
        for (k = 0; k < 65536; k++) {
            uint16_t src = (uint16_t)(buf[off] | (buf[off+1] << 8));
            uint16_t v   = dec_common(src, (uint16_t)k);
            int hz, kbps, len, n, ok;
            uint32_t p;
            if ((v >> 8) != 0xFF || (v & 0xE0) != 0xE0) continue;

            /* candidate: descramble a window and require a CHAIN of frames --
             * one lucky header is noise, four in a row at the exact computed
             * lengths is not */
            descramble(buf + off, 16384, (uint16_t)k, plain);
            len = frame_len(plain, &hz, &kbps);
            if (!len) continue;
            p = 0; ok = 0;
            /* 4 frames in a row happens by chance often enough to matter -- it
             * produced 14 false keys across this disc. 20, at the exact computed
             * frame lengths AND a constant bitrate, does not. */
            for (n = 0; n < 20; n++) {
                int hz2, kb2, l2;
                if (p + 4 > 32768) break;
                l2 = frame_len(plain + p, &hz2, &kb2);
                if (!l2 || hz2 != hz || kb2 != kbps) break;
                p += (uint32_t)l2; ok++;
            }
            if (ok >= 20) {
                printf("%-16s KEY1=0x%04X at offset 0x%X : %d Hz %d kbps, "
                       "%d consecutive frames\n",
                       path, k, off, hz, kbps, ok);
                hits++;
                if (hits >= 3) return 0;
            }
        }
    }
    if (!hits) printf("%-16s no key found in the first 0x%X bytes\n", path, max_off);
    return hits ? 0 : 1;
}
