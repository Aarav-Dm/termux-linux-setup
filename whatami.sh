#!/data/data/com.termux/files/usr/bin/bash
# Reports what is ACTUALLY installed. No guessing.
set -u
[ -f "$HOME/.config/termux-ubuntu.conf" ] && source "$HOME/.config/termux-ubuntu.conf"
DISTRO_ID="${DISTRO_ID:-ubuntu}"
echo ""
echo "=== Host (Termux) ==="
echo -n "  proot-distro: "; proot-distro --version 2>/dev/null | head -1 || echo unknown
echo -n "  Android:      "; getprop ro.build.version.release 2>/dev/null
echo -n "  Device:       "; getprop ro.product.model 2>/dev/null
echo ""
echo "=== Guest container: $DISTRO_ID ==="
proot-distro login "$DISTRO_ID" -- bash -lc '
echo -n "  Ubuntu:   "; (lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2- | tr -d \")
echo -n "  Codename: "; lsb_release -cs 2>/dev/null || echo unknown
echo -n "  Released: "; grep -o "[0-9]\{2\}\.[0-9]\{2\}" /etc/os-release | head -1
echo -n "  Arch:     "; dpkg --print-architecture
echo -n "  Firefox:  "; (dpkg -l firefox 2>/dev/null | awk "/^ii/{print \$3}") || echo "not installed"
' 2>/dev/null
echo ""
echo "  Note: uname shows Android's kernel. PRoot shares the host kernel;"
echo "        that number is not your Ubuntu release."
echo ""
