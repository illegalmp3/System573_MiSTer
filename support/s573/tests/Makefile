# Host tests for the 573 HPS MP3 service core. No cross toolchain needed.
CC      ?= gcc
CFLAGS  ?= -std=gnu99 -Wall -Wextra -Wno-unused-parameter -O1 -g
SRC      = test_s573mp3_core.c ../s573mp3_core.c ../s573_descramble.c
MUTS     = S573_MUT_WROTE_MASK15 S573_MUT_FREE_MASK15 S573_MUT_APPLY_NOFLUSH \
           S573_MUT_TAIL_STRICT S573_MUT_NO_WP_GATE S573_MUT_HOLD_SKIP S573_MUT_KEEP_TAIL

all: test test_logdir
	./test
	./test_logdir

test_logdir: test_s573_logdir.c ../s573_logdir.c ../s573_logdir.h
	$(CC) $(CFLAGS) test_s573_logdir.c ../s573_logdir.c -o test_logdir

test: $(SRC) ../s573mp3_core.h ../s573_descramble.h
	$(CC) $(CFLAGS) $(SRC) -o test

# Each mutation restores a defect that cost a hardware session. The suite must
# go RED under every one of them; a mutation that still passes means the test
# for that defect does not exist.
mutate: $(SRC)
	@rc=0; for m in $(MUTS); do \
	  $(CC) $(CFLAGS) -D$$m $(SRC) -o test_$$m 2>/dev/null || { echo "$$m: BUILD FAIL"; rc=1; continue; }; \
	  if ./test_$$m >/dev/null 2>&1; then echo "$$m: *** STILL PASSES - not tested ***"; rc=1; \
	  else echo "$$m: RED (good)"; fi; \
	done; rm -f test_S573_MUT_*; \
	if [ $$rc -eq 0 ]; then echo "MUTATION CHECK: PASS"; else echo "MUTATION CHECK: FAIL"; fi; exit $$rc

# The loader simulation (see sim_loader.c): needs minimp3.h and an MP3.
MINIMP3_PATH ?= $(HOME)/minimp3/minimp3.h   # NOT "MINIMP3_H": that is the header's own include guard
MP3       ?= song.mp3
loader: sim_loader.c ../s573mp3_core.c ../s573_descramble.c
	$(CC) -std=gnu99 -O1 -g -w -DMINIMP3_PATH='"$(MINIMP3_PATH)"' sim_loader.c ../s573mp3_core.c ../s573_descramble.c -o sim_loader -lm
	./sim_loader $(MP3) 1 && ./sim_loader $(MP3) 0 && JUNK=old ./sim_loader $(MP3) 0 \
	  && PRELOAD=1 START=0x4077ea STALEWP=0x7044cc ./sim_loader $(MP3) 0

# The DDR card reader (s573_wio*.c, s573wio.cpp). Both need the board's boot ROM
# (MAME ddr3ma.zip 885a01.bin) and a DDR game's GAME.DAT (the reader program is in
# it; ddrextrm's at container offset 0x144678), neither of which is committed:
#   make wio WIO_ROM=/path/885a01.bin WIO_GAME=/path/GAME.DAT
#   test_wio_board    the board alone: the game's JVS sequence, a virtual card and
#                     (-ext) the SNAC byte engine stand-in
#   test_wio_service  the whole service with Main's thread, the board thread, the
#                     card file writer and a model of the fabric (rtl/s573_wio.v)
#   wio-red           the service test with the fabric reporting no reader: must FAIL
WIO_ROM  ?= 885a01.bin
WIO_GAME ?= GAME.DAT
WIO_SRC   = ../s573_wio.c ../s573_wio_cpu.c ../s573_wio_card.c
WIO_HDR   = ../s573_wio.h ../s573_wio_cpu.h ../s573_wio_card.h
CXX      ?= g++

test_wio_board: test_s573_wio.c $(WIO_SRC) $(WIO_HDR)
	$(CC) -std=gnu99 -O2 -Wall -Wextra test_s573_wio.c $(WIO_SRC) -o $@

wio_c.o: $(WIO_SRC) $(WIO_HDR)
	$(CC) -std=gnu99 -O2 -Wall -Wextra -c ../s573_wio.c -o wio_c.o
	$(CC) -std=gnu99 -O2 -Wall -Wextra -c ../s573_wio_cpu.c -o wio_cpu_c.o
	$(CC) -std=gnu99 -O2 -Wall -Wextra -c ../s573_wio_card.c -o wio_card_c.o

test_wio_service: test_s573wio.cpp ../s573wio.cpp host_main_stubs.h wio_c.o
	$(CXX) -std=gnu++14 -O2 -Wall -Wno-format-truncation -DS573_HOST_TEST -I.. test_s573wio.cpp ../s573wio.cpp wio_c.o wio_cpu_c.o wio_card_c.o -lpthread -o $@

test_wio_service_red: test_s573wio.cpp ../s573wio.cpp host_main_stubs.h wio_c.o
	$(CXX) -std=gnu++14 -O2 -Wall -Wno-format-truncation -DS573_HOST_TEST -DTEST_RED -I.. test_s573wio.cpp ../s573wio.cpp wio_c.o wio_cpu_c.o wio_card_c.o -lpthread -o $@

wio: test_wio_board test_wio_service
	./test_wio_board $(WIO_ROM) $(WIO_GAME)
	./test_wio_board $(WIO_ROM) $(WIO_GAME) -ext
	./test_wio_service $(WIO_ROM) $(WIO_GAME)

wio-red: test_wio_service_red
	@if ./test_wio_service_red $(WIO_ROM) $(WIO_GAME) >/dev/null 2>&1; then echo "wio-red: *** PASSES with no reader -- the test tests nothing ***"; exit 1; \
	else echo "wio-red: RED (good)"; fi

clean:
	rm -f test test_logdir test_S573_MUT_* sim_loader test_wio_board test_wio_service test_wio_service_red wio_c.o wio_cpu_c.o wio_card_c.o

.PHONY: all mutate loader clean wio wio-red
