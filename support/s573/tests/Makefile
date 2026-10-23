# Host tests for the 573 HPS MP3 service core. No cross toolchain needed.
CC      ?= gcc
CFLAGS  ?= -std=gnu99 -Wall -Wextra -Wno-unused-parameter -O1 -g
SRC      = test_s573mp3_core.c ../s573mp3_core.c ../s573_descramble.c
MUTS     = S573_MUT_WROTE_MASK15 S573_MUT_FREE_MASK15 S573_MUT_APPLY_NOFLUSH \
           S573_MUT_TAIL_STRICT S573_MUT_NO_WP_GATE S573_MUT_HOLD_SKIP S573_MUT_KEEP_TAIL

all: test wio glue
	./test
	WIO_DDR4M_EXE=$(WIO_DDR4M_EXE) ./test_wio
	./test_glue

# White I/O HLE. WIO_DDR4M_EXE=<ddr4m game exe> adds the real upload replay.
WIO_DDR4M_EXE ?=
wio: test_s573_whiteio.c ../s573_whiteio.c ../s573_whiteio.h
	$(CC) $(CFLAGS) test_s573_whiteio.c ../s573_whiteio.c -o test_wio

# s573wio.cpp (Main-side glue) against a mock CMD_573_WIO mailbox. The glue
# includes "../../spi.h" etc., so it is built from a mirror of Main's layout
# whose headers are the stubs in glue/.
CXX ?= g++
glue: test_s573wio_glue.cpp ../s573wio.cpp ../s573_whiteio.c ../s573_whiteio.h glue/spi.h
	rm -rf build_glue && mkdir -p build_glue/support/s573
	cp glue/*.h build_glue/
	cp ../s573wio.cpp ../s573_whiteio.c ../s573_whiteio.h build_glue/support/s573/
	$(CC) $(CFLAGS) -c build_glue/support/s573/s573_whiteio.c -o build_glue/wio.o
	$(CXX) -std=gnu++14 -Wall -Wextra -Wno-unused-parameter -O1 -g -Iglue test_s573wio_glue.cpp \
	  build_glue/support/s573/s573wio.cpp build_glue/wio.o -o test_glue

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

clean:
	rm -rf test test_wio test_glue build_glue test_S573_MUT_* sim_loader

.PHONY: all wio glue mutate loader clean
