# termux-linux-setup — Galaxy Tab S8 Ultra / S9 Ultra

A hardened fork of [Unterschreiber/termux-linux-setup](https://github.com/Unterschreiber/termux-linux-setup) (itself a fork of [orailnoor/termux-linux-setup](https://github.com/orailnoor/termux-linux-setup)), extended to cover the **Galaxy Tab S9 Ultra** and with a batch of real installer and startup bugs fixed.

**One script.** It sets up a minimal Termux host, installs **Ubuntu 24.04** through `proot-distro`, puts a lean **XFCE4** desktop inside it, and renders that through **Termux:X11** with Turnip/Zink GPU acceleration on Adreno.

| | |
|---|---|
| **Host** | Termux, kept minimal (X11 server, PulseAudio, proot-distro, GPU drivers) |
| **Guest** | Ubuntu 24.04 LTS via proot-distro |
| **Desktop** | XFCE4 lean set, not `xubuntu-desktop` |
| **GPU** | Turnip + Zink on Adreno, VirGL/llvmpipe fallback |

Tested targets: **Tab S8 Ultra** (SD 8 Gen 1 / Adreno 730) and **Tab S9 Ultra** (SD 8 Gen 2 for Galaxy / Adreno 740). Both share the same 14.6in 2960x1848 panel, so one script covers both.

---

## What this fork fixes

These are real failures hit on a Tab S9 Ultra, with the cause in each case.

| # | Bug | Cause | Fix |
|---|---|---|---|
| 1 | `Installing Mesa Zink core... (failed)` | `mesa-zink` lives in **tur-repo**, which was never installed | Install `x11-repo` **and** `tur-repo`, then refresh |
| 2 | `Installing Vulkan loader... (failed)` | `vulkan-loader-generic` and `vulkan-loader-android` **conflict**; one was already present | Remove the conflicting loader first, then install the chosen path |
| 3 | `/tmp/pulse-err.log: Permission denied` | `/tmp` is Android's root filesystem and is **not writable** from Termux | All logs moved to `$TMPDIR` (`$PREFIX/tmp`) |
| 4 | `X server already running on display :0` then `xrdb: Connection refused` | `pkill` left a **stale socket** at `$TMPDIR/.X11-unix/X0`; the wait loop saw it and launched XFCE against a server that was not listening | `am force-stop com.termux.x11`, delete the stale socket, and use `termux-x11 -xstartup` so the server launches the session itself |
| 5 | Silently ignored X11 flags | `-ac` and `-xkbdir` are **not** termux-x11 flags | Removed. XKB now comes from `XKB_CONFIG_ROOT` |
| 6 | Unrelated processes killed | `pkill -9 -f "dbus"` matched every dbus on the device | Narrowed to `dbus-daemon --session` and `dbus-launch` |
| 7 | Possible Termux boot loop | autostart ran on every shell, including non-interactive ones | Guarded to interactive shells, skipped when `DISPLAY` is set, 3s Ctrl+C window |
| 8 | Broken shebang risk | script was committed with **CRLF** line endings | Normalised to LF |
| 9 | `MESA: error: ZINK: failed to choose pdev` / `failed to load driver: zink` | **zink runs inside the guest, but Turnip was only installed on the host.** Under PRoot the guest has its own `/usr/lib` and its own Vulkan loader, so it enumerated zero devices. `MESA_LOADER_DRIVER_OVERRIDE=zink` then forbade any fallback, turning a slow desktop into no desktop | Install `mesa-vulkan-drivers` + `libgl1-mesa-dri` **in the guest**, stop forcing the loader override, bind `/dev/kgsl-3d0`, and add a three-way GPU mode switch |
| 10 | `lost connection to rendering server` / `proot: vpid 1: terminated with signal 6` | Two host-side faults in the VirGL bridge. `virgl_test_server_android` was launched with `--use-egl-surfaceless --use-gles`, which belong to the *generic* `virgl_test_server`; the `_android` build exits when given them, so the guest connected to a dead server and aborted. And removing `GALLIUM_DRIVER` from the host env file (correct, it was leaking) also starved the VirGL server itself, which needs a GPU driver to do the real work | Launch the `_android` build bare, **scope** the GPU vars to that subshell so they never reach the guest, verify the server survived 2s, and auto-fall-back to software if it did not |

### GPU modes

`./switch-gpu.sh virgl|zink|software`

| Mode | How it works | When to use |
|---|---|---|
| **virgl** (default) | Host runs `virgl_test_server_android` and does the real GPU work on Adreno; the guest talks to it via `GALLIUM_DRIVER=virpipe` | Most reliable path under PRoot. Start here |
| **zink** | Turnip inside the guest, with `VK_ICD_FILENAMES` pointed at the freedreno ICD | Fastest when the guest ships a working ICD |
| **software** | llvmpipe | Always works. Use to prove the desktop itself is healthy |

Already installed and hitting the zink error? Repair without reinstalling:

```bash
curl -O https://raw.githubusercontent.com/Aarav-Dm/termux-linux-setup/main/fix-gpu.sh
chmod +x fix-gpu.sh && ./fix-gpu.sh
./stop-linux.sh && ./start-linux.sh
```

### On the Vulkan loader choice

The two loaders are mutually exclusive:

- **Turnip path (default)** — `vulkan-loader-generic` + `mesa-vulkan-icd-freedreno` + `mesa-zink`. Open-source Turnip driver talking to KGSL.
- **Android path (fallback)** — `vulkan-loader-android` + `mesa-zink`. Uses Qualcomm's system Vulkan driver. Known to crash zink on some Adreno parts with a memory-type assertion ([TUR issue #530](https://github.com/termux-user-repository/tur/issues/530), reported on Tab S8+, S22 Ultra, S23 Ultra).

The script defaults to Turnip. Switch at any time with `./switch-vulkan.sh android`.

---

## Prerequisites

Install both apps **before** running the script. Their versions must match each other.

**1. Termux** — not from Google Play, that build is unmaintained.
- [F-Droid](https://f-droid.org/en/packages/com.termux/) or [GitHub releases](https://github.com/termux/termux-app/releases)

**2. Termux:X11 (nightly)** — the display server that renders the desktop.
- [Nightly release](https://github.com/termux/termux-x11/releases/tag/nightly) — grab `app-arm64-v8a-debug.apk` or `termux-x11-universal-debug.apk`

> The APK must be the **nightly** build, because the script installs the `termux-x11-nightly` package. A mismatch between APK and package produces exactly the "X server already running / Connection refused" symptoms this fork fixes.

Open each app once after installing.

**Recommended:** enable **Settings → Developer options → Disable child process restrictions**. Android otherwise kills background Termux processes once they exceed the phantom process limit.

---

## Install

In Termux:

```bash
curl -O https://raw.githubusercontent.com/Aarav-Dm/termux-linux-setup/main/terminal-setup.sh
chmod +x terminal-setup.sh
./terminal-setup.sh
```

Roughly **15 to 40 minutes** depending on your connection. Needs about **8 GB free**.

The script runs 10 steps: pre-flight checks, host update, host base packages and the Vulkan stack, Ubuntu rootfs, Ubuntu bootstrap and user creation, XFCE4, GPU tools, dev tools, shared storage, launchers, and desktop shortcuts.

Anything that fails is logged to `~/linux-setup-errors.log` and listed in a summary at the end rather than failing silently.

---

## Usage

```bash
./start-linux.sh
```

It opens the Termux:X11 app for you. Switch to that app to see the desktop.

| Command | What it does |
|---|---|
| `./start-linux.sh` | Start the XFCE4 desktop with GPU acceleration |
| `./start-linux-safe.sh` | Software rendering + `-legacy-drawing`, for black screens |
| `./start-ubuntu-cli.sh` | Ubuntu shell only, no desktop |
| `./gpu-check.sh` | Show which Vulkan loader and renderer are active |
| `./switch-gpu.sh virgl\|zink\|software` | Swap the GPU rendering mode |
| `./switch-vulkan.sh turnip\|android` | Swap the host Vulkan loader |
| `./update-ubuntu.sh` | Update the Termux host and the Ubuntu container |
| `./setup-browser.sh firefox\|chromium` | Install a browser that actually runs under PRoot |
| `./polish-desktop.sh` | Silence fixable XFCE startup noise, install wallpapers, drop light-locker |
| `./stop-linux.sh` | Stop the desktop and clean up sockets |

### Verifying GPU acceleration

Inside the XFCE terminal:

```bash
glxinfo -B | head -20
```

You want **zink**, **Turnip**, or **Adreno**. If it says **llvmpipe**, you are on software rendering — try `./switch-vulkan.sh android`, then restart the desktop.

---

---

## Startup warnings you can ignore

The desktop prints a handful of warnings on every launch. Most are permanent: XFCE expects systemd, logind and a system dbus, and PRoot provides none of them. They are noise, not faults.

**Fixable — run `./polish-desktop.sh` once:**

| Message | Cause | Fix |
|---|---|---|
| `xubuntu-wallpaper.png: No such file` and a black desktop | that wallpaper ships in `xubuntu-wallpapers`, which the lean XFCE install skips | installs the wallpaper package (data-only, no desktop pulled in) and points xfdesktop at a real image |
| `Another compositing manager is running on screen 0` | xfwm4 composites on top of Termux:X11, which already does | disables xfwm4 compositing |
| `light-locker: session_id is not set` | the screen locker needs logind. Worse than noise: it can show a lock screen you cannot dismiss | removes light-locker and blocks its autostart |

**Permanent and harmless — no fix exists in PRoot:**

`Failed to get a systemd proxy` · `Failed to connect to colord` · `polkit ... Error getting authority` · `Failed to get system bus` · `GVFS-RemoteVolumeMonitor ... not supported` · `_IceTransmkdir: euid != 0` · `Failed to fetch _NET_CURRENT_DESKTOP` (startup race, resolves itself) · `pm-is-supported` missing (suspend/resume, meaningless on a tablet)

---

### Why the browser icon is there but nothing opens

Two separate structural problems, neither of them your install going wrong.

**The snap trap.** On Ubuntu 22.04 and later, `apt install firefox` and `apt install chromium-browser` install *transitional* packages whose only job is to pull the snap. `terminal-setup.sh` blocks snapd deliberately, because snap cannot function under PRoot at all. The transitional package still drops a `.desktop` file, so you get a menu icon backed by a binary that can never start.

**The sandbox.** Chromium's sandbox is built on unprivileged user namespaces. PRoot emulates syscalls with ptrace and cannot provide them, so Chromium dies while spawning its child processes. That is the "child process" error. `--no-sandbox` is mandatory here, not a workaround.

`./setup-browser.sh` removes the transitional package, installs a real `.deb` from the mozillateam PPA (or xtradeb for Chromium), pins apt so it does not silently revert to the snap, and writes a launcher with the required flags baked in.

**Security:** a no-sandbox browser has no isolation between tabs. Use it for docs, search and testing. Sign in to banking, university and email accounts in Android Chrome instead.

### "It looks old"

Two different things get read as "old":

- **The Ubuntu release.** `./setup-browser.sh` prints it. The `uname` line will show an *Android* kernel version, because PRoot shares the host kernel. That is not the Ubuntu release and cannot be upgraded from inside the container.
- **XFCE itself.** XFCE's default theme is deliberately conservative and looks a decade old out of the box. That is styling, not staleness. `apt install arc-theme papirus-icon-theme` then Settings → Appearance changes it in a minute.

If the desktop feels *slow* rather than looks dated, check the renderer with `glxinfo -B | head -20` inside the desktop. `llvmpipe` means software rendering, and `./switch-gpu.sh` is the fix.

---

## What's installed

| Category | Tools |
|---|---|
| Desktop | XFCE4 (session, panel, xfwm4, xfdesktop, settings), Thunar, Mousepad, Whisker menu |
| Graphics | Mesa Zink, Turnip Vulkan ICD, VirGL fallback, mesa-utils, vulkan-tools |
| Audio | PulseAudio with a TCP bridge into the container, pavucontrol |
| Dev | Python 3 + pip + venv, Git, Neovim, Vim |
| Build | build-essential, clang, cmake, pkg-config |
| Network | OpenSSH client and server, net-tools, iproute2, nmap, curl, wget, rsync |
| Fonts | DejaVu, Liberation |
| Storage | Device storage at `~/Storage` on the host, `/mnt/shared` inside Ubuntu |

---

## Troubleshooting

**A package failed to install.** Check `~/linux-setup-errors.log`. For the Vulkan or Zink packages specifically:

```bash
pkg install -y x11-repo tur-repo
apt update && apt-get -f install -y
./switch-vulkan.sh turnip
```

**`X server already running on display :0`.** Stale socket from a previous run:

```bash
./stop-linux.sh
./start-linux.sh
```

If it persists, force it clean:

```bash
am force-stop com.termux.x11
rm -rf $TMPDIR/.X11-unix
```

**Black screen with only a cursor.** Use `./start-linux-safe.sh`, which adds `-legacy-drawing`.

**`Process completed (signal 9)`.** Android's phantom process killer. Enable *Disable child process restrictions* in Developer options, or from a PC:

```bash
adb shell "/system/bin/device_config set_sync_disabled_for_tests persistent"
adb shell "/system/bin/device_config put activity_manager max_phantom_processes 2147483647"
adb shell settings put global settings_enable_monitor_phantom_procs false
```

**No sound.** Check `$TMPDIR/pulse-err.log`. The desktop still runs without audio.

**No storage access.** Run `termux-setup-storage`, grant the permission, then `ln -sfn ~/storage/shared ~/Storage`.

**Running alongside omarchy-android or another X11 desktop.** Both claim display `:0` and will fight. Run `./stop-linux.sh` before switching.

**Starting over.**

```bash
./stop-linux.sh
proot-distro remove ubuntu
./terminal-setup.sh
```

---

## Notes and limits

Everything here runs under **PRoot**, a userspace syscall translation layer, not a virtual machine. Consequences that no version of this script can fix:

- **No Docker.** The Android kernel lacks the namespaces it needs. Root would not help.
- **No systemd.** No `systemctl`, no service units.
- **No x86 binaries** without QEMU emulation.
- **File I/O is slow.** CPU-bound work runs near native; anything touching thousands of files pays a large penalty.
- **PRoot is not a security boundary.**

---

## Credits

Original by [orailnoor](https://github.com/orailnoor/termux-linux-setup). Tab S8 Ultra fork by [Unterschreiber](https://github.com/Unterschreiber/termux-linux-setup). This fork adds Tab S9 Ultra support and the bug fixes listed above.
