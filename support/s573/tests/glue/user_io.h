#pragma once
#include <stdint.h>
#include "file_io.h"
uint32_t user_io_status_get(const char *opt, int ex = 0);
fileTYPE *get_image(int i);
