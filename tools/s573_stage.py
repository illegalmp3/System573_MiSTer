#!/usr/bin/env python3
"""
s573_stage.py - set up games/System573 for the Konami System 573 MiSTer core from
your own MAME romsets.

    python3 s573_stage.py ROMS OUT             stage every title it can
    python3 s573_stage.py ROMS OUT --only ddr3mj,ddrmax
    python3 s573_stage.py ROMS --list          show what was found; write nothing
    python3 s573_stage.py --blank-saves OUT    only the empty .sav files (no romsets needed)
    python3 s573_stage.py --install-mp3 ROOT   put MiSTer_System573 (the music decoder) on
                                               the card and add its section to MiSTer.ini

ROMS  the folder holding your MAME System 573 romsets: <set>.zip files (non-merged,
      split or merged all work) and the disc images (<disc>.chd, usually in a
      <set> sub-folder, as MAME keeps them). Sub-folders are searched.
OUT   the MiSTer SD card (or USB drive) root, or its games/System573 folder.
      Given a drive root, the files go into OUT/games/System573.

Needs only Python 3.8 or newer -- nothing to install, and nothing from the core's
source tree. Files are found by their CRC32 and checked against MAME's SHA1, so the
zip and file names do not matter; a disc is found by the SHA1 in its CHD header.

What it writes, per title (each launcher in _Arcade names its files):
  573bios.bin            the System 573 BIOS (700a01.22g)
  <set>.u1 / .u6         the security cassette (a ZS01 dump is padded for the core)
  <set>.cas              two-cassette titles: the install cassette rides here
  <set>.chd              the disc, copied as-is
  <set>.cue + <set>.bin  the two MODE1/2048 discs (dsem, dsfdct), rebuilt as raw
                         2352-byte sectors the core can serve
  <set>.sav              the save file (flash + NVRAM), written as real zero bytes.
                         An existing .sav is NEVER replaced: it holds your install.
  885a01.bin             the memory card reader's boot ROM, for the DDR titles whose
                         cabinets have the reader (only needed for memory cards)

Re-running is safe: files already correct are left alone.

The title table below is generated from MAME's ksys573.cpp and the shipped launchers
by tools/gen_s573_titles.py in the core's repository. Do not edit it by hand.
"""
import argparse, binascii, hashlib, json, lzma, operator, os, struct, sys, zipfile, zlib

# ======== BEGIN GENERATED TABLE by tools/gen_s573_titles.py -- do not edit by hand ========
# from ksys573.cpp (md5 3ffdcb04b89f23601e6ee13ecfcb034a) + mgl/
TABLE = json.loads(r"""
{
 "roms": {
  "ddr3ma/ge887aa.u1": {
   "crc": "68e01a7b",
   "name": "ge887aa.u1",
   "set": "ddr3ma",
   "sha1": "a0094ae0f78ef4246957f998b1493973b3bb67ec",
   "size": 132
  },
  "ddr3ma/ge887aa.u6": {
   "crc": "af09e43c",
   "name": "ge887aa.u6",
   "set": "ddr3ma",
   "sha1": "d8372f2d6e0ae07061b496a2242a63e5bc2e54dc",
   "size": 8
  },
  "ddr3ma/gn887aa.u1": {
   "crc": "0c095e3d",
   "name": "gn887aa.u1",
   "set": "ddr3ma",
   "sha1": "0a5b3d4ba917f55b29ad80d989c20675c14b3cad",
   "size": 132
  },
  "ddr3ma/gn887aa.u6": {
   "crc": "ce84419e",
   "name": "gn887aa.u6",
   "set": "ddr3ma",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddr3mj/ge887ja.u1": {
   "crc": "cc8838ee",
   "name": "ge887ja.u1",
   "set": "ddr3mj",
   "sha1": "b4db610103c0c5ba473f725b3b8b7f987ac3eaec",
   "size": 132
  },
  "ddr3mj/ge887ja.u6": {
   "crc": "af09e43c",
   "name": "ge887ja.u6",
   "set": "ddr3mj",
   "sha1": "d8372f2d6e0ae07061b496a2242a63e5bc2e54dc",
   "size": 8
  },
  "ddr3mj/gn887ja.u1": {
   "crc": "987e93b2",
   "name": "gn887ja.u1",
   "set": "ddr3mj",
   "sha1": "9892b479fdc2c54b2e23783c69e270aa60596673",
   "size": 132
  },
  "ddr3mj/gn887ja.u6": {
   "crc": "ce84419e",
   "name": "gn887ja.u6",
   "set": "ddr3mj",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddr3mk/ge887kb.u1": {
   "crc": "68e01a7b",
   "name": "ge887kb.u1",
   "set": "ddr3mk",
   "sha1": "a0094ae0f78ef4246957f998b1493973b3bb67ec",
   "size": 132
  },
  "ddr3mk/ge887kb.u6": {
   "crc": "af09e43c",
   "name": "ge887kb.u6",
   "set": "ddr3mk",
   "sha1": "d8372f2d6e0ae07061b496a2242a63e5bc2e54dc",
   "size": 8
  },
  "ddr3mk/gn887kb.u1": {
   "crc": "0c095e3d",
   "name": "gn887kb.u1",
   "set": "ddr3mk",
   "sha1": "0a5b3d4ba917f55b29ad80d989c20675c14b3cad",
   "size": 132
  },
  "ddr3mk/gn887kb.u6": {
   "crc": "ce84419e",
   "name": "gn887kb.u6",
   "set": "ddr3mk",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddr3mka/ge887ka.u1": {
   "crc": "68e01a7b",
   "name": "ge887ka.u1",
   "set": "ddr3mka",
   "sha1": "a0094ae0f78ef4246957f998b1493973b3bb67ec",
   "size": 132
  },
  "ddr3mka/ge887ka.u6": {
   "crc": "af09e43c",
   "name": "ge887ka.u6",
   "set": "ddr3mka",
   "sha1": "d8372f2d6e0ae07061b496a2242a63e5bc2e54dc",
   "size": 8
  },
  "ddr3mka/gn887ka.u1": {
   "crc": "0c095e3d",
   "name": "gn887ka.u1",
   "set": "ddr3mka",
   "sha1": "0a5b3d4ba917f55b29ad80d989c20675c14b3cad",
   "size": 132
  },
  "ddr3mka/gn887ka.u6": {
   "crc": "ce84419e",
   "name": "gn887ka.u6",
   "set": "ddr3mka",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddr3mp/gca22ja.u1": {
   "crc": "02f8ba64",
   "name": "gca22ja.u1",
   "set": "ddr3mp",
   "sha1": "3d1b660ff7c98de7f6386fc4d3300dc4205b5a3a",
   "size": 140
  },
  "ddr3mp/gca22ja.u6": {
   "crc": "ce84419e",
   "name": "gca22ja.u6",
   "set": "ddr3mp",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddr3mp/gea22ja.u1": {
   "crc": "adfc9021",
   "name": "gea22ja.u1",
   "set": "ddr3mp",
   "sha1": "bb161b9c1bd358cb72e61197a9fafd58c44adb7c",
   "size": 548
  },
  "ddr3mp/gea22ja.u6": {
   "crc": "af09e43c",
   "name": "gea22ja.u6",
   "set": "ddr3mp",
   "sha1": "d8372f2d6e0ae07061b496a2242a63e5bc2e54dc",
   "size": 8
  },
  "ddr4m/gca33aa.u1": {
   "crc": "284effe1",
   "name": "gca33aa.u1",
   "set": "ddr4m",
   "sha1": "bdaeef1b47b643d9ad0ebac82651e60752565fcb",
   "size": 140
  },
  "ddr4m/gca33aa.u6": {
   "crc": "ce84419e",
   "name": "gca33aa.u6",
   "set": "ddr4m",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddr4m/gea33aa.u1": {
   "crc": "a9bf9a0e",
   "name": "gea33aa.u1",
   "set": "ddr4m",
   "sha1": "7210ff9606746bc94bfba28e3522ee79222da32c",
   "size": 548
  },
  "ddr4m/gea33aa.u6": {
   "crc": "af09e43c",
   "name": "gea33aa.u6",
   "set": "ddr4m",
   "sha1": "d8372f2d6e0ae07061b496a2242a63e5bc2e54dc",
   "size": 8
  },
  "ddr4mj/a33jaa.u1": {
   "crc": "adfc9021",
   "name": "a33jaa.u1",
   "set": "ddr4mj",
   "sha1": "bb161b9c1bd358cb72e61197a9fafd58c44adb7c",
   "size": 548
  },
  "ddr4mj/a33jaa.u6": {
   "crc": "af09e43c",
   "name": "a33jaa.u6",
   "set": "ddr4mj",
   "sha1": "d8372f2d6e0ae07061b496a2242a63e5bc2e54dc",
   "size": 8
  },
  "ddr4mj/gca33ja.u1": {
   "crc": "3a291fea",
   "name": "gca33ja.u1",
   "set": "ddr4mj",
   "sha1": "15e777d2137313e925d922e7289dd46c00838211",
   "size": 140
  },
  "ddr4mj/gca33ja.u6": {
   "crc": "ce84419e",
   "name": "gca33ja.u6",
   "set": "ddr4mj",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddr4mp/gca34ja.u1": {
   "crc": "e7f5f795",
   "name": "gca34ja.u1",
   "set": "ddr4mp",
   "sha1": "cf942ed741d9605aaa1d99bfa848cc13f3f87b1b",
   "size": 140
  },
  "ddr4mp/gca34ja.u6": {
   "crc": "ce84419e",
   "name": "gca34ja.u6",
   "set": "ddr4mp",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddr4mp/gea34ja.u1": {
   "crc": "adfc9021",
   "name": "gea34ja.u1",
   "set": "ddr4mp",
   "sha1": "bb161b9c1bd358cb72e61197a9fafd58c44adb7c",
   "size": 548
  },
  "ddr4mp/gea34ja.u6": {
   "crc": "af09e43c",
   "name": "gea34ja.u6",
   "set": "ddr4mp",
   "sha1": "d8372f2d6e0ae07061b496a2242a63e5bc2e54dc",
   "size": 8
  },
  "ddr4mps/gca34jb.u1": {
   "crc": "da6cc484",
   "name": "gca34jb.u1",
   "set": "ddr4mps",
   "sha1": "1fe1aa95bbee1de7fd4930e6883f99768486da2a",
   "size": 140
  },
  "ddr4mps/gca34jb.u6": {
   "crc": "ce84419e",
   "name": "gca34jb.u6",
   "set": "ddr4mps",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddr4mps/gea34jb.u1": {
   "crc": "b458d46a",
   "name": "gea34jb.u1",
   "set": "ddr4mps",
   "sha1": "791b938e0a65131238e66fe86efa5f83d9225332",
   "size": 548
  },
  "ddr4mps/gea34jb.u6": {
   "crc": "af09e43c",
   "name": "gea34jb.u6",
   "set": "ddr4mps",
   "sha1": "d8372f2d6e0ae07061b496a2242a63e5bc2e54dc",
   "size": 8
  },
  "ddr4ms/gca33ab.u1": {
   "crc": "15d7ccf0",
   "name": "gca33ab.u1",
   "set": "ddr4ms",
   "sha1": "2bda973c83cf2b042753492201a51db2e415338e",
   "size": 140
  },
  "ddr4ms/gca33ab.u6": {
   "crc": "ce84419e",
   "name": "gca33ab.u6",
   "set": "ddr4ms",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddr4ms/gea33ab.u1": {
   "crc": "4ca14f40",
   "name": "gea33ab.u1",
   "set": "ddr4ms",
   "sha1": "90cdcaea12f1305c1068496df80ef1069625e398",
   "size": 548
  },
  "ddr4ms/gea33ab.u6": {
   "crc": "af09e43c",
   "name": "gea33ab.u6",
   "set": "ddr4ms",
   "sha1": "d8372f2d6e0ae07061b496a2242a63e5bc2e54dc",
   "size": 8
  },
  "ddr4msj/a33jba.u1": {
   "crc": "b458d46a",
   "name": "a33jba.u1",
   "set": "ddr4msj",
   "sha1": "791b938e0a65131238e66fe86efa5f83d9225332",
   "size": 548
  },
  "ddr4msj/a33jba.u6": {
   "crc": "af09e43c",
   "name": "a33jba.u6",
   "set": "ddr4msj",
   "sha1": "d8372f2d6e0ae07061b496a2242a63e5bc2e54dc",
   "size": 8
  },
  "ddr4msj/gca33jb.u1": {
   "crc": "07b02cfb",
   "name": "gca33jb.u1",
   "set": "ddr4msj",
   "sha1": "291d654d9dec8180f48a9da1cb71f4a4f7e86c26",
   "size": 140
  },
  "ddr4msj/gca33jb.u6": {
   "crc": "ce84419e",
   "name": "gca33jb.u6",
   "set": "ddr4msj",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddr5m/gca27ja.u1": {
   "crc": "0044c64d",
   "name": "gca27ja.u1",
   "set": "ddr5m",
   "sha1": "ac25b51125675ccca992d60b12396b3b370c6368",
   "size": 140
  },
  "ddr5m/gca27ja.u6": {
   "crc": "ce84419e",
   "name": "gca27ja.u6",
   "set": "ddr5m",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddrextrm/gcc36ja.u1": {
   "crc": "197845c2",
   "name": "gcc36ja.u1",
   "set": "ddrextrm",
   "sha1": "c6c1c192f69331232a93ec6c690257e57a244e25",
   "size": 140
  },
  "ddrextrm/gcc36ja.u6": {
   "crc": "ce84419e",
   "name": "gcc36ja.u6",
   "set": "ddrextrm",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddrmax/gcb19ja.u1": {
   "crc": "680a3288",
   "name": "gcb19ja.u1",
   "set": "ddrmax",
   "sha1": "b413c6c43c4a18c5c713049a9c2fbde2d98e36bc",
   "size": 140
  },
  "ddrmax/gcb19ja.u6": {
   "crc": "ce84419e",
   "name": "gcb19ja.u6",
   "set": "ddrmax",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddrmax2/gcb20ja.u1": {
   "crc": "169be875",
   "name": "gcb20ja.u1",
   "set": "ddrmax2",
   "sha1": "de40794ebf9190fe3676326d21150fd6aa72dc25",
   "size": 140
  },
  "ddrmax2/gcb20ja.u6": {
   "crc": "ce84419e",
   "name": "gcb20ja.u6",
   "set": "ddrmax2",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddrs2k/gc905aa.u1": {
   "crc": "961a9dbe",
   "name": "gc905aa.u1",
   "set": "ddrs2k",
   "sha1": "c112af1da26eee8da237655ed28d9bae2bc5728a",
   "size": 132
  },
  "ddrs2k/gc905aa.u6": {
   "crc": "ce84419e",
   "name": "gc905aa.u6",
   "set": "ddrs2k",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddrs2k/ge905aa.u1": {
   "crc": "b7a75390",
   "name": "ge905aa.u1",
   "set": "ddrs2k",
   "sha1": "8ad65f4d9fa949296b5b21e7a12be0bde8ffec38",
   "size": 132
  },
  "ddrs2k/ge905aa.u6": {
   "crc": "af09e43c",
   "name": "ge905aa.u6",
   "set": "ddrs2k",
   "sha1": "d8372f2d6e0ae07061b496a2242a63e5bc2e54dc",
   "size": 8
  },
  "ddrsbm/gq894ja.u1": {
   "crc": "10b85f6b",
   "name": "gq894ja.u1",
   "set": "ddrsbm",
   "sha1": "c15ec333c8bb0c33edb8d31bf4f309aa0db9ff55",
   "size": 132
  },
  "ddrsbm/gq894ja.u6": {
   "crc": "ce84419e",
   "name": "gq894ja.u6",
   "set": "ddrsbm",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "ddrusa/gka44ua.u1": {
   "crc": "ca12febe",
   "name": "gka44ua.u1",
   "set": "ddrusa",
   "sha1": "3bd01332e5b20420ec195ab125671cb212a8f5f2",
   "size": 140
  },
  "ddrusa/gka44ua.u6": {
   "crc": "ce84419e",
   "name": "gka44ua.u6",
   "set": "ddrusa",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "drmn2m/ge912ja.u1": {
   "crc": "508d618d",
   "name": "ge912ja.u1",
   "set": "drmn2m",
   "sha1": "d30ba54ccc86072c10962632603028206ff08d4b",
   "size": 548
  },
  "drmn2m/ge912ja.u6": {
   "crc": "af09e43c",
   "name": "ge912ja.u6",
   "set": "drmn2m",
   "sha1": "d8372f2d6e0ae07061b496a2242a63e5bc2e54dc",
   "size": 8
  },
  "drmn2m/gn912ja.u1": {
   "crc": "952f4681",
   "name": "gn912ja.u1",
   "set": "drmn2m",
   "sha1": "667fc5ef07517801496444a91b6f1d88c8d0b9d2",
   "size": 140
  },
  "drmn2m/gn912ja.u6": {
   "crc": "ce84419e",
   "name": "gn912ja.u6",
   "set": "drmn2m",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "drmn3m/a23jaa.u1": {
   "crc": "508d618d",
   "name": "a23jaa.u1",
   "set": "drmn3m",
   "sha1": "d30ba54ccc86072c10962632603028206ff08d4b",
   "size": 548
  },
  "drmn3m/a23jaa.u6": {
   "crc": "af09e43c",
   "name": "a23jaa.u6",
   "set": "drmn3m",
   "sha1": "d8372f2d6e0ae07061b496a2242a63e5bc2e54dc",
   "size": 8
  },
  "drmn3m/gca23ja.u1": {
   "crc": "e78225db",
   "name": "gca23ja.u1",
   "set": "drmn3m",
   "sha1": "0870cfb01cd3f940812b842b315bc6329e956d88",
   "size": 140
  },
  "drmn3m/gca23ja.u6": {
   "crc": "ce84419e",
   "name": "gca23ja.u6",
   "set": "drmn3m",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "drmn4m/gea25jaa.27m": {
   "crc": "118fa45a",
   "name": "gea25jaa.27m",
   "set": "drmn4m",
   "sha1": "6bc6129e328f6f97a27b9f524066297b29efff5a",
   "size": 2097152
  },
  "drmn4m/gea25jaa.31m": {
   "crc": "a0dd0ef4",
   "name": "gea25jaa.31m",
   "set": "drmn4m",
   "sha1": "be4c1d3f2eb3c484b515be12b692c30cc780c36c",
   "size": 2097152
  },
  "drmn4m/gea25jaa.u1": {
   "crc": "8ee64348",
   "name": "gea25jaa.u1",
   "set": "drmn4m",
   "sha1": "9c02096c94da68d096efc225f19e420cb9445820",
   "size": 140
  },
  "drmn4m/gea25jaa.u6": {
   "crc": "ce84419e",
   "name": "gea25jaa.u6",
   "set": "drmn4m",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "drmn5m/gcb05jaa.u1": {
   "crc": "1f0e9f51",
   "name": "gcb05jaa.u1",
   "set": "drmn5m",
   "sha1": "64f9ae6c2d9a6264b09c1b66ae2acac9db9ada32",
   "size": 140
  },
  "drmn5m/gcb05jaa.u6": {
   "crc": "ce84419e",
   "name": "gcb05jaa.u6",
   "set": "drmn5m",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "drmn6m/gcb16jaa.27m": {
   "crc": "5696e133",
   "name": "gcb16jaa.27m",
   "set": "drmn6m",
   "sha1": "aad39cc25ce5279adac8a10fb10158f4f4418c0a",
   "size": 2097152
  },
  "drmn6m/gcb16jaa.31m": {
   "crc": "19de3e53",
   "name": "gcb16jaa.31m",
   "set": "drmn6m",
   "sha1": "bbb7a247bdd617a124330a946c2e8dd565b2a09c",
   "size": 2097152
  },
  "drmn6m/gcb16jaa.u1": {
   "crc": "a8ab305d",
   "name": "gcb16jaa.u1",
   "set": "drmn6m",
   "sha1": "7815ec63fa419174d689f237bcb3ec2372fb6baa",
   "size": 140
  },
  "drmn6m/gcb16jaa.u6": {
   "crc": "ce84419e",
   "name": "gcb16jaa.u6",
   "set": "drmn6m",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "drmn7m/gcc07jba.27m": {
   "crc": "9393fe8e",
   "name": "gcc07jba.27m",
   "set": "drmn7m",
   "sha1": "f60752e3e397121f3d4856a634e1c8ce5fc465b5",
   "size": 2097152
  },
  "drmn7m/gcc07jba.31m": {
   "crc": "7120d1ce",
   "name": "gcc07jba.31m",
   "set": "drmn7m",
   "sha1": "4df9828150120762b99c5b212bc7a91b0d525bce",
   "size": 2097152
  },
  "drmn7m/gcc07jba.u1": {
   "crc": "9b85fd8a",
   "name": "gcc07jba.u1",
   "set": "drmn7m",
   "sha1": "34fc42389fc5eb5d09a0a7b6b4c4b4597b1f6849",
   "size": 140
  },
  "drmn7m/gcc07jba.u6": {
   "crc": "ce84419e",
   "name": "gcc07jba.u6",
   "set": "drmn7m",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "drmn8m/gcc38jaa.u1": {
   "crc": "c2895619",
   "name": "gcc38jaa.u1",
   "set": "drmn8m",
   "sha1": "49dcebd44435760dde02638b0e0a89b743064e69",
   "size": 140
  },
  "drmn8m/gcc38jaa.u6": {
   "crc": "ce84419e",
   "name": "gcc38jaa.u6",
   "set": "drmn8m",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "drmn9ma/gcd09jaa.u1": {
   "crc": "f73f2f6b",
   "name": "gcd09jaa.u1",
   "set": "drmn9ma",
   "sha1": "30abe964fcef3901b2098e32946568f4a7c617d7",
   "size": 140
  },
  "drmn9ma/gcd09jaa.u6": {
   "crc": "ce84419e",
   "name": "gcd09jaa.u6",
   "set": "drmn9ma",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "dsem/ge936ea.u1": {
   "crc": "c7e3a7f9",
   "name": "ge936ea.u1",
   "set": "dsem",
   "sha1": "7120c0ef3c3dac23713922f9447d5eac1b91c54d",
   "size": 548
  },
  "dsem/ge936ea.u6": {
   "crc": "ce84419e",
   "name": "ge936ea.u6",
   "set": "dsem",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "dsem2/gkc23ea.u1": {
   "crc": "107e9868",
   "name": "gkc23ea.u1",
   "set": "dsem2",
   "sha1": "02a0f92fc3167d37818818332bf189f39e3c25fc",
   "size": 140
  },
  "dsem2/gkc23ea.u6": {
   "crc": "ce84419e",
   "name": "gkc23ea.u6",
   "set": "dsem2",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "dsfdct/gc910jc.u1": {
   "crc": "e09eb1c6",
   "name": "gc910jc.u1",
   "set": "dsfdct",
   "sha1": "046d5552c774ea2b9141fff45c13a926c18f705c",
   "size": 132
  },
  "dsfdct/gc910jc.u6": {
   "crc": "ce84419e",
   "name": "gc910jc.u6",
   "set": "dsfdct",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "dsfdct/ge887ja_gn887ja.u1": {
   "crc": "bfbba6c7",
   "name": "ge887ja_gn887ja.u1",
   "set": "dsfdct",
   "sha1": "eb082fe7bb1bbc3656391a0617075010281b8726",
   "size": 132
  },
  "dsfdct/ge887ja_gn887ja.u6": {
   "crc": "ce84419e",
   "name": "ge887ja_gn887ja.u6",
   "set": "dsfdct",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "dsfdr/gca37ja.u1": {
   "crc": "d7df793c",
   "name": "gca37ja.u1",
   "set": "dsfdr",
   "sha1": "3b85ef84edda34dce13fcafb7f6c77f4154eee5d",
   "size": 140
  },
  "dsfdr/gca37ja.u6": {
   "crc": "ce84419e",
   "name": "gca37ja.u6",
   "set": "dsfdr",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "dsfdr/gea37ja.u1": {
   "crc": "adfc9021",
   "name": "gea37ja.u1",
   "set": "dsfdr",
   "sha1": "bb161b9c1bd358cb72e61197a9fafd58c44adb7c",
   "size": 548
  },
  "dsfdr/gea37ja.u6": {
   "crc": "af09e43c",
   "name": "gea37ja.u6",
   "set": "dsfdr",
   "sha1": "d8372f2d6e0ae07061b496a2242a63e5bc2e54dc",
   "size": 8
  },
  "gtrfrk5m/gea26jaa.27m": {
   "crc": "345dc5f2",
   "name": "gea26jaa.27m",
   "set": "gtrfrk5m",
   "sha1": "61af3fcfe6119c1e8e18b92693855ab4fe708b30",
   "size": 2097152
  },
  "gtrfrk5m/gea26jaa.31m": {
   "crc": "1a25e660",
   "name": "gea26jaa.31m",
   "set": "gtrfrk5m",
   "sha1": "dbd8fad0bac307723c70d00763cadf4261a7ed73",
   "size": 2097152
  },
  "gtrfrk5m/gea26jaa.u1": {
   "crc": "5e16a3f1",
   "name": "gea26jaa.u1",
   "set": "gtrfrk5m",
   "sha1": "629dce132588035cea20d1fe92e0f17f90d0ef60",
   "size": 140
  },
  "gtrfrk5m/gea26jaa.u6": {
   "crc": "ce84419e",
   "name": "gea26jaa.u6",
   "set": "gtrfrk5m",
   "sha1": "839e8ee080ecfc79021a06417d930e8b32dfc6a1",
   "size": 8
  },
  "hypbbc2p/gx908ja.u1": {
   "crc": "8900eaff",
   "name": "gx908ja.u1",
   "set": "hypbbc2p",
   "sha1": "aea4449c2453875694dfa92451d46dace710faf2",
   "size": 132
  },
  "hyperbbc/876ea.22h": {
   "crc": "8e11d196",
   "name": "876ea.22h",
   "set": "hyperbbc",
   "sha1": "e7442fdd611f4290d531b1ebdc9f487e323fd531",
   "size": 8192
  },
  "hyperbbc/876ea.27h": {
   "crc": "49175f99",
   "name": "876ea.27h",
   "set": "hyperbbc",
   "sha1": "0154f6332ed210b6f0af20ba622133cde0994b7f",
   "size": 2097152
  },
  "hyperbbc/876ea.27j": {
   "crc": "9c156b1b",
   "name": "876ea.27j",
   "set": "hyperbbc",
   "sha1": "bf07d71cc1f7e9e14beb9f9dfb71667ef2b54f8d",
   "size": 2097152
  },
  "hyperbbc/876ea.27l": {
   "crc": "950a5267",
   "name": "876ea.27l",
   "set": "hyperbbc",
   "sha1": "373a7305a090d1e347bfeb62cc2db55cde2a106e",
   "size": 2097152
  },
  "hyperbbc/876ea.27m": {
   "crc": "689ddd94",
   "name": "876ea.27m",
   "set": "hyperbbc",
   "sha1": "512ca1529695f4f79ca8c1b8f64bb0067137e430",
   "size": 2097152
  },
  "hyperbbc/876ea.31h": {
   "crc": "368372fb",
   "name": "876ea.31h",
   "set": "hyperbbc",
   "sha1": "5cc4cb72e182c9e4d0737352e029fd703ba2f516",
   "size": 2097152
  },
  "hyperbbc/876ea.31j": {
   "crc": "ae497ebc",
   "name": "876ea.31j",
   "set": "hyperbbc",
   "sha1": "ef131e60726db94f0d9ceab70bce02c0de080ede",
   "size": 2097152
  },
  "hyperbbc/876ea.31l": {
   "crc": "d011c7a5",
   "name": "876ea.31l",
   "set": "hyperbbc",
   "sha1": "8861b62c8b654b8e719600a37337ae44e6438899",
   "size": 2097152
  },
  "hyperbbc/876ea.31m": {
   "crc": "a76043cb",
   "name": "876ea.31m",
   "set": "hyperbbc",
   "sha1": "1c37034298abf3219d0bba29f4fcea8d83782926",
   "size": 2097152
  },
  "konam80s/gc826ea.u1": {
   "crc": "7c12ec3f",
   "name": "gc826ea.u1",
   "set": "konam80s",
   "sha1": "7989ed47fe551116a821c7d4bc4de6bbb22eff29",
   "size": 548
  },
  "sys573/700a01,gchgchmp.22g": {
   "crc": "39ebb0ca",
   "name": "700a01,gchgchmp.22g",
   "set": "sys573",
   "sha1": "9aab8c637dd2be84d79007e52f108abe92bf29dd",
   "size": 524288
  },
  "sys573/700a01.22g": {
   "crc": "11812ef8",
   "name": "700a01.22g",
   "set": "sys573",
   "sha1": "e1284add4aaddd5337bd7f4e27614460d52b5b48",
   "size": 524288
  }
 },
 "titles": [
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddr3ma.cas": {
     "game_u6": "ddr3ma/gn887aa.u6",
     "install_chip": "X76F100",
     "install_u1": "ddr3ma/ge887aa.u1",
     "install_u6": "ddr3ma/ge887aa.u6",
     "make": "cas",
     "trailer": "5335373343000120"
    },
    "ddr3ma.chd": {
     "disc": "887aaa02",
     "make": "chd",
     "sha1": "6f9a0e9dd046a1fc0c81be9eeb45c136574a4472"
    },
    "ddr3ma.sav": {
     "make": "sav",
     "older": [
      50331648
     ],
     "size": 50340864
    },
    "ddr3ma.u1": {
     "chip": "X76F100",
     "make": "rom",
     "rom": "ddr3ma/gn887aa.u1"
    }
   },
   "launchers": [
    "Dance Dance Revolution 3rd Mix (Asia, 1999).mgl"
   ],
   "set": "ddr3ma",
   "title": "Dance Dance Revolution 3rd Mix (GN887 VER. AAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddr3mj.cas": {
     "game_u6": "ddr3mj/gn887ja.u6",
     "install_chip": "X76F100",
     "install_u1": "ddr3mj/ge887ja.u1",
     "install_u6": "ddr3mj/ge887ja.u6",
     "make": "cas",
     "trailer": "5335373343000120"
    },
    "ddr3mj.chd": {
     "disc": "887jaa02",
     "make": "chd",
     "sha1": "8736818f42822f77e3484ea46a9e63faa7f8517a"
    },
    "ddr3mj.sav": {
     "make": "sav",
     "older": [
      50331648
     ],
     "size": 50340864
    },
    "ddr3mj.u1": {
     "chip": "X76F100",
     "make": "rom",
     "rom": "ddr3mj/gn887ja.u1"
    }
   },
   "launchers": [
    "Dance Dance Revolution 3rd Mix (Japan, 1999).mgl"
   ],
   "set": "ddr3mj",
   "title": "Dance Dance Revolution 3rd Mix (GN887 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddr3mk.cas": {
     "game_u6": "ddr3mk/gn887kb.u6",
     "install_chip": "X76F100",
     "install_u1": "ddr3mk/ge887kb.u1",
     "install_u6": "ddr3mk/ge887kb.u6",
     "make": "cas",
     "trailer": "5335373343000120"
    },
    "ddr3mk.chd": {
     "disc": "887kba02",
     "make": "chd",
     "sha1": "9f2c6a4e7ad0de44295dc09b9b054afb044238a9"
    },
    "ddr3mk.sav": {
     "make": "sav",
     "older": [
      50331648
     ],
     "size": 50340864
    },
    "ddr3mk.u1": {
     "chip": "X76F100",
     "make": "rom",
     "rom": "ddr3mk/gn887kb.u1"
    }
   },
   "launchers": [
    "Dance Dance Revolution 3rd Mix - Ver.Korea2 (Korea, 2000).mgl"
   ],
   "set": "ddr3mk",
   "title": "Dance Dance Revolution 3rd Mix - Ver.Korea2 (GN887 VER. KBA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddr3mka.cas": {
     "game_u6": "ddr3mka/gn887ka.u6",
     "install_chip": "X76F100",
     "install_u1": "ddr3mka/ge887ka.u1",
     "install_u6": "ddr3mka/ge887ka.u6",
     "make": "cas",
     "trailer": "5335373343000120"
    },
    "ddr3mka.chd": {
     "disc": "887kaa02",
     "make": "chd",
     "sha1": "d002f2c98c012d67ad0587553e1d0f45c0ae470e"
    },
    "ddr3mka.sav": {
     "make": "sav",
     "older": [
      50331648
     ],
     "size": 50340864
    },
    "ddr3mka.u1": {
     "chip": "X76F100",
     "make": "rom",
     "rom": "ddr3mka/gn887ka.u1"
    }
   },
   "launchers": [
    "Dance Dance Revolution 3rd Mix - Ver.Korea (Korea, 2000).mgl"
   ],
   "set": "ddr3mka",
   "title": "Dance Dance Revolution 3rd Mix - Ver.Korea (GN887 VER. KAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddr3mp.cas": {
     "game_u6": "ddr3mp/gca22ja.u6",
     "install_chip": "X76F041",
     "install_u1": "ddr3mp/gea22ja.u1",
     "install_u6": "ddr3mp/gea22ja.u6",
     "make": "cas",
     "trailer": "5335373343000120"
    },
    "ddr3mp.chd": {
     "disc": "a22jaa02",
     "make": "chd",
     "sha1": "dc3c1223882716d47b4f4db45b5dd2e988cba64c"
    },
    "ddr3mp.sav": {
     "make": "sav",
     "older": [
      50331648,
      50332672
     ],
     "size": 50341888
    },
    "ddr3mp.u1": {
     "ds2401": "ddr3mp/gca22ja.u6",
     "make": "zs01",
     "rom": "ddr3mp/gca22ja.u1"
    }
   },
   "launchers": [
    "Dance Dance Revolution 3rd Mix Plus (Japan, 2000).mgl"
   ],
   "set": "ddr3mp",
   "title": "Dance Dance Revolution 3rd Mix Plus (G*A22 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddr4m.cas": {
     "game_u6": "ddr4m/gca33aa.u6",
     "install_chip": "X76F041",
     "install_u1": "ddr4m/gea33aa.u1",
     "install_u6": "ddr4m/gea33aa.u6",
     "make": "cas",
     "trailer": "5335373343000120"
    },
    "ddr4m.chd": {
     "disc": "a33aaa02",
     "make": "chd",
     "sha1": "cc7349cbee37bfb101480497e99f1f52acb4ffa1"
    },
    "ddr4m.sav": {
     "make": "sav",
     "older": [
      50331648,
      50332672
     ],
     "size": 50341888
    },
    "ddr4m.u1": {
     "ds2401": "ddr4m/gca33aa.u6",
     "make": "zs01",
     "rom": "ddr4m/gca33aa.u1"
    }
   },
   "launchers": [
    "Dance Dance Revolution 4th Mix (Asia, 2000).mgl"
   ],
   "set": "ddr4m",
   "title": "Dance Dance Revolution 4th Mix (G*A33 VER. AAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddr4mj.cas": {
     "game_u6": "ddr4mj/gca33ja.u6",
     "install_chip": "X76F041",
     "install_u1": "ddr4mj/a33jaa.u1",
     "install_u6": "ddr4mj/a33jaa.u6",
     "make": "cas",
     "trailer": "5335373343000120"
    },
    "ddr4mj.chd": {
     "disc": "a33jaa02",
     "make": "chd",
     "sha1": "9d9fb5e65f1532f358e9c273c56d11389d11fd79"
    },
    "ddr4mj.sav": {
     "make": "sav",
     "older": [
      50331648,
      50332672
     ],
     "size": 50341888
    },
    "ddr4mj.u1": {
     "ds2401": "ddr4mj/gca33ja.u6",
     "make": "zs01",
     "rom": "ddr4mj/gca33ja.u1"
    }
   },
   "launchers": [
    "Dance Dance Revolution 4th Mix (Japan, 2000).mgl"
   ],
   "set": "ddr4mj",
   "title": "Dance Dance Revolution 4th Mix (G*A33 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddr4mp.cas": {
     "game_u6": "ddr4mp/gca34ja.u6",
     "install_chip": "X76F041",
     "install_u1": "ddr4mp/gea34ja.u1",
     "install_u6": "ddr4mp/gea34ja.u6",
     "make": "cas",
     "trailer": "5335373343000120"
    },
    "ddr4mp.chd": {
     "disc": "a34jaa02",
     "make": "chd",
     "sha1": "c33e43192ce49845f8901c505f1c7867bc643a0b"
    },
    "ddr4mp.sav": {
     "make": "sav",
     "older": [
      50331648,
      50332672
     ],
     "size": 50341888
    },
    "ddr4mp.u1": {
     "ds2401": "ddr4mp/gca34ja.u6",
     "make": "zs01",
     "rom": "ddr4mp/gca34ja.u1"
    }
   },
   "launchers": [
    "Dance Dance Revolution 4th Mix Plus (Japan, 2000).mgl"
   ],
   "set": "ddr4mp",
   "title": "Dance Dance Revolution 4th Mix Plus (G*A34 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddr4mps.cas": {
     "game_u6": "ddr4mps/gca34jb.u6",
     "install_chip": "X76F041",
     "install_u1": "ddr4mps/gea34jb.u1",
     "install_u6": "ddr4mps/gea34jb.u6",
     "make": "cas",
     "trailer": "5335373343010121"
    },
    "ddr4mps.chd": {
     "disc": "a34jba02",
     "make": "chd",
     "sha1": "c33e43192ce49845f8901c505f1c7867bc643a0b"
    },
    "ddr4mps.sav": {
     "make": "sav",
     "older": [
      50331648,
      50332672
     ],
     "size": 50341888
    },
    "ddr4mps.u1": {
     "ds2401": "ddr4mps/gca34jb.u6",
     "make": "zs01",
     "rom": "ddr4mps/gca34jb.u1"
    }
   },
   "launchers": [
    "Dance Dance Revolution 4th Mix Plus Solo (Japan, 2000).mgl"
   ],
   "set": "ddr4mps",
   "title": "Dance Dance Revolution 4th Mix Plus Solo (G*A34 VER. JBA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddr4ms.cas": {
     "game_u6": "ddr4ms/gca33ab.u6",
     "install_chip": "X76F041",
     "install_u1": "ddr4ms/gea33ab.u1",
     "install_u6": "ddr4ms/gea33ab.u6",
     "make": "cas",
     "trailer": "5335373343010121"
    },
    "ddr4ms.chd": {
     "disc": "a33aba02",
     "make": "chd",
     "sha1": "cc7349cbee37bfb101480497e99f1f52acb4ffa1"
    },
    "ddr4ms.sav": {
     "make": "sav",
     "older": [
      50331648,
      50332672
     ],
     "size": 50341888
    },
    "ddr4ms.u1": {
     "ds2401": "ddr4ms/gca33ab.u6",
     "make": "zs01",
     "rom": "ddr4ms/gca33ab.u1"
    }
   },
   "launchers": [
    "Dance Dance Revolution 4th Mix Solo (Asia, 2000).mgl"
   ],
   "set": "ddr4ms",
   "title": "Dance Dance Revolution 4th Mix Solo (G*A33 VER. ABA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddr4msj.cas": {
     "game_u6": "ddr4msj/gca33jb.u6",
     "install_chip": "X76F041",
     "install_u1": "ddr4msj/a33jba.u1",
     "install_u6": "ddr4msj/a33jba.u6",
     "make": "cas",
     "trailer": "5335373343010121"
    },
    "ddr4msj.chd": {
     "disc": "a33jba02",
     "make": "chd",
     "sha1": "9d9fb5e65f1532f358e9c273c56d11389d11fd79"
    },
    "ddr4msj.sav": {
     "make": "sav",
     "older": [
      50331648,
      50332672
     ],
     "size": 50341888
    },
    "ddr4msj.u1": {
     "ds2401": "ddr4msj/gca33jb.u6",
     "make": "zs01",
     "rom": "ddr4msj/gca33jb.u1"
    }
   },
   "launchers": [
    "Dance Dance Revolution 4th Mix Solo (Japan, 2000).mgl"
   ],
   "set": "ddr4msj",
   "title": "Dance Dance Revolution 4th Mix Solo (G*A33 VER. JBA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddr5m.chd": {
     "disc": "a27jaa02",
     "make": "chd",
     "sha1": "70465669dfd48abf806cb58b2410ff4f1781f5f1"
    },
    "ddr5m.sav": {
     "make": "sav",
     "older": [
      50331648,
      50332672
     ],
     "size": 50341888
    },
    "ddr5m.u1": {
     "ds2401": "ddr5m/gca27ja.u6",
     "make": "zs01",
     "rom": "ddr5m/gca27ja.u1"
    },
    "ddr5m.u6": {
     "make": "rom",
     "rom": "ddr5m/gca27ja.u6",
     "trailer": "5335373343000120"
    }
   },
   "launchers": [
    "Dance Dance Revolution 5th Mix (Japan, 2001).mgl"
   ],
   "set": "ddr5m",
   "title": "Dance Dance Revolution 5th Mix (G*A27 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddrextrm.chd": {
     "disc": "c36jaa02",
     "make": "chd",
     "sha1": "edeb45fff0e66151b1ba2fd67542064ccddb031e"
    },
    "ddrextrm.sav": {
     "make": "sav",
     "older": [
      50331648,
      50332672
     ],
     "size": 50341888
    },
    "ddrextrm.u1": {
     "ds2401": "ddrextrm/gcc36ja.u6",
     "make": "zs01",
     "rom": "ddrextrm/gcc36ja.u1"
    },
    "ddrextrm.u6": {
     "make": "rom",
     "rom": "ddrextrm/gcc36ja.u6",
     "trailer": "5335373343000120"
    }
   },
   "launchers": [
    "Dance Dance Revolution Extreme (Japan, 2002).mgl"
   ],
   "set": "ddrextrm",
   "title": "Dance Dance Revolution Extreme (G*C36 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddrmax.chd": {
     "disc": "b19jaa02",
     "make": "chd",
     "sha1": "fe8a6731a2163fe7864cd3c4457034768eb98caa"
    },
    "ddrmax.sav": {
     "make": "sav",
     "older": [
      50331648,
      50332672
     ],
     "size": 50341888
    },
    "ddrmax.u1": {
     "ds2401": "ddrmax/gcb19ja.u6",
     "make": "zs01",
     "rom": "ddrmax/gcb19ja.u1"
    },
    "ddrmax.u6": {
     "make": "rom",
     "rom": "ddrmax/gcb19ja.u6",
     "trailer": "5335373343000120"
    }
   },
   "launchers": [
    "DDRMAX - Dance Dance Revolution 6th Mix (Japan, 2001).mgl"
   ],
   "set": "ddrmax",
   "title": "DDRMAX - Dance Dance Revolution 6th Mix (G*B19 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddrmax2.chd": {
     "disc": "b20jaa02",
     "make": "chd",
     "sha1": "ef6579192b86cfea08debe82f54fc4aae5985c92"
    },
    "ddrmax2.sav": {
     "make": "sav",
     "older": [
      50331648,
      50332672
     ],
     "size": 50341888
    },
    "ddrmax2.u1": {
     "ds2401": "ddrmax2/gcb20ja.u6",
     "make": "zs01",
     "rom": "ddrmax2/gcb20ja.u1"
    },
    "ddrmax2.u6": {
     "make": "rom",
     "rom": "ddrmax2/gcb20ja.u6",
     "trailer": "5335373343000120"
    }
   },
   "launchers": [
    "DDRMAX2 - Dance Dance Revolution 7th Mix (Japan, 2002).mgl"
   ],
   "set": "ddrmax2",
   "title": "DDRMAX2 - Dance Dance Revolution 7th Mix (G*B20 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddrs2k.cas": {
     "game_u6": "ddrs2k/gc905aa.u6",
     "install_chip": "X76F100",
     "install_u1": "ddrs2k/ge905aa.u1",
     "install_u6": "ddrs2k/ge905aa.u6",
     "make": "cas",
     "trailer": "5335373343010020"
    },
    "ddrs2k.chd": {
     "disc": "905aaa02",
     "make": "chd",
     "sha1": "1fc0f3fcc7d5d23711967023ff02c1fc76479024"
    },
    "ddrs2k.sav": {
     "make": "sav",
     "older": [
      16777216
     ],
     "size": 16786432
    },
    "ddrs2k.u1": {
     "chip": "X76F100",
     "make": "rom",
     "rom": "ddrs2k/gc905aa.u1"
    }
   },
   "launchers": [
    "Dance Dance Revolution Solo 2000 (Asia, 1999).mgl"
   ],
   "set": "ddrs2k",
   "title": "Dance Dance Revolution Solo 2000 (GC905 VER. AAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddrsbm.chd": {
     "disc": "894jaa02",
     "make": "chd",
     "sha1": "d6872078a87ee00280a627675540676fb8b10f60"
    },
    "ddrsbm.sav": {
     "make": "sav",
     "older": [
      16777216
     ],
     "size": 16786432
    },
    "ddrsbm.u1": {
     "chip": "X76F100",
     "make": "rom",
     "rom": "ddrsbm/gq894ja.u1"
    },
    "ddrsbm.u6": {
     "make": "rom",
     "rom": "ddrsbm/gq894ja.u6",
     "trailer": "5335373343010020"
    }
   },
   "launchers": [
    "Dance Dance Revolution Solo Bass Mix (Japan, 1999).mgl"
   ],
   "set": "ddrsbm",
   "title": "Dance Dance Revolution Solo Bass Mix (GQ894 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "ddrusa.chd": {
     "disc": "a44uaa02",
     "make": "chd",
     "sha1": "2cdbe1c62d16a2be65adb7e11331fce5c8e45504"
    },
    "ddrusa.sav": {
     "make": "sav",
     "older": [
      16777216,
      16778240
     ],
     "size": 16787456
    },
    "ddrusa.u1": {
     "ds2401": "ddrusa/gka44ua.u6",
     "make": "zs01",
     "rom": "ddrusa/gka44ua.u1"
    },
    "ddrusa.u6": {
     "make": "rom",
     "rom": "ddrusa/gka44ua.u6",
     "trailer": "5335373343000021"
    }
   },
   "launchers": [
    "Dance Dance Revolution USA (USA, 2000).mgl"
   ],
   "set": "ddrusa",
   "title": "Dance Dance Revolution USA (G*A44 VER. UAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "drmn2m.cas": {
     "game_u6": "drmn2m/gn912ja.u6",
     "install_chip": "X76F041",
     "install_u1": "drmn2m/ge912ja.u1",
     "install_u6": "drmn2m/ge912ja.u6",
     "make": "cas",
     "trailer": "5335373343020023"
    },
    "drmn2m.chd": {
     "disc": "912jab02",
     "make": "chd",
     "sha1": "19dfae94b63468d3e16d3cc4a3eeae60d5dff1d7"
    },
    "drmn2m.sav": {
     "make": "sav",
     "older": [
      16777216,
      16778240
     ],
     "size": 16787456
    },
    "drmn2m.u1": {
     "ds2401": "drmn2m/gn912ja.u6",
     "make": "zs01",
     "rom": "drmn2m/gn912ja.u1"
    }
   },
   "launchers": [
    "DrumMania 2nd Mix (Japan, 1999).mgl"
   ],
   "set": "drmn2m",
   "title": "DrumMania 2nd Mix (GE912 VER. JAB)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "drmn3m.cas": {
     "game_u6": "drmn3m/gca23ja.u6",
     "install_chip": "X76F041",
     "install_u1": "drmn3m/a23jaa.u1",
     "install_u6": "drmn3m/a23jaa.u6",
     "make": "cas",
     "trailer": "5335373343020023"
    },
    "drmn3m.chd": {
     "disc": "a23jaa02",
     "make": "chd",
     "sha1": "89e365f61a4db889621d7d9d9917bcfa2c09704e"
    },
    "drmn3m.sav": {
     "make": "sav",
     "older": [
      16777216,
      16778240
     ],
     "size": 16787456
    },
    "drmn3m.u1": {
     "ds2401": "drmn3m/gca23ja.u6",
     "make": "zs01",
     "rom": "drmn3m/gca23ja.u1"
    }
   },
   "launchers": [
    "DrumMania 3rd Mix (Japan, 2000).mgl"
   ],
   "set": "drmn3m",
   "title": "DrumMania 3rd Mix (G*A23 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "drmn4m.chd": {
     "disc": "a25jaa02",
     "make": "chd",
     "sha1": "8a0b761d1c282d927e2daf92519654a1c91ee1ab"
    },
    "drmn4m.sav": {
     "make": "sav",
     "older": [
      16777216,
      16778240
     ],
     "seed": {
      "fill": 255,
      "parts": [
       {
        "base": 0,
        "lane": 0,
        "rom": "drmn4m/gea25jaa.31m"
       },
       {
        "base": 0,
        "lane": 1,
        "rom": "drmn4m/gea25jaa.27m"
       }
      ],
      "size": 16777216
     },
     "size": 16787456
    },
    "drmn4m.u1": {
     "ds2401": "drmn4m/gea25jaa.u6",
     "make": "zs01",
     "rom": "drmn4m/gea25jaa.u1"
    },
    "drmn4m.u6": {
     "make": "rom",
     "rom": "drmn4m/gea25jaa.u6",
     "trailer": "5335373343020023"
    }
   },
   "launchers": [
    "DrumMania 4th Mix (Japan, 2001).mgl"
   ],
   "set": "drmn4m",
   "title": "DrumMania 4th Mix (G*A25 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "drmn5m.chd": {
     "disc": "b05jaa02",
     "make": "chd",
     "sha1": "7a6e7940d1441cff1d9be1bc3affc029fe6dc9e4"
    },
    "drmn5m.sav": {
     "make": "sav",
     "older": [
      16777216,
      16778240
     ],
     "size": 16787456
    },
    "drmn5m.u1": {
     "ds2401": "drmn5m/gcb05jaa.u6",
     "make": "zs01",
     "rom": "drmn5m/gcb05jaa.u1"
    },
    "drmn5m.u6": {
     "make": "rom",
     "rom": "drmn5m/gcb05jaa.u6",
     "trailer": "5335373343020023"
    }
   },
   "launchers": [
    "DrumMania 5th Mix (Japan, 2001).mgl"
   ],
   "set": "drmn5m",
   "title": "DrumMania 5th Mix (G*B05 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "drmn6m.chd": {
     "disc": "b16jaa02",
     "make": "chd",
     "sha1": "fa0862a9bd3a48d4f6e7b44b11ad387acc05037e"
    },
    "drmn6m.sav": {
     "make": "sav",
     "older": [
      16777216,
      16778240
     ],
     "seed": {
      "fill": 255,
      "parts": [
       {
        "base": 0,
        "lane": 0,
        "rom": "drmn6m/gcb16jaa.31m"
       },
       {
        "base": 0,
        "lane": 1,
        "rom": "drmn6m/gcb16jaa.27m"
       }
      ],
      "size": 16777216
     },
     "size": 16787456
    },
    "drmn6m.u1": {
     "ds2401": "drmn6m/gcb16jaa.u6",
     "make": "zs01",
     "rom": "drmn6m/gcb16jaa.u1"
    },
    "drmn6m.u6": {
     "make": "rom",
     "rom": "drmn6m/gcb16jaa.u6",
     "trailer": "5335373343020023"
    }
   },
   "launchers": [
    "DrumMania 6th Mix (Japan, 2001).mgl"
   ],
   "set": "drmn6m",
   "title": "DrumMania 6th Mix (G*B16 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "drmn7m.chd": {
     "disc": "c07jca02",
     "make": "chd",
     "sha1": "a81a35360933ab8a7630cf5e8a8c6988714cfa0d"
    },
    "drmn7m.sav": {
     "make": "sav",
     "older": [
      16777216,
      16778240
     ],
     "seed": {
      "fill": 255,
      "parts": [
       {
        "base": 0,
        "lane": 0,
        "rom": "drmn7m/gcc07jba.31m"
       },
       {
        "base": 0,
        "lane": 1,
        "rom": "drmn7m/gcc07jba.27m"
       }
      ],
      "size": 16777216
     },
     "size": 16787456
    },
    "drmn7m.u1": {
     "ds2401": "drmn7m/gcc07jba.u6",
     "make": "zs01",
     "rom": "drmn7m/gcc07jba.u1"
    },
    "drmn7m.u6": {
     "make": "rom",
     "rom": "drmn7m/gcc07jba.u6",
     "trailer": "5335373343020023"
    }
   },
   "launchers": [
    "DrumMania 7th Mix power-up ver. (Japan, 2002).mgl"
   ],
   "set": "drmn7m",
   "title": "DrumMania 7th Mix power-up ver. (G*C07 VER. JBA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "drmn8m.chd": {
     "disc": "c38jaa02",
     "make": "chd",
     "sha1": "9115252e6cc13ff90e73cd1a864e0d99e3c8b5ea"
    },
    "drmn8m.sav": {
     "make": "sav",
     "older": [
      16777216,
      16778240
     ],
     "size": 16787456
    },
    "drmn8m.u1": {
     "ds2401": "drmn8m/gcc38jaa.u6",
     "make": "zs01",
     "rom": "drmn8m/gcc38jaa.u1"
    },
    "drmn8m.u6": {
     "make": "rom",
     "rom": "drmn8m/gcc38jaa.u6",
     "trailer": "5335373343020023"
    }
   },
   "launchers": [
    "DrumMania 8th Mix (Japan, 2003).mgl"
   ],
   "set": "drmn8m",
   "title": "DrumMania 8th Mix (G*C38 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "drmn9ma.chd": {
     "disc": "d09jaa02",
     "make": "chd",
     "sha1": "33f3e48ed5a8becd8c4714413e454328d8d5baae"
    },
    "drmn9ma.sav": {
     "make": "sav",
     "older": [
      16777216,
      16778240
     ],
     "size": 16787456
    },
    "drmn9ma.u1": {
     "ds2401": "drmn9ma/gcd09jaa.u6",
     "make": "zs01",
     "rom": "drmn9ma/gcd09jaa.u1"
    },
    "drmn9ma.u6": {
     "make": "rom",
     "rom": "drmn9ma/gcd09jaa.u6",
     "trailer": "5335373343020023"
    }
   },
   "launchers": [
    "DrumMania 9th Mix (Japan, 2003, Ver. JAA).mgl"
   ],
   "set": "drmn9ma",
   "title": "DrumMania 9th Mix (G*D09 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "dsem.cue": {
     "bin": "dsem.bin",
     "disc": "936eaa",
     "make": "mode1",
     "sha1": "7cacc15ae065d47af31f1008374ec8241dba0d55"
    },
    "dsem.sav": {
     "make": "sav",
     "older": [
      16777216
     ],
     "size": 16786432
    },
    "dsem.u1": {
     "chip": "X76F041",
     "make": "rom",
     "rom": "dsem/ge936ea.u1"
    },
    "dsem.u6": {
     "make": "rom",
     "rom": "dsem/ge936ea.u6",
     "trailer": "5335373343000021"
    }
   },
   "launchers": [
    "Dancing Stage Euro Mix (Europe, 2000).mgl"
   ],
   "set": "dsem",
   "title": "Dancing Stage Euro Mix (G*936 VER. EAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "dsem2.chd": {
     "disc": "c23eaa02",
     "make": "chd",
     "sha1": "46868c97530db5be1b43ffa32744e3e12495c243"
    },
    "dsem2.sav": {
     "make": "sav",
     "older": [
      50331648,
      50332672
     ],
     "size": 50341888
    },
    "dsem2.u1": {
     "ds2401": "dsem2/gkc23ea.u6",
     "make": "zs01",
     "rom": "dsem2/gkc23ea.u1"
    },
    "dsem2.u6": {
     "make": "rom",
     "rom": "dsem2/gkc23ea.u6",
     "trailer": "5335373343000120"
    }
   },
   "launchers": [
    "Dancing Stage Euro Mix 2 (Europe, 2002).mgl"
   ],
   "set": "dsem2",
   "title": "Dancing Stage Euro Mix 2 (G*C23 VER. EAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "dsfdct.cas": {
     "game_u6": "dsfdct/gc910jc.u6",
     "install_chip": "X76F100",
     "install_u1": "dsfdct/ge887ja_gn887ja.u1",
     "install_u6": "dsfdct/ge887ja_gn887ja.u6",
     "make": "cas",
     "trailer": "5335373343000120"
    },
    "dsfdct.cue": {
     "bin": "dsfdct.bin",
     "disc": "910jca02",
     "make": "mode1",
     "sha1": "0c868f3c9f696d291e8f27687e3ad83e453a4894"
    },
    "dsfdct.sav": {
     "make": "sav",
     "older": [
      50331648
     ],
     "size": 50340864
    },
    "dsfdct.u1": {
     "chip": "X76F100",
     "make": "rom",
     "rom": "dsfdct/gc910jc.u1"
    }
   },
   "launchers": [
    "Dancing Stage featuring Dreams Come True (Japan, 1999, Ver. JCA).mgl"
   ],
   "set": "dsfdct",
   "title": "Dancing Stage featuring Dreams Come True (GC910 VER. JCA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "dsfdr.cas": {
     "game_u6": "dsfdr/gca37ja.u6",
     "install_chip": "X76F041",
     "install_u1": "dsfdr/gea37ja.u1",
     "install_u6": "dsfdr/gea37ja.u6",
     "make": "cas",
     "trailer": "5335373343000021"
    },
    "dsfdr.chd": {
     "disc": "a37jaa02",
     "make": "chd",
     "sha1": "c6a23b910e884aa0d4afc388dbc8379e0d09611a"
    },
    "dsfdr.sav": {
     "make": "sav",
     "older": [
      16777216,
      16778240
     ],
     "size": 16787456
    },
    "dsfdr.u1": {
     "ds2401": "dsfdr/gca37ja.u6",
     "make": "zs01",
     "rom": "dsfdr/gca37ja.u1"
    }
   },
   "launchers": [
    "Dancing Stage Featuring Disney's Rave (Japan, 2000).mgl"
   ],
   "set": "dsfdr",
   "title": "Dancing Stage Featuring Disney's Rave (GCA37JAA)"
  },
  {
   "files": {
    "573bios_gchgchmp.bin": {
     "make": "rom",
     "rom": "sys573/700a01,gchgchmp.22g"
    }
   },
   "launchers": [
    "Gacha Gachamp (Japan, 1999).mgl"
   ],
   "set": "gchgchmp",
   "title": "Gacha Gachamp (GE877 VER. JAB)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "gtrfrk5m.chd": {
     "disc": "a26jaa02",
     "make": "chd",
     "sha1": "9909e08abff780db6fd7a5fbcc57ffbe14ae08ce"
    },
    "gtrfrk5m.sav": {
     "make": "sav",
     "older": [
      50331648,
      50332672
     ],
     "seed": {
      "fill": 255,
      "parts": [
       {
        "base": 0,
        "lane": 0,
        "rom": "gtrfrk5m/gea26jaa.31m"
       },
       {
        "base": 0,
        "lane": 1,
        "rom": "gtrfrk5m/gea26jaa.27m"
       }
      ],
      "size": 16777216
     },
     "size": 50341888
    },
    "gtrfrk5m.u1": {
     "ds2401": "gtrfrk5m/gea26jaa.u6",
     "make": "zs01",
     "rom": "gtrfrk5m/gea26jaa.u1"
    },
    "gtrfrk5m.u6": {
     "make": "rom",
     "rom": "gtrfrk5m/gea26jaa.u6",
     "trailer": "5335373343030220"
    }
   },
   "launchers": [
    "Guitar Freaks 5th Mix (Japan, 2001).mgl"
   ],
   "set": "gtrfrk5m",
   "title": "Guitar Freaks 5th Mix (G*A26 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "flash16m_blank.bin": {
     "byte": 255,
     "make": "fill",
     "size": 16777216
    },
    "hypbbc2p.chd": {
     "disc": "908a02",
     "make": "chd",
     "sha1": "573194ca9938c30415fc88dcc0c0152dd3024d71"
    },
    "hypbbc2p.sav": {
     "make": "sav",
     "older": [
      16777216
     ],
     "size": 16786432
    },
    "hypbbc2p.u1": {
     "chip": "X76F100",
     "make": "rom",
     "rom": "hypbbc2p/gx908ja.u1"
    },
    "nvram8k_blank.bin": {
     "byte": 255,
     "make": "fill",
     "size": 8192
    }
   },
   "launchers": [
    "Hyper Bishi Bashi Champ - 2 Player (Japan, 1999) [Install].mgl",
    "Hyper Bishi Bashi Champ - 2 Player (Japan, 1999).mgl"
   ],
   "set": "hypbbc2p",
   "title": "Hyper Bishi Bashi Champ - 2 Player (GX908 1999/08/24 VER. JAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "hbbflash.bin": {
     "fill": 255,
     "make": "flash",
     "parts": [
      {
       "base": 0,
       "lane": 0,
       "rom": "hyperbbc/876ea.31m"
      },
      {
       "base": 0,
       "lane": 1,
       "rom": "hyperbbc/876ea.27m"
      },
      {
       "base": 4194304,
       "lane": 0,
       "rom": "hyperbbc/876ea.31l"
      },
      {
       "base": 4194304,
       "lane": 1,
       "rom": "hyperbbc/876ea.27l"
      },
      {
       "base": 8388608,
       "lane": 0,
       "rom": "hyperbbc/876ea.31j"
      },
      {
       "base": 8388608,
       "lane": 1,
       "rom": "hyperbbc/876ea.27j"
      },
      {
       "base": 12582912,
       "lane": 0,
       "rom": "hyperbbc/876ea.31h"
      },
      {
       "base": 12582912,
       "lane": 1,
       "rom": "hyperbbc/876ea.27h"
      }
     ],
     "size": 16777216
    },
    "hbbnvram.bin": {
     "make": "rom",
     "rom": "hyperbbc/876ea.22h"
    }
   },
   "launchers": [
    "Hyper Bishi Bashi Champ (Europe, 1998).mgl"
   ],
   "set": "hyperbbc",
   "title": "Hyper Bishi Bashi Champ (GQ876 VER. EAA)"
  },
  {
   "files": {
    "573bios.bin": {
     "make": "rom",
     "rom": "sys573/700a01.22g"
    },
    "konam80s.chd": {
     "disc": "826eaa01",
     "make": "chd",
     "sha1": "be5f8b31fd18ba631fe98c2132c56abf20193419"
    },
    "konam80s.sav": {
     "make": "sav",
     "older": [
      16777216
     ],
     "size": 16786432
    },
    "konam80s.u1": {
     "chip": "X76F041",
     "make": "rom",
     "rom": "konam80s/gc826ea.u1"
    }
   },
   "launchers": [
    "Konami 80's AC Special (Europe, 1998).mgl"
   ],
   "set": "konam80s",
   "title": "Konami 80's AC Special (GC826 VER. EAA)"
  }
 ]
}
""")
# ======== END GENERATED TABLE ========

MIB = 1 << 20


class Fail(Exception):
    """A title cannot be staged; the message says why."""


def say(msg=""):
    print(msg, flush=True)


TTY = sys.stdout.isatty()


def progress(text):
    """A self-overwriting progress line -- only on a terminal, not in a log file."""
    if TTY:
        print("\r" + text, end="", flush=True)


def progress_done():
    if TTY:
        print("\r" + " " * 60 + "\r", end="", flush=True)


# --------------------------------------------------------------------------- CHD
# Reader for MAME CHD v3/v4 (zlib) and v5 (zlib, lzma, cdzl, cdlz, uncompressed).
# It is only needed for the MODE1/2048 discs, which have to be re-wrapped; every
# other disc is copied as-is and the core reads it directly. Every hunk is checked
# against the CRC in the CHD's map, and the whole image against the CHD's raw SHA1,
# so a decoding mistake cannot produce a quietly wrong disc.

CD_FRAME, CD_DATA, CD_SUB = 2448, 2352, 96
SYNC = b"\x00" + b"\xff" * 10 + b"\x00"

# CD-ROM ECC (P/Q parity), needed when a v5 CD codec has stripped it from a raw
# sector; the same computation as MAME's cdrom.cpp ecc_generate.
_F = bytearray(256)
_B = bytearray(256)
for _i in range(256):
    _j = ((_i << 1) ^ (0x11D if _i & 0x80 else 0)) & 0xFF
    _F[_i] = _j
    _B[_i ^ _j] = _i
_F, _B = bytes(_F), bytes(_B)


def _ecc_block(src, major_count, minor_count, major_mult, minor_inc):
    size = major_count * minor_count
    getters = []
    for minor in range(minor_count):
        idx = []
        for major in range(major_count):
            i = (major >> 1) * major_mult + (major & 1) + minor * minor_inc
            idx.append(i % size)
        getters.append(operator.itemgetter(*idx))
    return getters


_P_GET = _ecc_block(None, 86, 24, 2, 86)
_Q_GET = _ecc_block(None, 52, 43, 86, 88)


def _xor(a, b):
    return (int.from_bytes(a, "big") ^ int.from_bytes(b, "big")).to_bytes(len(a), "big")


def _ecc_compute(src, getters, n):
    a = bytes(n)
    b = bytes(n)
    for g in getters:
        t = bytes(g(src))
        a = _xor(a, t).translate(_F)
        b = _xor(b, t)
    a = _xor(a.translate(_F), b).translate(_B)
    return a + _xor(a, b)


def ecc_generate(sector):
    """Fill in the P and Q parity of a 2352-byte mode-1 sector (bytearray)."""
    sector[0x81C:0x81C + 172] = _ecc_compute(bytes(sector[0xC:0xC + 2064]), _P_GET, 86)
    sector[0x8C8:0x8C8 + 104] = _ecc_compute(bytes(sector[0xC:0xC + 2236]), _Q_GET, 52)


def crc16(data):
    return binascii.crc_hqx(data, 0xFFFF)


class Bits:
    """MSB-first bit reader (libchdr bitstream). Reads past the end give zeros."""
    def __init__(self, data):
        self.d = bytes(data) + bytes(8)
        self.n = len(data) * 8
        self.pos = 0

    def read(self, count):
        if count == 0:
            return 0
        p = self.pos
        if p >= self.n:
            self.pos += count
            return 0
        a, b = p >> 3, (p + count + 7) >> 3
        v = int.from_bytes(self.d[a:b], "big")
        v = (v >> ((b << 3) - p - count)) & ((1 << count) - 1)
        self.pos = p + count
        return v


def _huffman_rle(bits, numcodes=16, maxbits=8):
    """libchdr huffman_import_tree_rle + canonical code assignment."""
    nb = 5 if maxbits >= 16 else 4 if maxbits >= 8 else 3
    lens = []
    while len(lens) < numcodes:
        v = bits.read(nb)
        if v != 1:
            lens.append(v)
        else:
            v = bits.read(nb)
            if v == 1:
                lens.append(1)
            else:
                lens.extend([v] * (bits.read(nb) + 3))
    if len(lens) != numcodes:
        raise Fail("CHD map: bad Huffman tree")
    histo = [0] * 33
    for n in lens:
        if n > maxbits:
            raise Fail("CHD map: bad Huffman tree")
        histo[n] += 1
    start = 0
    for length in range(32, 0, -1):
        nxt = (start + histo[length]) >> 1
        if length != 1 and nxt * 2 != start + histo[length]:
            raise Fail("CHD map: bad Huffman tree")
        histo[length] = start
        start = nxt
    codes = {}
    for sym, n in enumerate(lens):
        if n:
            codes[(n, histo[n])] = sym
            histo[n] += 1
    return codes


def _huffman_one(codes, bits, maxbits=8):
    v = 0
    for n in range(1, maxbits + 1):
        v = (v << 1) | bits.read(1)
        s = codes.get((n, v))
        if s is not None:
            return s
    raise Fail("CHD map: bad Huffman code")


def _lzma_dict(reduce_size):
    """LzmaEncProps_Normalize at level 9, as libchdr configures its LZMA codec."""
    for i in range(11, 31):
        if reduce_size <= (2 << i):
            return 2 << i
        if reduce_size <= (3 << i):
            return 3 << i
    return 1 << 26


def _inflate(src, size):
    out = zlib.decompressobj(-15).decompress(src, size)
    if len(out) != size:
        raise Fail("CHD hunk: deflate gave %d bytes, expected %d" % (len(out), size))
    return out


def _unlzma(src, size, reduce_size):
    d = lzma.LZMADecompressor(format=lzma.FORMAT_RAW, filters=[{
        "id": lzma.FILTER_LZMA1, "dict_size": _lzma_dict(reduce_size), "lc": 3, "lp": 0, "pb": 2}])
    out = d.decompress(src, size)
    if len(out) != size:
        raise Fail("CHD hunk: LZMA gave %d bytes, expected %d" % (len(out), size))
    return out


class Chd:
    def __init__(self, path):
        self.path = path
        self.f = open(path, "rb")
        h = self.f.read(124)
        if h[:8] != b"MComprHD":
            raise Fail(f"{path}: not a CHD")
        hlen, self.ver = struct.unpack(">II", h[8:16])
        self._cache = {}
        if self.ver in (3, 4):
            flags, comp, self.hunks = struct.unpack(">III", h[16:28])
            self.logical, self.metaoffset = struct.unpack(">QQ", h[28:44])
            self.hunkbytes = struct.unpack(">I", h[44:48] if self.ver == 4 else h[76:80])[0]
            self.rawsha1 = h[0x58:0x6C] if self.ver == 4 else None
            if flags & 1:
                raise Fail(f"{path}: this CHD needs a parent CHD (not supported)")
            if comp not in (0, 1, 2):
                raise Fail(f"{path}: CHD v{self.ver} compression {comp} is not supported")
            self.f.seek(hlen)
            self.map = self.f.read(16 * self.hunks)
            self.hunk = self._hunk_v34
        elif self.ver == 5:
            self.comps = [h[16 + 4 * i:20 + 4 * i] for i in range(4)]
            self.logical, self.mapoffset, self.metaoffset = struct.unpack(">QQQ", h[32:56])
            self.hunkbytes, self.unitbytes = struct.unpack(">II", h[56:64])
            self.rawsha1 = h[64:84]
            if any(h[104:124]):
                raise Fail(f"{path}: this CHD needs a parent CHD (not supported)")
            self.hunks = -(-self.logical // self.hunkbytes)
            if self.comps[0] == bytes(4):
                self.f.seek(self.mapoffset)
                self.map = self.f.read(4 * self.hunks)
                self.hunk = self._hunk_v5_raw
            else:
                self._read_v5_map()
                self.hunk = self._hunk_v5
        else:
            raise Fail(f"{path}: CHD version {self.ver} is not supported")

    def close(self):
        self.f.close()

    # --- metadata
    def tracks(self):
        out, off = [], self.metaoffset
        while off:
            self.f.seek(off)
            e = self.f.read(16)
            tag, ln, nxt = e[:4], struct.unpack(">I", e[4:8])[0] & 0xFFFFFF, struct.unpack(">Q", e[8:16])[0]
            data = self.f.read(ln)
            if tag in (b"CHT2", b"CHTR"):
                kv = dict(w.split(":", 1) for w in data.rstrip(b"\0").decode("ascii", "replace").split() if ":" in w)
                out.append(kv)
            off = nxt
        return out

    # --- v3 / v4
    def _hunk_v34(self, n):
        if n in self._cache:
            return self._cache[n]
        e = self.map[16 * n:16 * n + 16]
        off = struct.unpack(">Q", e[0:8])[0]
        crc = struct.unpack(">I", e[8:12])[0]
        length = struct.unpack(">H", e[12:14])[0] | (e[14] << 16)
        kind, nocrc = e[15] & 0x0F, e[15] & 0x10
        if kind == 1:
            self.f.seek(off)
            src = self.f.read(length)
            try:
                data = _inflate(src, self.hunkbytes)
            except (Fail, zlib.error):
                data = zlib.decompress(src)
        elif kind == 2:
            self.f.seek(off)
            data = self.f.read(self.hunkbytes)
        elif kind == 3:
            data = (e[0:8] * (self.hunkbytes // 8 + 1))[:self.hunkbytes]
        elif kind == 4:
            data = self._hunk_v34(off)
            nocrc = 1
        else:
            raise Fail(f"{self.path}: hunk {n} has map type {kind} (not supported)")
        if len(data) != self.hunkbytes:
            raise Fail(f"{self.path}: hunk {n} is {len(data)} bytes, expected {self.hunkbytes}")
        if not nocrc and kind != 4 and (zlib.crc32(data) & 0xFFFFFFFF) != crc:
            raise Fail(f"{self.path}: hunk {n} fails its CRC -- the CHD is damaged")
        self._cache = {n: data}
        return data

    # --- v5
    def _read_v5_map(self):
        self.f.seek(self.mapoffset)
        hdr = self.f.read(16)
        mapbytes = struct.unpack(">I", hdr[0:4])[0]
        offset = int.from_bytes(hdr[4:10], "big")
        mapcrc = struct.unpack(">H", hdr[10:12])[0]
        lengthbits, selfbits, parentbits = hdr[12], hdr[13], hdr[14]
        bits = Bits(self.f.read(mapbytes))
        codes = _huffman_rle(bits)
        kinds, last, rep = [], 0, 0
        for _ in range(self.hunks):
            if rep:
                kinds.append(last)
                rep -= 1
                continue
            v = _huffman_one(codes, bits)
            if v == 7:                                    # RLE_SMALL
                rep = 2 + _huffman_one(codes, bits)
                kinds.append(last)
            elif v == 8:                                  # RLE_LARGE
                rep = 2 + 16 + (_huffman_one(codes, bits) << 4)
                rep += _huffman_one(codes, bits)
                kinds.append(last)
            else:
                kinds.append(v)
                last = v
        self.map5 = []
        raw = bytearray()
        last_self = last_parent = 0
        for n, k in enumerate(kinds):
            length, crc, off = 0, 0, offset
            if k <= 3:
                length = bits.read(lengthbits)
                offset += length
                crc = bits.read(16)
            elif k == 4:
                length = self.hunkbytes
                offset += length
                crc = bits.read(16)
            elif k == 5:
                off = last_self = bits.read(selfbits)
            elif k == 6:
                off = last_parent = bits.read(parentbits)
            elif k in (9, 10):
                if k == 10:
                    last_self += 1
                k, off = 5, last_self
            elif k == 11:
                k, off = 6, n * self.hunkbytes // self.unitbytes
                last_parent = off
            elif k in (12, 13):
                if k == 13:
                    last_parent += self.hunkbytes // self.unitbytes
                k, off = 6, last_parent
            else:
                raise Fail(f"{self.path}: bad map entry type {k}")
            self.map5.append((k, length, off, crc))
            raw += bytes([k]) + length.to_bytes(3, "big") + off.to_bytes(6, "big") + crc.to_bytes(2, "big")
        if crc16(bytes(raw)) != mapcrc:
            raise Fail(f"{self.path}: hunk map fails its CRC -- the CHD is damaged or not understood")

    def _codec(self, tag, src):
        hb = self.hunkbytes
        if tag == b"zlib":
            return _inflate(src, hb)
        if tag == b"lzma":
            return _unlzma(src, hb, hb)
        if tag in (b"cdzl", b"cdlz"):
            frames = hb // CD_FRAME
            ecc_bytes = (frames + 7) // 8
            clen = 2 if hb < 65536 else 3
            base_len = int.from_bytes(src[ecc_bytes:ecc_bytes + clen], "big")
            p = ecc_bytes + clen
            if tag == b"cdzl":
                base = _inflate(src[p:p + base_len], frames * CD_DATA)
            else:
                base = _unlzma(src[p:p + base_len], frames * CD_DATA, frames * CD_DATA)
            sub = _inflate(src[p + base_len:], frames * CD_SUB)
            out = bytearray(hb)
            for i in range(frames):
                sec = bytearray(base[i * CD_DATA:(i + 1) * CD_DATA])
                if src[i >> 3] & (1 << (i & 7)):
                    sec[0:12] = SYNC
                    ecc_generate(sec)
                out[i * CD_FRAME:i * CD_FRAME + CD_DATA] = sec
                out[i * CD_FRAME + CD_DATA:(i + 1) * CD_FRAME] = sub[i * CD_SUB:(i + 1) * CD_SUB]
            return bytes(out)
        name = tag.decode("ascii", "replace")
        raise Fail(f"{self.path}: CHD codec '{name}' is not supported here. Re-compress the "
                   f"disc with MAME's chdman:  chdman copy -i IN.chd -o OUT.chd -c cdlz,cdzl")

    def _hunk_v5(self, n):
        if n in self._cache:
            return self._cache[n]
        k, length, off, crc = self.map5[n]
        if k <= 3:
            self.f.seek(off)
            data = self._codec(self.comps[k], self.f.read(length))
        elif k == 4:
            self.f.seek(off)
            data = self.f.read(self.hunkbytes)
        elif k == 5:
            data = self._hunk_v5(off)
        else:
            raise Fail(f"{self.path}: hunk {n} refers to a parent CHD (not supported)")
        if k <= 4 and crc16(data) != crc:
            raise Fail(f"{self.path}: hunk {n} fails its CRC -- the CHD is damaged")
        self._cache = {n: data}
        return data

    def _hunk_v5_raw(self, n):
        off = struct.unpack(">I", self.map[4 * n:4 * n + 4])[0] * self.hunkbytes
        if not off:
            return bytes(self.hunkbytes)
        self.f.seek(off)
        return self.f.read(self.hunkbytes)

    def verify_all(self, progress=None):
        """Decode every hunk; check the raw SHA1. Returns True if it was checked."""
        h = hashlib.sha1()
        for n in range(self.hunks):
            d = self.hunk(n)
            h.update(d[:min(self.hunkbytes, self.logical - n * self.hunkbytes)])
            if progress and n % 2000 == 0:
                progress(n, self.hunks)
        if self.rawsha1 is None or not any(self.rawsha1):
            return False
        if h.digest() != self.rawsha1:
            raise Fail(f"{self.path}: decoded data does not match the CHD's SHA1")
        return True


def chd_ident(path):
    """(version, sha1 hex) from a CHD header, or None. MAME's DISK_IMAGE SHA1 is this
    header field ('sha1', data + metadata), so no decoding is needed to identify."""
    try:
        with open(path, "rb") as f:
            h = f.read(124)
    except OSError:
        return None
    if len(h) < 124 or h[:8] != b"MComprHD":
        return None
    ver = struct.unpack(">I", h[12:16])[0]
    at = {3: 0x50, 4: 0x30, 5: 0x54}.get(ver)
    return (ver, h[at:at + 20].hex()) if at else None


# ----------------------------------------------------------------------- sources
class Sources:
    def __init__(self, root):
        self.root = root
        self.zips = {}       # (crc, size) -> [(zip path, member)]
        self.loose = {}      # size -> [path]   (CRC computed on demand)
        self.loose_crc = {}  # path -> crc
        self.chds = {}       # sha1 -> path
        self.other_chds = []
        self.sevenz = []
        sizes = {r["size"] for r in TABLE["roms"].values()} | {READER_ROM["size"]}
        for dp, dns, fns in os.walk(root):
            dns[:] = [d for d in dns if not d.startswith(".")]
            for fn in fns:
                if fn.startswith("._") or fn.startswith("."):
                    continue
                p = os.path.join(dp, fn)
                low = fn.lower()
                if low.endswith(".zip"):
                    try:
                        with zipfile.ZipFile(p) as z:
                            for i in z.infolist():
                                if not i.is_dir():
                                    self.zips.setdefault((i.CRC, i.file_size), []).append((p, i.filename))
                    except (zipfile.BadZipFile, OSError) as e:
                        say(f"  (skipping {p}: {e})")
                elif low.endswith(".chd"):
                    ident = chd_ident(p)
                    if ident:
                        self.chds.setdefault(ident[1], p)
                    else:
                        self.other_chds.append(p)
                elif low.endswith(".7z"):
                    self.sevenz.append(p)
                else:
                    try:
                        size = os.path.getsize(p)
                    except OSError:
                        continue
                    if size in sizes:
                        self.loose.setdefault(size, []).append(p)

    def rom(self, key):
        """The bytes of a ROM from the table (or READER_ROM), verified against MAME's
        CRC32 + SHA1."""
        r = key if isinstance(key, dict) else TABLE["roms"][key]
        crc, size = int(r["crc"], 16), r["size"]
        cands = sorted(self.zips.get((crc, size), []),
                       key=lambda c: os.path.splitext(os.path.basename(c[0]))[0].lower() != r["set"])
        for zp, member in cands:
            try:
                with zipfile.ZipFile(zp) as z:
                    data = z.read(member)
            except (zipfile.BadZipFile, OSError, zlib.error):
                continue
            if hashlib.sha1(data).hexdigest() == r["sha1"]:
                return data
        for p in self.loose.get(size, []):
            if p not in self.loose_crc:
                with open(p, "rb") as f:
                    self.loose_crc[p] = zlib.crc32(f.read()) & 0xFFFFFFFF
            if self.loose_crc[p] == crc:
                with open(p, "rb") as f:
                    data = f.read()
                if hashlib.sha1(data).hexdigest() == r["sha1"]:
                    return data
        raise Fail(f"missing {r['name']} (CRC {r['crc']}) from the MAME set '{r['set']}'")

    def has_rom(self, key):
        try:
            self.rom(key)
            return True
        except Fail:
            return False

    def chd(self, sha1, disc):
        p = self.chds.get(sha1)
        if not p:
            raise Fail(f"missing disc {disc}.chd (SHA1 {sha1[:12]}...)")
        return p


# ------------------------------------------------------------------------ makers
def same_file(path, data):
    try:
        if os.path.getsize(path) != len(data):
            return False
        with open(path, "rb") as f:
            return f.read() == data
    except OSError:
        return False


def write_atomic(path, data):
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def put(out, name, data, dry, log):
    p = os.path.join(out, name)
    if same_file(p, data):
        log.append(f"{name}: already correct")
        return
    if not dry:
        write_atomic(p, data)
    log.append(f"{name}: written ({len(data):,} bytes)")


ZS01_RAW, ZS01_PAD = 140, 4116
ZS01_RTR = bytes([0x5A, 0x53, 0x00, 0x01])
ZS01_CMD_KEY = bytes([0xED, 0x68, 0x50, 0x4B, 0xC6, 0x44, 0x48, 0x3E])
CHIP_LEN = {"X76F041": 0x224, "X76F100": 0x084}


def make_zs01(src, r):
    """The core picks the cassette chip from the .u1 size; a ZS01 is padded with zeros
    from its 140 dumped bytes to 4116 so it is not mistaken for an X76F100. Checked:
    the response-to-reset, the fixed command key every ZS01 carries, and (when the set
    has it) the cassette's DS2401 serial, which the data holds byte-reversed."""
    u1 = src.rom(r["rom"])
    if len(u1) != ZS01_RAW or u1[0:4] != ZS01_RTR or u1[4:12] != ZS01_CMD_KEY:
        raise Fail("the ZS01 cassette dump does not look like a ZS01")
    if r.get("ds2401"):
        ds = src.rom(r["ds2401"])
        if bytes(reversed(ds)) not in u1[28:140]:
            raise Fail("the ZS01 dump and its DS2401 serial do not belong together")
    return u1 + bytes(ZS01_PAD - ZS01_RAW)


def make_cas(src, r):
    """Two-cassette titles: [game .u6 8][install .u6 8][install .u1 as dumped]."""
    g6, i6, i1 = src.rom(r["game_u6"]), src.rom(r["install_u6"]), src.rom(r["install_u1"])
    if len(g6) != 8 or len(i6) != 8 or len(i1) != CHIP_LEN[r["install_chip"]]:
        raise Fail("cassette dump sizes do not match the driver")
    return g6 + i6 + i1


def make_flash(src, r):
    img = bytearray(bytes([r["fill"]]) * r["size"])
    for p in r["parts"]:
        d = src.rom(p["rom"])
        start = p["base"] + p["lane"]
        img[start:start + 2 * len(d):2] = d
    return bytes(img)


def copy_chd(path, dest, sha1, dry, log, name):
    if chd_ident(dest) == chd_ident(path) and os.path.getsize(dest) == os.path.getsize(path):
        log.append(f"{name}: already correct")
        return
    size = os.path.getsize(path)
    if not dry:
        tmp = dest + ".part"
        with open(path, "rb") as fi, open(tmp, "wb") as fo:
            done = 0
            while True:
                b = fi.read(8 * MIB)
                if not b:
                    break
                fo.write(b)
                done += len(b)
                progress(f"    copying {name}: {done * 100 // size:3d}%")
            fo.flush()
            os.fsync(fo.fileno())
        progress_done()
        if os.path.getsize(tmp) != size or chd_ident(tmp)[1] != sha1:
            raise Fail(f"{name}: the copy does not match the source")
        os.replace(tmp, dest)
    log.append(f"{name}: copied ({size:,} bytes)")


def bcd(n):
    return ((n // 10) << 4) | (n % 10)


def mode1_sector(lba, user):
    a = lba + 150
    hdr = bytes((bcd(a // (60 * 75)), bcd((a // 75) % 60), bcd(a % 75), 1))
    return SYNC + hdr + user + bytes(288)


def make_mode1(path, out, r, set_, dry, log):
    """A MODE1/2048 disc stores only the 2048 user bytes per sector; the core serves
    raw 2352-byte sectors, so each one is rebuilt: sync, BCD MSF header for LBA+150,
    mode 1, the user data, EDC/ECC left as zeros (nothing in the core checks them --
    the recipe of the dsem image proven on hardware since 2026-09-13)."""
    binname, cuename = r["bin"], set_ + ".cue"
    cue = f'FILE "{binname}" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n'.encode("ascii")
    c = Chd(path)
    try:
        tr = c.tracks()
        if len(tr) != 1 or tr[0].get("TYPE") != "MODE1":
            raise Fail(f"{os.path.basename(path)}: expected one MODE1 track, found "
                       + ", ".join(t.get("TYPE", "?") for t in tr))
        frames = int(tr[0]["FRAMES"])
        if c.hunkbytes % CD_FRAME:
            raise Fail(f"{os.path.basename(path)}: hunk size {c.hunkbytes} is not whole CD frames")
        bp = os.path.join(out, binname)
        want = frames * CD_DATA
        if os.path.exists(bp) and os.path.getsize(bp) == want and same_file(os.path.join(out, cuename), cue):
            log.append(f"{binname} + {cuename}: already present (use --force to rebuild)")
            return
        per = c.hunkbytes // CD_FRAME
        sha = hashlib.sha1()
        tmp = bp + ".part"
        fo = None if dry else open(tmp, "wb")
        try:
            lba = 0
            for n in range(c.hunks):
                d = c.hunk(n)
                sha.update(d[:min(c.hunkbytes, c.logical - n * c.hunkbytes)])
                if fo and lba < frames:
                    chunk = bytearray()
                    for k in range(per):
                        if lba >= frames:
                            break
                        chunk += mode1_sector(lba, d[k * CD_FRAME:k * CD_FRAME + 2048])
                        lba += 1
                    fo.write(chunk)
                else:
                    lba = min(frames, lba + per)
                if n % 1000 == 0:
                    progress(f"    building {binname}: {n * 100 // c.hunks:3d}%")
            progress_done()
            if c.rawsha1 is not None and any(c.rawsha1) and sha.digest() != c.rawsha1:
                raise Fail(f"{os.path.basename(path)}: decoded data does not match the CHD's SHA1")
            if fo:
                fo.flush()
                os.fsync(fo.fileno())
                fo.close()
                fo = None
                if os.path.getsize(tmp) != want:
                    raise Fail(f"{binname}: wrote {os.path.getsize(tmp)} bytes, expected {want}")
                os.replace(tmp, bp)
                write_atomic(os.path.join(out, cuename), cue)
        finally:
            if fo:
                fo.close()
        log.append(f"{binname} + {cuename}: built from {os.path.basename(path)} ({frames} sectors, "
                   f"{want:,} bytes; disc data verified against its SHA1)")
    finally:
        c.close()


def make_sav(out, name, r, dry, log, src=None):
    """Real zero bytes, never a sparse/truncated file: saves created by extending a
    file with truncate() were never written back by the MiSTer on exFAT.
    An upgrade title's save starts with the previous game already in the onboard
    flash (r["seed"]: the set's flash ROMs, as MAME preloads them) -- without it
    the game stops with ERROR 194 before installing."""
    p = os.path.join(out, name)
    size = r["size"]
    if os.path.exists(p):
        have = os.path.getsize(p)
        if have == size:
            log.append(f"{name}: kept (may hold your install)")
        elif have in r["older"]:
            if not dry:
                with open(p, "ab") as f:
                    f.write(bytes(size - have))
                    f.flush()
                    os.fsync(f.fileno())
            log.append(f"{name}: extended {have:,} -> {size:,} bytes for the newer core (install kept)")
        else:
            log.append(f"{name}: WARNING is {have:,} bytes, expected {size:,} -- left alone")
        return
    seed = r.get("seed")
    if seed and src is None:
        log.append(f"{name}: SKIPPED -- this title's save starts from its romset's flash ROMs; "
                   f"run the stager with the romsets to create it")
        return
    if not dry:
        tmp = p + ".part"
        with open(tmp, "wb") as f:
            left = size
            if seed:
                img = make_flash(src, seed)
                f.write(img)
                left -= len(img)
            blk = bytes(MIB)
            while left:
                n = min(left, MIB)
                f.write(blk[:n])
                left -= n
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, p)
    log.append(f"{name}: created ({size:,} bytes" + (", flash preloaded with the previous game, as MAME does)"
                                                      if seed else " of zeros)"))


# -------------------------------------------------------------------------- main
def needs(t):
    """Everything a title needs, so a missing piece is reported before writing."""
    roms, discs = [], []
    for r in t["files"].values():
        for k in ("rom", "ds2401", "game_u6", "install_u6", "install_u1"):
            if r.get(k):
                roms.append(r[k])
        roms += [p["rom"] for p in r.get("parts", [])]
        roms += [p["rom"] for p in r.get("seed", {}).get("parts", [])]
        if r["make"] in ("chd", "mode1"):
            discs.append((r["sha1"], r["disc"]))
    return roms, discs


def check(src, t):
    roms, discs = needs(t)
    missing = []
    for k in dict.fromkeys(roms):
        if not src.has_rom(k):
            r = TABLE["roms"][k]
            missing.append(f"{r['name']} (set {r['set']})")
    for sha1, disc in discs:
        if sha1 not in src.chds:
            missing.append(f"{disc}.chd")
    return missing


def stage(src, t, out, dry, force, log):
    for name, r in sorted(t["files"].items()):
        p = os.path.join(out, name)
        m = r["make"]
        # r["trailer"]: the per-title settings the core reads from the end of the
        # index-5 file -- control layout and PCMCIA slot (8 bytes, "S573C...").
        tail = bytes.fromhex(r.get("trailer", ""))
        if m == "rom":
            data = src.rom(r["rom"])
            if r.get("chip") and len(data) != CHIP_LEN[r["chip"]]:
                raise Fail(f"{name}: {len(data)} bytes is not a {r['chip']} dump")
            put(out, name, data + tail, dry, log)
        elif m == "zs01":
            put(out, name, make_zs01(src, r), dry, log)
        elif m == "cas":
            put(out, name, make_cas(src, r) + tail, dry, log)
        elif m == "fill":
            put(out, name, bytes([r["byte"]]) * r["size"], dry, log)
        elif m == "flash":
            put(out, name, make_flash(src, r), dry, log)
        elif m == "chd":
            path = src.chd(r["sha1"], r["disc"])
            ident = chd_ident(path)
            c = Chd(path) if ident[0] in (3, 4, 5) else None
            try:
                tr = c.tracks() if c else []
            finally:
                if c:
                    c.close()
            if any(x.get("TYPE") == "MODE1" for x in tr):
                raise Fail(f"{r['disc']}.chd is MODE1/2048 but this title's launcher loads the CHD directly")
            if force and os.path.exists(p) and not dry:
                os.remove(p)
            copy_chd(path, p, r["sha1"], dry, log, name)
        elif m == "mode1":
            if force and not dry:
                for q in (os.path.join(out, r["bin"]), os.path.join(out, t["set"] + ".cue")):
                    if os.path.exists(q):
                        os.remove(q)
            make_mode1(src.chd(r["sha1"], r["disc"]), out, r, t["set"], dry, log)
        elif m == "sav":
            make_sav(out, name, r, dry, log, src)
        else:
            raise Fail(f"{name}: unknown recipe {m}")


# ---- the memory card reader's boot ROM ----
# The DDR cabinets with a memory card reader (Konami GE885-PWB(A), on JVS) are the
# MAME machines that add KONAMI_573_MEMORY_CARD_READER: in ksys573.cpp the ddr3m,
# ddr3mp, ddr4ms and ddr5m configs and the sets built on them (tools/test_s573_stage.py
# re-derives READER_SETS from ksys573.cpp). The reader's boot ROM, k573mcr.cpp:
#     ROM_LOAD( "885a01.bin", 0x000000, 0x080000, CRC(e22d093f) SHA1(927f62f6...) )
# Non-merged sets carry it in each of those zips; split and merged sets keep it in
# k573mcr.zip. MiSTer_System573 loads it from games/System573/885a01.bin.
READER_ROM = {"name": "885a01.bin", "crc": "e22d093f", "size": 0x80000,
              "sha1": "927f62f63b5caa7899392decacd12fea0e6fdbea", "set": "k573mcr"}
READER_SETS = ("ddr3ma", "ddr3mj", "ddr3mk", "ddr3mka", "ddr3mp", "ddr4m", "ddr4mj",
               "ddr4mp", "ddr4mps", "ddr4ms", "ddr4msj", "ddr5m", "ddrextrm", "ddrmax",
               "ddrmax2")


def stage_reader_rom(src, out, dry, log):
    """885a01.bin for the titles with a card reader. Not finding it is not an error:
    the games run without it, just with no memory cards."""
    try:
        data = src.rom(READER_ROM)
    except Fail:
        log.append("885a01.bin: not found (only needed for memory cards; it is in MAME's "
                   "ddr3m*/ddr4m*/ddr5m/ddrmax* zips, or k573mcr.zip)")
        return False
    put(out, READER_ROM["name"], data, dry, log)
    return True


# ---- the MP3 decoder: a second Main binary, chosen per core by MiSTer.ini ----
# Main_MiSTer user_io.cpp (user_io_init): after the core is loaded and the INI parsed,
#     const char *main = getFullPath(cfg.main);
#     if (strcasecmp(main, getappname()) && FileExists(main)) app_restart(path, xml, main);
# cfg.main defaults to "MiSTer" (cfg.cpp), so every other core -- and the menu --
# switches back to the stock binary. The INI section that applies is matched against
# the core NAME, not the .rbf file name (cfg.cpp ini_get_section): for this core that
# is the launchers' <setname> "System573" (or "PSX", the CONF_STR name Main needs for
# its PSX disc handling). So the section is [System573]; [Konami_System_573] would
# never match.
MP3_MAIN = "MiSTer_System573"
MP3_SECTION = "System573"


def ini_add_main(path, dry, log):
    """Give `path` a [System573] section with main=MiSTer_System573. Idempotent;
    keeps a one-time backup (<name>.bak573). Line endings are preserved."""
    exists = os.path.exists(path)
    raw = open(path, "rb").read() if exists else b""
    text = raw.decode("utf-8", errors="surrogateescape")
    nl = "\r\n" if "\r\n" in text else "\n"
    lines = text.splitlines()
    want = f"main={MP3_MAIN}"
    start = None
    for i, ln in enumerate(lines):
        if ln.strip().lower() == f"[{MP3_SECTION.lower()}]":
            start = i
            break
    if start is None:
        new = lines + ([""] if lines and lines[-1].strip() else []) + [f"[{MP3_SECTION}]", want]
        what = f"added [{MP3_SECTION}] {want}"
    else:
        end = len(lines)
        for j in range(start + 1, len(lines)):
            if lines[j].lstrip().startswith("["):
                end = j
                break
        body = lines[start + 1:end]
        keyed = [k for k, ln in enumerate(body) if ln.split("=", 1)[0].strip().lower() == "main"]
        if keyed and body[keyed[0]].strip() == want and len(keyed) == 1:
            log.append(f"{os.path.basename(path)}: already has [{MP3_SECTION}] {want}")
            return
        body = [ln for k, ln in enumerate(body) if k not in keyed]
        new = lines[:start + 1] + [want] + body + lines[end:]
        what = f"set {want} in its [{MP3_SECTION}] section"
    if dry:
        log.append(f"{os.path.basename(path)}: would have {what}")
        return
    bak = path + ".bak573"
    if exists and not os.path.exists(bak):
        open(bak, "wb").write(raw)
    open(path, "wb").write((nl.join(new) + nl).encode("utf-8", errors="surrogateescape"))
    log.append(f"{os.path.basename(path)}: {what}" + (f" (backup: {os.path.basename(bak)})" if exists else " (new file)"))


def install_mp3(root, binary, dry):
    root = os.path.normpath(root)
    if os.path.basename(root).lower() == "system573" and os.path.basename(os.path.dirname(root)).lower() == "games":
        root = os.path.dirname(os.path.dirname(root))
    if not os.path.isfile(binary):
        sys.exit(f"no {MP3_MAIN} binary at {binary} (pass --mp3-binary PATH)")
    if open(binary, "rb").read(4) != b"\x7fELF":
        sys.exit(f"{binary} is not an ARM executable")
    if not (os.path.isdir(os.path.join(root, "_Arcade")) or os.path.isfile(os.path.join(root, "MiSTer"))):
        sys.exit(f"{root} does not look like a MiSTer SD card or USB root (no MiSTer or _Arcade)")
    log = []
    dst = os.path.join(root, MP3_MAIN)
    if not dry:
        tmp = dst + ".tmp"
        with open(binary, "rb") as f, open(tmp, "wb") as g:
            g.write(f.read())
        os.replace(tmp, dst)
    log.append(f"{MP3_MAIN}: {'would be ' if dry else ''}copied to {root}")
    inis = [os.path.join(root, "MiSTer.ini")]
    inis += sorted(os.path.join(root, n) for n in os.listdir(root)
                   if n.lower().startswith("mister_") and n.lower().endswith(".ini"))
    for ini in inis:
        ini_add_main(ini, dry, log)
    say(f"Music decoder for System 573 in {root}{'  (dry run)' if dry else ''}:")
    for line in log:
        say("    " + line)
    say("The stock MiSTer binary is not touched; Main switches to MiSTer_System573 only while")
    say("a System 573 launcher is running, and back for every other core and the menu.")
    return 0


def resolve_out(out):
    base = os.path.basename(os.path.normpath(out)).lower()
    if base == "system573":
        return out
    if base == "games":
        return os.path.join(out, "System573")
    if os.path.isdir(os.path.join(out, "games")) or os.path.isdir(os.path.join(out, "_Arcade")) \
            or os.path.isdir(os.path.join(out, "_Console")):
        return os.path.join(out, "games", "System573")
    return out


def main():
    ap = argparse.ArgumentParser(description="Stage System 573 titles for the MiSTer core from MAME romsets.")
    ap.add_argument("roms", nargs="?", help="folder with your MAME System 573 romsets (.zip) and discs (.chd)")
    ap.add_argument("out", nargs="?", help="SD card / USB root, or its games/System573 folder")
    ap.add_argument("--only", help="comma-separated MAME set names (e.g. ddr3mj,ddrmax)")
    ap.add_argument("--list", action="store_true", help="show what can be staged; write nothing")
    ap.add_argument("--dry-run", action="store_true", help="say what would be written; write nothing")
    ap.add_argument("--force", action="store_true", help="rebuild disc files even if present (never touches .sav)")
    ap.add_argument("--blank-saves", metavar="OUT",
                    help="write just the empty .sav file of every title into OUT (no romsets needed)")
    ap.add_argument("--install-mp3", metavar="ROOT",
                    help="copy MiSTer_System573 to ROOT and add [System573] main=MiSTer_System573 to its INI(s)")
    ap.add_argument("--mp3-binary", metavar="PATH",
                    default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "MiSTer_System573"),
                    help="the MiSTer_System573 file to install (default: next to this script)")
    ap.add_argument("--verify-chd", action="store_true",
                    help="also decode each copied disc and check it against its SHA1 (slow)")
    a = ap.parse_args()

    if a.install_mp3:
        return install_mp3(a.install_mp3, a.mp3_binary, a.dry_run)
    if a.blank_saves:
        out = resolve_out(a.blank_saves)
        os.makedirs(out, exist_ok=True)
        log = []
        for t in TABLE["titles"]:
            for name, r in sorted(t["files"].items()):
                if r["make"] == "sav":
                    make_sav(out, name, r, False, log)
        say(f"Blank saves in {out}:")
        for line in log:
            say("    " + line)
        return 0
    if not a.roms:
        ap.error("the ROMS folder is required")
    if not os.path.isdir(a.roms):
        sys.exit(f"no such folder: {a.roms}")
    titles = TABLE["titles"]
    if a.only:
        want = [s.strip() for s in a.only.split(",") if s.strip()]
        known = {t["set"] for t in titles}
        bad = [s for s in want if s not in known]
        if bad:
            sys.exit("unknown set(s): " + ", ".join(bad) + "\nknown: " + ", ".join(sorted(known)))
        titles = [t for t in titles if t["set"] in want]

    say(f"Searching {a.roms} ...")
    src = Sources(a.roms)
    say(f"  {sum(len(v) for v in src.zips.values())} zip members, {len(src.chds)} CHDs")
    ready, missing = [], []
    for t in titles:
        m = check(src, t)
        (missing if m else ready).append((t, m))

    say("")
    say(f"Can stage ({len(ready)}):")
    for t, _ in ready:
        say(f"  {t['set']:<9} {t['launchers'][0][:-4]}")
    if missing:
        say(f"Missing files ({len(missing)}):")
        for t, m in missing:
            say(f"  {t['set']:<9} {t['launchers'][0][:-4]}")
            say(f"            needs: {', '.join(m)}")
        if src.sevenz:
            say("  (some .7z files were found: this tool reads .zip only -- re-pack them as .zip)")
    reader = [t for t, _ in ready if t["set"] in READER_SETS]
    if reader:
        say("Memory card reader boot ROM (885a01.bin): "
            + ("found" if src.has_rom(READER_ROM) else "not found -- only needed for memory cards"))
    if a.list or not a.out:
        if not a.out and not a.list:
            say("\n(no output folder given -- nothing written)")
        return 0

    out = resolve_out(a.out)
    say(f"\nStaging into {out}{'  (dry run)' if a.dry_run else ''}")
    if not a.dry_run:
        os.makedirs(out, exist_ok=True)
    failed = []
    for t, _ in ready:
        log = []
        say(f"\n{t['set']}: {t['title']}")
        try:
            stage(src, t, out, a.dry_run, a.force, log)
            if a.verify_chd and not a.dry_run:
                for name, r in t["files"].items():
                    if r["make"] == "chd":
                        c = Chd(os.path.join(out, name))
                        try:
                            ok = c.verify_all(lambda n, k: progress(f"    verifying {name}: {n * 100 // k:3d}%"))
                        finally:
                            c.close()
                        progress_done()
                        log.append(f"{name}: {'verified against its SHA1' if ok else 'decoded (no SHA1 to check)'}")
        except Fail as e:
            log.append(f"FAILED: {e}")
            failed.append(t["set"])
        for line in log:
            say("    " + line)
    if reader:
        log = []
        say("\nMemory card reader (DDR titles with a card reader)")
        stage_reader_rom(src, out, a.dry_run, log)
        for line in log:
            say("    " + line)
    say("")
    say(f"Done: {len(ready) - len(failed)} staged, {len(failed)} failed, {len(missing)} missing files.")
    say("After an install, wait for the \"Flash saved\" message before switching the MiSTer off.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
