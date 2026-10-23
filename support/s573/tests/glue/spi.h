/* host stub of Main_MiSTer spi.h for test_s573wio_glue (the mock fabric) */
#pragma once
#include <stdint.h>
uint16_t spi_uio_cmd_cont(uint16_t cmd);
uint16_t spi_w(uint16_t word);
void DisableIO();
