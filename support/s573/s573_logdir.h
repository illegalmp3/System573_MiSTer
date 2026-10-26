/*
 * s573_logdir.h - the per-session log folder of MiSTer_System573 (2026-10-25).
 *
 * One file per session: <dir>/session-NNNNN[_YYYY-MM-DD_HHMM].log. The folder keeps
 * every session until it passes keep_bytes or keep_files; then the oldest sessions
 * (lowest numbers) are deleted first. Files that are not session-*.log are never
 * touched. Plain C and POSIX, so the host tests (support/s573/tests) run it.
 */
#ifndef S573_LOGDIR_H
#define S573_LOGDIR_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

/* The session number in a file name, or -1 when it is not a session log. */
int s573_logdir_session_num(const char *name);

/* Delete the oldest sessions until the folder holds less than keep_bytes and fewer
 * than keep_files session files (room for the one about to start). Returns the
 * highest session number found (0 = none), the next one is that + 1. */
unsigned s573_logdir_prune(const char *dir, uint64_t keep_bytes, unsigned keep_files);

/* The file name for session `num`, with the clock when `t` is a real date
 * (>= 2024-01-01; a MiSTer with no RTC board and no network reports 1970). */
void s573_logdir_name(char *out, size_t n, unsigned num, int64_t t);

#ifdef __cplusplus
}
#endif
#endif
