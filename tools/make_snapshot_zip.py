#!/usr/bin/env python3
"""make_snapshot_zip.py -- zip the project tree for hand-off, without the regenerable or
huge parts: Quartus db/ + incremental_db/, sim build dirs, the game dumps (*.chd, romset
*.zip under dumps/ -- Ricky's own files), local/t7 (copies of his .sav), local/sd-stage.
Keeps .git, docs, rtl, sim sources, tools, psx (vendored + patches), out/ (deploys,
sav backups), local/ logs + job history, output_files/*.rbf + *.rpt.

    python3 tools/make_snapshot_zip.py <project_root> <out.zip>
"""
import os, sys, zipfile, time
root, out = sys.argv[1], sys.argv[2]
SKIP_DIRS = {'db', 'incremental_db', 'build', 'build_cpubench_no0004', 'build_cpubench_with0004',
             'build_no0004', 'build_with0004', 't7', 'sd-stage', '__pycache__'}
def skip(rel):
    parts = rel.replace('\\', '/').split('/')
    if parts[0] == 'dumps' and (rel.endswith('.chd') or rel.endswith('.zip')): return True
    if parts[0] == 'output_files' and not (rel.endswith('.rbf') or rel.endswith('.rpt')): return True
    if parts[0] == 'local' and rel.endswith('_partial.zip'): return True
    return False
n = total = skipped = 0
base = os.path.basename(os.path.abspath(root))
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for dp, dn, fn in os.walk(root):
        dn[:] = sorted(d for d in dn if d not in SKIP_DIRS)
        for f in sorted(fn):
            p = os.path.join(dp, f); rel = os.path.relpath(p, root)
            if skip(rel): skipped += 1; continue
            # files copied off the MiSTer carry 1970/1979 mtimes (no clock on the board):
            # ZIP cannot store those, so clamp to 1980-01-01.
            st = os.stat(p); dt = time.localtime(st.st_mtime)[:6]
            if dt < (1980, 1, 1, 0, 0, 0): dt = (1980, 1, 1, 0, 0, 0)
            zi = zipfile.ZipInfo(os.path.join(base, rel), dt); zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = (st.st_mode & 0xFFFF) << 16
            with open(p, 'rb') as fh: z.writestr(zi, fh.read())
            n += 1; total += os.path.getsize(p)
print("files %d, %.1f MB in, zip %.1f MB, skipped %d" % (n, total / 1e6, os.path.getsize(out) / 1e6, skipped))
