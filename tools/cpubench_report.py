#!/usr/bin/env python3
"""cpubench_report.py -- cycles per iteration from a CPUBENCH bench_trace.log.

    tools/cpubench_report.py build/bench_trace.log A=80010010 B=80010120 C=80010140

Each trace line is "<clk1x cycle> <PC>" for a non-sequential PC change. A loop head
appears once per iteration (the back-branch lands on it), so the differences between
consecutive stamps of that PC are the loop's cycles per iteration. The first few
iterations warm the i-cache; the report gives the steady-state median and the min/max.
"""
import sys, statistics

def main():
    log = sys.argv[1]
    heads = {}
    for kv in sys.argv[2:]:
        k, v = kv.split("=")
        heads[k] = int(v, 16)
    stamps = {k: [] for k in heads}
    with open(log) as f:
        for line in f:
            parts = line.split()
            if len(parts) != 2: continue
            cyc, pc = int(parts[0]), int(parts[1], 16)
            for k, a in heads.items():
                # the tap sees the FETCH pc: after a taken branch it logs either the
                # target or target+4 depending on how fast the target hit
                if pc == a or pc == a + 4: stamps[k].append(cyc)
    for k in heads:
        s = stamps[k]
        if len(s) < 3:
            print("%s: only %d visits" % (k, len(s))); continue
        d = [b - a for a, b in zip(s, s[1:])]
        warm = d[:3]; steady = d[3:] if len(d) > 3 else d
        print("%s @%08x: %d iterations; cycles/iteration steady median=%d min=%d max=%d (first 3: %s)" % (
            k, heads[k], len(d), statistics.median(steady), min(steady), max(steady), warm))

if __name__ == "__main__":
    main()
