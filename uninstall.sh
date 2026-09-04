#!/data/data/com.termux/files/usr/bin/bash
#######################################################
# uninstall.sh
#
# Removes everything terminal-setup.sh created and returns Termux to
# roughly its pre-install state.
#
# SAFE BY DEFAULT
#   Runs a dry run first. Nothing is deleted until you type DELETE.
#   Offers to back up your container home before removing it.
#
# WHAT IS NEVER TOUCHED
#   - Your device storage (~/storage, ~/Storage). The Storage entry is a
#     SYMLINK to real shared storage; only the link is removed, never
#     anything it points at.
#   - Termux itself, and any package you installed yourself.
#   - The Termux:X11 app. That is an APK; uninstall it from Android
#     Settings if you want it gone.
#   - Android developer settings (phantom process limits). Revert those
#     in Settings > Developer options if you want them back.
#
# Usage:
#   ./uninstall.sh              dry run, shows what would go
#   ./uninstall.sh --run        actually remove, with confirmation
#   ./uninstall.sh --run --keep-packages   leave host packages installed
#######################################################

set -u

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[0;90m'; NC='\033[0m'

DRY_RUN=1
KEEP_PACKAGES=0
INSTALLED=()
HAS_CONTAINER=0
HAS_BASHRC=0
for arg in "$@"; do
    case "$arg" in
        --run)            DRY_RUN=0 ;;
        --keep-packages)  KEEP_PACKAGES=1 ;;
        -h|--help)        sed -n '2,28p' "$0"; exit 0 ;;
    esac
done

[ -f "$HOME/.config/termux-ubuntu.conf" ] && source "$HOME/.config/termux-ubuntu.conf"
DISTRO_ID="${DISTRO_ID:-ubuntu}"
UBUNTU_USER="${UBUNTU_USER:-droid}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TMPDIR="${TMPDIR:-$PREFIX/tmp}"

# Scripts and configs this project created. Explicit list, no globbing:
# a wildcard here would be the easiest way to delete something of yours.
FILES=(
    "$HOME/start-linux.sh"
    "$HOME/start-linux.sh.bak"
    "$HOME/start-linux-safe.sh"
    "$HOME/start-ubuntu-cli.sh"
    "$HOME/stop-linux.sh"
    "$HOME/update-ubuntu.sh"
    "$HOME/gpu-check.sh"
    "$HOME/switch-gpu.sh"
    "$HOME/switch-vulkan.sh"
    "$HOME/whatami.sh"
    "$HOME/fix-gpu.sh"
    "$HOME/polish-desktop.sh"
    "$HOME/setup-browser.sh"
    "$HOME/terminal-setup.sh"
    "$HOME/.xfce-session.sh"
    "$HOME/.x11-cleanup.sh"
    "$HOME/.config/termux-ubuntu.conf"
    "$HOME/.config/linux-gpu.sh"
    "$HOME/.config/gpu-mode"
    "$HOME/linux-setup-errors.log"
    "$TMPDIR/virgl.log"
    "$TMPDIR/pulse-err.log"
    "$TMPDIR/pulse-err-safe.log"
)

HOST_PKGS=(
    termux-x11-nightly xorg-xrandr xkeyboard-config pulseaudio
    virglrenderer-android virglrenderer-mesa-zink angle-android
    mesa-zink vulkan-loader-generic vulkan-tools
    mesa-vulkan-icd-freedreno proot-distro
)

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${CYAN}=== DRY RUN — nothing will be deleted ===${NC}"
else
    echo -e "${RED}=== UNINSTALL — this will delete things ===${NC}"
fi
echo ""

# ---------- 1. Container ----------
echo -e "${WHITE}[1] proot-distro container${NC}"
CONTAINER_SIZE="unknown"
if proot-distro login "$DISTRO_ID" -- true >/dev/null 2>&1; then
    ROOTFS="$PREFIX/var/lib/proot-distro/installed-rootfs"
    CONTAINER_SIZE=$(du -sh "$ROOTFS" 2>/dev/null | awk '{print $1}')
    echo -e "  ${YELLOW}REMOVE${NC} container '${DISTRO_ID}' (${CONTAINER_SIZE:-?})"
    echo -e "  ${RED}This deletes /home/${UBUNTU_USER} inside it, including any work there.${NC}"
    HAS_CONTAINER=1
else
    echo -e "  ${GRAY}none found${NC}"
    HAS_CONTAINER=0
fi

# ---------- 2. Files ----------
echo ""
echo -e "${WHITE}[2] Scripts and configs${NC}"
FOUND_FILES=0
for f in "${FILES[@]}"; do
    if [ -e "$f" ]; then
        echo -e "  ${YELLOW}REMOVE${NC} ${f/#$HOME/\~}"
        FOUND_FILES=$((FOUND_FILES + 1))
    fi
done
[ "$FOUND_FILES" -eq 0 ] && echo -e "  ${GRAY}none found${NC}"

# ---------- 3. Storage symlink ----------
echo ""
echo -e "${WHITE}[3] Storage link${NC}"
if [ -L "$HOME/Storage" ]; then
    echo -e "  ${YELLOW}REMOVE${NC} ~/Storage ${GRAY}(the symlink only)${NC}"
    echo -e "  ${GREEN}KEEP${NC}   $(readlink "$HOME/Storage" 2>/dev/null) ${GRAY}(your actual files)${NC}"
else
    echo -e "  ${GRAY}no symlink found${NC}"
fi

# ---------- 4. .bashrc ----------
echo ""
echo -e "${WHITE}[4] Termux .bashrc autostart${NC}"
if grep -q "start-linux.sh" "$HOME/.bashrc" 2>/dev/null; then
    echo -e "  ${YELLOW}CLEAN${NC}  remove the auto-start block from ~/.bashrc"
    echo -e "  ${GRAY}(a backup is written to ~/.bashrc.uninstall-backup)${NC}"
    HAS_BASHRC=1
else
    echo -e "  ${GRAY}no autostart block${NC}"
    HAS_BASHRC=0
fi

# ---------- 5. Host packages ----------
echo ""
echo -e "${WHITE}[5] Termux host packages${NC}"
if [ "$KEEP_PACKAGES" -eq 1 ]; then
    echo -e "  ${GREEN}KEEP${NC} all (--keep-packages)"
else
    INSTALLED=()
    for p in "${HOST_PKGS[@]}"; do
        dpkg -l "$p" 2>/dev/null | grep -q "^ii" && INSTALLED+=("$p")
    done
    if [ ${#INSTALLED[@]} -gt 0 ]; then
        echo -e "  ${YELLOW}REMOVE${NC} ${INSTALLED[*]}"
    else
        echo -e "  ${GRAY}none of ours installed${NC}"
    fi
fi

# ---------- Never touched ----------
echo ""
echo -e "${WHITE}Never touched${NC}"
echo -e "  ${GREEN}KEEP${NC} ~/storage and everything on your device storage"
echo -e "  ${GREEN}KEEP${NC} Termux itself and packages you installed yourself"
echo -e "  ${GREEN}KEEP${NC} the Termux:X11 app ${GRAY}(remove via Android Settings)${NC}"
echo -e "  ${GREEN}KEEP${NC} Android developer options ${GRAY}(revert manually if wanted)${NC}"

# ---------- Gate ----------
echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${CYAN}Dry run complete. To actually remove:${NC}"
    echo -e "  ${WHITE}./uninstall.sh --run${NC}"
    echo ""
    exit 0
fi

if [ "$HAS_CONTAINER" -eq 1 ]; then
    echo -e "${YELLOW}Back up /home/${UBUNTU_USER} before removing the container? (Y/n): ${NC}"
    read -r DOBACKUP
    if [[ ! "$DOBACKUP" =~ ^[Nn]$ ]]; then
        DEST="$HOME/storage/shared/ubuntu-home-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
        [ -d "$HOME/storage/shared" ] || DEST="$HOME/ubuntu-home-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
        echo -e "  Backing up to: ${WHITE}${DEST}${NC}"
        if proot-distro login "$DISTRO_ID" -- tar czf - "/home/${UBUNTU_USER}" 2>/dev/null > "$DEST"; then
            echo -e "  ${GREEN}[+]${NC} backup written ($(du -h "$DEST" 2>/dev/null | awk '{print $1}'))"
        else
            echo -e "  ${RED}[!] Backup failed. Aborting uninstall so nothing is lost.${NC}"
            exit 1
        fi
    fi
fi

echo ""
echo -e "${RED}Type DELETE to confirm removal, anything else to abort:${NC}"
read -r CONFIRM
if [ "$CONFIRM" != "DELETE" ]; then
    echo -e "${GREEN}Aborted. Nothing was removed.${NC}"
    exit 0
fi

echo ""
echo -e "${CYAN}=== Removing ===${NC}"

# Stop anything running first, or removal races the live session.
[ -x "$HOME/stop-linux.sh" ] && "$HOME/stop-linux.sh" >/dev/null 2>&1
pkill -f "pulseaudio" 2>/dev/null || true
sleep 1

if [ "$HAS_CONTAINER" -eq 1 ]; then
    echo -n "  container... "
    proot-distro remove "$DISTRO_ID" >/dev/null 2>&1 && echo -e "${GREEN}done${NC}" || echo -e "${YELLOW}skipped${NC}"
fi

echo -n "  files...     "
for f in "${FILES[@]}"; do [ -e "$f" ] && rm -f "$f"; done
echo -e "${GREEN}done${NC}"

# rm on a symlink removes the link, not the target. -f only, never -r.
if [ -L "$HOME/Storage" ]; then
    echo -n "  storage link... "
    rm -f "$HOME/Storage" && echo -e "${GREEN}done${NC}"
fi

if [ "$HAS_BASHRC" -eq 1 ]; then
    echo -n "  .bashrc...   "
    cp "$HOME/.bashrc" "$HOME/.bashrc.uninstall-backup"
    sed -i '/# Auto-start Ubuntu XFCE desktop/,/^esac$/d' "$HOME/.bashrc"
    sed -i '/start-linux.sh/d' "$HOME/.bashrc"
    echo -e "${GREEN}done${NC} ${GRAY}(backup: ~/.bashrc.uninstall-backup)${NC}"
fi

if [ "$KEEP_PACKAGES" -eq 0 ] && [ ${#INSTALLED[@]} -gt 0 ]; then
    echo -n "  packages...  "
    DEBIAN_FRONTEND=noninteractive apt-get remove -y "${INSTALLED[@]}" >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1
    echo -e "${GREEN}done${NC}"
fi

echo ""
echo -e "${GREEN}=== Uninstalled ===${NC}"
echo ""
echo -e "  Your device storage and Termux itself are untouched."
echo -e "  Remaining manual steps, if you want them:"
echo -e "    - Uninstall the ${WHITE}Termux:X11${NC} app in Android Settings"
echo -e "    - Revert ${WHITE}Developer options > Disable child process restrictions${NC}"
echo -e "    - Delete this script: ${WHITE}rm ~/uninstall.sh${NC}"
echo ""
