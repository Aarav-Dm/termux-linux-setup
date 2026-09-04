#!/data/data/com.termux/files/usr/bin/bash
#######################################################
# nuke.sh — one command, no prompts, DroidDesk-aware
#
# Wipes this project completely and leaves Termux in the state DroidDesk
# expects. No dry run, no confirmation, no questions.
#
# WHY THIS IS NOT "rm -rf everything"
#   DroidDesk (orailnoor/DroidDesk) runs on the SAME stack this project
#   does: Termux, Termux:X11, TUR, and Proot. Ripping out those shared
#   packages would not give you a cleaner slate — it would just force
#   DroidDesk to redownload them, and uninstalling the Termux:X11 APK
#   would actively break it.
#
#   So this removes everything that is OURS and leaves the shared
#   foundation intact. That is the state DroidDesk wants.
#
# REMOVED
#   - the proot-distro Ubuntu container (the multi-GB part)
#   - every script and config this project wrote
#   - the ~/Storage symlink (the link only, never your files)
#   - the .bashrc autostart block   <-- would fight DroidDesk every launch
#   - stale X11 sockets and any running session
#
# KEPT (DroidDesk needs these)
#   Termux · Termux:X11 APK · proot-distro · termux-x11-nightly
#   x11-repo · tur-repo · pulseaudio · your device storage
#
# BACKUP
#   If the container home holds more than ~50 MB it is tarred to shared
#   storage first, automatically, no prompt. Below that it is assumed to
#   be a fresh install and skipped. Force either way with
#   --backup / --no-backup.
#
# Usage:
#   ./nuke.sh                    remove ours, keep DroidDesk's deps
#   ./nuke.sh --purge-packages   also remove the shared Termux packages
#   ./nuke.sh --no-backup        never back up, fastest
#######################################################

set -u

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'
C='\033[0;36m'; W='\033[1;37m'; GR='\033[0;90m'; N='\033[0m'

PURGE=0
BACKUP_MODE="auto"
for a in "$@"; do
    case "$a" in
        --purge-packages) PURGE=1 ;;
        --no-backup)      BACKUP_MODE="never" ;;
        --backup)         BACKUP_MODE="always" ;;
    esac
done

[ -f "$HOME/.config/termux-ubuntu.conf" ] && source "$HOME/.config/termux-ubuntu.conf"
DISTRO_ID="${DISTRO_ID:-ubuntu}"
UBUNTU_USER="${UBUNTU_USER:-droid}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TMPDIR="${TMPDIR:-$PREFIX/tmp}"

echo ""
echo -e "${R}=== NUKE — removing this project now ===${N}"
echo ""

# ---------- 1. Stop everything ----------
echo -n "  stopping session...   "
[ -x "$HOME/stop-linux.sh" ] && "$HOME/stop-linux.sh" >/dev/null 2>&1
command -v am >/dev/null 2>&1 && am force-stop com.termux.x11 >/dev/null 2>&1
pkill -f "com.termux.x11" 2>/dev/null
pkill -f "termux-x11" 2>/dev/null
pkill -f "virgl_test_server" 2>/dev/null
pkill -f "pulseaudio" 2>/dev/null
pkill -f "proot" 2>/dev/null
sleep 2
echo -e "${G}done${N}"

# ---------- 2. Backup if the container holds real work ----------
if proot-distro login "$DISTRO_ID" -- true >/dev/null 2>&1; then
    DO_BACKUP=0
    if [ "$BACKUP_MODE" = "always" ]; then
        DO_BACKUP=1
    elif [ "$BACKUP_MODE" = "auto" ]; then
        HOME_KB=$(proot-distro login "$DISTRO_ID" -- du -sk "/home/${UBUNTU_USER}" 2>/dev/null | awk '{print $1}')
        HOME_KB=${HOME_KB:-0}
        # >50MB means you actually did something in there.
        [ "$HOME_KB" -gt 51200 ] && DO_BACKUP=1
        echo -e "  container home:       ${W}$((HOME_KB / 1024)) MB${N}"
    fi

    if [ "$DO_BACKUP" -eq 1 ]; then
        DEST="$HOME/storage/shared/ubuntu-home-$(date +%Y%m%d-%H%M%S).tar.gz"
        [ -d "$HOME/storage/shared" ] || DEST="$HOME/ubuntu-home-$(date +%Y%m%d-%H%M%S).tar.gz"
        echo -n "  backing up home...    "
        if proot-distro login "$DISTRO_ID" -- tar czf - "/home/${UBUNTU_USER}" 2>/dev/null > "$DEST"; then
            echo -e "${G}done${N} ${GR}$(du -h "$DEST" 2>/dev/null | awk '{print $1}')${N}"
            echo -e "  ${GR}-> ${DEST}${N}"
        else
            rm -f "$DEST"
            echo -e "${Y}skipped (nothing to save)${N}"
        fi
    else
        echo -e "  backup:               ${GR}skipped, home is essentially empty${N}"
    fi

    echo -n "  removing container... "
    proot-distro remove "$DISTRO_ID" >/dev/null 2>&1
    # Older aliases, in case the container was made before release pinning.
    for alt in ubuntu ubuntu-24.04 ubuntu-22.04 "ubuntu:24.04" "ubuntu:26.04"; do
        [ "$alt" = "$DISTRO_ID" ] && continue
        proot-distro remove "$alt" >/dev/null 2>&1
    done
    echo -e "${G}done${N}"
else
    echo -e "  container:            ${GR}none found${N}"
fi

# ---------- 3. Our files ----------
echo -n "  removing scripts...   "
for f in \
    "$HOME/start-linux.sh" "$HOME/start-linux.sh.bak" "$HOME/start-linux-safe.sh" \
    "$HOME/start-ubuntu-cli.sh" "$HOME/stop-linux.sh" "$HOME/update-ubuntu.sh" \
    "$HOME/gpu-check.sh" "$HOME/switch-gpu.sh" "$HOME/switch-vulkan.sh" \
    "$HOME/whatami.sh" "$HOME/fix-gpu.sh" "$HOME/polish-desktop.sh" \
    "$HOME/setup-browser.sh" "$HOME/terminal-setup.sh" "$HOME/uninstall.sh" \
    "$HOME/.xfce-session.sh" "$HOME/.x11-cleanup.sh" \
    "$HOME/.config/termux-ubuntu.conf" "$HOME/.config/linux-gpu.sh" \
    "$HOME/.config/gpu-mode" "$HOME/linux-setup-errors.log" \
    "$TMPDIR/virgl.log" "$TMPDIR/pulse-err.log" "$TMPDIR/pulse-err-safe.log" \
    ; do
    rm -f "$f" 2>/dev/null
done
echo -e "${G}done${N}"

# ---------- 4. Storage symlink (link only) ----------
echo -n "  storage link...       "
if [ -L "$HOME/Storage" ]; then
    rm -f "$HOME/Storage"   # -f not -r: cannot reach through the symlink
    echo -e "${G}done${N} ${GR}(your files untouched)${N}"
else
    echo -e "${GR}none${N}"
fi

# ---------- 5. .bashrc — the one that would fight DroidDesk ----------
echo -n "  .bashrc autostart...  "
if grep -q "start-linux.sh" "$HOME/.bashrc" 2>/dev/null; then
    cp "$HOME/.bashrc" "$HOME/.bashrc.pre-nuke"
    sed -i '/# Auto-start Ubuntu XFCE desktop/,/^esac$/d' "$HOME/.bashrc"
    sed -i '/start-linux.sh/d' "$HOME/.bashrc"
    echo -e "${G}removed${N} ${GR}(backup: ~/.bashrc.pre-nuke)${N}"
else
    echo -e "${GR}none${N}"
fi

# ---------- 6. Stale X11 sockets ----------
echo -n "  stale sockets...      "
rm -rf "$TMPDIR/.X11-unix" 2>/dev/null
mkdir -p "$TMPDIR/.X11-unix" 2>/dev/null
chmod 1777 "$TMPDIR/.X11-unix" 2>/dev/null
echo -e "${G}done${N}"

# ---------- 7. Packages (opt-in only) ----------
if [ "$PURGE" -eq 1 ]; then
    echo -n "  purging packages...   "
    DEBIAN_FRONTEND=noninteractive apt-get remove -y \
        termux-x11-nightly xorg-xrandr xkeyboard-config pulseaudio \
        virglrenderer-android virglrenderer-mesa-zink angle-android \
        mesa-zink vulkan-loader-generic vulkan-tools \
        mesa-vulkan-icd-freedreno proot-distro >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1
    echo -e "${G}done${N}"
    echo -e "  ${Y}Note: DroidDesk will redownload most of these.${N}"
else
    echo -e "  packages:             ${GR}kept — DroidDesk needs them${N}"
fi

echo ""
echo -e "${G}=== Clean ===${N}"
echo ""
echo -e "  ${W}Kept for DroidDesk:${N} Termux, Termux:X11 APK, proot-distro,"
echo -e "  termux-x11-nightly, x11-repo, tur-repo, and your device storage."
echo ""
echo -e "  ${W}Next:${N} restart Termux so the old .bashrc stops loading, then"
echo -e "  follow DroidDesk's install steps:"
echo -e "  ${C}https://github.com/orailnoor/DroidDesk${N}"
echo ""
echo -e "  ${GR}Finally: rm ~/nuke.sh${N}"
echo ""
