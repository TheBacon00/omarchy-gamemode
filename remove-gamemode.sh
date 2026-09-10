#!/bin/bash
# Remove SDDM session
rm -f /usr/share/wayland-sessions/gamescope-session.desktop
# Remove binaries
rm -f /usr/bin/start-gamescope-session
rm -f /usr/bin/steamos-session-select
# Remove steamos libs
rm -rf /usr/lib/steamos
# Remove systemd user units
rm -f /usr/lib/systemd/user/gamescope-session.service
rm -f /usr/lib/systemd/user/gamescope-session.target
rm -f /usr/lib/systemd/user/steam-launcher.service
rm -f /usr/lib/systemd/user/gamescope-sxhkd.service
# Remove polkit
rm -f /usr/share/polkit-1/actions/org.omarchy.set.session.policy
# Reset SDDM autologin
rm -f /etc/sddm.conf.d/zz-steamos-autologin.conf
echo "[Autologin]" > /etc/sddm.conf.d/autologin.conf
echo "User=garet" >> /etc/sddm.conf.d/autologin.conf
echo "Session=omarchy.desktop" >> /etc/sddm.conf.d/autologin.conf
chown garet /etc/sddm.conf.d/autologin.conf
chmod 664 /etc/sddm.conf.d/autologin.conf
# Reload systemd
su - garet -c 'systemctl --user daemon-reload' 2>/dev/null || true

# Remove the UI Widget from the Omarchy Shell
if [ -f /home/garet/.config/omarchy/shell.json ]; then
    jq 'del(.plugins[]? | select(.id == "user.gamemode")) | del(.bar.layout.right[]? | select(.id == "user.gamemode")) | del(.bar.layout.left[]? | select(.id == "user.gamemode")) | del(.bar.layout.center[]? | select(.id == "user.gamemode"))' /home/garet/.config/omarchy/shell.json > /tmp/shell.json
    cat /tmp/shell.json > /home/garet/.config/omarchy/shell.json
    rm -f /tmp/shell.json
    chown garet:garet /home/garet/.config/omarchy/shell.json
fi

# Remove the plugin directory
rm -rf /home/garet/.config/omarchy/plugins/user.gamemode
su - garet -c "omarchy restart shell >/dev/null 2>&1 &"
