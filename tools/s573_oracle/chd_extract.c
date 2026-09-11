/* chd_extract.c - CHD -> raw sectors / ISO user data, for the 573 byte-oracle.
 *
 * Built natively (not cross) against Main_MiSTer's vendored libchdr, purely to
 * give the s573mp3 dump=1 window something to be compared against: the game
 * copies its scrambled MP3 out of the disc into DIO sample RAM without
 * transforming it, so the bytes the HPS sees must appear verbatim on the disc.
 *
 * MAME stores a CD as interleaved 2352-byte sectors + 96 bytes of subcode. A
 * naive whole-hunk dump therefore has the subcode spliced through it every 2352
 * bytes, which breaks any contiguous match -- so -iso strips both the subcode
 * and each sector's 16-byte sync/header, leaving the 2048-byte Mode-1 user data.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libchdr/chd.h"

int main(int argc, char **argv)
{
    chd_file *chd = NULL;
    const chd_header *h;
    unsigned char *hunk;
    FILE *out;
    unsigned i, s, sectors_per_hunk, framesize;
    int iso = (argc > 3 && !strcmp(argv[3], "-iso"));
    unsigned long long written = 0;

    if (argc < 3) { fprintf(stderr, "usage: %s in.chd out.bin [-iso]\n", argv[0]); return 2; }
    if (chd_open(argv[1], CHD_OPEN_READ, NULL, &chd) != CHDERR_NONE) {
        fprintf(stderr, "chd_open failed\n"); return 1;
    }
    h = chd_get_header(chd);
    framesize = h->unitbytes ? h->unitbytes : 2448;
    sectors_per_hunk = h->hunkbytes / framesize;
    fprintf(stderr, "hunkbytes=%u unitbytes=%u totalhunks=%u logicalbytes=%llu "
                    "-> %u sectors/hunk, frame %u\n",
            h->hunkbytes, h->unitbytes, h->totalhunks,
            (unsigned long long)h->logicalbytes, sectors_per_hunk, framesize);

    hunk = (unsigned char *)malloc(h->hunkbytes);
    out = fopen(argv[2], "wb");
    if (!hunk || !out) { fprintf(stderr, "alloc/open failed\n"); return 1; }

    for (i = 0; i < h->totalhunks; i++) {
        if (chd_read(chd, i, hunk) != CHDERR_NONE) {
            fprintf(stderr, "chd_read failed at hunk %u\n", i); break;
        }
        if (!iso) { fwrite(hunk, 1, h->hunkbytes, out); written += h->hunkbytes; continue; }
        for (s = 0; s < sectors_per_hunk; s++) {
            unsigned char *sec = hunk + (size_t)s * framesize;
            /* Mode 1: 12 sync + 4 header + 2048 user + 288 EDC/ECC */
            fwrite(sec + 16, 1, 2048, out); written += 2048;
        }
    }
    fclose(out);
    fprintf(stderr, "wrote %llu bytes\n", written);
    chd_close(chd);
    return 0;
}
