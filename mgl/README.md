# Launchers

One `.mgl` per title. Copy them to the SD card's `_Arcade` folder, next to the `.mra`
files (any folder works -- Main lists `.mgl` files wherever it lists cores, and an
`.mgl` loads the same way from any of them). Each one loads
`_Console/Konami_System_573.rbf` with that title's BIOS, cassette, disc and save file,
which it expects under `games/System573/`, named by MAME romset (`ddr3mj.chd`,
`ddr3mj.u1`, ...). `tools/stage_573.py` puts those files in place and writes these
launchers.

File names are `<title> (<region>, <year>).mgl`, taken from the romset's `GAME()` line
in MAME's `ksys573.cpp` by `tools/s573_names.py`: MAME's title without its version
code, the region from the version code's first letter (J Japan, A Asia, E Europe,
U USA, K Korea), and MAME's year. When two sets in the driver would come out with the
same name, both also carry their version code (`..., Ver. JCA)`).

| launcher | MAME romset |
|---|---|
| Dance Dance Revolution 3rd Mix (Asia, 1999) | `ddr3ma` |
| Dance Dance Revolution 3rd Mix (Japan, 1999) | `ddr3mj` |
| Dance Dance Revolution 3rd Mix - Ver.Korea (Korea, 2000) | `ddr3mka` |
| Dance Dance Revolution 3rd Mix - Ver.Korea2 (Korea, 2000) | `ddr3mk` |
| Dance Dance Revolution 3rd Mix Plus (Japan, 2000) | `ddr3mp` |
| Dance Dance Revolution 4th Mix (Asia, 2000) | `ddr4m` |
| Dance Dance Revolution 4th Mix (Japan, 2000) | `ddr4mj` |
| Dance Dance Revolution 4th Mix Plus (Japan, 2000) | `ddr4mp` |
| Dance Dance Revolution 4th Mix Plus Solo (Japan, 2000) | `ddr4mps` |
| Dance Dance Revolution 4th Mix Solo (Asia, 2000) | `ddr4ms` |
| Dance Dance Revolution 4th Mix Solo (Japan, 2000) | `ddr4msj` |
| Dance Dance Revolution 5th Mix (Japan, 2001) | `ddr5m` |
| Dance Dance Revolution Extreme (Japan, 2002) | `ddrextrm` |
| Dance Dance Revolution Solo 2000 (Asia, 1999) | `ddrs2k` |
| Dance Dance Revolution Solo Bass Mix (Japan, 1999) | `ddrsbm` |
| Dance Dance Revolution USA (USA, 2000) | `ddrusa` |
| Dancing Stage Euro Mix (Europe, 2000) | `dsem` |
| Dancing Stage Euro Mix 2 (Europe, 2002) | `dsem2` |
| Dancing Stage Featuring Disney's Rave (Japan, 2000) | `dsfdr` |
| Dancing Stage featuring Dreams Come True (Japan, 1999, Ver. JCA) | `dsfdct` |
| DDRMAX - Dance Dance Revolution 6th Mix (Japan, 2001) | `ddrmax` |
| DDRMAX2 - Dance Dance Revolution 7th Mix (Japan, 2002) | `ddrmax2` |
| Gacha Gachamp (Japan, 1999) | `gchgchmp` |
| Hyper Bishi Bashi Champ (Europe, 1998) | `hyperbbc` |
| Hyper Bishi Bashi Champ - 2 Player (Japan, 1999) [Install] | `hypbbc2p` |
| Hyper Bishi Bashi Champ - 2 Player (Japan, 1999) | `hypbbc2p` |
| Konami 80's AC Special (Europe, 1998) | `konam80s` |

Two-cassette DDR titles have ONE launcher: the OSD "573 Cassette" option (Auto
follows Boot Device) picks the install or the game cassette. Hyper Bishi Bashi Champ
- 2 Player still has a separate `[Install]` launcher for its CD install.

`dsem.cue.example` is the cue sheet for Dancing Stage Euro Mix, whose disc is
MODE1/2048 and ships as cue + raw-2352 bin rather than a CHD.
