#!/usr/bin/env python3
"""test_s573_stage_ini.py - the --install-mp3 path of tools/s573_stage.py.
No dumps needed:  python3 tools/test_s573_stage_ini.py

Checks ini_add_main() on: no MiSTer.ini, a stock-style ini (CRLF), an ini that
already has a [System573] section with other keys and an old main=, a second run
(idempotent, backup kept from the first), a [Konami_System_573] section left alone,
and install_mp3() copying the binary and touching every MiSTer_*.ini."""
import importlib.util, os, shutil, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("s573_stage", os.path.join(ROOT, "tools", "s573_stage.py"))
M = importlib.util.module_from_spec(spec); spec.loader.exec_module(M)
fails = []
def check(c, what):
    print(("  ok   " if c else "  FAIL ") + what)
    if not c: fails.append(what)

def sections(text):
    out, cur = {}, None
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith("[") and s.endswith("]"):
            cur = s[1:-1]; out.setdefault(cur, [])
        elif cur is not None and s:
            out[cur].append(s)
    return out

d = tempfile.mkdtemp()
try:
    # 1. no ini at all -> a new file with just the section
    p = os.path.join(d, "MiSTer.ini"); log = []
    M.ini_add_main(p, False, log)
    t = open(p).read()
    check(sections(t) == {"System573": ["main=MiSTer_System573"]}, "new MiSTer.ini holds only [System573] main=")
    check(not os.path.exists(p + ".bak573"), "no backup for a file that did not exist")
    os.remove(p)

    # 2. stock-style CRLF ini
    stock = "[MiSTer]\r\nvideo_mode=8\r\n;comment\r\n\r\n[PSX]\r\nvsync_adjust=1\r\n"
    open(p, "wb").write(stock.encode())
    M.ini_add_main(p, False, [])
    raw = open(p, "rb").read()
    check(raw.startswith(stock.encode()), "existing content kept byte-for-byte")
    check(b"\r\n[System573]\r\nmain=MiSTer_System573\r\n" in raw, "section appended with the file's CRLF endings")
    check(open(p + ".bak573", "rb").read() == stock.encode(), "backup = the original")
    first = raw
    M.ini_add_main(p, False, (log := []))
    check(open(p, "rb").read() == first and "already" in log[0], "second run changes nothing")

    # 3. existing [System573] with an old main= and another key; a [Konami_System_573] left alone
    os.remove(p + ".bak573")
    open(p, "w").write("[MiSTer]\nvideo_mode=8\n[Konami_System_573]\nmain=MiSTer_System573\n"
                       "[system573]\nvsync_adjust=2\nmain=MiSTer\n[N64]\nvideo_mode=0\n")
    M.ini_add_main(p, False, [])
    sec = sections(open(p).read())
    check(sec["system573"] == ["main=MiSTer_System573", "vsync_adjust=2"], "old main= replaced, other keys kept")
    check(sec["N64"] == ["video_mode=0"] and sec["MiSTer"] == ["video_mode=8"], "other sections untouched")
    check(sec["Konami_System_573"] == ["main=MiSTer_System573"], "[Konami_System_573] left as it was")

    # 4. install_mp3: binary copied, every MiSTer_*.ini updated, dry run writes nothing
    sd = os.path.join(d, "sd"); os.makedirs(os.path.join(sd, "_Arcade"))
    open(os.path.join(sd, "MiSTer.ini"), "w").write("[MiSTer]\n")
    open(os.path.join(sd, "MiSTer_alt_1.ini"), "w").write("[MiSTer]\n")
    b = os.path.join(d, "MiSTer_System573"); open(b, "wb").write(b"\x7fELF" + b"\0" * 60)
    M.install_mp3(sd, b, True)
    check(not os.path.exists(os.path.join(sd, "MiSTer_System573")), "dry run copies nothing")
    check(open(os.path.join(sd, "MiSTer.ini")).read() == "[MiSTer]\n", "dry run edits nothing")
    M.install_mp3(os.path.join(sd, "games", "System573"), b, False)    # a games/System573 path resolves to the root
    check(open(os.path.join(sd, "MiSTer_System573"), "rb").read() == open(b, "rb").read(), "binary copied to the root")
    for n in ("MiSTer.ini", "MiSTer_alt_1.ini"):
        check(sections(open(os.path.join(sd, n)).read()).get("System573") == ["main=MiSTer_System573"], f"{n} has the section")
finally:
    shutil.rmtree(d)
print("RESULT: " + ("PASS" if not fails else f"FAIL ({len(fails)})"))
sys.exit(1 if fails else 0)
