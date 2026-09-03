#!/data/data/com.termux/files/usr/bin/bash
#######################################################
#  Termux Linux Setup Script (Ubuntu edition)
#
#  Supported: Samsung Galaxy Tab S8 Ultra
#             (Snapdragon 8 Gen 1 / Adreno 730)
#             Samsung Galaxy Tab S9 Ultra
#             (Snapdragon 8 Gen 2 for Galaxy / Adreno 740)
#
#  Strategy:
#  - Termux (host) stays minimal: X11 server, PulseAudio,
#    proot-distro, GPU host drivers (Turnip/Zink + VirGL).
#  - Real Linux userland is Ubuntu 24.04 LTS (noble) via
#    `proot-distro install ubuntu` (NOT Debian).
#  - XFCE4 lean desktop lives INSIDE Ubuntu, displayed
#    through Termux-X11 (:0) with --shared-tmp.
#
#  Why this works on both tablets:
#  - Same 14.6" 2960x1848 display -> same X11 flags.
#  - Both are Adreno (730 vs 740) -> same Turnip + Zink
#    path. Adreno 740 is actually better supported in
#    newer Mesa and ~25% faster, so S9 Ultra runs this
#    same script faster/cooler. No fork needed.
#
#  Ubuntu-specific fixes vs a naive Debian port:
#  - snapd blocked via nosnap.pref (snap CANNOT work in
#    proot; installing xubuntu-desktop without this fails)
#  - lean `xfce4` set, not `xubuntu-desktop` (3x smaller)
#  - dbus-x11 + xauth always installed (else startxfce4
#    fails with dbus/display errors in proot)
#  - non-root user created (XFCE as root = dbus/session
#    permission bugs on Ubuntu 24.04)
#  - DEBIAN_FRONTEND=noninteractive + TZ to dodge the
#    tzdata interactive hang
#  - --shared-tmp on every GUI login (MIT-SHM / Vulkan shm)
#######################################################

set -u
TOTAL_STEPS=10
CURRENT_STEP=0
ERROR_LOG="$HOME/linux-setup-errors.log"
: > "$ERROR_LOG"

# Ubuntu container identity (proot-distro alias)
DISTRO_ID="ubuntu"
DISTRO_NAME="Ubuntu 24.04 LTS"
UBUNTU_USER="droid"

# Device detection results (filled by detect_device)
DEVICE_MODEL="Unknown"
DEVICE_LABEL="Unknown device"
GPU_NAME="Unknown GPU"
IS_ADRENO=1

# ============== COLORS ==============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'
BOLD='\033[1m'

# ============== PROGRESS FUNCTIONS ==============
update_progress() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    PERCENT=$((CURRENT_STEP * 100 / TOTAL_STEPS))

    FILLED=$((PERCENT / 5))
    EMPTY=$((20 - FILLED))

    BAR="${GREEN}"
    for ((i=0; i<FILLED; i++)); do BAR+="*"; done
    BAR+="${GRAY}"
    for ((i=0; i<EMPTY; i++)); do BAR+="-"; done
    BAR+="${NC}"

    echo ""
    echo -e "${WHITE}------------------------------------------------------------${NC}"
    echo -e "${CYAN}  OVERALL PROGRESS: ${WHITE}Step ${CURRENT_STEP}/${TOTAL_STEPS}${NC} ${BAR} ${WHITE}${PERCENT}%${NC}"
    echo -e "${WHITE}------------------------------------------------------------${NC}"
    echo ""
}

spinner() {
    local pid=$1
    local message=$2
    local spin='-\|/'
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r  [*] ${message} ${CYAN}${spin:$i:1}${NC}  "
        sleep 0.1
    done

    wait "$pid"
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        printf "\r  [+] ${message}                    \n"
    else
        printf "\r  [-] ${message} ${RED}(failed - see ${ERROR_LOG})${NC}     \n"
    fi

    return $exit_code
}

# Host (Termux) package installer - non-fatal, logged
FAILED_PKGS_HOST=()
install_host_pkg() {
    local pkg=$1
    local name=${2:-$pkg}
    (
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            -o Dpkg::Options::="--force-confold" "$pkg" \
            >> "$ERROR_LOG" 2>&1
    ) &
    spinner $! "Installing ${name}..."
    local result=$?
    if [ $result -ne 0 ]; then
        FAILED_PKGS_HOST+=("$pkg")
    fi
    return $result
}

# Guest (Ubuntu proot) package installer - non-fatal, logged
# Usage: install_guest_pkg <pkg> [pretty-name]
FAILED_PKGS_GUEST=()
install_guest_pkg() {
    local pkg=$1
    local name=${2:-$pkg}
    (
        proot-distro login "$DISTRO_ID" -- env DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC \
            apt-get install -y -o Dpkg::Options::="--force-confold" "$pkg" \
            >> "$ERROR_LOG" 2>&1
    ) &
    spinner $! "Installing (Ubuntu) ${name}..."
    local result=$?
    if [ $result -ne 0 ]; then
        FAILED_PKGS_GUEST+=("$pkg")
    fi
    return $result
}

# Run an arbitrary command inside Ubuntu, logged
# Usage: run_guest "apt-get update ..."
run_guest() {
    local desc=$1
    shift
    (
        proot-distro login "$DISTRO_ID" -- env DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC "$@" \
            >> "$ERROR_LOG" 2>&1
    ) &
    spinner $! "$desc..."
}

# ============== PRE-FLIGHT CHECKS ==============
check_requirements() {
    echo -e "${PURPLE}[*] Running pre-flight checks...${NC}"
    echo ""

    if [ ! -d "/data/data/com.termux/files/usr" ]; then
        echo -e "${RED}[!] This script must be run inside Termux. Aborting.${NC}"
        exit 1
    fi

    if ! timeout 8 curl -s --head https://packages.termux.dev >/dev/null 2>&1; then
        echo -e "${RED}[!] No internet connection detected.${NC}"
        echo -e "${YELLOW}    Check your Wi-Fi/data connection and try again.${NC}"
        exit 1
    fi
    echo -e "  [+] Internet connection: ${GREEN}OK${NC}"

    # Ubuntu rootfs (~200MB) + XFCE lean (~1.5GB) + cache -> want 8GB free
    local avail_kb
    avail_kb=$(df "$HOME" | awk 'NR==2 {print $4}')
    local avail_gb=$((avail_kb / 1024 / 1024))
    if [ "$avail_gb" -lt 8 ]; then
        echo -e "${YELLOW}[!] Low storage: only ${avail_gb}GB free.${NC}"
        echo -e "${YELLOW}    Ubuntu + XFCE wants ~8GB free (rootfs + desktop + cache).${NC}"
        read -p "Continue anyway? (y/N): " CONT
        [[ "$CONT" =~ ^[Yy]$ ]] || exit 1
    else
        echo -e "  [+] Free storage: ${GREEN}${avail_gb}GB${NC} (OK)"
    fi

    local arch
    arch=$(uname -m)
    if [ "$arch" != "aarch64" ]; then
        echo -e "${YELLOW}[!] Architecture is ${arch}, expected aarch64.${NC}"
        echo -e "${YELLOW}    Both Tab S8/S9 Ultra are arm64; proot Ubuntu images assume that.${NC}"
    else
        echo -e "  [+] Architecture: ${GREEN}${arch}${NC} (OK)"
    fi

    # Play Store Termux is dead - warn early, saves hours of confusion
    if [ ! -f "$PREFIX/bin/proot-distro" ]; then
        echo -e "  [*] proot-distro not yet installed (will be installed in Step 2)."
    fi
    if pkg list-installed 2>/dev/null | grep -qi "from-play-store"; then
        echo -e "${YELLOW}[!] Play Store Termux detected - please use F-Droid/GitHub Termux instead.${NC}"
    fi

    echo ""
    sleep 1
}

# ============== DEVICE DETECTION (S8 Ultra vs S9 Ultra) ==============
detect_device() {
    echo -e "${PURPLE}[*] Detecting tablet model...${NC}"
    echo ""

    DEVICE_MODEL=$(getprop ro.product.model 2>/dev/null || echo "Unknown")
    local brand
    brand=$(getprop ro.product.brand 2>/dev/null || echo "Unknown")
    local android_ver
    android_ver=$(getprop ro.build.version.release 2>/dev/null || echo "Unknown")
    local egl
    egl=$(getprop ro.hardware.egl 2>/dev/null || echo "")

    echo -e "  [*] Device: ${WHITE}${brand} ${DEVICE_MODEL}${NC}"
    echo -e "  [*] Android: ${WHITE}${android_ver}${NC}"

    case "$DEVICE_MODEL" in
        SM-X900|SM-X906*|SM-X906B)
            DEVICE_LABEL="Galaxy Tab S8 Ultra (SD 8 Gen 1 / Adreno 730)"
            GPU_NAME="Adreno 730 (Turnip + Zink)"
            IS_ADRENO=1
            ;;
        SM-X910*|SM-X916*|SM-X916B)
            DEVICE_LABEL="Galaxy Tab S9 Ultra (SD 8 Gen 2 for Galaxy / Adreno 740)"
            GPU_NAME="Adreno 740 (Turnip + Zink)"
            IS_ADRENO=1
            ;;
        *)
            # Fallback heuristic: Samsung/OnePlus/Xiaomi on Adreno -> Turnip path
            if [[ "$egl" == *"adreno"* ]] || [[ "$brand" == *"samsung"* ]] || [[ "$brand" == *"Samsung"* ]]; then
                DEVICE_LABEL="${brand} ${DEVICE_MODEL} (Adreno-class, Turnip path)"
                GPU_NAME="Adreno-class (Turnip + Zink)"
                IS_ADRENO=1
            else
                DEVICE_LABEL="${brand} ${DEVICE_MODEL} (generic - VirGL fallback)"
                GPU_NAME="Non-Adreno (VirGL fallback)"
                IS_ADRENO=0
            fi
            ;;
    esac

    echo -e "  [*] Profile: ${WHITE}${DEVICE_LABEL}${NC}"
    echo -e "  [*] GPU: ${WHITE}${GPU_NAME}${NC}"
    if [ "$IS_ADRENO" == "1" ]; then
        echo -e "  [+] ${GREEN}Hardware acceleration supported (Turnip + Zink).${NC}"
    else
        echo -e "${YELLOW}      [!] Non-Adreno: will use VirGL/llvmpipe fallback. XFCE still works, 3D is slower.${NC}"
    fi
    echo ""
    sleep 1
}

# ============== BANNER ==============
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'BANNER'
    -------------------------------------------

       Termux Ubuntu Setup - Tab S8 / S9 Ultra

    -------------------------------------------
BANNER
    echo -e "${NC}"
    echo -e "${WHITE}  Guest: Ubuntu 24.04 LTS (proot) | Desktop: XFCE4 lean | GPU: Turnip/Zink + VirGL${NC}"
    echo ""
}

# ============== STEP 1: UPDATE TERMUX HOST ==============
step_update() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Updating Termux host packages...${NC}"
    echo ""
    (DEBIAN_FRONTEND=noninteractive apt-get update -y >> "$ERROR_LOG" 2>&1) &
    spinner $! "Updating package lists..."
    (DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q -o Dpkg::Options::="--force-confold" >> "$ERROR_LOG" 2>&1) &
    spinner $! "Upgrading installed packages..."
}

# ============== STEP 2: HOST BASE (X11 + proot + GPU host drivers) ==============
step_host_base() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing host base (X11, proot, GPU)...${NC}"
    echo ""

    install_host_pkg "x11-repo" "X11 Repository"
    install_host_pkg "termux-x11-nightly" "Termux-X11 Display Server"
    install_host_pkg "xorg-xrandr" "XRandR (Display Settings)"
    install_host_pkg "xkeyboard-config" "XKB Keyboard Data"
    install_host_pkg "pulseaudio" "PulseAudio Server"
    install_host_pkg "proot-distro" "proot-distro (Ubuntu container manager)"
    install_host_pkg "virglrenderer-android" "VirGL Server (fallback renderer)"
    install_host_pkg "vulkan-loader-android" "Vulkan Loader"
    install_host_pkg "mesa-zink" "Mesa Zink Core"

    # Package was renamed in newer Termux repos (-dri3 suffix). Try new, fall back to old.
    if ! install_host_pkg "mesa-vulkan-icd-freedreno-dri3" "Turnip Adreno Vulkan Driver"; then
        echo -e "  [*] Trying legacy Turnip package name..."
        install_host_pkg "mesa-vulkan-icd-freedreno" "Turnip Adreno Vulkan Driver (legacy)"
    fi
}

# ============== STEP 3: INSTALL UBUNTU ROOTFS ==============
step_ubuntu_install() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing ${DISTRO_NAME} (proot)...${NC}"
    echo ""

    if ! command -v proot-distro >/dev/null 2>&1; then
        echo -e "${RED}[!] proot-distro missing after Step 2. Check ${ERROR_LOG}.${NC}"
        exit 1
    fi

    if proot-distro login "$DISTRO_ID" -- true >/dev/null 2>&1; then
        echo -e "  [*] ${DISTRO_NAME} already installed. Verifying..."
        if proot-distro login "$DISTRO_ID" -- lsb_release -a >> "$ERROR_LOG" 2>&1; then
            echo -e "  [+] ${GREEN}Existing Ubuntu container is healthy, reusing it.${NC}"
        else
            echo -e "${YELLOW}  [!] Existing container looks broken. Remove with:${NC}"
            echo -e "      proot-distro remove $DISTRO_ID   then re-run setup."
            exit 1
        fi
        return
    fi

    echo -e "  [*] Downloading Ubuntu rootfs (~200MB, one time)..."
    (proot-distro install "$DISTRO_ID" >> "$ERROR_LOG" 2>&1) &
    if ! spinner $! "Installing ${DISTRO_NAME} rootfs..."; then
        echo -e "${RED}[!] Failed to install ${DISTRO_NAME}.${NC}"
        echo -e "${YELLOW}    Try manually: proot-distro install ${DISTRO_ID}${NC}"
        echo -e "${YELLOW}    Details: ${ERROR_LOG}${NC}"
        exit 1
    fi
}

# ============== STEP 4: UBUNTU BOOTSTRAP (snap block, sudo, locale) ==============
step_ubuntu_bootstrap() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Bootstrapping Ubuntu (snap block, base tools)...${NC}"
    echo ""

    run_guest "Updating Ubuntu package lists" apt-get update -y
    run_guest "Upgrading Ubuntu base" apt-get upgrade -y -o Dpkg::Options::="--force-confold"

    # Base admin tooling. software-properties-common is needed ONLY if we
    # later add the optional Turnip PPA; install now so that step can't fail.
    for p in sudo adduser lsb-release tzdata locales software-properties-common curl wget gnupg ca-certificates; do
        install_guest_pkg "$p" "$p"
    done

    # --- Block snapd BEFORE any desktop install. This is the #1 Ubuntu-proot fix. ---
    echo -e "  [*] Blocking snapd (cannot work inside proot)..."
    (
        proot-distro login "$DISTRO_ID" -- bash -lc '
            set -e
            mkdir -p /etc/apt/preferences.d
            cat > /etc/apt/preferences.d/nosnap.pref << "EOF"
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
            echo "snap blocked"
        ' >> "$ERROR_LOG" 2>&1
    ) &
    spinner $! "Writing nosnap.pref..."

    # Locale (quietly; missing locale breaks some Python builds)
    (
        proot-distro login "$DISTRO_ID" -- bash -lc 'locale-gen en_US.UTF-8 >/dev/null 2>&1; update-locale LANG=en_US.UTF-8 >/dev/null 2>&1; echo ok' >> "$ERROR_LOG" 2>&1
    ) &
    spinner $! "Setting locale..."

    # Non-root desktop user (XFCE + dbus misbehave as root on 24.04)
    echo -e "  [*] Ensuring desktop user '${UBUNTU_USER}'..."
    (
        proot-distro login "$DISTRO_ID" -- bash -lc "
            set -e
            if ! id '$UBUNTU_USER' >/dev/null 2>&1; then
                adduser --disabled-password --gecos '' '$UBUNTU_USER'
                usermod -aG sudo '$UBUNTU_USER'
                echo '$UBUNTU_USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-nopasswd
                chmod 440 /etc/sudoers.d/99-nopasswd
            fi
        " >> "$ERROR_LOG" 2>&1
    ) &
    spinner $! "Creating user ${UBUNTU_USER}..."
}

# ============== STEP 5: XFCE DESKTOP INSIDE UBUNTU ==============
step_ubuntu_desktop() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing XFCE4 desktop (inside Ubuntu)...${NC}"
    echo ""
    echo -e "  [*] Lean set (not xubuntu-desktop) to avoid snap bloat."

    # dbus-x11 + xauth are MANDATORY in proot - without them startxfce4 exits.
    install_guest_pkg "dbus-x11" "D-Bus X11 bindings (mandatory in proot)"
    install_guest_pkg "xauth" "xauth"
    install_guest_pkg "x11-xserver-utils" "x11-xserver-utils"
    install_guest_pkg "xfce4" "XFCE4 Desktop"
    install_guest_pkg "xfce4-terminal" "XFCE4 Terminal"
    install_guest_pkg "xfce4-whiskermenu-plugin" "Whisker Menu"
    install_guest_pkg "thunar" "Thunar File Manager"
    install_guest_pkg "thunar-volman" "Thunar Volume Manager"
    install_guest_pkg "mousepad" "Mousepad Editor"
    install_guest_pkg "fonts-dejavu" "DejaVu fonts"
    install_guest_pkg "fonts-liberation" "Liberation fonts"
}

# ============== STEP 6: GPU / GL TOOLS INSIDE UBUNTU ==============
step_ubuntu_gpu() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing GPU test tools (inside Ubuntu)...${NC}"
    echo ""

    install_guest_pkg "mesa-utils" "Mesa utils (glxinfo/glxgears)"
    install_guest_pkg "vulkan-tools" "Vulkan tools (vulkaninfo)"
    install_guest_pkg "libgl1" "OpenGL runtime"
    install_guest_pkg "libvulkan1" "Vulkan runtime"

    # Optional: newer Turnip PPA for Adreno 730/740. Non-fatal by design -
    # stock Ubuntu 24.04 mesa already works; PPA just gives newer freedreno.
    if [ "$IS_ADRENO" == "1" ]; then
        echo -e "  [*] Trying optional Turnip PPA (better Adreno 730/740GL) - safe to fail..."
        (
            proot-distro login "$DISTRO_ID" -- bash -lc '
                set -e
                add-apt-repository -y ppa:mastag/mesa-turnip-kgsl >/dev/null 2>&1
                apt-get update -y >/dev/null 2>&1
                DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -o Dpkg::Options::="--force-confold" >/dev/null 2>&1
            ' >> "$ERROR_LOG" 2>&1
        ) &
        if spinner $! "Upgrading Mesa from Turnip PPA..."; then
            echo -e "  [+] ${GREEN}Turnip PPA applied.${NC}"
        else
            echo -e "  ${YELLOW}[-] Turnip PPA skipped (stock Mesa kept - still fine).${NC}"
        fi
    else
        echo -e "  [*] Non-Adreno device: keeping stock Mesa + VirGL path."
    fi
}

# ============== STEP 7: DEV / SYSADMIN TOOLING INSIDE UBUNTU ==============
step_ubuntu_devtools() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Dev, SSH & Network Tools (inside Ubuntu)...${NC}"
    echo ""
    echo -e "  [*] NOTE: Ubuntu package names differ from Termux (python->python3, etc.)."

    # Core dev (Ubuntu names!)
    install_guest_pkg "python3" "Python 3"
    install_guest_pkg "python3-pip" "Pip"
    install_guest_pkg "python3-venv" "venv"
    install_guest_pkg "git" "Git Version Control"
    install_guest_pkg "neovim" "Neovim"
    install_guest_pkg "vim" "Vim"

    # Build tools
    install_guest_pkg "build-essential" "Build Essential (gcc/make/etc.)"
    install_guest_pkg "clang" "Clang"
    install_guest_pkg "cmake" "CMake"
    install_guest_pkg "pkg-config" "pkg-config"

    # SSH (Ubuntu splits client/server, Termux bundles them)
    install_guest_pkg "openssh-client" "OpenSSH client"
    install_guest_pkg "openssh-server" "OpenSSH server"

    # Network tools
    install_guest_pkg "net-tools" "Net-tools (ifconfig/netstat)"
    install_guest_pkg "iproute2" "iproute2 (ip/ss)"
    install_guest_pkg "nmap" "Nmap"
    install_guest_pkg "curl" "cURL"
    install_guest_pkg "wget" "Wget"
    install_guest_pkg "rsync" "Rsync"
    install_guest_pkg "htop" "htop"
    install_guest_pkg "unzip" "unzip"
    install_guest_pkg "pavucontrol" "PulseAudio Volume Control"
}

# ============== STEP 8: AUTOMATIC STORAGE INTEGRATION ==============
step_storage() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Setting up shared storage integration...${NC}"
    echo ""

    if [ ! -d "$HOME/storage" ]; then
        echo -e "  [*] Requesting storage permission (an Android permission popup may appear)..."
        termux-setup-storage
        for i in {1..10}; do
            [ -d "$HOME/storage/shared" ] && break
            sleep 1
        done
    fi

    if [ -d "$HOME/storage/shared" ]; then
        ln -sfn "$HOME/storage/shared" "$HOME/Storage"
        echo -e "  [+] ${GREEN}Storage linked${NC}: ~/Storage -> shared device storage"
        echo -e "  [*] Inside Ubuntu it is reachable via --bind (see start-linux.sh) at /mnt/shared"
    else
        echo -e "  [-] ${YELLOW}Storage permission was not granted (or timed out).${NC}"
        echo -e "      Run 'termux-setup-storage' manually later, then re-run:"
        echo -e "      ln -sfn ~/storage/shared ~/Storage"
    fi
}

# ============== STEP 9: LAUNCHERS (host X11 + guest XFCE) ==============
step_launchers() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Creating startup & stop scripts...${NC}"
    echo ""

    mkdir -p ~/.config

    # Host-side GPU env (Termux). Guest gets its own exports in the launcher.
    cat > ~/.config/linux-gpu.sh << 'EOF'
export MESA_NO_ERROR=1
export MESA_GL_VERSION_OVERRIDE=4.6
export MESA_GLES_VERSION_OVERRIDE=3.2
export GALLIUM_DRIVER=zink
export MESA_LOADER_DRIVER_OVERRIDE=zink
export TU_DEBUG=noconform
export MESA_VK_WSI_PRESENT_MODE=immediate
export ZINK_DESCRIPTORS=lazy
export XDG_DATA_DIRS=/data/data/com.termux/files/usr/share:${XDG_DATA_DIRS}
export XDG_CONFIG_DIRS=/data/data/com.termux/files/usr/etc/xdg:${XDG_CONFIG_DIRS}
EOF
    echo -e "  [+] Created ~/.config/linux-gpu.sh (host)"

    # ---- start-linux.sh : host X11/audio, then XFCE inside Ubuntu ----
    cat > ~/start-linux.sh << LAUNCHEREOF
#!/data/data/com.termux/files/usr/bin/bash
# Launch XFCE4 inside Ubuntu (proot) on Termux-X11.
# Tested profiles: Tab S8 Ultra (Adreno 730), Tab S9 Ultra (Adreno 740).
set -u
NC='\033[0m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'

UBUNTU_USER="${UBUNTU_USER}"
DISTRO_ID="${DISTRO_ID}"

fail() {
    echo -e "\${RED}[!] \$1\${NC}"
    exit 1
}

echo ""
echo -e "\${CYAN}[*] Starting XFCE4 inside Ubuntu...${NC}"
echo ""

source ~/.config/linux-gpu.sh 2>/dev/null || true

command -v proot-distro >/dev/null 2>&1 || fail "proot-distro is not installed. Re-run setup.sh."
command -v termux-x11 >/dev/null 2>&1 || fail "termux-x11 is not installed. Re-run setup.sh."
proot-distro login "\$DISTRO_ID" -- true >/dev/null 2>&1 || fail "Ubuntu container missing. Run: proot-distro install \$DISTRO_ID"

echo "[*] Cleaning up old sessions..."
pkill -9 -f "termux.x11" 2>/dev/null || true
pkill -9 -f "virgl_test_server_android" 2>/dev/null || true
pkill -9 -f "dbus" 2>/dev/null || true

# --- audio (host PulseAudio, guest connects over TCP) ---
if command -v pulseaudio >/dev/null 2>&1; then
    unset PULSE_SERVER
    pulseaudio --kill 2>/dev/null || true
    sleep 0.5
    echo "[*] Starting audio server..."
    if pulseaudio --start --exit-idle-time=-1 2>/tmp/pulse-err.log; then
        pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 2>/dev/null || true
        export PULSE_SERVER=127.0.0.1
        echo -e "  [+] \${GREEN}Audio server running\${NC}"
    else
        echo -e "  [-] \${YELLOW}Audio failed to start (see /tmp/pulse-err.log). Continuing without sound.\${NC}"
    fi
fi

# --- VirGL fallback daemon (harmless on Adreno; needed for non-Adreno) ---
if command -v virgl_test_server_android >/dev/null 2>&1; then
    echo "[*] Starting VirGL server (fallback path)..."
    virgl_test_server_android --use-egl-surfaceless --use-gles &>/tmp/virgl.log &
fi

# --- X11 ---
echo "[*] Starting X11 server..."
termux-x11 :0 -ac &
X11_PID=\$!

for i in \$(seq 1 20); do
    if [ -e "/data/data/com.termux/files/usr/tmp/.X11-unix/X0" ]; then
        break
    fi
    sleep 0.5
done

if ! kill -0 \$X11_PID 2>/dev/null; then
    fail "termux-x11 failed to start. Make sure the Termux-X11 APK (nightly) is installed and open."
fi

export DISPLAY=:0

echo -e "\${CYAN}-----------------------------------------------\${NC}"
echo -e "  \${GREEN}[*] Open the Termux-X11 app to view the desktop!\${NC}"
echo -e "\${CYAN}-----------------------------------------------\${NC}"
echo ""

# Storage bind (only if permission was granted)
BIND_ARGS="--shared-tmp"
if [ -d "\$HOME/storage/shared" ]; then
    BIND_ARGS="\$BIND_ARGS --bind \$HOME/storage/shared:/mnt/shared"
fi

# Pick login user: prefer the created desktop user, fall back to root
LOGIN_USER="root"
if proot-distro login "\$DISTRO_ID" -- id "\$UBUNTU_USER" >/dev/null 2>&1; then
    LOGIN_USER="\$UBUNTU_USER"
fi

echo "[*] Launching XFCE4 inside Ubuntu as '\$LOGIN_USER'..."
# shellcheck disable=SC2086
exec proot-distro login "\$DISTRO_ID" \$BIND_ARGS --user "\$LOGIN_USER" -- bash -lc '
    export DISPLAY=:0
    export PULSE_SERVER=127.0.0.1
    export XDG_RUNTIME_DIR=/tmp
    export MESA_NO_ERROR=1
    export MESA_GL_VERSION_OVERRIDE=4.6
    export MESA_GLES_VERSION_OVERRIDE=3.2
    export GALLIUM_DRIVER=zink
    export MESA_LOADER_DRIVER_OVERRIDE=zink
    export TU_DEBUG=noconform
    export MESA_VK_WSI_PRESENT_MODE=immediate
    export ZINK_DESCRIPTORS=lazy
    export LANG=en_US.UTF-8
    dbus-launch --exit-with-session startxfce4
'
LAUNCHEREOF
    chmod +x ~/start-linux.sh
    echo -e "  [+] Created ~/start-linux.sh (Ubuntu XFCE via Termux-X11)"

    # ---- safe mode: force software rendering inside guest ----
    cat > ~/start-linux-safe.sh << 'SAFEEOF'
#!/data/data/com.termux/files/usr/bin/bash
# Compatibility mode: llvmpipe inside Ubuntu (use if Zink/Turnip black-screens).
set -u
source ~/.config/linux-gpu.sh 2>/dev/null || true
echo "[*] Starting in compatibility mode (llvmpipe)..."
pkill -9 -f "termux.x11" 2>/dev/null || true
unset PULSE_SERVER
pulseaudio --kill 2>/dev/null || true
sleep 0.5
pulseaudio --start --exit-idle-time=-1 2>/dev/null || true
pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 2>/dev/null || true
export PULSE_SERVER=127.0.0.1
termux-x11 :0 -ac &
for i in $(seq 1 20); do
    [ -e "/data/data/com.termux/files/usr/tmp/.X11-unix/X0" ] && break
    sleep 0.5
done
export DISPLAY=:0
LOGIN_USER="root"
proot-distro login ubuntu -- id droid >/dev/null 2>&1 && LOGIN_USER="droid"
exec proot-distro login ubuntu --shared-tmp --user "$LOGIN_USER" -- bash -lc '
    export DISPLAY=:0 PULSE_SERVER=127.0.0.1 XDG_RUNTIME_DIR=/tmp LANG=en_US.UTF-8
    export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
    unset MESA_LOADER_DRIVER_OVERRIDE
    dbus-launch --exit-with-session startxfce4
'
SAFEEOF
    chmod +x ~/start-linux-safe.sh
    echo -e "  [+] Created ~/start-linux-safe.sh (llvmpipe fallback)"

    # ---- CLI-only Ubuntu login (no GUI) ----
    cat > ~/start-ubuntu-cli.sh << 'CLIEOF'
#!/data/data/com.termux/files/usr/bin/bash
# Terminal-only Ubuntu login (no X11 needed).
LOGIN_USER="root"
proot-distro login ubuntu -- id droid >/dev/null 2>&1 && LOGIN_USER="droid"
exec proot-distro login ubuntu --user "$LOGIN_USER"
CLIEOF
    chmod +x ~/start-ubuntu-cli.sh
    echo -e "  [+] Created ~/start-ubuntu-cli.sh"

    # ---- update helper ----
    cat > ~/update-ubuntu.sh << 'UPDATEEOF'
#!/data/data/com.termux/files/usr/bin/bash
echo "[*] Updating Termux host..."
DEBIAN_FRONTEND=noninteractive apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::="--force-confold"
echo "[*] Updating Ubuntu container..."
proot-distro login ubuntu -- bash -lc "DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get update -y && DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get upgrade -y -o Dpkg::Options::='--force-confold'"
UPDATEEOF
    chmod +x ~/update-ubuntu.sh
    echo -e "  [+] Created ~/update-ubuntu.sh"

    # ---- stop-linux.sh ----
    cat > ~/stop-linux.sh << 'STOPEOF'
#!/data/data/com.termux/files/usr/bin/bash
echo "Stopping XFCE4 (Ubuntu) desktop..."
pkill -9 -f "termux.x11" 2>/dev/null || true
pkill -9 -f "virgl_test_server_android" 2>/dev/null || true
pkill -9 -f "pulseaudio" 2>/dev/null || true
pkill -9 -f "dbus" 2>/dev/null || true
echo "Desktop stopped."
STOPEOF
    chmod +x ~/stop-linux.sh
    echo -e "  [+] Created ~/stop-linux.sh"

    echo ""
    read -p "Auto-launch the desktop every time you open Termux? (y/N): " AUTOSTART
    if [[ "$AUTOSTART" =~ ^[Yy]$ ]]; then
        if ! grep -q "start-linux.sh" ~/.bashrc 2>/dev/null; then
            echo -e '\n# Auto-start Ubuntu XFCE desktop\nif [ -z "$LINUX_STARTED" ]; then\n    export LINUX_STARTED=1\n    ~/start-linux.sh\nfi' >> ~/.bashrc
            echo -e "  [+] ${GREEN}Auto-start enabled${NC} (added to ~/.bashrc)"
        fi
    else
        echo -e "  [*] Skipped. Start manually anytime with: ${GREEN}./start-linux.sh${NC}"
    fi
}

# ============== STEP 10: SHORTCUTS (host-side .desktop files still work) ==============
step_shortcuts() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Creating desktop shortcuts...${NC}"
    echo ""
    mkdir -p ~/Desktop

    cat > ~/Desktop/Terminal.desktop << 'EOF'
[Desktop Entry]
Name=Terminal
Exec=xfce4-terminal
Icon=utilities-terminal
Type=Application
EOF

    cat > ~/Desktop/Files.desktop << 'EOF'
[Desktop Entry]
Name=Files
Exec=thunar
Icon=system-file-manager
Type=Application
EOF

    chmod +x ~/Desktop/*.desktop 2>/dev/null || true
    echo -e "  [+] Added Terminal and Files shortcuts (these resolve inside Ubuntu)."
}

# ============== COMPLETION ==============
show_completion() {
    echo ""
    local total_failed=$(( ${#FAILED_PKGS_HOST[@]} + ${#FAILED_PKGS_GUEST[@]} ))
    if [ "$total_failed" -gt 0 ]; then
        echo -e "${YELLOW}"
        cat << 'PARTIAL'
    ---------------------------------------------------------------
             [!]  INSTALL FINISHED WITH SOME FAILURES  [!]
    ---------------------------------------------------------------
PARTIAL
        echo -e "${NC}"
        if [ ${#FAILED_PKGS_HOST[@]} -gt 0 ]; then
            echo -e "${RED}[*] Host (Termux) failures:${NC}"
            for p in "${FAILED_PKGS_HOST[@]}"; do
                echo -e "    - $p"
            done
        fi
        if [ ${#FAILED_PKGS_GUEST[@]} -gt 0 ]; then
            echo -e "${RED}[*] Guest (Ubuntu) failures:${NC}"
            for p in "${FAILED_PKGS_GUEST[@]}"; do
                echo -e "    - $p"
            done
        fi
        echo -e "${YELLOW}[*] Details logged in: ${ERROR_LOG}${NC}"
        echo -e "${YELLOW}[*] Retry guest pkgs with: proot-distro login ubuntu -- apt update && apt install <name>${NC}"
    else
        echo -e "${GREEN}"
        cat << 'COMPLETE'
    ---------------------------------------------------------------
             [*]  INSTALLATION COMPLETE!  [*]
    ---------------------------------------------------------------
COMPLETE
        echo -e "${NC}"
    fi

    echo -e "${WHITE}[*] Profile: ${DEVICE_LABEL}${NC}"
    echo -e "${WHITE}[*] Your Ubuntu XFCE4 environment is ready.${NC}"
    echo -e "${CYAN}[*] Installed:${NC}"
    echo "    - ${DISTRO_NAME} via proot-distro + XFCE4 lean (Termux-X11)"
    echo "    - GPU: ${GPU_NAME} (safe mode available)"
    echo "    - PulseAudio (host) -> Ubuntu over 127.0.0.1"
    echo "    - Python3, Git, Neovim/Vim, gcc/clang/cmake/make"
    echo "    - SSH (client+server) & network tools (nmap/net-tools/iproute2)"
    echo "    - Shared storage: ~/Storage (host), /mnt/shared (inside Ubuntu)"
    echo ""
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    echo -e "${WHITE}[*] TO START DESKTOP:${NC}  ${GREEN}./start-linux.sh${NC}"
    echo -e "${WHITE}[*] SAFE MODE:${NC}          ${GREEN}./start-linux-safe.sh${NC}"
    echo -e "${WHITE}[*] UBUNTU TERMINAL:${NC}    ${GREEN}./start-ubuntu-cli.sh${NC}"
    echo -e "${WHITE}[*] UPDATE ALL:${NC}         ${GREEN}./update-ubuntu.sh${NC}"
    echo -e "${WHITE}[*] TO STOP DESKTOP:${NC}    ${GREEN}./stop-linux.sh${NC}"
    echo -e "${WHITE}[*] GPU TEST (in GUI terminal):${NC} ${GREEN}glxinfo -B | head -20${NC}"
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    echo ""
}

# ============== MAIN ==============
main() {
    show_banner
    check_requirements
    detect_device

    step_update
    step_host_base
    step_ubuntu_install
    step_ubuntu_bootstrap
    step_ubuntu_desktop
    step_ubuntu_gpu
    step_ubuntu_devtools
    step_storage
    step_launchers
    step_shortcuts

    show_completion
}

main
