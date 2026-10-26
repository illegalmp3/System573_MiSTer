/* host_main_stubs.h -- the few Main_MiSTer calls s573wio.cpp makes, for the host
 * test (test_s573wio.cpp), which implements them against a model of the fabric. */
#ifndef HOST_MAIN_STUBS_H
#define HOST_MAIN_STUBS_H
#include <stdio.h>
#include <stdint.h>

uint16_t spi_uio_cmd_cont(uint16_t cmd);
uint16_t spi_w(uint16_t w);
void     DisableIO(void);
uint32_t user_io_status_get(const char *opt, int ex = 0);

struct fileTYPE { FILE *filp; char name[261]; };
fileTYPE   *get_image(int i);
const char *GetIdx_S(int idx);
const char *getFullPath(const char *name);
const char *HomeDir(void);
#endif
