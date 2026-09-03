#!/data/data/com.termux/files/usr/bin/bash
#######################################################
# Termux Ubuntu Setup - Tab S8 Ultra / Tab S9 Ultra
#
# Main setup file: terminal-setup.sh
# (merged: Qwen base + setup.sh fixes)
#
# Target devices:
#   - Samsung Galaxy Tab S8 Ultra
#       Snapdragon 8 Gen 1 / Adreno 730
#   - Samsung Galaxy Tab S9 Ultra
#       Snapdragon 8 Gen 2 for Galaxy / Adreno 740
#
# Compatibility note: both tablets share the same 14.6" 2960x1848
# display (same X11 flags) and both are Adreno, so the same
# Turnip + Zink path works on both. Adreno 740 is better supported
# in newer Mesa and ~25% faster, so S9 Ultra runs this same script
# faster/cooler. No fork needed.
#
# Strategy:
#   - Termux host stays minimal:
#       X11 server, PulseAudio, proot-distro,
#       GPU host drivers (Turnip/Zink + VirGL fallback)
#
#   - Real Linux userland is Ubuntu via proot-distro.
#     This script installs Ubuntu, NOT Debian.
#
#   - XFCE4 lean desktop lives INSIDE Ubuntu and is
#     displayed through Termux-X11 on :0.
#
# Ubuntu/proot fixes included:
#   - snapd blocked before desktop install
#   - lean xfce4 install, not xubuntu-desktop
#   - dbus-x11 + xauth installed
#   - non-root desktop user created
#   - DEBIAN_FRONTEND=noninteractive + TZ=Etc/UTC
#   - shared tmp for proot GUI login
#   - PulseAudio TCP bridge for guest audio
#   - desktop shortcuts created inside Ubuntu, not only Termux
#######################################################

set -u

TOTAL_STEPS=10
CURRENT_STEP=0
ERROR_LOG="$HOME/linux-setup-errors.log"
: > "$ERROR_LOG"

# Ubuntu container identity.
# This is intentionally Ubuntu, not Debian.
DISTRO_ID="ubuntu"
DISTRO_NAME="Ubuntu 24.04 LTS"
UBUNTU_USER="droid"

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

FAILED_PKGS_HOST=()
FAILED_PKGS_GUEST=()
FAILED_TASKS=()

# ============== PROGRESS ==============
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
        printf "\r  [*] %s %s%s%s  " "$message" "$CYAN" "${spin:$i:1}" "$NC"
        sleep 0.1
    done

    wait "$pid"
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        printf "\r  [+] %s\n" "$message"
    else
        printf "\r  [-] %s \033[0;31m(failed - see %s)\033[0m\n" "$message" "$ERROR_LOG"
    fi

    return $exit_code
}

# Host Termux package installer
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

# Guest Ubuntu package installer
install_guest_pkg() {
    local pkg=$1
    local name=${2:-$pkg}

    (
        proot-distro login "$DISTRO_ID" -- env \
            DEBIAN_FRONTEND=noninteractive \
            TZ=Etc/UTC \
            apt-get install -y \
            -o Dpkg::Options::="--force-confold" "$pkg" \
            >> "$ERROR_LOG" 2>&1
    ) &

    spinner $! "Installing Ubuntu package: ${name}..."
    local result=$?

    if [ $result -ne 0 ]; then
        FAILED_PKGS_GUEST+=("$pkg")
    fi

    return $result
}

# Run command inside Ubuntu guest
run_guest() {
    local desc=$1
    shift

    (
        proot-distro login "$DISTRO_ID" -- env \
            DEBIAN_FRONTEND=noninteractive \
            TZ=Etc/UTC \
            "$@" \
            >> "$ERROR_LOG" 2>&1
    ) &

    spinner $! "${desc}..."
    local result=$?

    if [ $result -ne 0 ]; then
        FAILED_TASKS+=("$desc")
    fi

    return $result
}

# ============== PRE-FLIGHT ==============
check_requirements() {
    echo -e "${PURPLE}[*] Running pre-flight checks...${NC}"
    echo ""

    if [ ! -d "/data/data/com.termux/files/usr" ]; then
        echo -e "${RED}[!] This script must be run inside Termux. Aborting.${NC}"
        exit 1
    fi

    if command -v curl >/dev/null 2>&1; then
        if curl --max-time 8 -sI https://packages.termux.dev >/dev/null 2>&1; then
            echo -e "  [+] Internet connection: ${GREEN}OK${NC}"
        else
            echo -e "${RED}[!] No internet connection detected.${NC}"
            echo -e "${YELLOW}    Check Wi-Fi/mobile data and try again.${NC}"
            read -p "Continue anyway? (y/N): " NETCONT
            [[ "$NETCONT" =~ ^[Yy]$ ]] || exit 1
        fi
    else
        echo -e "  [*] curl not installed yet; skipping active internet check."
    fi

    local avail_kb
    avail_kb=$(df "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
    avail_kb=${avail_kb:-0}
    local avail_gb=$((avail_kb / 1024 / 1024))

    if [ "$avail_gb" -lt 8 ]; then
        echo -e "${YELLOW}[!] Low storage: only ${avail_gb}GB free.${NC}"
        echo -e "${YELLOW}    Ubuntu + XFCE wants about 8GB free.${NC}"
        read -p "Continue anyway? (y/N): " CONT
        [[ "$CONT" =~ ^[Yy]$ ]] || exit 1
    else
        echo -e "  [+] Free storage: ${GREEN}${avail_gb}GB${NC} OK"
    fi

    local arch
    arch=$(uname -m)

    if [ "$arch" != "aarch64" ]; then
        echo -e "${YELLOW}[!] Architecture is ${arch}, expected aarch64.${NC}"
        echo -e "${YELLOW}    Tab S8 Ultra and Tab S9 Ultra are both arm64.${NC}"
        read -p "Continue anyway? (y/N): " ARCHCONT
        [[ "$ARCHCONT" =~ ^[Yy]$ ]] || exit 1
    else
        echo -e "  [+] Architecture: ${GREEN}${arch}${NC} OK"
    fi

    # Play Store Termux is unmaintained - warn early, saves hours of confusion.
    if pkg list-installed 2>/dev/null | grep -qi "from-play-store"; then
        echo -e "${YELLOW}[!] Play Store Termux detected - use F-Droid/GitHub Termux instead.${NC}"
    fi

    echo ""
    sleep 1
}

# ============== DEVICE DETECTION ==============
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
    local platform
    platform=$(getprop ro.board.platform 2>/dev/null || echo "")

    echo -e "  [*] Device: ${WHITE}${brand} ${DEVICE_MODEL}${NC}"
    echo -e "  [*] Android: ${WHITE}${android_ver}${NC}"
    echo -e "  [*] Platform: ${WHITE}${platform}${NC}"

    case "$DEVICE_MODEL" in
        SM-X900|SM-X906*|SM-X906B)
            DEVICE_LABEL="Galaxy Tab S8 Ultra (Snapdragon 8 Gen 1 / Adreno 730)"
            GPU_NAME="Adreno 730 (Turnip + Zink path)"
            IS_ADRENO=1
            ;;
        SM-X910*|SM-X916*|SM-X918*)
            DEVICE_LABEL="Galaxy Tab S9 Ultra (Snapdragon 8 Gen 2 for Galaxy / Adreno 740)"
            GPU_NAME="Adreno 740 (Turnip + Zink path)"
            IS_ADRENO=1
            ;;
        *)
            if [[ "$egl" == *adreno* ]] || [[ "$platform" == "taro" ]] || [[ "$platform" == "kalama" ]] || [[ "$DEVICE_MODEL" == SM-X9* ]]; then
                DEVICE_LABEL="${brand} ${DEVICE_MODEL} (Adreno-class, Turnip path)"
                GPU_NAME="Adreno-class (Turnip + Zink path)"
                IS_ADRENO=1
            else
                DEVICE_LABEL="${brand} ${DEVICE_MODEL} (generic - VirGL/llvmpipe fallback)"
                GPU_NAME="Non-Adreno (VirGL/llvmpipe fallback)"
                IS_ADRENO=0
            fi
            ;;
    esac

    echo -e "  [*] Profile: ${WHITE}${DEVICE_LABEL}${NC}"
    echo -e "  [*] GPU: ${WHITE}${GPU_NAME}${NC}"

    if [ "$IS_ADRENO" == "1" ]; then
        echo -e "  [+] ${GREEN}Hardware acceleration path available.${NC}"
    else
        echo -e "${YELLOW}  [!] Non-Adreno device: using fallback renderer. XFCE still works, but 3D may be slower.${NC}"
    fi

    echo ""
    sleep 1
}

# ============== BANNER ==============
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'BANNER'
---------------------------------------------------------------
Termux Ubuntu Setup - Tab S8 Ultra / Tab S9 Ultra
---------------------------------------------------------------
BANNER
    echo -e "${NC}"
    echo -e "${WHITE}  Host: Termux minimal${NC}"
    echo -e "${WHITE}  Guest: Ubuntu via proot-distro${NC}"
    echo -e "${WHITE}  Desktop: XFCE4 lean inside Ubuntu${NC}"
    echo -e "${WHITE}  GPU: Turnip/Zink for Adreno, VirGL/llvmpipe fallback${NC}"
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
    spinner $! "Upgrading installed host packages..."
}

# ============== STEP 2: HOST BASE ==============
step_host_base() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing host base packages...${NC}"
    echo ""

    install_host_pkg "x11-repo" "X11 repository"

    (DEBIAN_FRONTEND=noninteractive apt-get update -y >> "$ERROR_LOG" 2>&1) &
    spinner $! "Refreshing package lists after x11-repo..."

    install_host_pkg "termux-x11-nightly" "Termux-X11 display server"
    install_host_pkg "xorg-xrandr" "XRandR"
    install_host_pkg "xkeyboard-config" "XKB keyboard data"
    install_host_pkg "pulseaudio" "PulseAudio server"
    install_host_pkg "proot-distro" "proot-distro"
    install_host_pkg "virglrenderer-android" "VirGL fallback renderer"
    install_host_pkg "vulkan-loader-android" "Vulkan loader"
    install_host_pkg "mesa-zink" "Mesa Zink core"

    local turnip_pkg="mesa-vulkan-icd-freedreno"
    local turnip_candidate="mesa-vulkan-icd-freedreno-dri3"

    if apt-cache policy "$turnip_candidate" 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -Eq '^[0-9]'; then
        turnip_pkg="$turnip_candidate"
    fi

    install_host_pkg "$turnip_pkg" "Turnip Adreno Vulkan driver"
}

# ============== STEP 3: INSTALL UBUNTU ROOTFS ==============
step_ubuntu_install() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Ubuntu via proot-distro...${NC}"
    echo ""

    if ! command -v proot-distro >/dev/null 2>&1; then
        echo -e "${RED}[!] proot-distro is missing after host setup.${NC}"
        echo -e "${YELLOW}    Check: ${ERROR_LOG}${NC}"
        exit 1
    fi

    local known
    known=$(proot-distro list 2>/dev/null | awk '{print $1}')

    if ! printf '%s\n' "$known" | grep -qx "$DISTRO_ID"; then
        for candidate in ubuntu ubuntu-24.04 ubuntu-22.04; do
            if printf '%s\n' "$known" | grep -qx "$candidate"; then
                DISTRO_ID="$candidate"
                DISTRO_NAME="Ubuntu (${candidate})"
                break
            fi
        done
    fi

    if ! printf '%s\n' "$known" | grep -qx "$DISTRO_ID"; then
        echo -e "${YELLOW}[!] No Ubuntu alias found in proot-distro list.${NC}"
        echo -e "${YELLOW}    Will still try: proot-distro install ${DISTRO_ID}${NC}"
    fi

    echo -e "  [*] Selected Ubuntu alias: ${WHITE}${DISTRO_ID}${NC}"

    if proot-distro login "$DISTRO_ID" -- true >/dev/null 2>&1; then
        if proot-distro login "$DISTRO_ID" -- lsb_release -a >> "$ERROR_LOG" 2>&1; then
            echo -e "  [+] ${GREEN}Existing Ubuntu container is healthy, reusing it.${NC}"
        else
            echo -e "${YELLOW}  [!] Existing container looks broken. Remove with:${NC}"
            echo -e "      proot-distro remove $DISTRO_ID   then re-run setup."
            exit 1
        fi
        return
    fi

    echo -e "  [*] Downloading Ubuntu rootfs. This can take a while..."
    (proot-distro install "$DISTRO_ID" >> "$ERROR_LOG" 2>&1) &

    if ! spinner $! "Installing Ubuntu rootfs..."; then
        echo -e "${RED}[!] Failed to install Ubuntu.${NC}"
        echo -e "${YELLOW}    Try manually: proot-distro install ${DISTRO_ID}${NC}"
        echo -e "${YELLOW}    Details: ${ERROR_LOG}${NC}"
        exit 1
    fi
}

# ============== STEP 4: UBUNTU BOOTSTRAP ==============
step_ubuntu_bootstrap() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Bootstrapping Ubuntu...${NC}"
    echo ""

    if ! run_guest "Updating Ubuntu package lists" apt-get update -y; then
        echo -e "${RED}[!] Ubuntu apt update failed.${NC}"
        echo -e "${YELLOW}    Check: ${ERROR_LOG}${NC}"
        exit 1
    fi

    run_guest "Upgrading Ubuntu base" apt-get upgrade -y -o Dpkg::Options::="--force-confold"

    for p in sudo adduser lsb-release tzdata locales software-properties-common curl wget gnupg ca-certificates; do
        install_guest_pkg "$p" "$p"
    done

    echo -e "  [*] Blocking snapd. Snap cannot work inside proot."
    run_guest "Blocking snapd" bash -lc '
set -e
mkdir -p /etc/apt/preferences.d
cat > /etc/apt/preferences.d/nosnap.pref << "EOF"
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
echo snap blocked
'

    run_guest "Setting locale" bash -lc '
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 || true
echo locale done
'

    echo -e "  [*] Ensuring non-root desktop user: ${WHITE}${UBUNTU_USER}${NC}"
    run_guest "Creating user ${UBUNTU_USER}" bash -lc "
set -e
if ! id '$UBUNTU_USER' >/dev/null 2>&1; then
    adduser --disabled-password --gecos '' '$UBUNTU_USER'
    usermod -aG sudo '$UBUNTU_USER'
    echo '$UBUNTU_USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-nopasswd
    chmod 440 /etc/sudoers.d/99-nopasswd
fi
chown -R '$UBUNTU_USER:$UBUNTU_USER' '/home/$UBUNTU_USER' 2>/dev/null || true
"
}

# ============== STEP 5: XFCE DESKTOP INSIDE UBUNTU ==============
step_ubuntu_desktop() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing XFCE4 inside Ubuntu...${NC}"
    echo ""

    echo -e "  [*] Using lean XFCE set, not xubuntu-desktop."

    install_guest_pkg "dbus-x11" "D-Bus X11 bindings"
    install_guest_pkg "xauth" "xauth"
    install_guest_pkg "x11-xserver-utils" "x11-xserver-utils"

    install_guest_pkg "xfce4" "XFCE4 meta"
    install_guest_pkg "xfce4-session" "XFCE4 session"
    install_guest_pkg "xfce4-panel" "XFCE4 panel"
    install_guest_pkg "xfwm4" "XFCE4 window manager"
    install_guest_pkg "xfdesktop4" "XFCE4 desktop"
    install_guest_pkg "xfce4-settings" "XFCE4 settings"
    install_guest_pkg "xfce4-terminal" "XFCE4 terminal"
    install_guest_pkg "xfce4-whiskermenu-plugin" "Whisker menu"

    install_guest_pkg "thunar" "Thunar file manager"
    install_guest_pkg "thunar-volman" "Thunar volume manager"
    install_guest_pkg "mousepad" "Mousepad editor"

    install_guest_pkg "fonts-dejavu" "DejaVu fonts"
    install_guest_pkg "fonts-liberation" "Liberation fonts"
}

# ============== STEP 6: GPU / GL TOOLS INSIDE UBUNTU ==============
step_ubuntu_gpu() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing GPU test tools inside Ubuntu...${NC}"
    echo ""

    install_guest_pkg "mesa-utils" "mesa-utils"
    install_guest_pkg "vulkan-tools" "vulkan-tools"
    install_guest_pkg "libgl1" "libgl1"
    install_guest_pkg "libvulkan1" "libvulkan1"
    install_guest_pkg "libegl1" "libegl1"
    install_guest_pkg "libgles2" "libgles2"

    if [ "$IS_ADRENO" == "1" ]; then
        echo -e "  [*] Trying optional Turnip PPA. It is safe if this fails."
        (
            proot-distro login "$DISTRO_ID" -- bash -lc '
add-apt-repository -y ppa:mastag/mesa-turnip-kgsl >/dev/null 2>&1 || exit 1
apt-get update -y >/dev/null 2>&1 || exit 1
DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -o Dpkg::Options::="--force-confold" >/dev/null 2>&1
' >> "$ERROR_LOG" 2>&1
        ) &

        if spinner $! "Optional Mesa Turnip PPA upgrade"; then
            echo -e "  [+] ${GREEN}Turnip PPA applied.${NC}"
        else
            echo -e "  [*] ${YELLOW}Turnip PPA skipped. Stock Ubuntu Mesa is still fine.${NC}"
        fi
    else
        echo -e "  [*] Non-Adreno device: keeping fallback GPU path."
    fi
}

# ============== STEP 7: DEV TOOLS INSIDE UBUNTU ==============
step_ubuntu_devtools() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing development and network tools inside Ubuntu...${NC}"
    echo ""

    install_guest_pkg "python3" "Python 3"
    install_guest_pkg "python3-pip" "pip"
    install_guest_pkg "python3-venv" "venv"
    install_guest_pkg "git" "Git"
    install_guest_pkg "neovim" "Neovim"
    install_guest_pkg "vim" "Vim"

    install_guest_pkg "build-essential" "build-essential"
    install_guest_pkg "clang" "Clang"
    install_guest_pkg "cmake" "CMake"
    install_guest_pkg "pkg-config" "pkg-config"

    install_guest_pkg "openssh-client" "OpenSSH client"
    install_guest_pkg "openssh-server" "OpenSSH server"

    install_guest_pkg "net-tools" "net-tools"
    install_guest_pkg "iproute2" "iproute2"
    install_guest_pkg "nmap" "nmap"
    install_guest_pkg "curl" "curl"
    install_guest_pkg "wget" "wget"
    install_guest_pkg "rsync" "rsync"
    install_guest_pkg "htop" "htop"
    install_guest_pkg "unzip" "unzip"
    install_guest_pkg "pavucontrol" "PulseAudio volume control"
}

# ============== STEP 8: STORAGE ==============
step_storage() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Setting up shared storage...${NC}"
    echo ""

    if [ ! -d "$HOME/storage" ]; then
        echo -e "  [*] Requesting storage permission. Android may show a permission popup."
        if command -v termux-setup-storage >/dev/null 2>&1; then
            termux-setup-storage
        else
            echo -e "  [-] termux-setup-storage not found."
        fi

        for i in {1..10}; do
            [ -d "$HOME/storage/shared" ] && break
            sleep 1
        done
    fi

    if [ -d "$HOME/storage/shared" ]; then
        ln -sfn "$HOME/storage/shared" "$HOME/Storage"
        echo -e "  [+] ${GREEN}Storage linked${NC}: ~/Storage -> shared device storage"
        echo -e "  [*] Inside Ubuntu it may be mounted at /mnt/shared if proot-distro supports --bind."
    else
        echo -e "  [-] ${YELLOW}Storage permission was not granted.${NC}"
        echo -e "      Run termux-setup-storage later, then re-run this script if needed."
    fi
}

# ============== STEP 9: LAUNCHERS ==============
step_launchers() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Creating launcher scripts...${NC}"
    echo ""

    mkdir -p "$HOME/.config"

    cat > "$HOME/.config/termux-ubuntu.conf" << EOF
DISTRO_ID="$DISTRO_ID"
UBUNTU_USER="$UBUNTU_USER"
EOF

    cat > "$HOME/.config/linux-gpu.sh" << 'EOF'
export MESA_NO_ERROR=1
export MESA_GL_VERSION_OVERRIDE=4.6
export MESA_GLES_VERSION_OVERRIDE=3.2
export GALLIUM_DRIVER=zink
export MESA_LOADER_DRIVER_OVERRIDE=zink
export TU_DEBUG=noconform
export MESA_VK_WSI_PRESENT_MODE=immediate
export ZINK_DESCRIPTORS=lazy
export XDG_DATA_DIRS=/data/data/com.termux/files/usr/share:${XDG_DATA_DIRS:-}
export XDG_CONFIG_DIRS=/data/data/com.termux/files/usr/etc/xdg:${XDG_CONFIG_DIRS:-}
EOF

    echo -e "  [+] Created ~/.config/termux-ubuntu.conf"
    echo -e "  [+] Created ~/.config/linux-gpu.sh"

    cat > "$HOME/start-linux.sh" << 'LAUNCHEREOF'
#!/data/data/com.termux/files/usr/bin/bash
set -u

[ -f "$HOME/.config/termux-ubuntu.conf" ] && source "$HOME/.config/termux-ubuntu.conf"

DISTRO_ID="${DISTRO_ID:-ubuntu}"
UBUNTU_USER="${UBUNTU_USER:-droid}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

fail() {
    printf '\033[0;31m[!] %s\033[0m\n' "$1"
    exit 1
}

echo ""
echo "[*] Starting XFCE4 inside Ubuntu..."
echo ""

command -v proot-distro >/dev/null 2>&1 || fail "proot-distro is not installed. Re-run setup.sh."
command -v termux-x11 >/dev/null 2>&1 || fail "termux-x11 is not installed. Re-run setup.sh."
proot-distro login "$DISTRO_ID" -- true >/dev/null 2>&1 || fail "Ubuntu container missing. Run: proot-distro install $DISTRO_ID"

source "$HOME/.config/linux-gpu.sh" 2>/dev/null || true

echo "[*] Cleaning up old sessions..."
pkill -9 -f "termux.x11" 2>/dev/null || true
pkill -9 -f "virgl_test_server_android" 2>/dev/null || true
pkill -9 -f "dbus" 2>/dev/null || true

if command -v pulseaudio >/dev/null 2>&1; then
    unset PULSE_SERVER
    pulseaudio --kill 2>/dev/null || true
    sleep 0.5

    echo "[*] Starting audio server..."
    if pulseaudio --start --exit-idle-time=-1 2>/tmp/pulse-err.log; then
        pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 2>/dev/null || true
        export PULSE_SERVER=tcp:127.0.0.1
        echo "  [+] Audio server running"
    else
        echo "  [-] Audio failed to start. Continuing without sound."
    fi
fi

if command -v virgl_test_server_android >/dev/null 2>&1; then
    echo "[*] Starting VirGL server fallback..."
    virgl_test_server_android --use-egl-surfaceless --use-gles >/tmp/virgl.log 2>&1 &
fi

echo "[*] Starting X11 server..."
export XKB_CONFIG_ROOT="$PREFIX/share/X11/xkb"

if [ -d "$XKB_CONFIG_ROOT" ]; then
    termux-x11 :0 -ac -xkbdir "$XKB_CONFIG_ROOT" >/tmp/termux-x11.log 2>&1 &
else
    termux-x11 :0 -ac >/tmp/termux-x11.log 2>&1 &
fi

X11_PID=$!
SOCKET="$PREFIX/tmp/.X11-unix/X0"

for ((i=0; i<30; i++)); do
    [ -e "$SOCKET" ] && break
    kill -0 "$X11_PID" 2>/dev/null || break
    sleep 0.5
done

if [ ! -e "$SOCKET" ]; then
    fail "termux-x11 did not create $SOCKET. Install/open the Termux-X11 APK, then retry."
fi

export DISPLAY=:0

echo "-----------------------------------------------"
echo "  [*] Open the Termux-X11 app to view desktop!"
echo "-----------------------------------------------"
echo ""

BIND_ARGS=(--shared-tmp)

if [ -d "$HOME/storage/shared" ]; then
    if proot-distro login --help 2>&1 | grep -q -- '--bind'; then
        BIND_ARGS+=(--bind "$HOME/storage/shared:/mnt/shared")
    else
        echo "  [*] proot-distro --bind not available; skipping /mnt/shared"
    fi
fi

LOGIN_USER="root"
if proot-distro login "$DISTRO_ID" -- id "$UBUNTU_USER" >/dev/null 2>&1; then
    LOGIN_USER="$UBUNTU_USER"
fi

echo "[*] Launching XFCE4 inside Ubuntu as '$LOGIN_USER'..."

exec proot-distro login "$DISTRO_ID" "${BIND_ARGS[@]}" --user "$LOGIN_USER" -- bash -lc '
export DISPLAY=:0
export PULSE_SERVER=tcp:127.0.0.1
export XDG_RUNTIME_DIR=/tmp/runtime-$(id -un)
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
export LANG=en_US.UTF-8
export MESA_NO_ERROR=1
export MESA_GL_VERSION_OVERRIDE=4.6
export MESA_GLES_VERSION_OVERRIDE=3.2
export GALLIUM_DRIVER=zink
export MESA_LOADER_DRIVER_OVERRIDE=zink
export TU_DEBUG=noconform
export MESA_VK_WSI_PRESENT_MODE=immediate
export ZINK_DESCRIPTORS=lazy
dbus-launch --exit-with-session startxfce4
'
LAUNCHEREOF

    chmod +x "$HOME/start-linux.sh"
    echo -e "  [+] Created ~/start-linux.sh"

    cat > "$HOME/start-linux-safe.sh" << 'SAFEEOF'
#!/data/data/com.termux/files/usr/bin/bash
set -u

[ -f "$HOME/.config/termux-ubuntu.conf" ] && source "$HOME/.config/termux-ubuntu.conf"

DISTRO_ID="${DISTRO_ID:-ubuntu}"
UBUNTU_USER="${UBUNTU_USER:-droid}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

echo ""
echo "[*] Starting XFCE4 inside Ubuntu in compatibility mode..."
echo ""

command -v proot-distro >/dev/null 2>&1 || { echo "[!] proot-distro missing"; exit 1; }
command -v termux-x11 >/dev/null 2>&1 || { echo "[!] termux-x11 missing"; exit 1; }

pkill -9 -f "termux.x11" 2>/dev/null || true
pkill -9 -f "virgl_test_server_android" 2>/dev/null || true
pkill -9 -f "dbus" 2>/dev/null || true

if command -v pulseaudio >/dev/null 2>&1; then
    unset PULSE_SERVER
    pulseaudio --kill 2>/dev/null || true
    sleep 0.5
    pulseaudio --start --exit-idle-time=-1 2>/dev/null || true
    pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 2>/dev/null || true
    export PULSE_SERVER=tcp:127.0.0.1
fi

export XKB_CONFIG_ROOT="$PREFIX/share/X11/xkb"

if [ -d "$XKB_CONFIG_ROOT" ]; then
    termux-x11 :0 -ac -xkbdir "$XKB_CONFIG_ROOT" >/tmp/termux-x11-safe.log 2>&1 &
else
    termux-x11 :0 -ac >/tmp/termux-x11-safe.log 2>&1 &
fi

X11_PID=$!
SOCKET="$PREFIX/tmp/.X11-unix/X0"

for ((i=0; i<30; i++)); do
    [ -e "$SOCKET" ] && break
    kill -0 "$X11_PID" 2>/dev/null || break
    sleep 0.5
done

if [ ! -e "$SOCKET" ]; then
    echo "[!] termux-x11 did not start. Install/open the Termux-X11 APK."
    exit 1
fi

export DISPLAY=:0

LOGIN_USER="root"
if proot-distro login "$DISTRO_ID" -- id "$UBUNTU_USER" >/dev/null 2>&1; then
    LOGIN_USER="$UBUNTU_USER"
fi

exec proot-distro login "$DISTRO_ID" --shared-tmp --user "$LOGIN_USER" -- bash -lc '
export DISPLAY=:0
export PULSE_SERVER=tcp:127.0.0.1
export XDG_RUNTIME_DIR=/tmp/runtime-$(id -un)
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
export LANG=en_US.UTF-8
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
unset MESA_LOADER_DRIVER_OVERRIDE
dbus-launch --exit-with-session startxfce4
'
SAFEEOF

    chmod +x "$HOME/start-linux-safe.sh"
    echo -e "  [+] Created ~/start-linux-safe.sh"

    cat > "$HOME/start-ubuntu-cli.sh" << 'CLIEOF'
#!/data/data/com.termux/files/usr/bin/bash
set -u

[ -f "$HOME/.config/termux-ubuntu.conf" ] && source "$HOME/.config/termux-ubuntu.conf"

DISTRO_ID="${DISTRO_ID:-ubuntu}"
UBUNTU_USER="${UBUNTU_USER:-droid}"

LOGIN_USER="root"
if proot-distro login "$DISTRO_ID" -- id "$UBUNTU_USER" >/dev/null 2>&1; then
    LOGIN_USER="$UBUNTU_USER"
fi

exec proot-distro login "$DISTRO_ID" --user "$LOGIN_USER"
CLIEOF

    chmod +x "$HOME/start-ubuntu-cli.sh"
    echo -e "  [+] Created ~/start-ubuntu-cli.sh"

    cat > "$HOME/update-ubuntu.sh" << 'UPDATEEOF'
#!/data/data/com.termux/files/usr/bin/bash
set -u

[ -f "$HOME/.config/termux-ubuntu.conf" ] && source "$HOME/.config/termux-ubuntu.conf"

DISTRO_ID="${DISTRO_ID:-ubuntu}"

echo "[*] Updating Termux host..."
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::="--force-confold"

echo "[*] Updating Ubuntu container..."
proot-distro login "$DISTRO_ID" -- env DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get update -y
proot-distro login "$DISTRO_ID" -- env DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get upgrade -y -o Dpkg::Options::="--force-confold"
UPDATEEOF

    chmod +x "$HOME/update-ubuntu.sh"
    echo -e "  [+] Created ~/update-ubuntu.sh"

    cat > "$HOME/stop-linux.sh" << 'STOPEOF'
#!/data/data/com.termux/files/usr/bin/bash
echo "Stopping Ubuntu XFCE desktop..."
pkill -9 -f "termux.x11" 2>/dev/null || true
pkill -9 -f "virgl_test_server_android" 2>/dev/null || true
pkill -9 -f "pulseaudio" 2>/dev/null || true
pkill -9 -f "dbus" 2>/dev/null || true
echo "Desktop stopped."
STOPEOF

    chmod +x "$HOME/stop-linux.sh"
    echo -e "  [+] Created ~/stop-linux.sh"

    echo ""
    read -p "Auto-launch the desktop every time you open Termux? (y/N): " AUTOSTART
    if [[ "$AUTOSTART" =~ ^[Yy]$ ]]; then
        if ! grep -q "start-linux.sh" "$HOME/.bashrc" 2>/dev/null; then
            cat >> "$HOME/.bashrc" << 'BASHEOF'

# Auto-start Ubuntu XFCE desktop
if [ -z "${LINUX_STARTED:-}" ] && [ -x "$HOME/start-linux.sh" ]; then
    export LINUX_STARTED=1
    "$HOME/start-linux.sh"
fi
BASHEOF
            echo -e "  [+] ${GREEN}Auto-start enabled${NC}"
        fi
    else
        echo -e "  [*] Skipped. Start manually with: ${GREEN}./start-linux.sh${NC}"
    fi
}

# ============== STEP 10: SHORTCUTS INSIDE UBUNTU ==============
step_shortcuts() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Creating desktop shortcuts inside Ubuntu...${NC}"
    echo ""

    local tmp_script
    tmp_script=$(mktemp "$HOME/.ubuntu-shortcuts.XXXXXX")

    cat > "$tmp_script" << 'SHORTCUTEOF'
#!/bin/bash
set -e

USER_NAME="${USER_NAME:-droid}"
USER_HOME="/home/${USER_NAME}"

mkdir -p "${USER_HOME}/Desktop"

cat > "${USER_HOME}/Desktop/Terminal.desktop" << 'EOF'
[Desktop Entry]
Name=Terminal
Exec=xfce4-terminal
Icon=utilities-terminal
Type=Application
EOF

cat > "${USER_HOME}/Desktop/Files.desktop" << 'EOF'
[Desktop Entry]
Name=Files
Exec=thunar
Icon=system-file-manager
Type=Application
EOF

chmod +x "${USER_HOME}/Desktop/"*.desktop 2>/dev/null || true

if id "${USER_NAME}" >/dev/null 2>&1; then
    chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/Desktop" 2>/dev/null || true
fi

echo "Ubuntu desktop shortcuts created"
SHORTCUTEOF

    (
        proot-distro login "$DISTRO_ID" -- env USER_NAME="$UBUNTU_USER" bash -s < "$tmp_script" >> "$ERROR_LOG" 2>&1
    ) &

    spinner $! "Creating Ubuntu desktop shortcuts..."
    local result=$?

    rm -f "$tmp_script"

    if [ $result -ne 0 ]; then
        FAILED_TASKS+=("desktop-shortcuts")
    fi
}

# ============== COMPLETION ==============
show_completion() {
    echo ""

    local total_failed=$(( ${#FAILED_PKGS_HOST[@]} + ${#FAILED_PKGS_GUEST[@]} + ${#FAILED_TASKS[@]} ))

    if [ "$total_failed" -gt 0 ]; then
        echo -e "${YELLOW}"
        cat << 'PARTIAL'
---------------------------------------------------------------
[!]  INSTALL FINISHED WITH SOME FAILURES
---------------------------------------------------------------
PARTIAL
        echo -e "${NC}"

        if [ ${#FAILED_PKGS_HOST[@]} -gt 0 ]; then
            echo -e "${RED}[*] Host failures:${NC}"
            for p in "${FAILED_PKGS_HOST[@]}"; do
                echo -e "    - $p"
            done
        fi

        if [ ${#FAILED_PKGS_GUEST[@]} -gt 0 ]; then
            echo -e "${RED}[*] Ubuntu package failures:${NC}"
            for p in "${FAILED_PKGS_GUEST[@]}"; do
                echo -e "    - $p"
            done
        fi

        if [ ${#FAILED_TASKS[@]} -gt 0 ]; then
            echo -e "${RED}[*] Task failures:${NC}"
            for p in "${FAILED_TASKS[@]}"; do
                echo -e "    - $p"
            done
        fi

        echo -e "${YELLOW}[*] Details: ${ERROR_LOG}${NC}"
    else
        echo -e "${GREEN}"
        cat << 'COMPLETE'
---------------------------------------------------------------
[*]  INSTALLATION COMPLETE
---------------------------------------------------------------
COMPLETE
        echo -e "${NC}"
    fi

    echo -e "${WHITE}[*] Device profile: ${DEVICE_LABEL}${NC}"
    echo -e "${WHITE}[*] Distro: ${DISTRO_NAME} (${DISTRO_ID})${NC}"
    echo -e "${WHITE}[*] Desktop: XFCE4 inside Ubuntu${NC}"
    echo -e "${WHITE}[*] GPU: ${GPU_NAME}${NC}"
    echo ""
    echo -e "${CYAN}[*] Commands:${NC}"
    echo -e "    Start desktop:        ${GREEN}./start-linux.sh${NC}"
    echo -e "    Safe mode:            ${GREEN}./start-linux-safe.sh${NC}"
    echo -e "    Ubuntu terminal only: ${GREEN}./start-ubuntu-cli.sh${NC}"
    echo -e "    Update host + Ubuntu: ${GREEN}./update-ubuntu.sh${NC}"
    echo -e "    Stop desktop:         ${GREEN}./stop-linux.sh${NC}"
    echo ""
    echo -e "${YELLOW}[*] Remember: install/open the Termux-X11 APK to see the desktop.${NC}"
    echo -e "${WHITE}[*] Shared storage:${NC} ~/Storage (host), /mnt/shared (inside Ubuntu)"
    echo -e "${WHITE}[*] GPU test (in GUI terminal):${NC} ${GREEN}glxinfo -B | head -20${NC} (want Turnip Adreno, not llvmpipe)"
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