#!/data/data/com.termux/files/usr/bin/bash
#######################################################
# fix-gpu.sh
#
# Standalone repair for:
#   MESA: error: ZINK: failed to choose pdev
#   glx: failed to create drisw screen
#   failed to load driver: zink
#
# ROOT CAUSE
#   zink runs INSIDE the Ubuntu guest, but the Turnip Vulkan driver
#   was only installed on the Termux HOST. Under proot the guest has
#   its own /usr/lib and its own Vulkan loader, so it enumerates zero
#   physical devices -> "failed to choose pdev".
#
#   Worse, MESA_LOADER_DRIVER_OVERRIDE=zink forbids Mesa from falling
#   back to software, so instead of a slow desktop you get no GL at all.
#
# WHAT THIS DOES
#   1. Installs the Vulkan/DRI drivers the GUEST was missing.
#   2. Adds a GPU mode switch with three modes.
#   3. Rewrites ~/.xfce-session.sh to honour the selected mode and to
#      stop force-overriding the Mesa loader.
#
# MODES
#   virgl    (default) Host runs virgl_test_server_android and does the
#            real GPU work on Adreno; guest talks to it with
#            GALLIUM_DRIVER=virpipe. Most reliable path under proot.
#   zink     Turnip inside the guest. Fastest when it works, but depends
#            on the guest shipping a usable freedreno ICD.
#   software llvmpipe. Always works. Use to prove the desktop is fine.
#
# Run:  chmod +x fix-gpu.sh && ./fix-gpu.sh
#######################################################

set -u

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

[ -f "$HOME/.config/termux-ubuntu.conf" ] && source "$HOME/.config/termux-ubuntu.conf"
DISTRO_ID="${DISTRO_ID:-ubuntu}"
UBUNTU_USER="${UBUNTU_USER:-droid}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TMPDIR="${TMPDIR:-$PREFIX/tmp}"
export TMPDIR

echo ""
echo -e "${CYAN}=== GPU repair for Termux + proot-distro ===${NC}"
echo ""

if ! command -v proot-distro >/dev/null 2>&1; then
    echo -e "${RED}[!] proot-distro not found. Run terminal-setup.sh first.${NC}"
    exit 1
fi
if ! proot-distro login "$DISTRO_ID" -- true >/dev/null 2>&1; then
    echo -e "${RED}[!] Container '$DISTRO_ID' not found.${NC}"
    exit 1
fi

# ---------- 1. HOST: the virgl + zink pieces ----------
echo -e "${WHITE}[1/5] Host packages...${NC}"
pkg install -y x11-repo tur-repo >/dev/null 2>&1 || true
apt-get update -y >/dev/null 2>&1 || true

for p in virglrenderer-android virglrenderer-mesa-zink angle-android mesa-zink; do
    if apt-get install -y "$p" >/dev/null 2>&1; then
        echo -e "  ${GREEN}[+]${NC} $p"
    else
        echo -e "  ${YELLOW}[-]${NC} $p (not available, continuing)"
    fi
done

# ---------- 2. GUEST: the drivers that were actually missing ----------
# This is the fix. Without mesa-vulkan-drivers in the guest there is no
# ICD for zink to find, hence "failed to choose pdev".
echo ""
echo -e "${WHITE}[2/5] Guest drivers (this is the missing piece)...${NC}"
proot-distro login "$DISTRO_ID" -- env DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC bash -lc '
apt-get update -y >/dev/null 2>&1
apt-get install -y \
    mesa-vulkan-drivers \
    libgl1-mesa-dri \
    libglx-mesa0 \
    libgl1 \
    libvulkan1 \
    libegl1 \
    libgles2 \
    mesa-utils \
    vulkan-tools \
    xdg-desktop-portal >/dev/null 2>&1
echo "  guest drivers installed"
' 2>&1 | tail -2

echo -e "  ${GREEN}[+]${NC} mesa-vulkan-drivers + libgl1-mesa-dri installed in $DISTRO_ID"

# ---------- 3. Mode file + switcher ----------
echo ""
echo -e "${WHITE}[3/5] Installing GPU mode switch...${NC}"
mkdir -p "$HOME/.config"
[ -f "$HOME/.config/gpu-mode" ] || echo "virgl" > "$HOME/.config/gpu-mode"

cat > "$HOME/switch-gpu.sh" << 'SWEOF'
#!/data/data/com.termux/files/usr/bin/bash
# Usage: ./switch-gpu.sh virgl|zink|software
set -u
MODE="${1:-}"
case "$MODE" in
  virgl|zink|software)
    echo "$MODE" > "$HOME/.config/gpu-mode"
    echo "[+] GPU mode set to: $MODE"
    echo "    Restart the desktop:  ./stop-linux.sh && ./start-linux.sh"
    ;;
  *)
    echo "Current mode: $(cat "$HOME/.config/gpu-mode" 2>/dev/null || echo virgl)"
    echo ""
    echo "Usage: $0 virgl|zink|software"
    echo ""
    echo "  virgl    - host does the GPU work, guest uses virpipe."
    echo "             Most reliable under proot. Default."
    echo "  zink     - Turnip inside the guest. Fastest when it works."
    echo "  software - llvmpipe. Always works, no GPU."
    exit 1 ;;
esac
SWEOF
chmod +x "$HOME/switch-gpu.sh"
echo -e "  ${GREEN}[+]${NC} ~/switch-gpu.sh"

# ---------- 4. Rewrite the session launcher ----------
echo ""
echo -e "${WHITE}[4/5] Rewriting ~/.xfce-session.sh...${NC}"

cat > "$HOME/.xfce-session.sh" << 'SESSIONEOF'
#!/data/data/com.termux/files/usr/bin/bash
set -u

[ -f "$HOME/.config/termux-ubuntu.conf" ] && source "$HOME/.config/termux-ubuntu.conf"
DISTRO_ID="${DISTRO_ID:-ubuntu}"
UBUNTU_USER="${UBUNTU_USER:-droid}"

GPU_MODE="$(cat "$HOME/.config/gpu-mode" 2>/dev/null || echo virgl)"
[ "${SOFTWARE_MODE:-0}" = "1" ] && GPU_MODE="software"

BIND_ARGS=(--shared-tmp)
if [ -d "$HOME/storage/shared" ]; then
    if proot-distro login --help 2>&1 | grep -q -- '--bind'; then
        BIND_ARGS+=(--bind "$HOME/storage/shared:/mnt/shared")
    fi
fi
# Expose the Adreno kernel node so an in-guest Turnip can reach the GPU.
[ -e /dev/kgsl-3d0 ] && BIND_ARGS+=(--bind /dev/kgsl-3d0:/dev/kgsl-3d0)

LOGIN_USER="root"
if proot-distro login "$DISTRO_ID" -- id "$UBUNTU_USER" >/dev/null 2>&1; then
    LOGIN_USER="$UBUNTU_USER"
fi

case "$GPU_MODE" in
  virgl)
    # Host-side GPU. Never override the Mesa loader here: virpipe IS the
    # gallium driver, and overriding it is what broke the previous build.
    GPU_ENV='
export GALLIUM_DRIVER=virpipe
export MESA_GL_VERSION_OVERRIDE=4.3COMPAT
export MESA_GLES_VERSION_OVERRIDE=3.2
export MESA_NO_ERROR=1
'
    ;;
  zink)
    # Turnip inside the guest. Point the loader at the freedreno ICD if the
    # guest actually shipped one; otherwise Mesa is left free to fall back.
    GPU_ENV='
export GALLIUM_DRIVER=zink
export MESA_GL_VERSION_OVERRIDE=4.3COMPAT
export MESA_GLES_VERSION_OVERRIDE=3.2
export MESA_NO_ERROR=1
export ZINK_DESCRIPTORS=lazy
export TU_DEBUG=noconform
export MESA_VK_WSI_PRESENT_MODE=immediate
for icd in /usr/share/vulkan/icd.d/freedreno_icd.aarch64.json \
           /usr/share/vulkan/icd.d/freedreno_icd.json; do
    [ -f "$icd" ] && export VK_ICD_FILENAMES="$icd" && break
done
'
    ;;
  software|*)
    GPU_ENV='
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
'
    ;;
esac

exec proot-distro login "$DISTRO_ID" "${BIND_ARGS[@]}" --user "$LOGIN_USER" -- bash -lc "
export DISPLAY=:0
export PULSE_SERVER=tcp:127.0.0.1
export XDG_RUNTIME_DIR=/tmp/runtime-\$(id -un)
mkdir -p \"\\\$XDG_RUNTIME_DIR\" 2>/dev/null || true
chmod 700 \"\\\$XDG_RUNTIME_DIR\" 2>/dev/null || true
export LANG=en_US.UTF-8
export XKB_CONFIG_ROOT=/usr/share/X11/xkb
${GPU_ENV}
exec dbus-launch --exit-with-session startxfce4
"
SESSIONEOF
chmod +x "$HOME/.xfce-session.sh"
echo -e "  ${GREEN}[+]${NC} ~/.xfce-session.sh rewritten"

# ---------- 5. Rewrite start-linux.sh's VirGL launch ----------
#
# Second bug, found after the first fix landed:
#
#   lost connection to rendering server on 8 read -1 22
#   proot info: vpid 1: terminated with signal 6
#
# Two causes, both on the HOST side of the virgl bridge:
#
#   a) virgl_test_server_android was being launched with
#      --use-egl-surfaceless --use-gles. Those are flags for the generic
#      virgl_test_server. The _android build is already preconfigured for
#      Android GLES and exits when handed them. It died instantly, so the
#      guest connected to nothing and aborted with SIGABRT.
#
#   b) The virgl server itself needs a GPU driver to do the real work.
#      Removing GALLIUM_DRIVER from the host env file (correct, it was
#      leaking into the guest) also starved the server. The fix is to
#      SCOPE those vars to the server process, not to delete them.
echo ""
echo -e "${WHITE}[5/5] Fixing the VirGL server launch in start-linux.sh...${NC}"

[ -f "$HOME/start-linux.sh" ] && cp "$HOME/start-linux.sh" "$HOME/start-linux.sh.bak"

cat > "$HOME/start-linux.sh" << 'LAUNCHEREOF'
#!/data/data/com.termux/files/usr/bin/bash
set -u

[ -f "$HOME/.config/termux-ubuntu.conf" ] && source "$HOME/.config/termux-ubuntu.conf"
DISTRO_ID="${DISTRO_ID:-ubuntu}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TMPDIR="${TMPDIR:-$PREFIX/tmp}"
export TMPDIR

fail() { printf '\033[0;31m[!] %s\033[0m\n' "$1"; exit 1; }

GPU_MODE="$(cat "$HOME/.config/gpu-mode" 2>/dev/null || echo virgl)"

echo ""
echo "[*] Starting XFCE4 inside Ubuntu   (GPU mode: $GPU_MODE)"
echo ""

command -v proot-distro >/dev/null 2>&1 || fail "proot-distro missing. Re-run setup."
command -v termux-x11   >/dev/null 2>&1 || fail "termux-x11 missing. Re-run setup."
proot-distro login "$DISTRO_ID" -- true >/dev/null 2>&1 \
    || fail "Ubuntu container missing. Run: proot-distro install $DISTRO_ID"

echo "[*] Cleaning up old sessions..."
"$HOME/.x11-cleanup.sh"

if command -v pulseaudio >/dev/null 2>&1; then
    unset PULSE_SERVER
    pulseaudio --kill 2>/dev/null || true
    sleep 0.5
    echo "[*] Starting audio server..."
    if pulseaudio --start --exit-idle-time=-1 2>"$TMPDIR/pulse-err.log"; then
        pactl load-module module-native-protocol-tcp \
            auth-ip-acl=127.0.0.1 auth-anonymous=1 >/dev/null 2>&1 || true
        export PULSE_SERVER=tcp:127.0.0.1
        echo "  [+] Audio server running"
    else
        echo "  [-] Audio failed. Continuing without sound. Log: $TMPDIR/pulse-err.log"
    fi
fi

# VirGL: only in virgl mode, and only if it actually stays alive.
if [ "$GPU_MODE" = "virgl" ] && command -v virgl_test_server_android >/dev/null 2>&1; then
    echo "[*] Starting VirGL server..."
    # No --use-* flags. Those belong to the generic virgl_test_server; the
    # _android build is preconfigured for Android GLES and exits if given
    # them, which is what produced "lost connection to rendering server".
    # GPU vars are scoped to this subshell so they never reach the guest.
    (
        export XDG_RUNTIME_DIR="$TMPDIR"
        export MESA_NO_ERROR=1
        export MESA_GL_VERSION_OVERRIDE=4.0
        export GALLIUM_DRIVER=zink
        exec virgl_test_server_android
    ) >"$TMPDIR/virgl.log" 2>&1 &
    VIRGL_PID=$!
    sleep 2
    if kill -0 "$VIRGL_PID" 2>/dev/null; then
        echo "  [+] VirGL server running (pid $VIRGL_PID)"
    else
        echo "  [-] VirGL server died on startup."
        echo "      Log: $TMPDIR/virgl.log"
        echo "      Falling back to software rendering for this run."
        export SOFTWARE_MODE=1
    fi
fi

if command -v am >/dev/null 2>&1; then
    echo "[*] Opening the Termux:X11 app..."
    am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity \
        >/dev/null 2>&1 || echo "  [*] Open Termux:X11 manually."
    sleep 2
fi

export XKB_CONFIG_ROOT="$PREFIX/share/X11/xkb"
export DISPLAY=:0

echo "-----------------------------------------------"
echo "  [*] Switch to the Termux:X11 app to see the desktop"
echo "-----------------------------------------------"
echo ""
echo "[*] Launching X server + XFCE4 session..."

exec termux-x11 :0 -xstartup "$HOME/.xfce-session.sh"
LAUNCHEREOF

chmod +x "$HOME/start-linux.sh"

if bash -n "$HOME/start-linux.sh" 2>/dev/null; then
    echo -e "  ${GREEN}[+]${NC} start-linux.sh rewritten (backup: start-linux.sh.bak)"
else
    echo -e "  ${RED}[!]${NC} rewrite failed syntax check, restoring backup"
    [ -f "$HOME/start-linux.sh.bak" ] && mv "$HOME/start-linux.sh.bak" "$HOME/start-linux.sh"
fi

echo ""
echo -e "${GREEN}=== Done ===${NC}"
echo ""
echo -e "  Current GPU mode: ${WHITE}$(cat "$HOME/.config/gpu-mode")${NC}"
echo ""
echo -e "  ${CYAN}Restart the desktop:${NC}"
echo -e "    ./stop-linux.sh && ./start-linux.sh"
echo ""
echo -e "  ${CYAN}Then inside the XFCE terminal:${NC}"
echo -e "    glxinfo -B | head -20"
echo ""
echo -e "  virgl mode should report ${WHITE}virgl${NC} or ${WHITE}zink (Turnip Adreno)${NC} as the renderer."
echo -e "  If it still fails, try: ${WHITE}./switch-gpu.sh software${NC} to confirm the"
echo -e "  desktop itself is healthy, then ${WHITE}./switch-gpu.sh zink${NC}."
echo ""
