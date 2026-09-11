# The console would not boot: a toolchain ABI pin, measured

**Date:** 2026-09-11 · **Board:** Ricky's MiSTer console · **Symptom:** with the
freshly built `MiSTer` binary in place, the console never came up. Reverted to the
July binary that shipped with it.

## Cause

The binary was built with **ARM GNU 13.3.Rel1**, and it requires glibc symbol
versions that no MiSTer rootfs provides:

| version | symbols |
|---|---|
| `GLIBC_2.38` | `__isoc23_fscanf`, `__isoc23_sscanf`, `__isoc23_strtol`, `__isoc23_strtoul`, `__isoc23_strtoull` — GCC 13 + glibc 2.38 headers redirect the C89 spellings to C23 variants |
| `GLIBC_2.34` | `pthread_create/join/detach`, `pthread_mutexattr_*`, `shm_open`, `shm_unlink`, `__libc_start_main` — glibc folded libpthread and librt into libc |
| `GLIBC_2.35` | `hypotf` |

The dynamic loader refuses such a binary **before `main()` runs**, so Main never
starts and there is no menu, no log and no error anywhere the user can see. It
presents as "the console won't boot".

## The evidence that it was not our code

`MiSTer.nos573` — September master built from the same tree with the **same
toolchain and zero 573 code** — has the byte-identical GLIBC requirement set. Any
binary from that toolchain would have failed the same way. Building the control
alongside the real thing is what made this a one-step diagnosis instead of a
session of bisecting our own service.

## This was avoidable, and the evidence was already in hand

Main's `Makefile` says `# using gcc version 10.2.1`, and `.devcontainer/Dockerfile`
downloads `gcc-arm-10.2-2020.11` explicitly. Both were read hours earlier. The
conclusion drawn from them was:

> There is no `-Werror` in CFLAGS, so newer-compiler warnings will not fail the
> build; 10.2 aarch64 is the fallback if 13.3 misbehaves.

That reasoned about **compile-time** warnings. The pin is a **runtime ABI** pin: it
exists so the binary still *loads* on MiSTer's old rootfs. The right fact was found
and the wrong inference drawn from it — worth recording as its own failure mode,
separate from the bug.

## Fix

Build with the toolchain upstream pins: `gcc-arm-10.2-2020.11`, aarch64-hosted,
sysroot **glibc 2.31**. No source change of any kind. The result tops out at
**GLIBC_2.28** and links `librt.so.1` / `libpthread.so.0` separately — the
pre-2.34 shape upstream's own releases have.

| binary | max GLIBC | sha256 |
|---|---|---|
| `MiSTer` (with the service) | 2.28 | `4b3f8057…` |
| `MiSTer.upstream-nos573` (control) | 2.28 | `37f585c3…` |

## The gate, so this cannot recur

`tools/build-hps-mp3.sh` now refuses to stage a binary whose glibc floor is higher
than that of **the binary the board already runs** (`MiSTer.orig`, kept as the
reference on the SD card). Two details of that gate are deliberate:

1. It compares against the board's own working binary rather than a hardcoded
   version number — the board is the authority on what the board can load.
2. **An unreadable reference is a hard failure, not a pass.** While writing this the
   SD card was in the console, the mount returned nothing, and the naive comparison
   printed `VERDICT: ours still demands newer glibc — DO NOT DEPLOY` from two empty
   strings. It happened to say the safe thing, and it was still a vacuous result
   from a dead instrument. That is the fourth time on this project that an empty
   reading nearly became a finding: `stdout` to `/dev/null`, the log marker that
   never landed, the MAME tap that never fired, and now this. *Verify the
   instrument before believing a null* — including when the null agrees with you.
