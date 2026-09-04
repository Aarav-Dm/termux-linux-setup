#!/data/data/com.termux/files/usr/bin/bash
#######################################################
# Termux Ubuntu Setup - Tab S8 Ultra / Tab S9 Ultra
# terminal-setup.sh  (FIXED BUILD)
#
# Fixes vs previous version:
#  1. tur-repo added        -> mesa-zink lives in TUR, not x11-repo.
#                              This was why "Mesa Zink core" failed.
#  2. Vulkan loader conflict handled explicitly.
#                              vulkan-loader-generic and vulkan-loader-android
#                              CONFLICT. Only one may be installed.
#                              Default here is the Turnip path.
#  3. All /tmp writes moved to $TMPDIR ($PREFIX/tmp).
#                              /tmp is NOT writable in Termux -> "Permission denied".
#  4. X11 startup race fixed.
#                              Stale $TMPDIR/.X11-unix/X0 made the old script
#                              think X was up, so startxfce4 said
#                              "X server already running on display :0"
#                              and then "xrdb: Connection refused".
#                              Now: force-stop app, delete stale socket,
#                              and use termux-x11 -xstartup so the server
#                              launches the session itself. No race possible.
#  5. Removed undocumented flags -ac and -xkbdir.
#                              termux-x11 documents only:
#                              -xstartup, -legacy-drawing, -force-bgra, -dpi.
#                              XKB is configured via XKB_CONFIG_ROOT env var.
#  6. pkill "dbus" narrowed   -> was killing unrelated dbus processes.
#  7. Autostart guarded       -> only on interactive shells, and opt-out safe.
#  8. Added ./gpu-check.sh and ./switch-vulkan.sh helpers.
#######################################################

set -u

TOTAL_STEPS=10
CURRENT_STEP=0
ERROR_LOG="$HOME/linux-setup-errors.log"
: > "$ERROR_LOG"

DISTRO_ID="ubuntu"
DISTRO_NAME="Ubuntu (release resolved at install time)"
UBUNTU_USER="droid"

DEVICE_MODEL="Unknown"
DEVICE_LABEL="Unknown device"
GPU_NAME="Unknown GPU"
IS_ADRENO=1

# Termux writable temp. NEVER use bare /tmp on the host.
TMPDIR="${TMPDIR:-$PREFIX/tmp}"
export TMPDIR

# ============== COLORS ==============
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
WHITE='\033[1;37m'; GRAY='\033[0;90m'; NC='\033[0m'; BOLD='\033[1m'

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
    [ $result -ne 0 ] && FAILED_PKGS_HOST+=("$pkg")
    return $result
}

# Optional host package: records nothing on failure, used for "nice to have" pkgs.
try_host_pkg() {
    local pkg=$1
    local name=${2:-$pkg}
    (
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            -o Dpkg::Options::="--force-confold" "$pkg" \
            >> "$ERROR_LOG" 2>&1
    ) &
    spinner $! "Installing ${name} (optional)..."
    return $?
}

install_guest_pkg() {
    local pkg=$1
    local name=${2:-$pkg}
    (
        proot-distro login "$DISTRO_ID" -- env \
            DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC \
            apt-get install -y \
            -o Dpkg::Options::="--force-confold" "$pkg" \
            >> "$ERROR_LOG" 2>&1
    ) &
    spinner $! "Installing Ubuntu package: ${name}..."
    local result=$?
    [ $result -ne 0 ] && FAILED_PKGS_GUEST+=("$pkg")
    return $result
}

run_guest() {
    local desc=$1
    shift
    (
        proot-distro login "$DISTRO_ID" -- env \
            DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC \
            "$@" >> "$ERROR_LOG" 2>&1
    ) &
    spinner $! "${desc}..."
    local result=$?
    [ $result -ne 0 ] && FAILED_TASKS+=("$desc")
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

    # FIX 3: verify our temp dir is actually writable before anything else.
    if ! ( : > "$TMPDIR/.write-test" ) 2>/dev/null; then
        echo -e "${RED}[!] TMPDIR ($TMPDIR) is not writable. Aborting.${NC}"
        exit 1
    fi
    rm -f "$TMPDIR/.write-test"
    echo -e "  [+] Writable TMPDIR: ${GREEN}${TMPDIR}${NC}"

    if command -v curl >/dev/null 2>&1; then
        if curl --max-time 8 -sI https://packages.termux.dev >/dev/null 2>&1; then
            echo -e "  [+] Internet connection: ${GREEN}OK${NC}"
        else
            echo -e "${RED}[!] No internet connection detected.${NC}"
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
        echo -e "${YELLOW}[!] Low storage: only ${avail_gb}GB free (want 8GB+).${NC}"
        read -p "Continue anyway? (y/N): " CONT
        [[ "$CONT" =~ ^[Yy]$ ]] || exit 1
    else
        echo -e "  [+] Free storage: ${GREEN}${avail_gb}GB${NC} OK"
    fi

    local arch
    arch=$(uname -m)
    if [ "$arch" != "aarch64" ]; then
        echo -e "${YELLOW}[!] Architecture is ${arch}, expected aarch64.${NC}"
        read -p "Continue anyway? (y/N): " ARCHCONT
        [[ "$ARCHCONT" =~ ^[Yy]$ ]] || exit 1
    else
        echo -e "  [+] Architecture: ${GREEN}${arch}${NC} OK"
    fi

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
    local brand android_ver egl platform
    brand=$(getprop ro.product.brand 2>/dev/null || echo "Unknown")
    android_ver=$(getprop ro.build.version.release 2>/dev/null || echo "Unknown")
    egl=$(getprop ro.hardware.egl 2>/dev/null || echo "")
    platform=$(getprop ro.board.platform 2>/dev/null || echo "")

    echo -e "  [*] Device: ${WHITE}${brand} ${DEVICE_MODEL}${NC}"
    echo -e "  [*] Android: ${WHITE}${android_ver}${NC}"
    echo -e "  [*] Platform: ${WHITE}${platform}${NC}"

    case "$DEVICE_MODEL" in
        SM-X900*|SM-X906*)
            DEVICE_LABEL="Galaxy Tab S8 Ultra (Snapdragon 8 Gen 1 / Adreno 730)"
            GPU_NAME="Adreno 730 (Turnip + Zink path)"; IS_ADRENO=1 ;;
        SM-X910*|SM-X916*|SM-X918*)
            DEVICE_LABEL="Galaxy Tab S9 Ultra (Snapdragon 8 Gen 2 for Galaxy / Adreno 740)"
            GPU_NAME="Adreno 740 (Turnip + Zink path)"; IS_ADRENO=1 ;;
        *)
            if [[ "$egl" == *adreno* ]] || [[ "$platform" == "taro" ]] || \
               [[ "$platform" == "kalama" ]] || [[ "$DEVICE_MODEL" == SM-X9* ]]; then
                DEVICE_LABEL="${brand} ${DEVICE_MODEL} (Adreno-class, Turnip path)"
                GPU_NAME="Adreno-class (Turnip + Zink path)"; IS_ADRENO=1
            else
                DEVICE_LABEL="${brand} ${DEVICE_MODEL} (generic - VirGL/llvmpipe fallback)"
                GPU_NAME="Non-Adreno (VirGL/llvmpipe fallback)"; IS_ADRENO=0
            fi ;;
    esac

    echo -e "  [*] Profile: ${WHITE}${DEVICE_LABEL}${NC}"
    echo -e "  [*] GPU: ${WHITE}${GPU_NAME}${NC}"
    if [ "$IS_ADRENO" == "1" ]; then
        echo -e "  [+] ${GREEN}Hardware acceleration path available.${NC}"
    else
        echo -e "${YELLOW}  [!] Non-Adreno: fallback renderer. XFCE works, 3D slower.${NC}"
    fi
    echo ""
    sleep 1
}

show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'BANNER'
---------------------------------------------------------------
Termux Ubuntu Setup - Tab S8 Ultra / Tab S9 Ultra  [FIXED]
---------------------------------------------------------------
BANNER
    echo -e "${NC}"
    echo -e "${WHITE}  Host: Termux minimal${NC}"
    echo -e "${WHITE}  Guest: Ubuntu via proot-distro${NC}"
    echo -e "${WHITE}  Desktop: XFCE4 lean inside Ubuntu${NC}"
    echo -e "${WHITE}  GPU: Turnip/Zink for Adreno, VirGL/llvmpipe fallback${NC}"
    echo ""
}

# ============== STEP 1: UPDATE HOST ==============
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
# FIX 1 + FIX 2 live here.
step_host_base() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing host base packages...${NC}"
    echo ""

    # --- FIX 1: both repos, THEN refresh. mesa-zink is in tur-repo. ---
    install_host_pkg "x11-repo" "X11 repository"
    install_host_pkg "tur-repo"  "Termux User Repository (needed for mesa-zink)"

    (DEBIAN_FRONTEND=noninteractive apt-get update -y >> "$ERROR_LOG" 2>&1) &
    spinner $! "Refreshing package lists after adding repos..."

    # Repair any half-configured state left by a previous failed run.
    (DEBIAN_FRONTEND=noninteractive apt-get -f install -y >> "$ERROR_LOG" 2>&1) &
    spinner $! "Repairing broken dependencies (if any)..."

    install_host_pkg "termux-x11-nightly" "Termux-X11 display server"
    install_host_pkg "xorg-xrandr" "XRandR"
    install_host_pkg "xkeyboard-config" "XKB keyboard data"
    install_host_pkg "pulseaudio" "PulseAudio server"
    install_host_pkg "proot-distro" "proot-distro"
    install_host_pkg "virglrenderer-android" "VirGL fallback renderer"

    step_vulkan_stack
}

# --- FIX 2: the Vulkan loader conflict, handled properly ---
#
# vulkan-loader-generic and vulkan-loader-android CONFLICT. Installing one
# while the other is present is exactly why "Installing Vulkan loader..." and
# "Installing Mesa Zink core..." both failed on the first run.
#
# Two mutually exclusive paths:
#
#   TURNIP  (default, recommended for Adreno)
#     vulkan-loader-generic + mesa-vulkan-icd-freedreno + mesa-zink
#     Open-source Turnip driver talking to KGSL. This is the standard
#     working Adreno recipe.
#
#   ANDROID (fallback)
#     vulkan-loader-android + mesa-zink
#     Uses Qualcomm's system Vulkan driver. Known to crash zink on some
#     Adreno parts with a memory-type assertion (TUR issue #530, reported
#     on Tab S8+ / S22 / S23 Ultra). Only try this if Turnip misbehaves.
#
# Switch later with: ./switch-vulkan.sh turnip | android
step_vulkan_stack() {
    echo ""
    echo -e "  ${CYAN}[*] Configuring Vulkan stack (Turnip path)...${NC}"

    # Remove the conflicting loader first. Ignore failure if not installed.
    (
        DEBIAN_FRONTEND=noninteractive apt-get remove -y vulkan-loader-android \
            >> "$ERROR_LOG" 2>&1 || true
    ) &
    spinner $! "Removing conflicting vulkan-loader-android (if present)..."

    install_host_pkg "vulkan-loader-generic" "Vulkan loader (generic)"

    # Turnip ICD. Package name differs across repo snapshots, so probe.
    local turnip_pkg=""
    for cand in mesa-vulkan-icd-freedreno mesa-vulkan-icd-freedreno-dri3 mesa-vulkan-icd-wrapper; do
        if apt-cache policy "$cand" 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -Eq '^[0-9]'; then
            turnip_pkg="$cand"
            break
        fi
    done

    if [ -n "$turnip_pkg" ]; then
        install_host_pkg "$turnip_pkg" "Turnip Adreno Vulkan driver (${turnip_pkg})"
    else
        echo -e "  ${YELLOW}[!] No Turnip ICD candidate found in repos. Zink may fall back to software.${NC}"
        FAILED_PKGS_HOST+=("mesa-vulkan-icd-freedreno")
    fi

    install_host_pkg "mesa-zink" "Mesa Zink core"
    try_host_pkg "vulkan-tools" "vulkan-tools (host, for vulkaninfo)"
}

# ============== STEP 3: UBUNTU ROOTFS ==============
step_ubuntu_install() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Ubuntu via proot-distro...${NC}"
    echo ""

    if ! command -v proot-distro >/dev/null 2>&1; then
        echo -e "${RED}[!] proot-distro is missing after host setup.${NC}"
        echo -e "${YELLOW}    Check: ${ERROR_LOG}${NC}"
        exit 1
    fi

    # FIX 11: pin the release. Do not install a bare "ubuntu".
    #
    # proot-distro 5.x pulls from Docker Hub, where a bare name resolves
    # to the ":latest" tag. Docker's ubuntu:latest tracks the newest
    # release, NOT the newest LTS, and it moves. Installing "ubuntu"
    # therefore gives whatever shipped this month, and two people running
    # this script weeks apart get different systems. A setup script must
    # be deterministic.
    #
    # Default is the LTS: wider package coverage, fewer PPA gaps, and it
    # is what community guides assume. Override for a newer release with:
    #     UBUNTU_RELEASE=26.04 ./terminal-setup.sh
    UBUNTU_RELEASE="${UBUNTU_RELEASE:-24.04}"

    local known
    known=$(proot-distro list 2>/dev/null | awk '{print $1}')

    # proot-distro 5.x accepts "name:tag"; older builds use plugin aliases.
    if proot-distro install --help 2>&1 | grep -qi "image\|tag\|ubuntu:"; then
        DISTRO_ID="ubuntu:${UBUNTU_RELEASE}"
        DISTRO_NAME="Ubuntu ${UBUNTU_RELEASE}"
        echo -e "  [*] proot-distro supports pinned images."
    else
        for candidate in "ubuntu-${UBUNTU_RELEASE}" ubuntu-24.04 ubuntu-22.04 ubuntu; do
            if printf '%s\n' "$known" | grep -qx "$candidate"; then
                DISTRO_ID="$candidate"
                DISTRO_NAME="Ubuntu (${candidate})"
                break
            fi
        done
        echo -e "  ${YELLOW}[!] Older proot-distro: cannot pin a tag.${NC}"
        echo -e "  ${YELLOW}    Release will be whatever this alias ships.${NC}"
    fi

    echo -e "  [*] Selected Ubuntu image: ${WHITE}${DISTRO_ID}${NC}"

    if proot-distro login "$DISTRO_ID" -- true >/dev/null 2>&1; then
        echo -e "  [+] ${GREEN}Existing Ubuntu container is healthy, reusing it.${NC}"
        return
    fi

    echo -e "  [*] Downloading Ubuntu rootfs. This can take a while..."
    (proot-distro install "$DISTRO_ID" >> "$ERROR_LOG" 2>&1) &
    if ! spinner $! "Installing Ubuntu rootfs..."; then
        echo -e "${RED}[!] Failed to install Ubuntu.${NC}"
        echo -e "${YELLOW}    Try manually: proot-distro install ${DISTRO_ID}${NC}"
        exit 1
    fi
}

# ============== STEP 4: UBUNTU BOOTSTRAP ==============
step_ubuntu_bootstrap() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Bootstrapping Ubuntu...${NC}"
    echo ""

    if ! run_guest "Updating Ubuntu package lists" apt-get update -y; then
        echo -e "${RED}[!] Ubuntu apt update failed. Check: ${ERROR_LOG}${NC}"
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

# ============== STEP 5: XFCE DESKTOP ==============
step_ubuntu_desktop() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing XFCE4 inside Ubuntu...${NC}"
    echo ""
    echo -e "  [*] Using lean XFCE set, not xubuntu-desktop."

    install_guest_pkg "dbus-x11" "D-Bus X11 bindings"
    install_guest_pkg "xauth" "xauth"
    install_guest_pkg "x11-xserver-utils" "x11-xserver-utils"
    install_guest_pkg "x11-utils" "x11-utils (xdpyinfo, for health checks)"

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

# ============== STEP 6: GPU TOOLS ==============
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

    # FIX 9: these three were the actual cause of
    #   "MESA: error: ZINK: failed to choose pdev"
    # zink runs INSIDE the guest, but Turnip was only installed on the host.
    # Under proot the guest has its own /usr/lib and its own Vulkan loader,
    # so with no ICD present it enumerates zero devices and zink dies.
    install_guest_pkg "mesa-vulkan-drivers" "Mesa Vulkan drivers (guest ICD)"
    install_guest_pkg "libgl1-mesa-dri" "Mesa DRI drivers (guest)"
    install_guest_pkg "libglx-mesa0" "Mesa GLX (guest)"
    install_guest_pkg "xdg-desktop-portal" "xdg-desktop-portal"

    if [ "$IS_ADRENO" == "1" ]; then
        echo -e "  [*] Trying optional Turnip PPA. Safe if this fails."
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
    fi
}

# ============== STEP 7: DEV TOOLS ==============
step_ubuntu_devtools() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing dev and network tools inside Ubuntu...${NC}"
    echo ""
    for p in python3 python3-pip python3-venv git neovim vim \
             build-essential clang cmake pkg-config \
             openssh-client openssh-server \
             net-tools iproute2 nmap curl wget rsync htop unzip pavucontrol; do
        install_guest_pkg "$p" "$p"
    done
}

# ============== STEP 8: STORAGE ==============
step_storage() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Setting up shared storage...${NC}"
    echo ""

    if [ ! -d "$HOME/storage" ]; then
        echo -e "  [*] Requesting storage permission. Android may show a popup."
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
    else
        echo -e "  [-] ${YELLOW}Storage permission not granted.${NC}"
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

    # HOST-side env only. Guest GPU settings live in ~/.xfce-session.sh and
    # are chosen by ./switch-gpu.sh. Deliberately no GALLIUM_DRIVER or
    # MESA_LOADER_DRIVER_OVERRIDE here: they leaked into the container and
    # forced zink even when the guest had no Vulkan ICD, which is what
    # produced "ZINK: failed to choose pdev" with no fallback.
    cat > "$HOME/.config/linux-gpu.sh" << 'EOF'
# Host-side Mesa hints for the Termux X server and virgl. Safe to leak.
export MESA_NO_ERROR=1
EOF

    echo -e "  [+] Created ~/.config/termux-ubuntu.conf"
    echo -e "  [+] Created ~/.config/linux-gpu.sh"

    # ---- Shared session body, launched BY termux-x11 via -xstartup ----
    # FIX 4: this is the whole point. termux-x11 starts the X server, waits
    # until it is genuinely accepting connections, and only then runs this.
    # No socket polling, no race, no "X server already running".
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

# FIX 9: never force MESA_LOADER_DRIVER_OVERRIDE. Forcing it forbids Mesa
# from falling back, so a zink failure became a dead desktop instead of a
# slow one. Modes are selected with ./switch-gpu.sh
case "$GPU_MODE" in
  virgl)
    GPU_ENV='
export GALLIUM_DRIVER=virpipe
export MESA_GL_VERSION_OVERRIDE=4.3COMPAT
export MESA_GLES_VERSION_OVERRIDE=3.2
export MESA_NO_ERROR=1
'
    ;;
  zink)
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
mkdir -p \"\$XDG_RUNTIME_DIR\" 2>/dev/null || true
chmod 700 \"\$XDG_RUNTIME_DIR\" 2>/dev/null || true
export LANG=en_US.UTF-8
export XKB_CONFIG_ROOT=/usr/share/X11/xkb
${GPU_ENV}
exec dbus-launch --exit-with-session startxfce4
"
SESSIONEOF
    chmod +x "$HOME/.xfce-session.sh"
    echo -e "  [+] Created ~/.xfce-session.sh"

    # ---- Shared cleanup helper ----
    cat > "$HOME/.x11-cleanup.sh" << 'CLEANEOF'
#!/data/data/com.termux/files/usr/bin/bash
# FIX 4: proper teardown. The old script left a stale socket behind, which
# made the next run think X was already up.
TMPDIR="${TMPDIR:-$PREFIX/tmp}"

# Stop the Android activity too, not just the CLI helper.
if command -v am >/dev/null 2>&1; then
    am force-stop com.termux.x11 >/dev/null 2>&1 || true
fi

pkill -f "com.termux.x11" 2>/dev/null || true
pkill -f "termux-x11" 2>/dev/null || true
pkill -f "virgl_test_server_android" 2>/dev/null || true

# FIX 6: only kill OUR dbus session, not every dbus on the device.
pkill -f "dbus-daemon --session" 2>/dev/null || true
pkill -f "dbus-launch" 2>/dev/null || true

sleep 1

# Delete the stale socket. This is the single most important line here.
rm -f "$TMPDIR/.X11-unix/X0" 2>/dev/null || true
rm -rf "$TMPDIR/.X11-unix" 2>/dev/null || true
mkdir -p "$TMPDIR/.X11-unix" 2>/dev/null || true
chmod 1777 "$TMPDIR/.X11-unix" 2>/dev/null || true
CLEANEOF
    chmod +x "$HOME/.x11-cleanup.sh"
    echo -e "  [+] Created ~/.x11-cleanup.sh"

    # ---- Main launcher ----
    cat > "$HOME/start-linux.sh" << 'LAUNCHEREOF'
#!/data/data/com.termux/files/usr/bin/bash
set -u

[ -f "$HOME/.config/termux-ubuntu.conf" ] && source "$HOME/.config/termux-ubuntu.conf"
DISTRO_ID="${DISTRO_ID:-ubuntu}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TMPDIR="${TMPDIR:-$PREFIX/tmp}"
export TMPDIR

fail() { printf '\033[0;31m[!] %s\033[0m\n' "$1"; exit 1; }

echo ""
echo "[*] Starting XFCE4 inside Ubuntu..."
echo ""

command -v proot-distro >/dev/null 2>&1 || fail "proot-distro missing. Re-run setup."
command -v termux-x11   >/dev/null 2>&1 || fail "termux-x11 missing. Re-run setup."
proot-distro login "$DISTRO_ID" -- true >/dev/null 2>&1 \
    || fail "Ubuntu container missing. Run: proot-distro install $DISTRO_ID"

source "$HOME/.config/linux-gpu.sh" 2>/dev/null || true

echo "[*] Cleaning up old sessions..."
"$HOME/.x11-cleanup.sh"

# FIX 3: logs go to $TMPDIR, never /tmp.
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
        echo "  [-] Audio failed to start. Continuing without sound."
        echo "      Log: $TMPDIR/pulse-err.log"
    fi
fi

# FIX 10: only start VirGL in virgl mode, with no --use-* flags, and
# verify it survives. Those flags belong to the generic virgl_test_server;
# the _android build is preconfigured for Android GLES and exits when
# given them, which produced "lost connection to rendering server" and a
# SIGABRT in the guest. GPU vars are scoped to this subshell so they can
# never leak into the container.
GPU_MODE="$(cat "$HOME/.config/gpu-mode" 2>/dev/null || echo virgl)"
if [ "$GPU_MODE" = "virgl" ] && command -v virgl_test_server_android >/dev/null 2>&1; then
    echo "[*] Starting VirGL server..."
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

# Bring the Termux:X11 app to the foreground so it has a surface to draw on.
if command -v am >/dev/null 2>&1; then
    echo "[*] Opening the Termux:X11 app..."
    am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity \
        >/dev/null 2>&1 || \
        echo "  [*] Could not auto-open Termux:X11. Open it manually."
    sleep 2
fi

export XKB_CONFIG_ROOT="$PREFIX/share/X11/xkb"
export DISPLAY=:0

echo "-----------------------------------------------"
echo "  [*] Switch to the Termux:X11 app to see the desktop"
echo "-----------------------------------------------"
echo ""
echo "[*] Launching X server + XFCE4 session..."

# FIX 4 + FIX 5:
#  - no -ac / -xkbdir (not real termux-x11 flags; XKB comes from the env var)
#  - -xstartup makes termux-x11 launch the session itself once X is ready,
#    which removes the race that produced
#    "X server already running on display :0" + "xrdb: Connection refused".
exec termux-x11 :0 -xstartup "$HOME/.xfce-session.sh"
LAUNCHEREOF
    chmod +x "$HOME/start-linux.sh"
    echo -e "  [+] Created ~/start-linux.sh"

    # ---- Safe / software launcher ----
    cat > "$HOME/start-linux-safe.sh" << 'SAFEEOF'
#!/data/data/com.termux/files/usr/bin/bash
set -u

[ -f "$HOME/.config/termux-ubuntu.conf" ] && source "$HOME/.config/termux-ubuntu.conf"
DISTRO_ID="${DISTRO_ID:-ubuntu}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TMPDIR="${TMPDIR:-$PREFIX/tmp}"
export TMPDIR

echo ""
echo "[*] Starting XFCE4 in SOFTWARE mode (llvmpipe, -legacy-drawing)..."
echo ""

command -v proot-distro >/dev/null 2>&1 || { echo "[!] proot-distro missing"; exit 1; }
command -v termux-x11   >/dev/null 2>&1 || { echo "[!] termux-x11 missing"; exit 1; }

"$HOME/.x11-cleanup.sh"

if command -v pulseaudio >/dev/null 2>&1; then
    unset PULSE_SERVER
    pulseaudio --kill 2>/dev/null || true
    sleep 0.5
    pulseaudio --start --exit-idle-time=-1 2>"$TMPDIR/pulse-err-safe.log" || true
    pactl load-module module-native-protocol-tcp \
        auth-ip-acl=127.0.0.1 auth-anonymous=1 >/dev/null 2>&1 || true
    export PULSE_SERVER=tcp:127.0.0.1
fi

if command -v am >/dev/null 2>&1; then
    am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1 || true
    sleep 2
fi

export XKB_CONFIG_ROOT="$PREFIX/share/X11/xkb"
export DISPLAY=:0
export SOFTWARE_MODE=1

# -legacy-drawing is the documented fix for black-screen-with-cursor devices.
exec termux-x11 :0 -legacy-drawing -xstartup "$HOME/.xfce-session.sh"
SAFEEOF
    chmod +x "$HOME/start-linux-safe.sh"
    echo -e "  [+] Created ~/start-linux-safe.sh"

    # ---- CLI only ----
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

    # ---- Vulkan path switcher ----
    cat > "$HOME/switch-vulkan.sh" << 'VKEOF'
#!/data/data/com.termux/files/usr/bin/bash
# Swap between the two mutually exclusive Vulkan loaders.
# Usage: ./switch-vulkan.sh turnip | android
set -u
MODE="${1:-}"

case "$MODE" in
  turnip)
    echo "[*] Switching to Turnip (open-source Adreno driver)..."
    apt-get remove -y vulkan-loader-android 2>/dev/null || true
    apt-get install -y vulkan-loader-generic mesa-zink || exit 1
    for c in mesa-vulkan-icd-freedreno mesa-vulkan-icd-freedreno-dri3; do
        apt-get install -y "$c" 2>/dev/null && break
    done
    echo "[+] Turnip path active. Test with ./gpu-check.sh"
    ;;
  android)
    echo "[*] Switching to Android system Vulkan (Qualcomm driver)..."
    echo "    Note: known to crash zink on some Adreno parts (TUR issue #530)."
    apt-get remove -y vulkan-loader-generic 2>/dev/null || true
    apt-get install -y vulkan-loader-android mesa-zink || exit 1
    echo "[+] Android loader active. Test with ./gpu-check.sh"
    ;;
  *)
    echo "Usage: $0 turnip|android"
    echo ""
    echo "  turnip  - vulkan-loader-generic + freedreno ICD (recommended, default)"
    echo "  android - vulkan-loader-android + system Qualcomm driver (fallback)"
    echo ""
    echo "These two loaders CONFLICT. Only one can be installed at a time."
    exit 1
    ;;
esac
VKEOF
    chmod +x "$HOME/switch-vulkan.sh"
    echo -e "  [+] Created ~/switch-vulkan.sh"

    # ---- GPU mode (virgl default: most reliable under proot) ----
    [ -f "$HOME/.config/gpu-mode" ] || echo "virgl" > "$HOME/.config/gpu-mode"

    cat > "$HOME/switch-gpu.sh" << 'SWGPUEOF'
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
SWGPUEOF
    chmod +x "$HOME/switch-gpu.sh"
    echo -e "  [+] Created ~/switch-gpu.sh (mode: virgl)"

    # ---- GPU check ----
    cat > "$HOME/gpu-check.sh" << 'GPUEOF'
#!/data/data/com.termux/files/usr/bin/bash
set -u
[ -f "$HOME/.config/termux-ubuntu.conf" ] && source "$HOME/.config/termux-ubuntu.conf"
DISTRO_ID="${DISTRO_ID:-ubuntu}"

echo "=== HOST: installed vulkan loaders ==="
dpkg -l 2>/dev/null | grep -E "vulkan-loader|mesa-zink|freedreno" || echo "(none found)"

echo ""
echo "=== HOST: vulkaninfo summary ==="
if command -v vulkaninfo >/dev/null 2>&1; then
    vulkaninfo --summary 2>/dev/null | head -30 || echo "vulkaninfo failed"
else
    echo "vulkaninfo not installed on host"
fi

echo ""
echo "=== GUEST: OpenGL renderer (needs the desktop running) ==="
echo "Run this INSIDE the XFCE terminal:"
echo "    glxinfo -B | head -20"
echo ""
echo "You WANT to see 'zink' / 'Turnip' / 'Adreno'."
echo "If you see 'llvmpipe', you are on software rendering."
echo "Then try: ./switch-vulkan.sh android"
GPUEOF
    chmod +x "$HOME/gpu-check.sh"
    echo -e "  [+] Created ~/gpu-check.sh"

    # ---- Update / stop ----
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
"$HOME/.x11-cleanup.sh"
pkill -f "pulseaudio" 2>/dev/null || true
echo "Desktop stopped."
STOPEOF
    chmod +x "$HOME/stop-linux.sh"
    echo -e "  [+] Created ~/stop-linux.sh"

    # FIX 7: autostart only on interactive shells, and never inside the session
    # itself. The old version could trap you in a boot loop.
    echo ""
    read -p "Auto-launch the desktop every time you open Termux? (y/N): " AUTOSTART
    if [[ "$AUTOSTART" =~ ^[Yy]$ ]]; then
        if ! grep -q "start-linux.sh" "$HOME/.bashrc" 2>/dev/null; then
            cat >> "$HOME/.bashrc" << 'BASHEOF'

# Auto-start Ubuntu XFCE desktop (interactive shells only)
case $- in
  *i*)
    if [ -z "${LINUX_STARTED:-}" ] && [ -z "${DISPLAY:-}" ] && [ -x "$HOME/start-linux.sh" ]; then
        export LINUX_STARTED=1
        echo "Starting desktop in 3s. Press Ctrl+C to cancel."
        sleep 3 && "$HOME/start-linux.sh"
    fi
    ;;
esac
BASHEOF
            echo -e "  [+] ${GREEN}Auto-start enabled (Ctrl+C cancels it)${NC}"
        fi
    else
        echo -e "  [*] Skipped. Start manually with: ${GREEN}./start-linux.sh${NC}"
    fi
}

# ============== STEP 10: SHORTCUTS ==============
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
        proot-distro login "$DISTRO_ID" -- env USER_NAME="$UBUNTU_USER" \
            bash -s < "$tmp_script" >> "$ERROR_LOG" 2>&1
    ) &
    spinner $! "Creating Ubuntu desktop shortcuts..."
    local result=$?
    rm -f "$tmp_script"
    [ $result -ne 0 ] && FAILED_TASKS+=("desktop-shortcuts")
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
            for p in "${FAILED_PKGS_HOST[@]}"; do echo -e "    - $p"; done
        fi
        if [ ${#FAILED_PKGS_GUEST[@]} -gt 0 ]; then
            echo -e "${RED}[*] Ubuntu package failures:${NC}"
            for p in "${FAILED_PKGS_GUEST[@]}"; do echo -e "    - $p"; done
        fi
        if [ ${#FAILED_TASKS[@]} -gt 0 ]; then
            echo -e "${RED}[*] Task failures:${NC}"
            for p in "${FAILED_TASKS[@]}"; do echo -e "    - $p"; done
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
    echo -e "${WHITE}[*] GPU: ${GPU_NAME}${NC}"
    echo ""
    echo -e "${CYAN}[*] Commands:${NC}"
    echo -e "    Start desktop:        ${GREEN}./start-linux.sh${NC}"
    echo -e "    Software fallback:    ${GREEN}./start-linux-safe.sh${NC}"
    echo -e "    Ubuntu terminal only: ${GREEN}./start-ubuntu-cli.sh${NC}"
    echo -e "    Check GPU path:       ${GREEN}./gpu-check.sh${NC}"
    echo -e "    Swap Vulkan loader:   ${GREEN}./switch-vulkan.sh turnip|android${NC}"
    echo -e "    Update host + Ubuntu: ${GREEN}./update-ubuntu.sh${NC}"
    echo -e "    Stop desktop:         ${GREEN}./stop-linux.sh${NC}"
    echo ""
    echo -e "${YELLOW}[*] Termux:X11 APK must be the NIGHTLY build, matching termux-x11-nightly.${NC}"
    echo -e "${YELLOW}[*] Do not run this desktop and omarchy-android at the same time.${NC}"
    echo -e "${YELLOW}    Both want display :0. Run ./stop-linux.sh before switching.${NC}"
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
