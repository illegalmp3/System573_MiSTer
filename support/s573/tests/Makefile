# Host tests for the 573 HPS MP3 service core. No cross toolchain needed.
CC      ?= gcc
CFLAGS  ?= -std=gnu99 -Wall -Wextra -Wno-unused-parameter -O1 -g
SRC      = test_s573mp3_core.c ../s573mp3_core.c ../s573_descramble.c
MUTS     = S573_MUT_WROTE_MASK15 S573_MUT_FREE_MASK15 S573_MUT_APPLY_NOFLUSH \
           S573_MUT_TAIL_STRICT S573_MUT_NO_WP_GATE

all: test
	./test

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

clean:
	rm -f test test_S573_MUT_*

.PHONY: all mutate clean
