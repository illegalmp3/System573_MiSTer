#!/usr/bin/env python3
"""
test_s573_stage.py - check tools/s573_stage.py (the standalone stager we ship)
against the in-repo stager and the files proven on hardware.

    python3 tools/test_s573_stage.py /tmp/s573t [MANIFEST]   # WORK dir, needs ~6 GB free

  1. reference: tools/stage_573.py stages every title it handles (CHDs left out,
     except the two MODE1 discs it converts), into WORK/ref
  2. tools/s573_stage.py stages everything from dumps/mame573 into WORK/new
  3. every reference file must be byte-identical in WORK/new; every copied CHD must
     equal its source; the BIOS, Hyper Bishi Bashi flash/NVRAM images and blanks
     must equal local/sd-stage (the files used on the cabinet)
  4. a second run must write nothing; an existing .sav is kept; an old-size .sav is
     extended with the install kept
  5. lookup by CRC: one title from a zip with every member renamed and its CHD
     under another name in a sub-folder
  6. an SD-root OUT goes to OUT/games/System573; --dry-run writes nothing
"""
import filecmp, hashlib, importlib.util, os, re, shutil, subprocess, sys, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUMPS = os.path.join(ROOT, "dumps", "mame573")
TOOL = os.path.join(ROOT, "tools", "s573_stage.py")
SDSTAGE = os.path.join(ROOT, "local", "sd-stage", "games", "System573")

spec = importlib.util.spec_from_file_location("s573_stage", TOOL)
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)

fails = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what, flush=True)
    if not cond:
        fails.append(what)


def md5(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(8 << 20), b""):
            h.update(b)
    return h.hexdigest()


def run(args, **kw):
    r = subprocess.run([sys.executable, TOOL] + args, capture_output=True, text=True, **kw)
    return r.returncode, r.stdout + r.stderr


def main():
    work = sys.argv[1]
    if os.path.exists(work):
        shutil.rmtree(work)
    ref, new, lite = (os.path.join(work, d) for d in ("ref", "new", "dumps"))
    for d in (ref, new, lite):
        os.makedirs(d)

    # --- 1. reference staging with stage_573.py (no CHD copies; MODE1 discs converted)
    print("== reference: tools/stage_573.py", flush=True)
    for f in os.listdir(DUMPS):
        if f.endswith(".zip") or f == "ksys573.cpp" or f in ("936eaa.chd", "910jca02.chd"):
            os.symlink(os.path.join(DUMPS, f), os.path.join(lite, f))
    refsets = []
    for t in M.TABLE["titles"]:
        s = t["set"]
        if f"{s}.u1" not in t["files"] or not os.path.exists(os.path.join(DUMPS, s + ".zip")):
            continue
        code = ("import sys; sys.path.insert(0, %r); import stage_573 as S; S.DUMPS = %r; "
                "S.DRIVER = %r; sys.argv = ['stage_573', %r, %r]; S.main()"
                % (os.path.join(ROOT, "tools"), lite, os.path.join(lite, "ksys573.cpp"), s, ref))
        r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
        check(r.returncode == 0, f"stage_573 {s}" + ("" if r.returncode == 0 else ":\n" + r.stdout + r.stderr))
        refsets.append(s)

    # --- 2. the standalone stager, everything
    print("== tools/s573_stage.py dumps/mame573 -> new", flush=True)
    rc, out = run([DUMPS, new])
    print("\n".join("     | " + l for l in out.splitlines()))
    check(rc == 0, "standalone run exits 0")
    staged = re.findall(r"^  (\w+)\s{2,}", out.split("Can stage")[1].split("Missing files")[0], re.M)

    # --- 3. compare
    print("== compare", flush=True)
    # only what the shipped launchers load: stage_573 also writes <set>.u6 for the
    # two-cassette titles, whose launchers load the .cas pack in its place
    wanted = {}
    for t in M.TABLE["titles"]:
        if t["set"] in staged:
            for name, r in t["files"].items():
                wanted[name] = r
                if r.get("bin"):
                    wanted[r["bin"]] = r
    unused = []
    for f in sorted(os.listdir(ref)):
        if f not in wanted:
            unused.append(f)
            continue
        a, b = os.path.join(ref, f), os.path.join(new, f)
        check(os.path.exists(b) and filecmp.cmp(a, b, shallow=False), f"{f} identical to stage_573's")
    if unused:
        print("  (not loaded by any launcher of a staged title, not compared: " + " ".join(unused) + ")")
    for t in M.TABLE["titles"]:
        if t["set"] not in staged:
            continue
        for name, r in t["files"].items():
            p = os.path.join(new, name)
            check(os.path.exists(p), f"{t['set']}: {name} present")
            if r["make"] == "chd":
                srcp = os.path.join(DUMPS, r["disc"] + ".chd")
                check(os.path.getsize(p) == os.path.getsize(srcp) and md5(p) == md5(srcp),
                      f"{name} == {r['disc']}.chd")
            if r["make"] == "mode1":
                check(os.path.exists(os.path.join(new, r["bin"])), f"{r['bin']} present")
            if r["make"] == "sav":
                with open(p, "rb") as fh:
                    z = fh.read()
                check(len(z) == r["size"] and not any(z), f"{name}: {r['size']} zero bytes")
    for f in ("573bios.bin", "573bios_gchgchmp.bin", "hbbflash.bin", "hbbnvram.bin",
              "flash16m_blank.bin", "nvram8k_blank.bin", "ddrsbm.u1", "ddrsbm.u6"):
        a, b = os.path.join(SDSTAGE, f), os.path.join(new, f)
        if os.path.exists(b):
            check(filecmp.cmp(a, b, shallow=False), f"{f} identical to local/sd-stage (used on hardware)")
    check(not [f for f in os.listdir(new) if f.endswith(".part")], "no .part files left behind")

    # --- 4. idempotency and saves
    print("== second run / saves", flush=True)
    rc, out = run([DUMPS, new])
    acted = [l for l in out.splitlines() if re.search(r": (written|copied|created|built|extended)", l)]
    check(rc == 0 and not acted, "second run writes nothing" + ("" if not acted else ": " + "; ".join(acted)))
    sav = os.path.join(new, "ddr3mj.sav")
    with open(sav, "r+b") as fh:
        fh.seek(12345)
        fh.write(b"\x5a")
    old = os.path.join(new, "dsem.sav")
    with open(old, "wb") as fh:
        fh.write(b"INSTALL!" + bytes((16 << 20) - 8))
    rc, out = run([DUMPS, new, "--only", "ddr3mj,dsem"])
    with open(sav, "rb") as fh:
        fh.seek(12345)
        kept = fh.read(1) == b"\x5a"
    check(kept and "ddr3mj.sav: kept" in out, "an existing .sav is kept as it is")
    with open(old, "rb") as fh:
        d = fh.read()
    check(len(d) == 16786432 and d[:8] == b"INSTALL!" and not any(d[8:]),
          "an old 16 MiB .sav is extended to 16786432 with its contents kept")

    # --- 5. lookup by CRC / SHA1, not by name
    print("== renamed sources", flush=True)
    sp, so = os.path.join(work, "split"), os.path.join(work, "split_out")
    os.makedirs(os.path.join(sp, "discs"))
    t = next(t for t in M.TABLE["titles"] if t["set"] == "ddr3mj")
    roms, discs = M.needs(t)
    with zipfile.ZipFile(os.path.join(DUMPS, "ddr3mj.zip")) as zi, \
            zipfile.ZipFile(os.path.join(sp, "renamed.zip"), "w") as zo:
        crcs = {int(M.TABLE["roms"][k]["crc"], 16) for k in roms}
        for i, info in enumerate(zi.infolist()):
            if info.CRC in crcs:
                zo.writestr(f"file{i}.bin", zi.read(info))
    os.symlink(os.path.join(DUMPS, discs[0][1] + ".chd"), os.path.join(sp, "discs", "some disc.chd"))
    rc, out = run([sp, so, "--only", "ddr3mj"])
    same = rc == 0 and all(filecmp.cmp(os.path.join(so, f), os.path.join(new, f), shallow=False)
                           for f in t["files"] if f != "ddr3mj.sav")
    check(same, "ddr3mj from renamed zip members + renamed CHD == the normal staging")

    # --- 6. output folder resolution, dry run
    print("== OUT handling", flush=True)
    root = os.path.join(work, "sdroot")
    os.makedirs(os.path.join(root, "_Arcade"))
    rc, out = run([DUMPS, root, "--only", "gchgchmp"])
    check(rc == 0 and os.path.exists(os.path.join(root, "games", "System573", "573bios_gchgchmp.bin")),
          "an SD-root OUT stages into OUT/games/System573")
    dry = os.path.join(work, "dry")
    os.makedirs(dry)
    rc, out = run([DUMPS, dry, "--dry-run", "--only", "ddrusa,dsem"])
    check(rc == 0 and not os.listdir(dry), "--dry-run writes nothing")

    if len(sys.argv) > 2:          # md5 manifest of the staged files, for comparing runs
        with open(sys.argv[2], "w") as fh:
            for f in sorted(os.listdir(new)):
                if not f.endswith(".chd"):
                    fh.write(f"{f} {os.path.getsize(os.path.join(new, f))} {md5(os.path.join(new, f))}\n")
    print()
    print(f"{'PASS' if not fails else 'FAIL'}: {len(fails)} failure(s)")
    for f in fails:
        print("   - " + f.splitlines()[0])
    shutil.rmtree(work)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
