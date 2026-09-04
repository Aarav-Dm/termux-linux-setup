#!/data/data/com.termux/files/usr/bin/bash
#######################################################
# polish-desktop.sh
#
# The desktop works. This silences the startup noise that is actually
# fixable and leaves the rest alone, because the rest cannot be fixed.
#
# FIXES (3):
#   1. light-locker  - removed. It needs logind, which does not exist in
#                      proot. Worse than noise: it can throw up a lock
#                      screen you cannot dismiss, because there is no
#                      session to authenticate against.
#   2. wallpaper     - xfdesktop looks for xubuntu-wallpaper.png, which
#                      only ships with xubuntu-desktop. We install the
#                      lean xfce4 set, so it is absent. Points xfdesktop
#                      at a plain colour instead.
#   3. xfwm4 compositing - disabled. termux-x11 already composites, so
#                      running a second compositor causes the
#                      "Another compositing manager is running" warning
#                      plus tearing and wasted GPU work.
#
# NOT FIXED, and not fixable in proot. These are permanent and harmless:
#   - "Failed to get a systemd proxy"        no systemd, by design
#   - "Failed to connect to colord"          needs the system dbus
#   - "Error getting authority" (polkit)     needs the system dbus
#   - "Failed to get system bus"             needs the system dbus
#   - "GVFS-RemoteVolumeMonitor not supported"  needs udisks2
#   - "_IceTransmkdir: euid != 0"            cosmetic, ICE still works
#   - "Failed to fetch _NET_CURRENT_DESKTOP" startup race, resolves itself
#   - "pm-is-supported not found"            suspend/resume, meaningless here
#
# Run:  chmod +x polish-desktop.sh && ./polish-desktop.sh
#######################################################

set -u

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
WHITE='\033[1;37m'; RED='\033[0;31m'; NC='\033[0m'

[ -f "$HOME/.config/termux-ubuntu.conf" ] && source "$HOME/.config/termux-ubuntu.conf"
DISTRO_ID="${DISTRO_ID:-ubuntu}"
UBUNTU_USER="${UBUNTU_USER:-droid}"

echo ""
echo -e "${CYAN}=== Desktop polish ===${NC}"
echo ""

if ! proot-distro login "$DISTRO_ID" -- true >/dev/null 2>&1; then
    echo -e "${RED}[!] Container '$DISTRO_ID' not found.${NC}"
    exit 1
fi

proot-distro login "$DISTRO_ID" -- env \
    DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC USER_NAME="$UBUNTU_USER" bash -lc '
set -u
UH="/home/${USER_NAME}"

# --- 1. light-locker: remove it ---------------------------------------
if dpkg -l light-locker 2>/dev/null | grep -q "^ii"; then
    apt-get remove -y light-locker >/dev/null 2>&1 && echo "  [+] light-locker removed"
else
    echo "  [=] light-locker not installed"
fi
# Belt and braces: stop it autostarting even if reinstalled as a dep.
mkdir -p "${UH}/.config/autostart"
for app in light-locker xfce4-power-manager xscreensaver; do
    cat > "${UH}/.config/autostart/${app}.desktop" << EOF
[Desktop Entry]
Type=Application
Name=${app}
Hidden=true
X-GNOME-Autostart-enabled=false
EOF
done
echo "  [+] screen locker + power manager autostart disabled"

# --- 2. wallpaper: install real ones, then point xfdesktop at one -----
# The black background and the "xubuntu-wallpaper.png: No such file"
# error are the same bug. That file ships in xubuntu-wallpapers, which
# the lean xfce4 install does not pull in. It is a data-only package,
# so installing it does NOT drag in xubuntu-desktop.
apt-get install -y xubuntu-wallpapers >/dev/null 2>&1 \
    || apt-get install -y ubuntu-wallpapers >/dev/null 2>&1 \
    || apt-get install -y xfdesktop4-data >/dev/null 2>&1 || true

# Pick the first wallpaper that actually exists on disk.
WP=""
for cand in \
    /usr/share/xfce4/backdrops/xubuntu-wallpaper.png \
    /usr/share/backgrounds/xfce/xfce-shapes.svg \
    /usr/share/backgrounds/xfce/xfce-verticals.png \
    /usr/share/xfce4/backdrops/*.png \
    /usr/share/xfce4/backdrops/*.jpg \
    /usr/share/backgrounds/*.png \
    /usr/share/backgrounds/*.jpg ; do
    [ -f "$cand" ] && WP="$cand" && break
done

mkdir -p "${UH}/.config/xfce4/xfconf/xfce-perchannel-xml"

if [ -n "$WP" ]; then
    # image-style 5 = zoomed, correct for a 2960x1848 panel.
    cat > "${UH}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitorscreen" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="${WP}"/>
        </property>
      </property>
      <property name="monitorTermuxX11" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="${WP}"/>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF
    echo "  [+] wallpaper set: ${WP}"
else
    # No image anywhere: solid colour beats a broken-file error.
    cat > "${UH}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" << "EOF"
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitorscreen" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="0"/>
          <property name="rgba1" type="array">
            <value type="double" value="0.12"/>
            <value type="double" value="0.14"/>
            <value type="double" value="0.18"/>
            <value type="double" value="1.0"/>
          </property>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF
    echo "  [-] no wallpaper image found, using solid colour"
fi

# --- 3. xfwm4 compositing: off, termux-x11 already composites ---------
cat > "${UH}/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" << "EOF"
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
    <property name="sync_to_vblank" type="bool" value="false"/>
  </property>
</channel>
EOF
echo "  [+] xfwm4 compositing disabled"

# --- Ownership -------------------------------------------------------
if id "${USER_NAME}" >/dev/null 2>&1; then
    chown -R "${USER_NAME}:${USER_NAME}" "${UH}/.config" 2>/dev/null || true
fi
'

echo ""
echo -e "${GREEN}=== Done ===${NC}"
echo ""
echo -e "  Restart the desktop:  ${WHITE}./stop-linux.sh && ./start-linux.sh${NC}"
echo ""
echo -e "  ${YELLOW}Still expect these, and ignore them.${NC} They need systemd,"
echo -e "  logind, or a system dbus, none of which exist in proot:"
echo -e "    systemd proxy · colord · polkit · system bus · GVFS volume monitor"
echo ""
