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

clean:
	rm -f test test_logdir test_S573_MUT_* sim_loader

.PHONY: all mutate loader clean
