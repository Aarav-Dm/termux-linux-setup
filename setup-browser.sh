#!/data/data/com.termux/files/usr/bin/bash
#######################################################
# setup-browser.sh
#
# Answers "what version is this and why won't the browser open",
# then installs a browser that actually works under PRoot.
#
# WHY THE BROWSER FAILS
#   Two independent causes, both structural:
#
#   1. On Ubuntu 22.04+, `apt install firefox` and
#      `apt install chromium-browser` install TRANSITIONAL packages that
#      just pull the snap. terminal-setup.sh deliberately blocks snapd,
#      because snap cannot work in PRoot at all. So the install appears
#      to succeed and you get a browser that cannot start.
#      Fix: real .deb builds from the mozillateam / xtradeb PPAs.
#
#   2. Chromium's sandbox is built on unprivileged user namespaces.
#      PRoot emulates syscalls with ptrace and cannot provide them, so
#      Chromium dies trying to spawn its child processes. That is the
#      "child process" error.
#      Fix: --no-sandbox, baked into the launcher and .desktop entry.
#
# SECURITY NOTE
#   A --no-sandbox browser has no process isolation between tabs. Fine
#   for docs, search and testing. Do not sign in to your bank, your
#   university account, or your email in it.
#
# Run:  chmod +x setup-browser.sh && ./setup-browser.sh
#######################################################

set -u

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

[ -f "$HOME/.config/termux-ubuntu.conf" ] && source "$HOME/.config/termux-ubuntu.conf"
DISTRO_ID="${DISTRO_ID:-ubuntu}"
UBUNTU_USER="${UBUNTU_USER:-droid}"

BROWSER="${1:-firefox}"

if ! proot-distro login "$DISTRO_ID" -- true >/dev/null 2>&1; then
    echo -e "${RED}[!] Container '$DISTRO_ID' not found.${NC}"
    exit 1
fi

# ---------- System report: answers "what version is this" ----------
echo ""
echo -e "${CYAN}=== System report ===${NC}"
proot-distro login "$DISTRO_ID" -- bash -lc '
echo -n "  Ubuntu:   "; (lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2- | tr -d \")
echo -n "  Codename: "; lsb_release -cs 2>/dev/null || echo unknown
echo -n "  Kernel:   "; uname -r
echo -n "  Arch:     "; dpkg --print-architecture
echo -n "  XFCE:     "; (xfce4-session --version 2>/dev/null | head -1) || echo "not detected"
echo -n "  Renderer: "; (glxinfo -B 2>/dev/null | grep -i "OpenGL renderer" | cut -d: -f2-) || echo "run inside the desktop"
' 2>/dev/null
echo -e "  ${YELLOW}Note:${NC} the kernel line is Android's. PRoot shares the host kernel;"
echo -e "        it is not the Ubuntu release and cannot be upgraded from here."
echo ""

# ---------- Browser install ----------
echo -e "${CYAN}=== Installing browser: ${BROWSER} ===${NC}"
echo ""

case "$BROWSER" in
firefox)
proot-distro login "$DISTRO_ID" -- env \
    DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC USER_NAME="$UBUNTU_USER" bash -lc '
set -u
# Drop the snap transitional package if it is sitting there.
apt-get remove -y firefox >/dev/null 2>&1 || true

apt-get install -y software-properties-common >/dev/null 2>&1
add-apt-repository -y ppa:mozillateam/ppa >/dev/null 2>&1

# Without this pin, apt keeps preferring the snap transitional package.
cat > /etc/apt/preferences.d/mozilla-firefox << "EOF"
Package: *
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001
EOF

# Stop unattended-upgrades quietly swapping it back to the snap.
cat > /etc/apt/apt.conf.d/51unattended-upgrades-firefox << "EOF"
Unattended-Upgrade::Allowed-Origins:: "LP-PPA-mozillateam:${distro_codename}";
EOF

apt-get update -y >/dev/null 2>&1
if apt-get install -y firefox >/dev/null 2>&1; then
    echo "  installed: $(firefox --version 2>/dev/null || echo firefox)"
else
    echo "  FAILED - see: apt-get install firefox"
    exit 1
fi

# Firefox has its own content sandbox that PRoot cannot satisfy either.
UH="/home/${USER_NAME}"
mkdir -p "${UH}/.local/bin" "${UH}/.local/share/applications"
cat > "${UH}/.local/bin/firefox-proot" << "EOF"
#!/bin/bash
export MOZ_DISABLE_CONTENT_SANDBOX=1
export MOZ_DISABLE_GMP_SANDBOX=1
export MOZ_DISABLE_RDD_SANDBOX=1
exec /usr/bin/firefox "$@"
EOF
chmod +x "${UH}/.local/bin/firefox-proot"

cat > "${UH}/.local/share/applications/firefox.desktop" << "EOF"
[Desktop Entry]
Name=Firefox
Exec=/home/USERPLACEHOLDER/.local/bin/firefox-proot %u
Icon=firefox
Type=Application
Categories=Network;WebBrowser;
EOF
sed -i "s|USERPLACEHOLDER|${USER_NAME}|" "${UH}/.local/share/applications/firefox.desktop"

id "${USER_NAME}" >/dev/null 2>&1 && chown -R "${USER_NAME}:${USER_NAME}" "${UH}/.local" 2>/dev/null || true
echo "  launcher: firefox-proot (sandbox disabled for PRoot)"
'
;;

chromium)
proot-distro login "$DISTRO_ID" -- env \
    DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC USER_NAME="$UBUNTU_USER" bash -lc '
set -u
apt-get remove -y chromium-browser >/dev/null 2>&1 || true
apt-get install -y software-properties-common >/dev/null 2>&1

# xtradeb ships a real chromium .deb; Ubuntu ships only a snap shim.
add-apt-repository -y ppa:xtradeb/apps >/dev/null 2>&1
apt-get update -y >/dev/null 2>&1

if apt-get install -y chromium >/dev/null 2>&1; then
    echo "  installed: chromium"
else
    echo "  FAILED - the xtradeb PPA may not cover this Ubuntu release."
    echo "  Try firefox instead: ./setup-browser.sh firefox"
    exit 1
fi

UH="/home/${USER_NAME}"
mkdir -p "${UH}/.local/bin" "${UH}/.local/share/applications"
# --no-sandbox is mandatory: PRoot cannot provide user namespaces.
cat > "${UH}/.local/bin/chromium-proot" << "EOF"
#!/bin/bash
exec /usr/bin/chromium --no-sandbox --disable-gpu-sandbox \
    --disable-dev-shm-usage --test-type "$@"
EOF
chmod +x "${UH}/.local/bin/chromium-proot"

cat > "${UH}/.local/share/applications/chromium.desktop" << "EOF"
[Desktop Entry]
Name=Chromium
Exec=/home/USERPLACEHOLDER/.local/bin/chromium-proot %U
Icon=chromium
Type=Application
Categories=Network;WebBrowser;
EOF
sed -i "s|USERPLACEHOLDER|${USER_NAME}|" "${UH}/.local/share/applications/chromium.desktop"

id "${USER_NAME}" >/dev/null 2>&1 && chown -R "${USER_NAME}:${USER_NAME}" "${UH}/.local" 2>/dev/null || true
echo "  launcher: chromium-proot (--no-sandbox, required under PRoot)"
'
;;

*)
    echo -e "${RED}[!] Unknown browser: ${BROWSER}${NC}"
    echo "Usage: $0 firefox|chromium"
    exit 1
;;
esac

echo ""
echo -e "${GREEN}=== Done ===${NC}"
echo ""
echo -e "  Launch from the XFCE menu, or in the desktop terminal:"
echo -e "    ${WHITE}${BROWSER}-proot${NC}"
echo ""
echo -e "  ${YELLOW}Do not sign in to banking, university or email accounts${NC}"
echo -e "  in this browser. Its sandbox is off because PRoot cannot"
echo -e "  provide the kernel namespaces it needs. Use Android Chrome"
echo -e "  for anything you log in to."
echo ""
