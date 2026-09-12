#!/bin/bash
#
# Game Mode Toggle Installer for Omarchy
# ========================================
# Based on the CachyOS/SteamOS gamescope-session architecture.
#
# This sets up Super + Alt + G to switch between Omarchy (Hyprland) and
# gamescope + Steam Big Picture Mode. Within Steam, "Switch to Desktop"
# (or "Exit to Desktop") returns to Hyprland.
#
# Run as root (sudo ./install-gamemode-final.sh)
#
# Safety: includes boot-loop protection. If gamescope crashes 3 times
# within 60 seconds, the system automatically reverts to Omarchy desktop.
#
set -euo pipefail

GAME_USER="garet"
DESKTOP_SESSION_FILE="omarchy.desktop"
GAMESCOPE_SESSION_FILE="gamescope-session.desktop"

echo "=== Game Mode Toggle Installer ==="
echo ""

# ─── 1. Validate prerequisites ──────────────────────────────────────────────

for cmd in gamescope steam loginctl sddm sxhkd; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' not found. Install it first."
        exit 1
    fi
done

# Verify SDDM is the display manager
DM_UNIT="$(systemctl show -p Id --value display-manager.service 2>/dev/null || true)"
if [[ "${DM_UNIT%.service}" != "sddm" ]]; then
    echo "ERROR: This script requires SDDM as the display manager."
    echo "       Detected: ${DM_UNIT:-none}"
    exit 1
fi

# Verify the desktop session file exists
DESKTOP_SESSION_FOUND=0
for dir in /usr/share/wayland-sessions /usr/local/share/wayland-sessions; do
    if [[ -f "$dir/$DESKTOP_SESSION_FILE" ]]; then
        DESKTOP_SESSION_FOUND=1
        break
    fi
done
if [[ "$DESKTOP_SESSION_FOUND" -eq 0 ]]; then
    echo "ERROR: Desktop session '$DESKTOP_SESSION_FILE' not found."
    echo "       Available sessions:"
    ls /usr/share/wayland-sessions/ /usr/local/share/wayland-sessions/ 2>/dev/null
    exit 1
fi

# ─── 2. Detect display resolution ───────────────────────────────────────────

# Try to get the current resolution from the running Hyprland session
SCREEN_WIDTH=3440
SCREEN_HEIGHT=1440
if command -v hyprctl &>/dev/null; then
    DETECTED=$(su - "$GAME_USER" -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u); hyprctl monitors -j 2>/dev/null' | python3 -c "
import sys, json
try:
    monitors = json.load(sys.stdin)
    if monitors:
        m = monitors[0]
        print(f\"{m['width']}x{m['height']}\")
except:
    pass
" 2>/dev/null || true)
    if [[ -n "$DETECTED" ]]; then
        SCREEN_WIDTH="${DETECTED%%x*}"
        SCREEN_HEIGHT="${DETECTED##*x}"
    fi
fi
echo "Display resolution: ${SCREEN_WIDTH}x${SCREEN_HEIGHT}"

# ─── 3. Create the privileged session-switching helper ───────────────────────
# This is the root helper that writes the SDDM autologin config.
# Modeled on CachyOS's steam-set-session.

echo "Installing steam-set-session helper..."
mkdir -p /usr/lib/steamos
cat > /usr/lib/steamos/steam-set-session << 'SETEOF'
#!/bin/bash
set -e

# Detect display manager config path
DISPLAY_MANAGER="$(systemctl show -p Id --value display-manager.service 2>/dev/null || true)"
case "${DISPLAY_MANAGER%.service}" in
    sddm) CONF_FILE="/etc/sddm.conf.d/zz-steamos-autologin.conf";;
    *)    echo "Unsupported display manager: $DISPLAY_MANAGER" >&2; exit 1;;
esac

# Session to switch to (default: gamescope)
SESSION="${1:-gamescope-session.desktop}"

mkdir -p "$(dirname "$CONF_FILE")"

cat <<EOF > "$CONF_FILE"
[Autologin]
User=garet
Session=$SESSION
Relogin=true
EOF

echo "Set next session to: $SESSION"
SETEOF
chmod 755 /usr/lib/steamos/steam-set-session

# ─── 4. Create polkit policy for passwordless session switching ──────────────

echo "Installing polkit policy..."
mkdir -p /usr/share/polkit-1/actions
cat > /usr/share/polkit-1/actions/org.omarchy.set.session.policy << 'POLKIT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
 "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>

  <vendor>Omarchy Game Mode</vendor>
  <vendor_url>https://omarchy.org</vendor_url>

  <action id="org.omarchy.policykit.steamos.pkexec.run-session-select">
    <description>Switch between desktop and gamescope sessions</description>
    <icon_name>input-gaming</icon_name>
    <defaults>
      <allow_any>yes</allow_any>
      <allow_inactive>yes</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/lib/steamos/steam-set-session</annotate>
  </action>

</policyconfig>
POLKIT

# ─── 5. Create steamos-session-select (the bidirectional switch) ─────────────
# This is called by:
#   - The Hyprland keybinding (Super+Alt+G → "steamos-session-select gamescope")
#   - Steam's "Switch to Desktop" button (calls "steamos-session-select plasma")
#
# Based on CachyOS's steamos-session-select.

echo "Installing steamos-session-select..."
cat > /usr/bin/steamos-session-select << 'SELECTEOF'
#!/bin/bash
set -e

DESKTOP_SESSION="omarchy.desktop"
GAMESCOPE_SESSION="gamescope-session.desktop"
GAME_USER="garet"

case "$1" in
    plasma|desktop)
        # Switch TO desktop (called by Steam's "Switch to Desktop")
        echo "Switching to desktop session..."

        # 1. Set SDDM to auto-login to the desktop session next time
        pkexec /usr/lib/steamos/steam-set-session "$DESKTOP_SESSION"

        # 2. Gracefully shut down Steam (it's running inside gamescope)
        steam -shutdown 2>/dev/null || true

        # 3. Stop the gamescope session target
        # This will cause start-gamescope-session to exit cleanly (exit 0)
        # SDDM will then auto-login to the new desktop session.
        systemctl --user stop gamescope-session.target 2>/dev/null || true
        ;;

    gamescope|gamemode)
        # Switch TO gamescope (called by keybinding in Hyprland)
        echo "Switching to Game Mode..."

        # 1. Set SDDM to auto-login to gamescope session next time
        pkexec /usr/lib/steamos/steam-set-session "$GAMESCOPE_SESSION"

        # 2. Gracefully terminate the current Hyprland/uwsm session.
        # This allows sddm-helper to exit cleanly (exit 0).
        if command -v uwsm &>/dev/null; then
            uwsm stop 2>/dev/null || true
        fi
        if command -v hyprctl &>/dev/null; then
            hyprctl dispatch exit 2>/dev/null || true
        fi
        ;;

    *)
        if [[ -n "$1" ]]; then
            echo "Unknown session: '$1'"
            echo ""
        fi
        cat <<USAGE
Usage: $(basename "$0") <mode>

Modes:
  gamescope    Switch to Game Mode (gamescope + Steam Big Picture)
  desktop      Switch to Desktop (Omarchy/Hyprland)
  plasma       Alias for 'desktop' (Steam compatibility)

Examples:
  $(basename "$0") gamescope    # Enter Game Mode
  $(basename "$0") desktop      # Return to Desktop
USAGE
        exit 1
        ;;
esac
SELECTEOF
chmod 755 /usr/bin/steamos-session-select

# ─── 6. Create the short-session tracker (boot loop protection) ──────────────
# If gamescope/Steam crashes repeatedly (3 times in <60s each), automatically
# revert to the desktop session.

echo "Installing boot loop protection..."
mkdir -p /usr/lib/steamos
cat > /usr/lib/steamos/steam-short-session-tracker << 'TRACKEREOF'
#!/bin/bash

SHORT_SESSION_FILE="/tmp/steamos-short-session-tracker"
SHORT_SESSION_START="/tmp/steamos-short-session-start"
SHORT_SESSION_DURATION=60
SHORT_SESSION_MAX_FAILURES=3
DESKTOP_SESSION="omarchy.desktop"

do_recover() {
    echo >&2 "steam-short-session-tracker: Too many short sessions! Reverting to desktop."

    # Force desktop session for next login
    if [[ -w /etc/sddm.conf.d/zz-steamos-autologin.conf ]] || [[ $EUID -eq 0 ]]; then
        cat > /etc/sddm.conf.d/zz-steamos-autologin.conf <<EOF
[Autologin]
User=garet
Session=$DESKTOP_SESSION
Relogin=true
EOF
    else
        pkexec /usr/lib/steamos/steam-set-session "$DESKTOP_SESSION" || true
    fi

    # Rearm the tracker
    rm -f "$SHORT_SESSION_FILE"
}

handle_started() {
    local count=0
    if [[ -f "$SHORT_SESSION_FILE" ]]; then
        count=$(wc -l < "$SHORT_SESSION_FILE")
    fi
    date +%s > "$SHORT_SESSION_START"

    if [[ "$count" -ge "$SHORT_SESSION_MAX_FAILURES" ]]; then
        echo >&2 "steam-short-session-tracker: Detected $count consecutive short sessions (threshold: $SHORT_SESSION_MAX_FAILURES)"
        do_recover
        exit 1
    fi
}

handle_stopped() {
    if [[ ! -f "$SHORT_SESSION_START" ]]; then
        return
    fi

    local start_time
    start_time=$(cat "$SHORT_SESSION_START")
    local now
    now=$(date +%s)
    local elapsed=$(( now - start_time ))

    if [[ "$elapsed" -lt "$SHORT_SESSION_DURATION" ]]; then
        echo "short" >> "$SHORT_SESSION_FILE"
        echo >&2 "steam-short-session-tracker: Short session detected (${elapsed}s < ${SHORT_SESSION_DURATION}s threshold)"
    else
        # Session lasted long enough — clear the tracker
        rm -f "$SHORT_SESSION_FILE"
    fi
}

case "$1" in
    --track-started)  handle_started ;;
    --track-stopped)  handle_stopped ;;
    --recover-now)    do_recover ;;
    *)
        echo "Usage: $0 --track-started | --track-stopped | --recover-now"
        exit 1
        ;;
esac
TRACKEREOF
chmod 755 /usr/lib/steamos/steam-short-session-tracker

# ─── 7. Create the gamescope session entry point ─────────────────────────────
# This is what SDDM executes. It manages systemd targets for clean lifecycle.
# Based on CachyOS's start-gamescope-session.

echo "Installing gamescope session entry point..."
cat > /usr/bin/start-gamescope-session << 'STARTEOF'
#!/bin/bash

# Clean up any leftover state from a previous session
systemctl --user stop gamescope-session.target 2>/dev/null || true
systemctl --user stop graphical-session-pre.target 2>/dev/null || true
systemctl --user reset-failed 2>/dev/null || true

# Export session environment to systemd and dbus
dbus-update-activation-environment --systemd DESKTOP_SESSION $(env | grep 
XDG_ | cut -d = -f 1) 2>/dev/null || true

# Prevent irrelevant desktop portals from starting
systemctl --user set-environment XDG_DESKTOP_PORTAL_DIR="" 2>/dev/null || true

# Remove DISPLAY/XAUTHORITY from user env — gamescope will set these
systemctl --user unset-environment DISPLAY XAUTHORITY 2>/dev/null || true

# If this script is killed, bring down the gamescope session cleanly
trap 'systemctl --user stop gamescope-session.target 2>/dev/null || true' HUP INT TERM

# Start and wait for gamescope-session target
systemctl --user --wait start gamescope-session.target &
wait

logger "Gamescope Session Ended - Performing Final Cleanup"

# Wait for all dependent targets to stop
systemctl --user stop graphical-session-pre.target 2>/dev/null || true

# Restore portal discovery
systemctl --user unset-environment XDG_DESKTOP_PORTAL_DIR 2>/dev/null || true

logger "Gamescope Session Ended - Cleanup Complete"
STARTEOF
chmod 755 /usr/bin/start-gamescope-session

# ─── 8. Create the gamescope launcher script ─────────────────────────────────
# This is the actual script that launches gamescope with all the right flags.
# It handles socket-based startup coordination and environment export.


echo "Compiling Gamescope X11 spoof for VRR visibility..."
cat > /usr/lib/steamos/gamescope-x11-spoof.c << 'SPOOFEOF'
#include <X11/Xlib.h>
#include <dlfcn.h>
#include <string.h>

static Atom external_atom = 0;

Atom XInternAtom(Display *display, const char *atom_name, Bool only_if_exists) {
    static Atom (*real_XInternAtom)(Display *, const char *, Bool) = NULL;
    if (!real_XInternAtom) {
        real_XInternAtom = (Atom (*)(Display *, const char *, Bool))dlsym(RTLD_NEXT, "XInternAtom");
    }
    
    Atom a = real_XInternAtom(display, atom_name, only_if_exists);
    if (atom_name && strcmp(atom_name, "GAMESCOPE_DISPLAY_IS_EXTERNAL") == 0) {
        external_atom = a;
    }
    return a;
}

int XChangeProperty(Display *display, Window w, Atom property, Atom type,
                    int format, int mode, const unsigned char *data, int nelements)
{
    static int (*real_XChangeProperty)(Display *, Window, Atom, Atom, int, int, const unsigned char *, int) = NULL;
    if (!real_XChangeProperty) {
        real_XChangeProperty = (int (*)(Display *, Window, Atom, Atom, int, int, const unsigned char *, int))dlsym(RTLD_NEXT, "XChangeProperty");
    }

    if (external_atom != 0 && property == external_atom) {
        unsigned char zero = 0;
        return real_XChangeProperty(display, w, property, type, format, mode, &zero, 1);
    }

    return real_XChangeProperty(display, w, property, type, format, mode, data, nelements);
}
SPOOFEOF
gcc -shared -fPIC /usr/lib/steamos/gamescope-x11-spoof.c -o /usr/lib/steamos/gamescope-x11-spoof.so -ldl -lX11

echo "Installing gamescope session script..."
cat > /usr/lib/steamos/gamescope-session << GSEOF
#!/bin/bash

# --- Runtime socket setup ---
tmpdir="\$([[ -n \${XDG_RUNTIME_DIR+x} ]] && mktemp -p "\$XDG_RUNTIME_DIR" -d -t gamescope.XXXXXXX)"
socket="\${tmpdir:+\$tmpdir/startup.socket}"
stats="\${tmpdir:+\$tmpdir/stats.pipe}"

if [[ -z \$tmpdir || -z \${XDG_RUNTIME_DIR+x} ]]; then
    echo >&2 "!! XDG_RUNTIME_DIR not set, cannot create gamescope sockets"
    exit 1
fi

# --- Environment variables ---
export SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0
export STEAM_MULTIPLE_XWAYLANDS=1
export STEAM_GAMESCOPE_NIS_SUPPORTED=1
export STEAM_GAMESCOPE_HDR_SUPPORTED=1
export STEAM_GAMESCOPE_HAS_TEARING_SUPPORT=1
export STEAM_GAMESCOPE_TEARING_SUPPORTED=1
export STEAM_GAMESCOPE_VRR_SUPPORTED=1

export STEAM_DISPLAY_REFRESH_LIMITS=48,165
export ENABLE_GAMESCOPE_WSI=1
export vk_xwayland_wait_ready=false
export GAMESCOPE_NV12_COLORSPACE=k_EStreamColorspace_BT601
export VKD3D_SWAPCHAIN_LATENCY_FRAMES=3
export QT_QPA_PLATFORM=xcb

# MangoHud
export MANGOHUD_CONFIGFILE="\${tmpdir:+\$tmpdir/mangohud.config}"
mkdir -p "\$(dirname "\$MANGOHUD_CONFIGFILE")"
echo "no_display" > "\$MANGOHUD_CONFIGFILE"

# Gamescope mode/EDID save files
export GAMESCOPE_MODE_SAVE_FILE="\${XDG_CONFIG_HOME:-\$HOME/.config}/gamescope/modes.cfg"
export GAMESCOPE_PATCHED_EDID_FILE="\${XDG_CONFIG_HOME:-\$HOME/.config}/gamescope/edid.bin"
mkdir -p "\$(dirname "\$GAMESCOPE_MODE_SAVE_FILE")"
touch "\$GAMESCOPE_MODE_SAVE_FILE"
mkdir -p "\$(dirname "\$GAMESCOPE_PATCHED_EDID_FILE")"
touch "\$GAMESCOPE_PATCHED_EDID_FILE"

# VRS config
export RADV_FORCE_VRS_CONFIG_FILE="\$(mktemp /tmp/radv_vrs.XXXXXXXX)"
echo "1x1" > "\$RADV_FORCE_VRS_CONFIG_FILE"

# Limiter
export GAMESCOPE_LIMITER_FILE="\$(mktemp /tmp/gamescope-limiter.XXXXXXXX)"

# Intel VRR / Crash fixes
export INTEL_DEBUG=norbc
ulimit -n 524288

# --- Stats/socket setup ---
export GAMESCOPE_STATS="\$stats"
mkfifo -- "\$stats"
mkfifo -- "\$socket"

# Claim global session link
linkname="gamescope-stats"
sessionlink="\${XDG_RUNTIME_DIR:+\$XDG_RUNTIME_DIR/}\${linkname}"
lockfile="\$sessionlink".lck
exec 9>"\$lockfile"
if flock -n 9 && rm -f "\$sessionlink" && ln -sf "\$tmpdir" "\$sessionlink"; then
    echo >&2 "Claimed global gamescope stats session"
else
    echo >&2 "!! Failed to claim global gamescope stats session"
fi

# --- Read gamescope environment when it starts ---
read_gamescope_env() {
    if read -r -t 5 response_x_display response_wl_display <> "\$socket"; then
        export DISPLAY="\$response_x_display"
        export GAMESCOPE_WAYLAND_DISPLAY="\$response_wl_display"
        # Export environment so steam-launcher.service can pick it up
        env > "\$XDG_RUNTIME_DIR/gamescope-environment"
        systemd-notify --ready
    else
        echo >&2 "!! gamescope failed to start within 5 seconds"
        systemd-notify --ready  # notify anyway so systemd doesn't hang
    fi
}

# Spawn the env reader in parallel
(read_gamescope_env &)


# --- Launch gamescope ---
# HDR options (only if supported)
HDR_OPTIONS=""
if gamescope --help 2>&1 | grep -q -- "--hdr-enabled"; then
    HDR_OPTIONS="--hdr-enabled"
fi

LD_PRELOAD="/usr/lib/steamos/gamescope-x11-spoof.so" exec gamescope \
    -W ${SCREEN_WIDTH} -H ${SCREEN_HEIGHT} \
    -w ${SCREEN_WIDTH} -h ${SCREEN_HEIGHT} \
    -f \
    --generate-drm-mode fixed \
    --adaptive-sync \
    --xwayland-count 2 \
    -e -R "\$socket" -T "\$stats" \
    --steam
GSEOF
chmod 755 /usr/lib/steamos/gamescope-session

# ─── 9. Create the Steam launcher script ────────────────────────────────────

echo "Installing Steam launcher..."
cat > /usr/lib/steamos/steam-launcher << 'STEAMEOF'
#!/bin/bash
exec steam -steamos3 -gamepadui -steampal
STEAMEOF
chmod 755 /usr/lib/steamos/steam-launcher

# ─── 10. Create systemd user units ──────────────────────────────────────────

echo "Installing systemd user units..."
mkdir -p /usr/lib/systemd/user

# gamescope-session.service — the gamescope compositor
cat > /usr/lib/systemd/user/gamescope-session.service << 'UNITEOF'
[Unit]
Description=Gamescope Session
Before=graphical-session.target
PartOf=graphical-session.target
Wants=graphical-session-pre.target
After=graphical-session-pre.target
RefuseManualStart=yes
Before=xdg-desktop-portal.service

[Service]
TimeoutStartSec=10
TimeoutStopSec=15
ExecStart=/usr/lib/steamos/gamescope-session
ExecStopPost=/usr/bin/bash -c '/usr/bin/rm -rf "$XDG_RUNTIME_DIR"/gamescope{.,-}* /tmp/gamescope-limiter*'
Type=notify
NotifyAccess=all
Environment="SRT_LOG_TO_JOURNAL=1" "XDG_SESSION_TYPE=x11"
UnsetEnvironment=DISPLAY XAUTHORITY
Slice=session.slice
UNITEOF

# gamescope-session.target — orchestrates all gamescope services
cat > /usr/lib/systemd/user/gamescope-session.target << 'UNITEOF'
[Unit]
Description=Gamescope Session Target
Requires=graphical-session.target
BindsTo=graphical-session.target
After=graphical-session.target
PropagatesStopTo=graphical-session.target

Requires=gamescope-session.service
BindsTo=gamescope-session.service

Upholds=steam-launcher.service
Upholds=gamescope-sxhkd.service
UNITEOF

# steam-launcher.service — Steam Big Picture
cat > /usr/lib/systemd/user/steam-launcher.service << 'UNITEOF'
[Unit]
Description=Steam Launcher (Game Mode)
After=graphical-session.target
PartOf=graphical-session.target
After=xdg-desktop-portal.service

[Service]
ExecStart=/usr/lib/steamos/steam-launcher

# Boot loop protection
ExecStartPre=/usr/lib/steamos/steam-short-session-tracker --track-started
ExecStopPost=/usr/lib/steamos/steam-short-session-tracker --track-stopped

# Steam doesn't forward signals — kill its child process
ExecStop=/bin/bash -c 'kill -TERM $(pgrep -P $MAINPID || echo $MAINPID)'
KillSignal=SIGCONT
KillMode=mixed
TimeoutStopSec=60
Type=exec
EnvironmentFile=%t/gamescope-environment
UNITEOF

# gamescope-sxhkd.service — sxhkd daemon for media keys
cat > /usr/lib/systemd/user/gamescope-sxhkd.service << 'UNITEOF'
[Unit]
Description=sxhkd daemon for Gamescope session media keys
PartOf=gamescope-session.target
After=gamescope-session.target

[Service]
ExecStart=/usr/bin/sxhkd -c /usr/lib/steamos/sxhkdrc
Restart=always
EnvironmentFile=%t/gamescope-environment
UNITEOF

echo "Installing sxhkd config for media keys..."
cat > /usr/lib/steamos/sxhkdrc << 'SXHKDEOF'
XF86AudioRaiseVolume
    omarchy-audio-output-volume raise

XF86AudioLowerVolume
    omarchy-audio-output-volume lower

XF86AudioMute
    omarchy-audio-output-volume mute-toggle

XF86AudioMicMute
    omarchy-audio-input-mute

XF86MonBrightnessUp
    omarchy-brightness-display +5%

XF86MonBrightnessDown
    omarchy-brightness-display 5%-
SXHKDEOF

# ─── 11. Create the gamescope session .desktop file for SDDM ────────────────

echo "Installing gamescope session desktop file..."
cat > /usr/share/wayland-sessions/gamescope-session.desktop << 'DESKTOPEOF'
[Desktop Entry]
Encoding=UTF-8
Name=Steam Game Mode
Comment=Steam Big Picture in Gamescope
Exec=start-gamescope-session
Icon=steamicon.png
Type=Application
DesktopNames=gamescope
DESKTOPEOF

# Remove the old session file if it exists
rm -f /usr/share/wayland-sessions/steam-gamescope.desktop

# Remove old gamescope-session from previous install attempts
rm -f /usr/local/bin/gamescope-session

# ─── 12. Set up SDDM autologin to default to desktop ────────────────────────

echo "Configuring SDDM autologin (defaulting to desktop)..."
mkdir -p /etc/sddm.conf.d

# Remove the old autologin.conf to avoid conflicts
# (our zz-steamos-autologin.conf replaces it)
if [[ -f /etc/sddm.conf.d/autologin.conf ]]; then
    echo "  Removing old autologin.conf (replaced by zz-steamos-autologin.conf)"
    rm -f /etc/sddm.conf.d/autologin.conf
fi

cat > /etc/sddm.conf.d/zz-steamos-autologin.conf << EOF
[Autologin]
User=${GAME_USER}
Session=${DESKTOP_SESSION_FILE}
Relogin=true
EOF

# ─── 13. Reload systemd to pick up new units ────────────────────────────────

echo "Reloading systemd user daemon..."
su - "$GAME_USER" -c 'systemctl --user daemon-reload' 2>/dev/null || true

# ─── 14. Summary ────────────────────────────────────────────────────────────

echo ""
echo "=== Installation Complete ==="
echo ""
echo "What was installed:"
echo "  • /usr/share/wayland-sessions/gamescope-session.desktop  (SDDM session entry)"
echo "  • /usr/bin/start-gamescope-session                       (Session entry point)"
echo "  • /usr/bin/steamos-session-select                        (Bidirectional switch)"
echo "  • /usr/lib/steamos/gamescope-session                     (Gamescope launcher)"
echo "  • /usr/lib/steamos/steam-launcher                        (Steam launcher)"
echo "  • /usr/lib/steamos/steam-set-session                     (Root session helper)"
echo "  • /usr/lib/steamos/steam-short-session-tracker           (Boot loop protection)"
echo "  • /usr/lib/systemd/user/gamescope-session.{service,target}"
echo "  • /usr/lib/systemd/user/steam-launcher.service"
echo "  • /usr/lib/systemd/user/gamescope-sxhkd.service"
echo "  • /usr/share/polkit-1/actions/org.omarchy.set.session.policy"
echo ""
echo "Keybinding:"
echo "  The existing binding in ~/.config/hypr/bindings.lua should be:"
echo "    o.bind(\"SUPER + ALT + G\", \"Enter Game Mode\", \"omarchy-launch-floating-terminal-with-presentation /usr/lib/steamos/steamos-session-select-interactive\")"
echo ""
echo "How it works:"
echo "  1. Super+Alt+G → omarchy-launch-floating-terminal-with-presentation /usr/lib/steamos/steamos-session-select-interactive"
echo "     → sets SDDM to auto-login to gamescope → terminates Hyprland session"
echo "     → SDDM auto-logs in → gamescope + Steam Big Picture"
echo ""
echo "  2. Steam → 'Switch to Desktop' → steamos-session-select plasma"
echo "     → sets SDDM to auto-login to desktop → shuts down Steam"
echo "     → stops gamescope target → SDDM auto-logs in → Hyprland"
echo ""
echo "Boot loop protection:"
echo "  If gamescope crashes 3× within 60s, auto-reverts to desktop."
echo ""
echo "NOTE: You also need to update the Hyprland keybinding."
echo "      The 'launch' wrapper may interfere — use a direct exec instead."

# --- 15. Inject UI Toggle Widget ---
echo "Injecting UI Toggle Widget into Omarchy Shell..."

cat << 'INT_EOF' > /usr/lib/steamos/steamos-session-select-interactive
#!/bin/bash
if gum confirm 'Switch to Game Mode? This will close all desktop applications.'; then
    /usr/bin/steamos-session-select gamemode
fi
INT_EOF
chmod +x /usr/lib/steamos/steamos-session-select-interactive

su - garet -c "mkdir -p ~/.config/omarchy/plugins/user.gamemode"
cat << 'QML_EOF' > /home/garet/.config/omarchy/plugins/user.gamemode/manifest.json
{
  "schemaVersion": 1,
  "id": "user.gamemode",
  "name": "Game Mode",
  "version": "1.0.0",
  "author": "Garet",
  "description": "Toggle Steam Game Mode",
  "kinds": ["bar-widget"],
  "entryPoints": { "barWidget": "GameMode.qml" },
  "barWidget": {
    "displayName": "Game Mode",
    "category": "System",
    "allowMultiple": false
  }
}
QML_EOF
cat << 'QML_EOF' > /home/garet/.config/omarchy/plugins/user.gamemode/GameMode.qml
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "user.gamemode"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰊴"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: "Enter Game Mode"
    onPressed: function() {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation /usr/lib/steamos/steamos-session-select-interactive")
    }
  }
}
QML_EOF
chown -R garet:garet /home/garet/.config/omarchy/plugins/user.gamemode
su - garet -c "jq '.plugins += [{\"id\": \"user.gamemode\"}] | .bar.layout.right = [{\"id\": \"user.gamemode\"}] + .bar.layout.right' ~/.config/omarchy/shell.json > /tmp/shell.json && mv /tmp/shell.json ~/.config/omarchy/shell.json"
su - garet -c "omarchy restart shell >/dev/null 2>&1 &"
