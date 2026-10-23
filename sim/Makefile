# System 573 core - RTL unit test runner (Icarus Verilog)
#
#   make            run every testbench
#   make ds2401     run a single module's testbench
#   make clean

IV      := iverilog
VVP     := vvp
IVFLAGS := -g2005-sv -Wall
RTL     := ../rtl
BUILD   := build

TESTS := s573_cfg_trailer s573_flash_pccard1 573in1_ide 573in1_rtc 573in1_cart k573dio_cpld x76f041_konami gn845pwbb s573_sav_mount_order s573_seccart_dual s573_tk_nv s573_press_hold s573_prof s573_prof_gpu s573_prof_pc s573_cass_nv watchdog adc0834 m48t58 s573_nvram_loader s573_nvram_saver s573_flash_saver s573_flash_saver_card s573_ch4_arb s573_seccart_loader ds2401 adc0838 x76f100 x76f100_hypbbc2p x76f041 crc16 zs01 zs01_golden zs01_rtr zs01_detect zs01_cmd sectrace_arm k573dio k573dio_ram s573_ddram_arb s573_mp3_pcm s573_audio_mix s573_pcm_ring s573_mp3_credit s573_hps_ext s573_mp3_path s573_dio_mux_seam dio_i2c dio_mp3_reload k573_mp3dec k573_mp3stream k573_mp3stream_engate atapi atapi_settle atapi_inquiry irqdeliver s573_flash s573_flash_sdram s573_flash_erase s573_flash_pccard s573_flash_image flash_nor s573_seccart s573_bus s573_io system573_top drivecheck s573_cdimg s573_cdimg_ack s573_cdtoc atapi_cdread cdboot

# `make` with no target must run the whole suite: the secdata/cddata helper
# targets were added ABOVE `all`, silently turning `make -C sim` into a no-op
# (first-target-is-default). Pin the default goal explicitly.
.DEFAULT_GOAL := all

# Per-test RTL dependencies
SRC_watchdog      := $(RTL)/watchdog.v
SRC_adc0834       := $(RTL)/adc0834.v
SRC_adc0838       := $(RTL)/adc0838.v
SRC_m48t58        := $(RTL)/m48t58.v
SRC_s573_nvram_loader := $(RTL)/s573_nvram_loader.v $(RTL)/m48t58.v
SRC_s573_nvram_saver  := $(RTL)/s573_nvram_saver.v $(RTL)/s573_nvram_loader.v $(RTL)/m48t58.v
SRC_s573_flash_saver  := $(RTL)/s573_flash_saver.v
SRC_s573_sav_mount_order := $(RTL)/s573_flash_saver.v
SRC_s573_flash_saver_card := $(RTL)/s573_flash_saver.v
SRC_s573_prof     := $(RTL)/s573_prof.v
SRC_s573_prof_gpu := $(RTL)/s573_prof_gpu.v
SRC_s573_prof_pc  := $(RTL)/s573_prof_pc.v
SRC_s573_press_hold := $(RTL)/s573_press_hold.v
SRC_s573_cass_nv  := $(RTL)/s573_flash_saver.v $(RTL)/s573_cass_nv.v $(RTL)/s573_seccart.v $(RTL)/x76f100.v $(RTL)/x76f041.v $(RTL)/zs01.v $(RTL)/ds2401.v
SRC_s573_tk_nv    := $(RTL)/s573_flash_saver.v $(RTL)/s573_tk_nv.v $(RTL)/s573_cass_nv.v $(RTL)/m48t58.v $(RTL)/s573_nvram_loader.v
SRC_s573_ch4_arb      := $(RTL)/s573_ch4_arb.v
SRC_s573_seccart_loader := $(RTL)/s573_seccart_loader.v
SRC_ds2401        := $(RTL)/ds2401.v
SRC_x76f100       := $(RTL)/x76f100.v
SRC_x76f100_hypbbc2p := $(RTL)/x76f100.v
SRC_x76f041       := $(RTL)/x76f041.v
SRC_x76f041_konami := $(RTL)/x76f041.v
SRC_crc16         := $(RTL)/crc16.v
SRC_zs01          := $(RTL)/zs01.v
SRC_zs01_golden   := $(RTL)/zs01.v
SRC_zs01_detect   := $(RTL)/system573_top.v $(RTL)/s573_prof.v $(RTL)/s573_bus.v $(RTL)/s573_io.v $(RTL)/gn845pwbb.v \
                     $(RTL)/watchdog.v $(RTL)/adc0834.v $(RTL)/m48t58.v $(RTL)/ds2401.v \
                     $(RTL)/s573_flash.v $(RTL)/flash_nor.v $(RTL)/s573_seccart.v $(RTL)/s573_sectrace.v $(RTL)/x76f100.v $(RTL)/x76f041.v $(RTL)/zs01.v \
                     $(RTL)/atapi.v $(RTL)/s573_cdimg.v $(RTL)/s573_cdtoc.v $(RTL)/k573dio.v $(RTL)/k573dio_cpld.v $(RTL)/k573_mp3stream.v $(RTL)/k573_mp3dec.v $(RTL)/mas3507d_i2c.v
SRC_sectrace_arm  := $(RTL)/s573_sectrace.v
SRC_573in1_rtc    := $(RTL)/m48t58.v
SRC_573in1_ide    := $(RTL)/atapi.v
SRC_573in1_cart   := $(RTL)/s573_seccart.v $(RTL)/x76f100.v $(RTL)/x76f041.v $(RTL)/zs01.v $(RTL)/ds2401.v
SRC_zs01_rtr      := $(RTL)/s573_seccart.v $(RTL)/x76f100.v $(RTL)/x76f041.v $(RTL)/zs01.v $(RTL)/ds2401.v
SRC_zs01_cmd      := $(RTL)/s573_seccart.v $(RTL)/x76f100.v $(RTL)/x76f041.v $(RTL)/zs01.v $(RTL)/ds2401.v
SRC_k573dio       := $(RTL)/k573dio.v $(RTL)/k573dio_cpld.v $(RTL)/ds2401.v $(RTL)/k573_mp3stream.v $(RTL)/k573_mp3dec.v $(RTL)/mas3507d_i2c.v
SRC_k573dio_cpld  := $(RTL)/k573dio.v $(RTL)/k573dio_cpld.v $(RTL)/ds2401.v $(RTL)/k573_mp3stream.v $(RTL)/k573_mp3dec.v $(RTL)/mas3507d_i2c.v
SRC_k573dio_ram   := $(RTL)/k573dio.v $(RTL)/k573dio_cpld.v $(RTL)/ds2401.v $(RTL)/k573_mp3stream.v $(RTL)/k573_mp3dec.v $(RTL)/mas3507d_i2c.v
SRC_s573_ddram_arb := $(RTL)/s573_ddram_arb.v
SRC_s573_mp3_pcm  := $(RTL)/s573_mp3_pcm.v
SRC_s573_audio_mix := $(RTL)/s573_audio_mix.v
SRC_s573_pcm_ring := $(RTL)/s573_pcm_ring.v $(RTL)/s573_mp3_pcm.v
SRC_s573_mp3_credit := $(RTL)/s573_mp3_credit.v
SRC_s573_hps_ext  := $(RTL)/s573_hps_ext.v
SRC_s573_mp3_path := $(RTL)/s573_hps_ext.v $(RTL)/s573_pcm_ring.v $(RTL)/s573_mp3_pcm.v $(RTL)/s573_audio_mix.v
SRC_s573_dio_mux_seam := $(RTL)/s573_ddram_arb.v
SRC_dio_i2c       := $(RTL)/k573dio.v $(RTL)/k573dio_cpld.v $(RTL)/ds2401.v $(RTL)/k573_mp3stream.v $(RTL)/k573_mp3dec.v $(RTL)/mas3507d_i2c.v
SRC_dio_mp3_reload := $(RTL)/k573dio.v $(RTL)/k573dio_cpld.v $(RTL)/ds2401.v $(RTL)/k573_mp3stream.v $(RTL)/k573_mp3dec.v $(RTL)/mas3507d_i2c.v
SRC_k573_mp3dec   := $(RTL)/k573_mp3dec.v
SRC_k573_mp3stream := $(RTL)/k573_mp3stream.v $(RTL)/k573_mp3dec.v
SRC_k573_mp3stream_engate := $(RTL)/k573_mp3stream.v $(RTL)/k573_mp3dec.v
SRC_atapi         := $(RTL)/atapi.v
SRC_atapi_settle  := $(RTL)/atapi.v
SRC_irqdeliver    := $(RTL)/atapi.v
SRC_s573_cdimg    := $(RTL)/s573_cdimg.v
SRC_s573_cdimg_ack := $(RTL)/s573_cdimg.v
SRC_s573_cdtoc    := $(RTL)/s573_cdtoc.v
SRC_atapi_cdread  := $(RTL)/atapi.v $(RTL)/s573_cdimg.v
SRC_cdboot        := $(RTL)/atapi.v $(RTL)/s573_cdimg.v $(RTL)/s573_cdtoc.v
SRC_gate5_replay  := $(RTL)/atapi.v $(RTL)/s573_cdimg.v $(RTL)/s573_cdtoc.v
SRC_s573_flash    := $(RTL)/s573_flash.v $(RTL)/flash_nor.v
SRC_s573_flash_sdram := $(RTL)/s573_flash.v $(RTL)/flash_nor.v
SRC_s573_flash_erase := $(RTL)/s573_flash.v $(RTL)/flash_nor.v
SRC_s573_flash_pccard := $(RTL)/s573_flash.v $(RTL)/flash_nor.v
SRC_s573_flash_pccard1 := $(RTL)/s573_flash.v $(RTL)/flash_nor.v
SRC_s573_cfg_trailer := $(RTL)/s573_seccart_loader.v $(RTL)/s573_cfg_trailer.v $(RTL)/s573_cass_pack.v
SRC_s573_flash_image := $(RTL)/s573_flash.v $(RTL)/flash_nor.v
SRC_flash_nor     := $(RTL)/flash_nor.v
SRC_s573_seccart  := $(RTL)/s573_seccart.v $(RTL)/x76f100.v $(RTL)/x76f041.v $(RTL)/zs01.v $(RTL)/ds2401.v
SRC_s573_seccart_dual := $(RTL)/s573_cass_pack.v $(RTL)/s573_seccart.v $(RTL)/x76f100.v $(RTL)/x76f041.v $(RTL)/zs01.v $(RTL)/ds2401.v
SRC_s573_bus      := $(RTL)/s573_bus.v
SRC_s573_io       := $(RTL)/s573_io.v
SRC_gn845pwbb     := $(RTL)/gn845pwbb.v
SRC_system573_top := $(RTL)/system573_top.v $(RTL)/s573_prof.v $(RTL)/s573_bus.v $(RTL)/s573_io.v $(RTL)/gn845pwbb.v \
                     $(RTL)/watchdog.v $(RTL)/adc0834.v $(RTL)/m48t58.v $(RTL)/ds2401.v \
                     $(RTL)/s573_flash.v $(RTL)/flash_nor.v $(RTL)/s573_seccart.v $(RTL)/s573_sectrace.v $(RTL)/x76f100.v $(RTL)/x76f041.v $(RTL)/zs01.v \
                     $(RTL)/atapi.v $(RTL)/s573_cdimg.v $(RTL)/s573_cdtoc.v $(RTL)/k573dio.v $(RTL)/k573dio_cpld.v $(RTL)/k573_mp3stream.v $(RTL)/k573_mp3dec.v $(RTL)/mas3507d_i2c.v
SRC_drivecheck     := $(SRC_system573_top)
# (must come AFTER SRC_system573_top: := expands immediately)
SRC_atapi_inquiry  := $(SRC_system573_top)

.PHONY: all clean secdata cddata gate5_replay $(TESTS)

# Derive the (gitignored, copyrighted) pnchmn2 security-cart $readmemh fixtures from
# the dump before the seccart test. No-op (test self-skips Part 2) if the dump is
# absent. Order-only so it always runs first for s573_seccart.
secdata:
	@bash gen_secdata.sh >/dev/null 2>&1 || true   # bash: the script uses pipefail (dash rejects it)
s573_seccart: secdata
s573_seccart_dual: secdata
s573_cass_nv: secdata
zs01: secdata
zs01_golden: secdata
zs01_rtr: secdata
zs01_cmd: secdata
zs01_detect: secdata
x76f041_konami: secdata
573in1_cart: secdata

# Derive the (gitignored, copyrighted) CD-image $readmemh sector fixture from the
# hypbbc2p CHD before the end-to-end ATAPI read test. No-op (test self-skips to a
# synthetic ISO9660 sector) if the dump / chdman is absent.
cddata:
	@bash gen_cddata.sh >/dev/null 2>&1 || true   # bash: pipefail
atapi_cdread: cddata

# Derive the Digital I/O bitstream fixture from a 573in1 checkout (data/fpga.bit)
# before the CPLD upload bench. No-op (bench runs synthetic streams only) if absent.
fpgadata:
	@bash gen_fpgadata.sh >/dev/null 2>&1 || true   # bash: pipefail
k573dio_cpld: fpgadata

all:
	@fail=0; \
	for t in $(TESTS); do \
	  $(MAKE) -s $$t || fail=1; \
	done; \
	echo "-----------------------------------------"; \
	if [ $$fail -eq 0 ]; then echo "ALL TESTS PASSED"; \
	else echo "SOME TESTS FAILED"; exit 1; fi

# Optional `make S573_FLASH_OLD_AND=1 s573_flash_sdram` compiles s573_flash.v with
# -DS573_FLASH_OLD_AND, restoring the buggy faithful-NOR AND on the SDRAM-backed
# program path. The FIX-2 red/green test (tb_s573_flash_sdram #11) is RED under that
# define and GREEN with the default (overwrite) build -- proof the test exercises the
# fix without hand-reverting RTL. Default builds (and `all`) never set it.
# Optional `make S573_CH4_NOARB=1 s573_ch4_arb` compiles tb_s573_ch4_arb.v with
# -DS573_CH4_NOARB, swapping the arbiter for the old bare ch4 mux. That TB is RED
# under the define (the SAVE read samples the wrong offset at service time) and
# GREEN by default (the arbiter holds the address) -- proof the test exercises the
# fix without hand-reverting RTL. Default builds (and `all`) never set it.
# Optional `make ATAPI_IDENT_NOSETTLE=1 atapi_settle` compiles atapi.v with
# -DATAPI_IDENT_NOSETTLE, restoring the buggy instant IDENTIFY data-ready IRQ (raised in
# the same cycle as the 0xA1 command write -- the ddrsbm BOOT-CHECK race). tb_atapi_settle
# is RED under the define (the IRQ fires with no BSY settle) and GREEN by default (the
# S_PREP settle holds BSY first) -- proof the test exercises the fix without hand-reverting
# RTL. Default builds (and `all`) never set it.
# Optional `make DIO_I2C_STUB=1 dio_i2c` compiles k573dio.v with -DDIO_I2C_STUB,
# removing the 0xac MAS3507D I2C register (the pre-fix stub whose missing SCL echo
# froze ddrsbm's BOOT CHECK). tb_dio_i2c is RED under the define (SCL echo never
# comes back) and GREEN by default (the mas3507d_i2c slave ACKs the boot
# transactions) -- proof the test exercises the fix without hand-reverting RTL.
# Default builds (and `all`) never set it.
# Optional `make S573_FLASH_ERASE_NOOP=1 s573_flash_erase` compiles s573_flash.v with
# -DS573_FLASH_ERASE_NOOP, restoring the pre-fix NO-OP erase on the SDRAM-backed path
# (command decoded, action dropped -- the ddrsbm installer's ERASE TIMEOUT).
# tb_s573_flash_erase is RED under the define (no busy status, the DQ7 data-poll
# times out, nothing reads 0xFFFF) and GREEN by default (per-bank busy status + the
# background 0xFF walker really blanks the SDRAM backing) -- proof the test exercises
# the fix without hand-reverting RTL. Default builds (and `all`) never set it.
# Optional `make DIO_RAM_STUB=1 k573dio_ram` compiles k573dio.v with
# -DDIO_RAM_STUB, forcing the pre-fix 8 KB aliasing inline DRAM array in place
# of the DDR3-backed 32 MiB store (the ddrsbm POST "MEMORY CHECK 22G/22H/22J
# BAD" root cause: the 3x 8 MB chip regions all alias mod 8 KB). tb_k573dio_ram
# is RED under the define (the region-distinctness pattern collides) and GREEN
# by default -- proof the test exercises the fix without hand-reverting RTL.
# Default builds (and `all`) never set it.
# Optional `make MP3_UNPACED=1 k573_mp3stream` compiles k573_mp3stream.v with
# -DMP3_UNPACED, restoring the pre-fix streamer: it ignores out_ready (floods the
# sink instead of pacing to the MAS3507D DEMAND) and ignores reload (one-shot park
# that never resumes on an mp3_end extension). tb_k573_mp3stream is RED under the
# define (a paced sink loses bytes; the phase-2 extension never re-streams) and
# GREEN by default -- proof the test exercises the fix without hand-reverting RTL.
# Default builds (and `all`) never set it.
# Optional `make MP3_ENGATE_BUG=1 k573_mp3stream_engate` compiles k573_mp3stream.v
# with -DMP3_ENGATE_BUG, restoring the pre-fix enable gating: a bit13/14 disable
# unwinds to S_IDLE from ANY state, so a disable landing after word_stb (S_STB) but
# before cur advances (S_LO) leaves the key schedule advanced for a word the stream
# has not finished -- on resume it re-reads the same cur and re-descrambles that word
# with an already-advanced schedule (corrupt tail + one EXTRA byte, 2N not 2N-1).
# tb_k573_mp3stream_engate sweeps a pause across every cycle offset and is RED under
# the define / GREEN by default -- proof the test exercises the fix without
# hand-reverting RTL. Default builds (and `all`) never set it.
# Optional `make MP3_CREDIT_FREERUN=1 s573_mp3_credit` compiles s573_mp3_credit.v
# with -DMP3_CREDIT_FREERUN, tying out_ready HIGH instead of gating it on real
# HPS credit -- the "invent a clock" anti-pattern the pacing model forbids, which
# advances k573_mp3stream's cur (and so the game-visible 0xae bit12) at a rate
# nobody measured. tb_s573_mp3_credit is RED under the define (every release
# assertion over-counts) and GREEN by default -- proof the test exercises the
# pacing contract without hand-reverting RTL. Default builds never set it.
# Optional `make HPS_EXT_WIDE_DELTA=1 s573_hps_ext` compiles s573_hps_ext.v with
# -DHPS_EXT_WIDE_DELTA, restoring the context-widened (untruncated) cumulative-
# counter diff in the CMD_573_CTRL event path. tb_s573_hps_ext is RED under it
# (the wrap phase 0xFE->0x02 floods 260 dec_frame_sync pulses instead of 4 --
# a fabricated 0xa8 frame count) and GREEN by default -- proof the bench
# exercises wrap correctness without hand-reverting RTL. Default builds never set it.
# Optional `make MP3_RELOAD_RACE=1 dio_mp3_reload` compiles k573dio.v with
# -DMP3_RELOAD_RACE, restoring the pre-fix SAME-EDGE MP3 re-arm pulse: mp3_reload is
# combinational on the bus write while the register it updates lands non-blocking on
# that same posedge, so k573_mp3stream's `cur <= mp3_start` samples the PRE-write value
# and the stream re-arms to the PREVIOUS song's address. Only bites when a0/a2 closes
# the setup burst (any further setup write re-pulses and self-heals). tb_dio_mp3_reload
# drives the REAL k573dio bus and is RED under the define (a2-last streams the wrong
# DRAM region and runs long; a0-last never starts and the 0xae streaming bit never
# rises) and GREEN by default -- proof the test exercises the fix without hand-reverting
# RTL. Default builds (and `all`) never set it.
# Optional `make MP3_COUNTER_STUB=1 k573dio` compiles k573dio.v with
# -DMP3_COUNTER_STUB, restoring the pre-fix behaviour: the decode-counter registers
# (0xa8 frame count, 0xaa mpeg_status, 0xca/cc sample position, 0xce diff) fall back
# to reading 0. tb_k573dio is RED under the define (the counters never advance off
# the frame-sync / PCM-tick inputs) and GREEN by default -- proof the test exercises
# the counter slice without hand-reverting RTL. Default builds never set it.
# Optional `make S573_FLASH_NO_PCCARD=1 s573_flash_pccard` compiles s573_flash.v
# with -DS573_FLASH_NO_PCCARD, restoring the pre-Tier-3 bank decode in which
# PCMCIA slot 2 (banks 32-47) is permanently an EMPTY SLOT regardless of card_en.
# tb_s573_flash_pccard is RED under the define (every card read returns 0xFFFF and
# no SDRAM fill is ever requested) and GREEN by default -- proof the bench exercises
# the 32 MB Fujitsu linear-flash card decode (MAME bus/pccard/linflash.cpp +
# ksys573.cpp flashbank_map) without hand-reverting RTL. Default builds (and `all`)
# never set it.
S573_FLASH_OLD_AND ?=
# Optional `make SAVER_LIVE_NBLOCKS=1 s573_flash_saver_card` compiles
# s573_flash_saver.v with -DSAVER_LIVE_NBLOCKS, restoring the live-wire `==`
# terminal block comparison that stopped ddrusa and dsfdr booting on 2026-09-14:
# a second img_mounted[4] pulse (Main mounts config/<core>.s4 at core init, the
# .mgl then mounts the real .sav) moved the terminal count below block_cnt, the
# equality never matched, and the LOAD ran forever with `busy` high -- which emu
# ORs into the CPU reset hold, so the core loaded and the CPU never left reset.
# tb_s573_flash_saver_card test 6 is RED under the define (bench TIMEOUT, the
# simulation image of a black screen) and GREEN by default. Default builds
# (and `all`) never set it.
S573_FLASH_NO_PCCARD ?=
SAVER_LIVE_NBLOCKS ?=
S573_CH4_NOARB ?=
ATAPI_IDENT_NOSETTLE ?=
DIO_I2C_STUB ?=
S573_FLASH_ERASE_NOOP ?=
DIO_RAM_STUB ?=
MP3_UNPACED ?=
MP3_ENGATE_BUG ?=
MP3_CREDIT_FREERUN ?=
MP3_COUNTER_STUB ?=
MP3_RELOAD_RACE ?=
PCM_FAKE_UNDERRUN ?=
# Optional `make PCM_NO_STOP_FLUSH=1 s573_mp3_pcm` compiles s573_mp3_pcm.v with
# -DPCM_NO_STOP_FLUSH, restoring the pre-2026-09-16 elastic buffer that keeps its
# decoded samples across a stream stop (the old song's tail played at the start of
# the next one: ddrextrm song-select pops). tb_s573_mp3_pcm phase G is RED under the
# define and GREEN by default. MAME reference: mas3507d.cpp reset_playback().
PCM_NO_STOP_FLUSH ?=
# Optional `make PCM_NO_PAUSE_HOLD=1 s573_mp3_pcm`: the drain ignores the core pause, i.e.
# the pre-2026-10-02 core whose music played on while the OSD paused the game.
# tb_s573_mp3_pcm phase H is RED under the define and GREEN by default.
PCM_NO_PAUSE_HOLD ?=
# Optional `make CASS_NV_NO_RESTORE=1 s573_cass_nv` compiles s573_cass_nv.v with
# -DCASS_NV_NO_RESTORE: a LOAD never applies the saved ZS01 cassette block, i.e. the
# pre-2026-09-16 core in which the .mgl's pristine .u1 always wins and an installed
# ddrextrm stops with ERROR 175 after a power cycle. tb_s573_cass_nv test 3 is RED
# under the define and GREEN by default. MAME reference: zs01.cpp nvram_read/nvram_write.
CASS_NV_NO_RESTORE ?=
# Optional `make TK_NV_NO_RESTORE=1 s573_tk_nv` compiles s573_tk_nv.v with
# -DTK_NV_NO_RESTORE: a LOAD never applies the saved M48T58 image, i.e. the
# pre-2026-09-28 core in which an .mgl launch always boots a blank timekeeper and
# ddrextrm shows NOTE 605 "RTC-RAM cleared" every time. tb_s573_tk_nv test 3 is RED
# under the define and GREEN by default. MAME reference: timekpr.cpp (NVRAM device).
TK_NV_NO_RESTORE ?=
# Optional `make SAVER_UNGATED_BUFF_WR=1 s573_tk_nv` compiles s573_flash_saver.v with
# -DSAVER_UNGATED_BUFF_WR: the staging buffer captures hps_io's shared SD stream for
# EVERY slot, not just ours, i.e. the pre-2026-09-28 core in which a CD sector Main
# streamed to slot 1 between our fill and its read landed in the .sav (PCCARD2 after a
# save during the attract loop). tb_s573_tk_nv (foreign_sector before every service)
# is RED under the define and GREEN by default.
SAVER_UNGATED_BUFF_WR ?=
# MGL_SAV_LAST=1: tb_s573_sav_mount_order runs the launcher order shipped until
# 2026-09-29 (the .sav mounted after the downloads) in the scenarios the fix is for.
# The boot-time flash restore then starts on Main's slot-4 bookmark (the previous
# title's .sav) and the image comes out mixed -- RED under the define, GREEN by default
# (docs/2026-09-29-sav-mount-order.md).
MGL_SAV_LAST ?=
HPS_EXT_WIDE_DELTA ?=
DEFS :=
ifeq ($(HPS_EXT_WIDE_DELTA),1)
DEFS += -DHPS_EXT_WIDE_DELTA
endif
ifeq ($(MP3_UNPACED),1)
DEFS += -DMP3_UNPACED
endif
ifeq ($(MP3_ENGATE_BUG),1)
DEFS += -DMP3_ENGATE_BUG
endif
ifeq ($(MP3_CREDIT_FREERUN),1)
DEFS += -DMP3_CREDIT_FREERUN
endif
ifeq ($(PCM_FAKE_UNDERRUN),1)
DEFS += -DPCM_FAKE_UNDERRUN
endif
ifeq ($(CASS_NV_NO_RESTORE),1)
DEFS += -DCASS_NV_NO_RESTORE
endif
ifeq ($(TK_NV_NO_RESTORE),1)
DEFS += -DTK_NV_NO_RESTORE
endif
ifeq ($(SAVER_UNGATED_BUFF_WR),1)
DEFS += -DSAVER_UNGATED_BUFF_WR
endif
ifeq ($(MGL_SAV_LAST),1)
DEFS += -DMGL_SAV_LAST
endif
ifeq ($(PCM_NO_PAUSE_HOLD),1)
DEFS += -DPCM_NO_PAUSE_HOLD
endif
ifeq ($(PCM_NO_STOP_FLUSH),1)
DEFS += -DPCM_NO_STOP_FLUSH
endif
ifeq ($(MP3_COUNTER_STUB),1)
DEFS += -DMP3_COUNTER_STUB
endif
ifeq ($(MP3_RELOAD_RACE),1)
DEFS += -DMP3_RELOAD_RACE
endif
ifeq ($(DIO_RAM_STUB),1)
DEFS += -DDIO_RAM_STUB
endif
ifeq ($(S573_FLASH_OLD_AND),1)
DEFS += -DS573_FLASH_OLD_AND
endif
ifeq ($(S573_FLASH_NO_PCCARD),1)
DEFS += -DS573_FLASH_NO_PCCARD
endif
ifeq ($(SAVER_LIVE_NBLOCKS),1)
DEFS += -DSAVER_LIVE_NBLOCKS
endif
ifeq ($(S573_FLASH_ERASE_NOOP),1)
DEFS += -DS573_FLASH_ERASE_NOOP
endif
ifeq ($(S573_CH4_NOARB),1)
DEFS += -DS573_CH4_NOARB
endif
ifeq ($(ATAPI_IDENT_NOSETTLE),1)
DEFS += -DATAPI_IDENT_NOSETTLE
endif
ifeq ($(DIO_I2C_STUB),1)
DEFS += -DDIO_I2C_STUB
endif

# Template: compile tb_<name>.v + SRC_<name>, run, require "RESULT: PASS".
# A compile FAILURE must fail the test. It used to not: iverilog's exit status was
# discarded, so when a bench stopped compiling the PREVIOUS build's .vvp was still
# on disk and vvp happily ran THAT, printing "RESULT: PASS" from stale code. A
# green suite that is not testing the current source is the exact failure class
# this project spends its time hunting, so: delete the image first, and abort on a
# non-zero compile.
define RUN_TEST
$(1): | $(BUILD)
	@rm -f $(BUILD)/$(1).vvp; \
	if ! $(IV) $(IVFLAGS) $(DEFS) -o $(BUILD)/$(1).vvp $(SRC_$(1)) tb_$(1).v 2> $(BUILD)/$(1).log; then \
	  echo "  FAIL  $(1)  (COMPILE ERROR)"; sed 's/^/        /' $(BUILD)/$(1).log; exit 1; \
	fi; \
	out=$$$$($(VVP) $(BUILD)/$(1).vvp 2>> $(BUILD)/$(1).log); \
	echo "$$$$out" | grep -q "RESULT: PASS"; \
	if [ $$$$? -eq 0 ]; then \
	  echo "  PASS  $(1)"; \
	else \
	  echo "  FAIL  $(1)"; echo "$$$$out" | sed 's/^/        /'; \
	  echo "        (compile log: $(BUILD)/$(1).log)"; exit 1; \
	fi
endef
$(foreach t,$(TESTS),$(eval $(call RUN_TEST,$(t))))

# gate5_replay -- the gate-5 CDROM-timeout regression bench (sim/tb_gate5_replay.v).
# It drove the gate-5 fix RED->GREEN (RED against the pre-fix RTL; GREEN now the fix
# landed: ide_rst wired -> s573_cdimg + sec_req accepted outside S_IDLE + STOP UNIT
# (0x1b) answered GOOD). Kept OUT of TESTS so `make -C sim` stays the 38-test suite;
# run it explicitly as the standalone gate-5 guard:
#   make -C sim gate5_replay   -- GREEN
$(eval $(call RUN_TEST,gate5_replay))


$(BUILD):
	@mkdir -p $(BUILD)

clean:
	@rm -rf $(BUILD)
