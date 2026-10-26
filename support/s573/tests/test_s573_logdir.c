/* Host test for s573_logdir.c: names, the session number scan, and pruning
 * (oldest first, only session-*.log, by bytes and by count). */
#include "../s573_logdir.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <time.h>

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); fails++; } } while (0)

static char dir[256];
static void mk(const char *name, size_t bytes)
{
    char p[512]; snprintf(p, sizeof p, "%s/%s", dir, name);
    FILE *f = fopen(p, "wb");
    for (size_t i = 0; i < bytes; i++) fputc('x', f);
    fclose(f);
}
static int exists(const char *name)
{
    char p[512]; struct stat st; snprintf(p, sizeof p, "%s/%s", dir, name);
    return stat(p, &st) == 0;
}

int main(void)
{
    char n[128];
    /* names */
    CHECK(s573_logdir_session_num("session-00042.log") == 42, "plain");
    CHECK(s573_logdir_session_num("session-00042_2026-10-25_2017.log") == 42, "dated");
    CHECK(s573_logdir_session_num("session-.log") == -1, "no number");
    CHECK(s573_logdir_session_num("session-12.txt") == -1, "not .log");
    CHECK(s573_logdir_session_num("sessions.txt") == -1, "index");
    CHECK(s573_logdir_session_num("s573mp3-before-sessions.log") == -1, "legacy");
    s573_logdir_name(n, sizeof n, 7, 0);
    CHECK(!strcmp(n, "session-00007.log"), "no clock name %s", n);
    setenv("TZ", "UTC", 1); tzset();
    s573_logdir_name(n, sizeof n, 7, 1792981020);           /* 2026-10-26 02:17 UTC */
    CHECK(!strcmp(n, "session-00007_2026-10-26_0217.log"), "clock name %s", n);

    /* empty / missing folder */
    snprintf(dir, sizeof dir, "/tmp/s573_logdir_test_%d", (int)getpid());
    CHECK(s573_logdir_prune(dir, 1000, 10) == 0, "missing dir");
    mkdir(dir, 0777);
    CHECK(s573_logdir_prune(dir, 1000, 10) == 0, "empty dir");

    /* five sessions of 100 bytes + files that must never be touched */
    mk("session-00001.log", 100); mk("session-00002_2026-10-24_1900.log", 100);
    mk("session-00003.log", 100); mk("session-00010.log", 100); mk("session-00004.log", 100);
    mk("sessions.txt", 5000); mk("s573mp3-before-sessions.log", 5000);
    CHECK(s573_logdir_prune(dir, 1000000, 100) == 10, "max number");
    CHECK(exists("session-00001.log") && exists("session-00010.log"), "nothing pruned under the caps");

    /* bytes: 500 in the folder, keep < 350 -> the two oldest go */
    CHECK(s573_logdir_prune(dir, 350, 100) == 10, "max after byte prune");
    CHECK(!exists("session-00001.log") && !exists("session-00002_2026-10-24_1900.log"), "oldest two deleted");
    CHECK(exists("session-00003.log") && exists("session-00004.log") && exists("session-00010.log"), "newest kept");
    CHECK(exists("sessions.txt") && exists("s573mp3-before-sessions.log"), "others untouched (bytes)");

    /* count: 3 left, keep_files 2 -> room for one more = keep 1 */
    s573_logdir_prune(dir, 1000000, 2);
    CHECK(!exists("session-00003.log") && !exists("session-00004.log") && exists("session-00010.log"), "count prune");
    CHECK(exists("sessions.txt") && exists("s573mp3-before-sessions.log"), "others untouched (count)");

    if (system("rm -rf /tmp/s573_logdir_test_*")) {}
    printf("LOGDIR: %s\n", fails ? "FAIL" : "PASS");
    return fails ? 1 : 0;
}
