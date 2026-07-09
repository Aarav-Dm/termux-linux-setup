# termux-linux-setup (Unterschreiber Edition)

An optimized fork of [orailnoor/termux-linux-setup](https://github.com/orailnoor/termux-linux-setup), tuned specifically for the **Samsung Galaxy Tab S8 Ultra** (Snapdragon 8 Gen 1 / Adreno 730, 12GB RAM, 256GB storage).

This version trims the original down to a single, lightweight XFCE4 desktop and adds automatic storage integration, better error handling, and a more reliable startup script — instead of offering four desktop environments and Windows app support most tablet users won't need.

### What's different from the original
- **XFCE4 only** — no LXQt/MATE/KDE picker, since XFCE is the best RAM/performance fit for this hardware
- **No Wine/Hangover** — Windows app support removed to keep the install lean
- **No Firefox/VLC bundled** — install whatever browser/player you actually use from Termux yourself
- **Turnip/Adreno GPU acceleration** hardcoded for the Adreno 730, no brand-detection guesswork
- **Automatic shared storage setup** — runs `termux-setup-storage` and links `~/Storage` to your device's shared storage automatically
- **Real error handling** — failed package installs are logged to `~/linux-setup-errors.log` and reported at the end instead of silently failing
- **Smarter start-linux.sh** — checks that X11 and audio actually started instead of just guessing with fixed `sleep` delays
- **Optional auto-launch** — choose whether the desktop starts automatically every time you open Termux

## Prerequisites

Before running this script, install the correct versions of these two apps on your tablet.

1. **Termux Base App**: Do not install Termux from the Google Play Store — that version is outdated and no longer works correctly. Get the official, maintained version from F-Droid:
   * [Download Termux (F-Droid)](https://f-droid.org/en/packages/com.termux/)

2. **Termux-X11 App**: This is the display server that actually renders your Linux desktop on screen. It's no longer on F-Droid, so grab the companion APK (`app-arm64-v8a-debug.apk`) directly from GitHub releases:
   * [Download Termux-X11 Nightly (GitHub)](https://github.com/termux/termux-x11/releases/tag/nightly)

Install both APKs before continuing.

## How to Install

Open **Termux** on your tablet and run:

```bash
curl -O https://raw.githubusercontent.com/Unterschreiber/termux-linux-setup/main/setup.sh && chmod +x setup.sh && ./setup.sh
```

The script will:
1. Run pre-flight checks (internet connection, free storage space)
2. Update Termux packages
3. Install Termux-X11 and XFCE4
4. Install Turnip GPU acceleration for the Adreno 730
5. Install PulseAudio
6. Install Python, Git, Neovim/Vim, build tools, SSH, and network tools
7. Set up automatic shared storage access at `~/Storage`
8. Create `start-linux.sh` and `stop-linux.sh`
9. Add desktop shortcuts

Installation takes roughly 15–30 minutes depending on your connection.

## Usage

Once the install finishes, open the **Termux-X11** app first (it just needs to be open, not doing anything), then in Termux run:

```bash
./start-linux.sh
```

Switch to the Termux-X11 app to see your XFCE4 desktop. When you're done:

```bash
./stop-linux.sh
```

If you chose auto-launch during setup, the desktop starts automatically every time you open Termux.

## What's Installed

| Category | Tools |
|---|---|
| Desktop | XFCE4, Thunar file manager, XFCE4 Terminal |
| Graphics | Mesa/Zink, Turnip Vulkan driver (Adreno 730) |
| Audio | PulseAudio |
| Dev | Python 3, pip, Git, Neovim, Vim |
| Build tools | build-essential, clang, cmake, pkg-config |
| SSH | OpenSSH (client + server) |
| Networking | net-tools, iproute2, nmap, curl, wget, rsync |
| Storage | Shared device storage auto-linked to `~/Storage` |

## Troubleshooting

- **A package failed to install**: check `~/linux-setup-errors.log` for details, then retry with `apt-get update && apt-get install <package-name>`.
- **Desktop won't start / X11 errors**: make sure the Termux-X11 app is installed and opened before running `./start-linux.sh`.
- **No storage access**: run `termux-setup-storage` manually, grant the permission, then run `ln -sfn ~/storage/shared ~/Storage`.
- **No sound**: check `/tmp/pulse-err.log`, created automatically if PulseAudio fails to start.

## Credits

Based on the original work by [Unterschreiber/termux-linux-setup](https://github.com/Unterschreiber/termux-linux-setup). This fork is maintained by Orailnoor as a leaner, device-specific build for the Galaxy Tab S8 Ultra.
