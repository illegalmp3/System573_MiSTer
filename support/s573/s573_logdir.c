/* s573_logdir.c - see s573_logdir.h */
#include "s573_logdir.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>

#define S573_CLOCK_VALID 1704067200   /* 2024-01-01 00:00 UTC */

int s573_logdir_session_num(const char *name)
{
    unsigned n = 0;
    int i = 0;
    if (strncmp(name, "session-", 8)) return -1;
    name += 8;
    for (; name[i] >= '0' && name[i] <= '9'; i++) {
        if (n > 100000000u) return -1;
        n = n * 10 + (unsigned)(name[i] - '0');
    }
    if (i == 0 || (name[i] != '_' && name[i] != '.')) return -1;
    if (!strstr(name + i, ".log") || strcmp(name + strlen(name) - 4, ".log")) return -1;
    return (int)n;
}

struct s573_logent { unsigned num; uint64_t size; char name[128]; };

unsigned s573_logdir_prune(const char *dir, uint64_t keep_bytes, unsigned keep_files)
{
    struct s573_logent *e = NULL;
    size_t cap = 0, cnt = 0;
    unsigned maxn = 0;
    uint64_t total = 0;
    DIR *d = opendir(dir);
    struct dirent *de;
    if (!d) return 0;
    while ((de = readdir(d))) {
        int n = s573_logdir_session_num(de->d_name);
        char path[512];
        struct stat st;
        if (n < 0 || strlen(de->d_name) >= sizeof e->name) continue;
        snprintf(path, sizeof path, "%s/%s", dir, de->d_name);
        if (stat(path, &st) || !S_ISREG(st.st_mode)) continue;
        if ((unsigned)n > maxn) maxn = (unsigned)n;
        if (cnt == cap) {
            size_t nc = cap ? cap * 2 : 256;
            struct s573_logent *ne = (struct s573_logent *)realloc(e, nc * sizeof *e);
            if (!ne) break;
            e = ne; cap = nc;
        }
        e[cnt].num = (unsigned)n;
        e[cnt].size = (uint64_t)st.st_size;
        strcpy(e[cnt].name, de->d_name);
        total += (uint64_t)st.st_size;
        cnt++;
    }
    closedir(d);
    while (cnt && (total >= keep_bytes || cnt >= keep_files)) {
        size_t lo = 0, i;
        char path[512];
        for (i = 1; i < cnt; i++) if (e[i].num < e[lo].num) lo = i;
        snprintf(path, sizeof path, "%s/%s", dir, e[lo].name);
        unlink(path);
        total -= e[lo].size;
        e[lo] = e[--cnt];
    }
    free(e);
    return maxn;
}

void s573_logdir_name(char *out, size_t n, unsigned num, int64_t t)
{
    struct tm tm;
    time_t tt = (time_t)t;
    if (t >= S573_CLOCK_VALID && localtime_r(&tt, &tm))
        snprintf(out, n, "session-%05u_%04d-%02d-%02d_%02d%02d.log", num,
                 tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min);
    else
        snprintf(out, n, "session-%05u.log", num);
}
