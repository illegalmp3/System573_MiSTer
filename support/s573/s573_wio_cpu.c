/*
 * s573_wio_cpu.c -- TX39/H interpreter.  See wio_cpu.h for the sources.
 */
#include "s573_wio_cpu.h"
#include <string.h>

#define C0_BADVADDR 8
#define C0_STATUS   12
#define C0_CAUSE    13
#define C0_EPC      14
#define C0_PRID     15

#define ST_BEV      (1u << 22)
#define CAUSE_BD    (1u << 31)

/* TMPR3904F manual Fig. 5-1: kuseg 0x00000000-0x7fffffff -> physical +0x40000000 */
static uint32_t vtop(uint32_t va)
{
    if ((va & 0xc0000000u) == 0x80000000u) return va & 0x1fffffffu;
    if (va < 0x80000000u) return va + 0x40000000u;
    return va;
}

void wio_cpu_reset(wio_cpu_t *c)
{
    memset(c->r, 0, sizeof c->r);
    c->hi = c->lo = 0;
    memset(c->cp0, 0, sizeof c->cp0);
    c->cp0[C0_STATUS] = ST_BEV;
    c->cp0[C0_PRID]   = 0x00002200;  /* TX39 family id class 0x22; the code never reads it */
    c->pc  = 0xbfc00000u;
    c->npc = c->pc + 4;
    c->in_delay = 0;
    c->hw_ip = 0;
}

static void take_exception(wio_cpu_t *c, int code, uint32_t badva)
{
    uint32_t st = c->cp0[C0_STATUS];
    uint32_t cause = c->cp0[C0_CAUSE] & 0x00000300u;   /* keep software IP */
    cause |= (uint32_t)(code & 0x1f) << 2;
    cause |= (c->hw_ip & 0x3f) << 10;
    if (c->in_delay) {
        cause |= CAUSE_BD;
        c->cp0[C0_EPC] = c->pc - 4;
    } else {
        c->cp0[C0_EPC] = c->pc;
    }
    if (code == WIO_EXC_ADEL || code == WIO_EXC_ADES)
        c->cp0[C0_BADVADDR] = badva;
    c->cp0[C0_CAUSE] = cause;
    /* push the KU/IE stack */
    c->cp0[C0_STATUS] = (st & ~0x3fu) | ((st << 2) & 0x3cu);
    c->pc  = (st & ST_BEV) ? 0xbfc00180u : 0x80000080u;
    c->npc = c->pc + 4;
    c->in_delay = 0;
}

void wio_cpu_exception(wio_cpu_t *c, int code) { take_exception(c, code, 0); }

int wio_cpu_irq_pending(const wio_cpu_t *c)
{
    uint32_t st = c->cp0[C0_STATUS];
    uint32_t ip;
    if (!(st & 1)) return 0;
    ip = ((c->hw_ip & 0x3f) << 10) | (c->cp0[C0_CAUSE] & 0x300u);
    return (ip & st & 0xff00u) != 0;
}

/* --- memory helpers: return 0 on success, else an exception was taken --- */
static inline int ld(wio_cpu_t *c, uint32_t va, int size, uint32_t *v)
{
    uint32_t pa;
    if (va & (uint32_t)(size - 1)) { take_exception(c, WIO_EXC_ADEL, va); return 1; }
    pa = vtop(va);
    if (pa < c->ram_size) {
        const uint8_t *p = c->ram + pa;
        *v = size == 1 ? p[0] : size == 2 ? (uint32_t)(p[0] << 8 | p[1])
           : ((uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]);
        return 0;
    }
    if (c->read(c->mem_ctx, pa, size, v)) { take_exception(c, WIO_EXC_DBE, va); return 1; }
    return 0;
}

static inline int st(wio_cpu_t *c, uint32_t va, int size, uint32_t v)
{
    uint32_t pa;
    if (va & (uint32_t)(size - 1)) { take_exception(c, WIO_EXC_ADES, va); return 1; }
    pa = vtop(va);
    if (pa < c->ram_size) {
        uint8_t *p = c->ram + pa;
        if (size == 1) p[0] = (uint8_t)v;
        else if (size == 2) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
        else { p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v; }
        c->ram_stores++;
        return 0;
    }
    if (c->write(c->mem_ctx, pa, size, v)) { take_exception(c, WIO_EXC_DBE, va); return 1; }
    return 0;
}

#define RS  ((insn >> 21) & 31)
#define RT  ((insn >> 16) & 31)
#define RD  ((insn >> 11) & 31)
#define SA  ((insn >> 6) & 31)
#define IMM ((uint32_t)(int32_t)(int16_t)(insn & 0xffff))
#define UIMM (insn & 0xffff)

static inline void setr(wio_cpu_t *c, int n, uint32_t v) { if (n) c->r[n] = v; }

int wio_cpu_step(wio_cpu_t *c)
{
    uint32_t insn, pc, npc, a, v, t;
    int op;

    if (wio_cpu_irq_pending(c)) {
        take_exception(c, WIO_EXC_INT, 0);
        c->cycles++;
        return 0;
    }

    pc = c->pc;
    if (pc & 3) { take_exception(c, WIO_EXC_ADEL, pc); c->cycles++; return 0; }
    {
        uint32_t pa = vtop(pc);
        if (pa < c->ram_size) {
            const uint8_t *p = c->ram + pa;
            insn = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
        } else if (c->fetch(c->mem_ctx, pa, &insn)) { take_exception(c, WIO_EXC_IBE, pc); c->cycles++; return 0; }
    }

    /* default sequencing: the instruction after this one */
    npc = c->npc + 4;
    {
        int was_delay = c->in_delay;
        uint32_t next = c->npc;
        int branch = 0;          /* 1 = branch taken -> next is delay slot     */
        int likely_skip = 0;     /* branch-likely not taken: skip delay slot   */
        uint32_t target = 0;

        (void)was_delay;
        op = insn >> 26;
        c->cycles++;

        switch (op) {
        case 0x00: { /* SPECIAL */
            int fn = insn & 63;
            switch (fn) {
            case 0x00: setr(c, RD, c->r[RT] << SA); break;
            case 0x02: setr(c, RD, c->r[RT] >> SA); break;
            case 0x03: setr(c, RD, (uint32_t)((int32_t)c->r[RT] >> SA)); break;
            case 0x04: setr(c, RD, c->r[RT] << (c->r[RS] & 31)); break;
            case 0x06: setr(c, RD, c->r[RT] >> (c->r[RS] & 31)); break;
            case 0x07: setr(c, RD, (uint32_t)((int32_t)c->r[RT] >> (c->r[RS] & 31))); break;
            case 0x08: target = c->r[RS]; branch = 1; break;                 /* JR   */
            case 0x09: target = c->r[RS]; setr(c, RD, pc + 8); branch = 1; break; /* JALR */
            case 0x0c: take_exception(c, WIO_EXC_SYS, 0); return 0;
            case 0x0d: take_exception(c, WIO_EXC_BP, 0); return 0;
            case 0x0f: break;                                                 /* SYNC */
            case 0x10: setr(c, RD, c->hi); break;
            case 0x11: c->hi = c->r[RS]; break;
            case 0x12: setr(c, RD, c->lo); break;
            case 0x13: c->lo = c->r[RS]; break;
            case 0x18: { /* MULT (TX39: rd <- LO) */
                int64_t p = (int64_t)(int32_t)c->r[RS] * (int64_t)(int32_t)c->r[RT];
                c->lo = (uint32_t)p; c->hi = (uint32_t)((uint64_t)p >> 32);
                setr(c, RD, c->lo); break; }
            case 0x19: { /* MULTU */
                uint64_t p = (uint64_t)c->r[RS] * (uint64_t)c->r[RT];
                c->lo = (uint32_t)p; c->hi = (uint32_t)(p >> 32);
                setr(c, RD, c->lo); break; }
            case 0x1a: { /* DIV */
                int32_t n = (int32_t)c->r[RS], d = (int32_t)c->r[RT];
                if (d == 0) { c->lo = (n < 0) ? 1u : 0xffffffffu; c->hi = (uint32_t)n; }
                else if (n == INT32_MIN && d == -1) { c->lo = (uint32_t)INT32_MIN; c->hi = 0; }
                else { c->lo = (uint32_t)(n / d); c->hi = (uint32_t)(n % d); }
                break; }
            case 0x1b: { /* DIVU */
                uint32_t n = c->r[RS], d = c->r[RT];
                if (d == 0) { c->lo = 0xffffffffu; c->hi = n; }
                else { c->lo = n / d; c->hi = n % d; }
                break; }
            case 0x20: { /* ADD */
                uint32_t s = c->r[RS], u = c->r[RT], r = s + u;
                if (~(s ^ u) & (s ^ r) & 0x80000000u) { take_exception(c, WIO_EXC_OV, 0); return 0; }
                setr(c, RD, r); break; }
            case 0x21: setr(c, RD, c->r[RS] + c->r[RT]); break;
            case 0x22: { /* SUB */
                uint32_t s = c->r[RS], u = c->r[RT], r = s - u;
                if ((s ^ u) & (s ^ r) & 0x80000000u) { take_exception(c, WIO_EXC_OV, 0); return 0; }
                setr(c, RD, r); break; }
            case 0x23: setr(c, RD, c->r[RS] - c->r[RT]); break;
            case 0x24: setr(c, RD, c->r[RS] & c->r[RT]); break;
            case 0x25: setr(c, RD, c->r[RS] | c->r[RT]); break;
            case 0x26: setr(c, RD, c->r[RS] ^ c->r[RT]); break;
            case 0x27: setr(c, RD, ~(c->r[RS] | c->r[RT])); break;
            case 0x2a: setr(c, RD, (int32_t)c->r[RS] < (int32_t)c->r[RT]); break;
            case 0x2b: setr(c, RD, c->r[RS] < c->r[RT]); break;
            default: take_exception(c, WIO_EXC_RI, 0); return 0;
            }
            break; }
        case 0x01: { /* REGIMM */
            int rt = RT, cond;
            int32_t s = (int32_t)c->r[RS];
            int link = (rt & 0x10) != 0, likely = (rt & 0x02) != 0;
            if ((rt & 0x0c) != 0) { take_exception(c, WIO_EXC_RI, 0); return 0; }
            cond = (rt & 1) ? (s >= 0) : (s < 0);
            if (link) setr(c, 31, pc + 8);
            if (cond) { target = next + (IMM << 2); branch = 1; }
            else if (likely) likely_skip = 1;
            break; }
        case 0x02: target = (next & 0xf0000000u) | ((insn & 0x03ffffffu) << 2); branch = 1; break;
        case 0x03: target = (next & 0xf0000000u) | ((insn & 0x03ffffffu) << 2); setr(c, 31, pc + 8); branch = 1; break;
        case 0x04: case 0x14: /* BEQ / BEQL */
            if (c->r[RS] == c->r[RT]) { target = next + (IMM << 2); branch = 1; } else if (op & 0x10) likely_skip = 1;
            break;
        case 0x05: case 0x15: /* BNE / BNEL */
            if (c->r[RS] != c->r[RT]) { target = next + (IMM << 2); branch = 1; } else if (op & 0x10) likely_skip = 1;
            break;
        case 0x06: case 0x16: /* BLEZ / BLEZL */
            if ((int32_t)c->r[RS] <= 0) { target = next + (IMM << 2); branch = 1; } else if (op & 0x10) likely_skip = 1;
            break;
        case 0x07: case 0x17: /* BGTZ / BGTZL */
            if ((int32_t)c->r[RS] > 0) { target = next + (IMM << 2); branch = 1; } else if (op & 0x10) likely_skip = 1;
            break;
        case 0x08: { /* ADDI */
            uint32_t s = c->r[RS], u = IMM, r = s + u;
            if (~(s ^ u) & (s ^ r) & 0x80000000u) { take_exception(c, WIO_EXC_OV, 0); return 0; }
            setr(c, RT, r); break; }
        case 0x09: setr(c, RT, c->r[RS] + IMM); break;
        case 0x0a: setr(c, RT, (int32_t)c->r[RS] < (int32_t)IMM); break;
        case 0x0b: setr(c, RT, c->r[RS] < IMM); break;
        case 0x0c: setr(c, RT, c->r[RS] & UIMM); break;
        case 0x0d: setr(c, RT, c->r[RS] | UIMM); break;
        case 0x0e: setr(c, RT, c->r[RS] ^ UIMM); break;
        case 0x0f: setr(c, RT, UIMM << 16); break;
        case 0x10: { /* COP0 */
            int rs = RS;
            if (rs == 0x00) {            /* MFC0 */
                uint32_t val = c->cp0[RD];
                if (RD == C0_CAUSE) val = (val & ~0xfc00u) | ((c->hw_ip & 0x3f) << 10);
                setr(c, RT, val);
            } else if (rs == 0x04) {     /* MTC0 */
                uint32_t val = c->r[RT];
                if (RD == C0_CAUSE) val = (c->cp0[C0_CAUSE] & ~0x300u) | (val & 0x300u);
                else if (RD == C0_PRID) val = c->cp0[C0_PRID];
                c->cp0[RD] = val;
            } else if (rs == 0x10) {
                int fn = insn & 63;
                if (fn == 0x10) {        /* RFE */
                    uint32_t s = c->cp0[C0_STATUS];
                    c->cp0[C0_STATUS] = (s & ~0x0fu) | ((s >> 2) & 0x0fu);
                } else if (fn == 0x1f) { /* DERET (TX39 debug) */
                    target = c->cp0[17]; branch = 1;
                } else { take_exception(c, WIO_EXC_RI, 0); return 0; }
            } else { take_exception(c, WIO_EXC_RI, 0); return 0; }
            break; }
        case 0x11: case 0x12: case 0x13:
            take_exception(c, WIO_EXC_CPU, 0); c->cp0[C0_CAUSE] |= (uint32_t)(op & 3) << 28; return 0;
        case 0x1c: { /* SPECIAL2: TX39 MADD / MADDU */
            int fn = insn & 0x7ff;
            uint64_t acc = ((uint64_t)c->hi << 32) | c->lo;
            if (fn == 0) acc += (uint64_t)((int64_t)(int32_t)c->r[RS] * (int64_t)(int32_t)c->r[RT]);
            else if (fn == 1) acc += (uint64_t)c->r[RS] * (uint64_t)c->r[RT];
            else { take_exception(c, WIO_EXC_RI, 0); return 0; }
            c->lo = (uint32_t)acc; c->hi = (uint32_t)(acc >> 32);
            setr(c, RD, c->lo);
            break; }
        case 0x20: a = c->r[RS] + IMM; if (ld(c, a, 1, &v)) return 0; setr(c, RT, (uint32_t)(int32_t)(int8_t)v); break;
        case 0x21: a = c->r[RS] + IMM; if (ld(c, a, 2, &v)) return 0; setr(c, RT, (uint32_t)(int32_t)(int16_t)v); break;
        case 0x23: a = c->r[RS] + IMM; if (ld(c, a, 4, &v)) return 0; setr(c, RT, v); break;
        case 0x24: a = c->r[RS] + IMM; if (ld(c, a, 1, &v)) return 0; setr(c, RT, v & 0xff); break;
        case 0x25: a = c->r[RS] + IMM; if (ld(c, a, 2, &v)) return 0; setr(c, RT, v & 0xffff); break;
        case 0x22: case 0x26: { /* LWL / LWR (big-endian) */
            uint32_t w, sh;
            a = c->r[RS] + IMM;
            if (ld(c, a & ~3u, 4, &w)) return 0;
            sh = (a & 3) * 8;
            if (op == 0x22) t = (c->r[RT] & ~(0xffffffffu << sh)) | (w << sh);
            else {
                uint32_t rs2 = 24 - sh;
                t = (c->r[RT] & ~(0xffffffffu >> rs2)) | (w >> rs2);
            }
            setr(c, RT, t); break; }
        case 0x28: a = c->r[RS] + IMM; if (st(c, a, 1, c->r[RT] & 0xff)) return 0; break;
        case 0x29: a = c->r[RS] + IMM; if (st(c, a, 2, c->r[RT] & 0xffff)) return 0; break;
        case 0x2b: a = c->r[RS] + IMM; if (st(c, a, 4, c->r[RT])) return 0; break;
        case 0x2a: case 0x2e: { /* SWL / SWR (big-endian) */
            uint32_t w, sh;
            a = c->r[RS] + IMM;
            if (ld(c, a & ~3u, 4, &w)) return 0;
            sh = (a & 3) * 8;
            if (op == 0x2a) w = (w & ~(0xffffffffu >> sh)) | (c->r[RT] >> sh);
            else {
                uint32_t ls = 24 - sh;
                w = (w & ~(0xffffffffu << ls)) | (c->r[RT] << ls);
            }
            if (st(c, a & ~3u, 4, w)) return 0;
            break; }
        case 0x2f: break;                      /* CACHE: no cache modelled */
        default:
            take_exception(c, WIO_EXC_RI, 0); return 0;
        }

        /* sequencing */
        if (likely_skip) {
            c->pc = next + 4; c->npc = next + 8; c->in_delay = 0;
        } else if (branch) {
            c->pc = next; c->npc = target; c->in_delay = 1;
        } else {
            c->pc = next; c->npc = npc; c->in_delay = 0;
        }
    }
    return 0;
}
