#!/data/data/com.termux/files/usr/bin/bash
#######################################################
#  Termux Linux Setup Script
#  Custom build for: Samsung Galaxy Tab S8 Ultra
#                     (Snapdragon 8 Gen 1 / Adreno 730,
#                      12GB RAM, 256GB storage)
#
#  Features:
#  - XFCE4 Desktop only (lean, no DE menu)
#  - Turnip/Freedreno GPU acceleration (Adreno)
#  - Automatic shared-storage integration
#  - Python, Git, Neovim/Vim, SSH & network tools,
#    build tools pre-installed
#  - Robust startup/stop scripts with real health checks
#  - Error logging instead of silent failures
#######################################################

set -u
TOTAL_STEPS=9
CURRENT_STEP=0
ERROR_LOG="$HOME/linux-setup-errors.log"
: > "$ERROR_LOG"

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

# Installs a package, logs real errors instead of hiding them, and does not
# treat a failed package as fatal to the whole run (so one bad mirror hit
# doesn't kill an hour of progress). Failures are collected and reported
# at the end.
FAILED_PKGS=()
install_pkg() {
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
        FAILED_PKGS+=("$pkg")
    fi
    return $result
}

# ============== PRE-FLIGHT CHECKS ==============
check_requirements() {
    echo -e "${PURPLE}[*] Running pre-flight checks...${NC}"
    echo ""

    # Confirm we're actually in Termux
    if [ ! -d "/data/data/com.termux/files/usr" ]; then
        echo -e "${RED}[!] This script must be run inside Termux. Aborting.${NC}"
        exit 1
    fi

    # Internet check
    if ! timeout 8 curl -s --head https://packages.termux.dev >/dev/null 2>&1; then
        echo -e "${RED}[!] No internet connection detected.${NC}"
        echo -e "${YELLOW}    Check your Wi-Fi/data connection and try again.${NC}"
        exit 1
    fi
    echo -e "  [+] Internet connection: ${GREEN}OK${NC}"

    # Free space check (want at least ~4GB free for a full XFCE + toolchain install)
    local avail_kb
    avail_kb=$(df "$HOME" | awk 'NR==2 {print $4}')
    local avail_gb=$((avail_kb / 1024 / 1024))
    if [ "$avail_gb" -lt 4 ]; then
        echo -e "${RED}[!] Low storage: only ${avail_gb}GB free.${NC}"
        echo -e "${YELLOW}    Recommend at least 4GB free before continuing.${NC}"
        read -p "Continue anyway? (y/N): " CONT
        [[ "$CONT" =~ ^[Yy]$ ]] || exit 1
    else
        echo -e "  [+] Free storage: ${GREEN}${avail_gb}GB${NC} (OK)"
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
                                               
       Termux Linux Setup - Tab S8 Ultra       
                                               
    -------------------------------------------
BANNER
    echo -e "${NC}"
    echo -e "${WHITE}  Desktop: XFCE4  |  GPU: Adreno 730 (Turnip)  |  RAM: 12GB${NC}"
    echo ""
}

# ============== STEP 1: UPDATE SYSTEM ==============
step_update() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Updating system packages...${NC}"
    echo ""
    (DEBIAN_FRONTEND=noninteractive apt-get update -y >> "$ERROR_LOG" 2>&1) &
    spinner $! "Updating package lists..."
    (DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q -o Dpkg::Options::="--force-confold" >> "$ERROR_LOG" 2>&1) &
    spinner $! "Upgrading installed packages..."
}

# ============== STEP 2: REPOSITORIES + TERMUX-X11 ==============
step_x11() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Adding repos & installing Termux-X11...${NC}"
    echo ""
    install_pkg "x11-repo" "X11 Repository"
    install_pkg "termux-x11-nightly" "Termux-X11 Display Server"
    install_pkg "xorg-xrandr" "XRandR (Display Settings)"
}

# ============== STEP 3: INSTALL XFCE4 DESKTOP ==============
step_desktop() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing XFCE4 Desktop...${NC}"
    echo ""
    install_pkg "xfce4" "XFCE4 Desktop"
    install_pkg "xfce4-terminal" "XFCE4 Terminal"
    install_pkg "xfce4-whiskermenu-plugin" "Whisker Menu"
    install_pkg "thunar" "Thunar File Manager"
    install_pkg "thunar-volman" "Thunar Volume Manager (removable/shared storage)"
    install_pkg "mousepad" "Mousepad Editor"
}

# ============== STEP 4: GPU ACCELERATION (Adreno 730 / Turnip) ==============
step_gpu() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing GPU Acceleration (Adreno/Turnip)...${NC}"
    echo ""
    install_pkg "mesa-zink" "Mesa Zink Core"
    install_pkg "mesa-vulkan-icd-freedreno" "Turnip Adreno Vulkan Driver"
    install_pkg "vulkan-loader-android" "Vulkan Loader"
}

# ============== STEP 5: AUDIO ==============
step_audio() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Audio (PulseAudio)...${NC}"
    echo ""
    install_pkg "pulseaudio" "PulseAudio Server"
}

# ============== STEP 6: DEV / SYSADMIN TOOLING ==============
step_devtools() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Installing Dev, SSH & Network Tools...${NC}"
    echo ""

    # Core dev
    install_pkg "python" "Python 3"
    install_pkg "python-pip" "Pip"
    install_pkg "git" "Git Version Control"
    install_pkg "neovim" "Neovim"
    install_pkg "vim" "Vim"

    # Build tools
    install_pkg "build-essential" "Build Essential (gcc/make/etc.)"
    install_pkg "clang" "Clang"
    install_pkg "cmake" "CMake"
    install_pkg "pkg-config" "pkg-config"

    # SSH tools
    install_pkg "openssh" "OpenSSH (client + server)"

    # Network tools
    install_pkg "net-tools" "Net-tools (ifconfig/netstat)"
    install_pkg "iproute2" "iproute2 (ip/ss)"
    install_pkg "nmap" "Nmap"
    install_pkg "curl" "cURL"
    install_pkg "wget" "Wget"
    install_pkg "rsync" "Rsync"
}

# ============== STEP 7: AUTOMATIC STORAGE INTEGRATION ==============
step_storage() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Setting up shared storage integration...${NC}"
    echo ""

    if [ ! -d "$HOME/storage" ]; then
        echo -e "  [*] Requesting storage permission (an Android permission popup may appear)..."
        termux-setup-storage
        # termux-setup-storage is async from the user's tap; give it a moment
        for i in {1..10}; do
            [ -d "$HOME/storage/shared" ] && break
            sleep 1
        done
    fi

    if [ -d "$HOME/storage/shared" ]; then
        ln -sfn "$HOME/storage/shared" "$HOME/Storage"
        echo -e "  [+] ${GREEN}Storage linked${NC}: ~/Storage -> shared device storage"
        echo -e "  [+] Also available: ~/storage/dcim, ~/storage/downloads, ~/storage/pictures, etc."
    else
        echo -e "  [-] ${YELLOW}Storage permission was not granted (or timed out).${NC}"
        echo -e "      Run 'termux-setup-storage' manually later, then re-run:"
        echo -e "      ln -sfn ~/storage/shared ~/Storage"
    fi
}

# ============== STEP 8: LAUNCHERS (start/stop) ==============
step_launchers() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Creating startup & stop scripts...${NC}"
    echo ""

    mkdir -p ~/.config

    # XDG env injection so XFCE finds Termux-installed apps/icons
    XDG_INJECT="export XDG_DATA_DIRS=/data/data/com.termux/files/usr/share:\${XDG_DATA_DIRS}\nexport XDG_CONFIG_DIRS=/data/data/com.termux/files/usr/etc/xdg:\${XDG_CONFIG_DIRS}"

    cat > ~/.config/linux-gpu.sh << EOF
export MESA_NO_ERROR=1
export MESA_GL_VERSION_OVERRIDE=4.6
export MESA_GLES_VERSION_OVERRIDE=3.2
export GALLIUM_DRIVER=zink
export MESA_LOADER_DRIVER_OVERRIDE=zink
export TU_DEBUG=noconform
export MESA_VK_WSI_PRESENT_MODE=immediate
export ZINK_DESCRIPTORS=lazy
$(echo -e "$XDG_INJECT")
EOF

    # ---- start-linux.sh : real checks instead of blind sleeps ----
    cat > ~/start-linux.sh << 'LAUNCHEREOF'
#!/data/data/com.termux/files/usr/bin/bash
set -u
NC='\033[0m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'

fail() {
    echo -e "${RED}[!] $1${NC}"
    exit 1
}

echo ""
echo -e "${CYAN}[*] Starting XFCE4 Desktop...${NC}"
echo ""

source ~/.config/linux-gpu.sh 2>/dev/null

# --- sanity checks ---
command -v startxfce4 >/dev/null 2>&1 || fail "XFCE4 is not installed. Re-run setup.sh."
command -v termux-x11 >/dev/null 2>&1 || fail "termux-x11 is not installed. Re-run setup.sh."
command -v pulseaudio >/dev/null 2>&1 || echo -e "${YELLOW}[!] PulseAudio not found - continuing without audio.${NC}"

echo "[*] Cleaning up old sessions..."
pkill -9 -f "termux.x11" 2>/dev/null
pkill -9 xfce4-session 2>/dev/null
pkill -9 -f "dbus" 2>/dev/null

# --- audio ---
if command -v pulseaudio >/dev/null 2>&1; then
    unset PULSE_SERVER
    pulseaudio --kill 2>/dev/null
    sleep 0.5
    echo "[*] Starting audio server..."
    if pulseaudio --start --exit-idle-time=-1 2>/tmp/pulse-err.log; then
        pactl load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 2>/dev/null
        export PULSE_SERVER=127.0.0.1
        echo -e "  [+] ${GREEN}Audio server running${NC}"
    else
        echo -e "  [-] ${YELLOW}Audio failed to start (see /tmp/pulse-err.log). Continuing without sound.${NC}"
    fi
fi

# --- X11 ---
echo "[*] Starting X11 server..."
termux-x11 :0 -ac &
X11_PID=$!

# wait (up to 10s) for the X socket to actually appear instead of a blind sleep
for i in $(seq 1 20); do
    if [ -e "/data/data/com.termux/files/usr/tmp/.X11-unix/X0" ]; then
        break
    fi
    sleep 0.5
done

if ! kill -0 $X11_PID 2>/dev/null; then
    fail "termux-x11 failed to start. Make sure the Termux-X11 app is installed and open."
fi

export DISPLAY=:0

echo -e "${CYAN}-----------------------------------------------${NC}"
echo -e "  ${GREEN}[*] Open the Termux-X11 app to view the desktop!${NC}"
echo -e "${CYAN}-----------------------------------------------${NC}"
echo ""
echo "[*] Launching XFCE4..."
exec startxfce4
LAUNCHEREOF
    chmod +x ~/start-linux.sh
    echo -e "  [+] Created ~/start-linux.sh"

    # ---- stop-linux.sh ----
    cat > ~/stop-linux.sh << 'STOPEOF'
#!/data/data/com.termux/files/usr/bin/bash
echo "Stopping XFCE4 desktop..."
pkill -9 -f "termux.x11" 2>/dev/null
pkill -9 -f "pulseaudio" 2>/dev/null
pkill -9 xfce4-session 2>/dev/null
pkill -9 -f "dbus" 2>/dev/null
echo "Desktop stopped."
STOPEOF
    chmod +x ~/stop-linux.sh
    echo -e "  [+] Created ~/stop-linux.sh"

    # Offer automatic launch on every Termux session (optional, since "automatic" was requested)
    echo ""
    read -p "Auto-launch the desktop every time you open Termux? (y/N): " AUTOSTART
    if [[ "$AUTOSTART" =~ ^[Yy]$ ]]; then
        if ! grep -q "start-linux.sh" ~/.bashrc 2>/dev/null; then
            echo -e '\n# Auto-start XFCE4 desktop\nif [ -z "$LINUX_STARTED" ]; then\n    export LINUX_STARTED=1\n    ~/start-linux.sh\nfi' >> ~/.bashrc
            echo -e "  [+] ${GREEN}Auto-start enabled${NC} (added to ~/.bashrc)"
        fi
    else
        echo -e "  [*] Skipped. Start manually anytime with: ${GREEN}./start-linux.sh${NC}"
    fi
}

# ============== SHORTCUTS ==============
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

    chmod +x ~/Desktop/*.desktop 2>/dev/null
    echo -e "  [+] Added Terminal and Files shortcuts."
}

# ============== COMPLETION ==============
show_completion() {
    echo ""
    if [ ${#FAILED_PKGS[@]} -gt 0 ]; then
        echo -e "${YELLOW}"
        cat << 'PARTIAL'
    ---------------------------------------------------------------
             [!]  INSTALL FINISHED WITH SOME FAILURES  [!]
    ---------------------------------------------------------------
PARTIAL
        echo -e "${NC}"
        echo -e "${RED}[*] The following packages failed to install:${NC}"
        for p in "${FAILED_PKGS[@]}"; do
            echo -e "    - $p"
        done
        echo -e "${YELLOW}[*] Details logged in: ${ERROR_LOG}${NC}"
        echo -e "${YELLOW}[*] Try: apt-get update && apt-get install <package name>${NC}"
    else
        echo -e "${GREEN}"
        cat << 'COMPLETE'
    ---------------------------------------------------------------
             [*]  INSTALLATION COMPLETE!  [*]
    ---------------------------------------------------------------
COMPLETE
        echo -e "${NC}"
    fi

    echo -e "${WHITE}[*] Your XFCE4 environment is ready.${NC}"
    echo -e "${CYAN}[*] Installed:${NC}"
    echo "    - XFCE4 Desktop + Termux-X11"
    echo "    - Turnip GPU acceleration (Adreno 730)"
    echo "    - PulseAudio"
    echo "    - Python, Git, Neovim/Vim"
    echo "    - Build tools (gcc/clang/cmake/make)"
    echo "    - SSH (openssh) & network tools (nmap/net-tools/iproute2)"
    echo "    - Shared storage linked at ~/Storage"
    echo ""
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    echo -e "${WHITE}[*] TO START THE DESKTOP:${NC}  ${GREEN}./start-linux.sh${NC}"
    echo -e "${WHITE}[*] TO STOP THE DESKTOP:${NC}   ${GREEN}./stop-linux.sh${NC}"
    echo -e "${WHITE}[*] SHARED STORAGE:${NC}        ${GREEN}~/Storage${NC}"
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    echo ""
}

# ============== MAIN ==============
main() {
    show_banner
    check_requirements

    step_update
    step_x11
    step_desktop
    step_gpu
    step_audio
    step_devtools
    step_storage
    step_launchers
    step_shortcuts

    show_completion
}

main
