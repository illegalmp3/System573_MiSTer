/*
 * s573_wio_cpu.h -- TX39/H processor core (Toshiba TMPR3904F) interpreter for the
 * White I/O (GE885-PWB(A)) memory card reader emulation.
 *
 * Instruction set: MIPS I (R3000A) + the MIPS II branch-likely forms + the TX39
 * additions the board's code uses: three-operand MULT/MULTU (rd receives LO),
 * MADD/MADDU (SPECIAL2), SYNC, CACHE (no-op here), SDBBP.  The TX39 interlocks
 * loads, so there is no load delay slot.  Reference for the TX39-specific encodings:
 * GDB's MIPS simulator (sim/mips/tx.igen, mips.igen "*r3900" entries).
 *
 * CP0 is the R3000 set (TX39/H has no TLB): Status 12, Cause 13, EPC 14, PRId 15,
 * Config 3, Cache 7, Debug 16, DEPC 17, BadVAddr 8.  Exceptions use the R3000
 * KU/IE stack and RFE; the general vector is 0x80000080 (BEV=0) or 0xbfc00180.
 * Cause IP[5:0] are bits 15:10 (TMPR3904F manual 11.3.1: IP[4] = IRC request,
 * IP[3:0] = interrupt number, IP[5] = INT[0]).
 *
 * Memory is reached through callbacks so the board decides what is RAM, ROM or a
 * peripheral.  All accesses are big-endian.
 */
#ifndef WIO_CPU_H
#define WIO_CPU_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    WIO_EXC_INT = 0, WIO_EXC_ADEL = 4, WIO_EXC_ADES = 5, WIO_EXC_IBE = 6,
    WIO_EXC_DBE = 7, WIO_EXC_SYS = 8, WIO_EXC_BP = 9, WIO_EXC_RI = 10,
    WIO_EXC_CPU = 11, WIO_EXC_OV = 12
};

typedef struct wio_cpu {
    uint32_t r[32];
    uint32_t pc;          /* address of the instruction about to execute    */
    uint32_t npc;         /* address of the one after it (branch target)    */
    uint32_t hi, lo;
    uint32_t cp0[32];
    int      in_delay;    /* the instruction at pc sits in a delay slot      */
    uint32_t hw_ip;       /* Cause IP[5:0] driven by the IRC (bits 15:10)    */
    uint64_t cycles;      /* executed instructions (1 per cycle)            */

    /* memory interface: size 1, 2, 4; return 0 ok, nonzero = bus error */
    void *mem_ctx;
    int (*read)(void *ctx, uint32_t paddr, int size, uint32_t *val);
    int (*write)(void *ctx, uint32_t paddr, int size, uint32_t val);
    int (*fetch)(void *ctx, uint32_t paddr, uint32_t *insn);

    /* fast path: RAM at physical 0 (big-endian bytes), read and written directly
     * instead of through the callbacks; ram_stores counts the stores it took */
    uint8_t *ram;
    uint32_t ram_size;
    uint64_t ram_stores;
} wio_cpu_t;

void wio_cpu_reset(wio_cpu_t *c);
/* run one instruction (or take a pending interrupt); returns 0 normally */
int  wio_cpu_step(wio_cpu_t *c);
/* raise an exception at the current instruction (used by the board for NMI) */
void wio_cpu_exception(wio_cpu_t *c, int code);
/* 1 if an enabled interrupt is pending (so the board may wake the CPU) */
int  wio_cpu_irq_pending(const wio_cpu_t *c);
/* virtual -> physical, as the CPU maps it: kseg0/kseg1 strip the top bits,
 * kuseg is +0x40000000 (TMPR3904F manual Fig. 5-1), kseg2 is identity */
static inline uint32_t wio_vtop(uint32_t va)
{
    if ((va & 0xc0000000u) == 0x80000000u) return va & 0x1fffffffu;
    if (va < 0x80000000u) return va + 0x40000000u;
    return va;
}

#ifdef __cplusplus
}
#endif
#endif
