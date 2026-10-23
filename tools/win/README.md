# Windows-side tooling (all work on this project runs on the Windows PC)

Two one-time steps, then everything else arrives as job files.

## 1. WSL Ubuntu (the Linux side: simulators, firmware cross-build)

In an **administrator** PowerShell:

```powershell
wsl --install -d Ubuntu-24.04
```

Reboot if it asks. On first launch Ubuntu asks for a username and password —
anything; the job runner uses the `root` account, which WSL allows without a
password. Check it works:

```powershell
wsl -d Ubuntu-24.04 -u root -- uname -a
```

## 2. The job runner

In an ordinary PowerShell window, leave this running:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\ricky\Documents\System573_MiSTer\tools\win\jobrunner.ps1
```

It executes job files that appear in `local\jobs\queue\` in name order
(`.cmd` → cmd.exe, `.ps1` → PowerShell, `.sh` → WSL Ubuntu as root, from the
project directory) and leaves `NAME.log` + `NAME.rc` in `local\jobs\done\`.
Each job is a readable file before it runs and its full output is kept, so the
paper trail is complete. `local\` is git-ignored.

The queued jobs at the time of writing:

| job | does |
|---|---|
| `001-setup-ubuntu.sh` | `tools/wsl/setup-ubuntu.sh`: apt (Icarus, GHDL, build tools), builds NVC from source, installs the updated `sim/Makefile` |
| `002-sims.sh` | the Icarus suite: the four profile/mailbox benches first, then the whole suite |
| `003-fw-inputs.sh` | downloads the ARM 10.2 toolchain, the newest STABLE Main_MiSTer release (its source at the release commit + the stock binary; `MAIN_RELEASE=YYYYMMDD` pins one) and minimp3.h into `Documents` |
| `004-fw-build.sh` | `tools/build-hps-mp3.sh all` → `out/MiSTer_System573` |

Quartus builds can run the same way (`NNN-quartus.cmd` calling
`tools\build-573.ps1 -Crt`), so a build no longer needs anyone at the keyboard.
