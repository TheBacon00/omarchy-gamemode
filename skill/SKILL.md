---
name: omarchy-gamemode
description: Knowledge and troubleshooting for the Omarchy bidirectional Game Mode and Moonlight HDR setup.
---

# Omarchy Game Mode

This skill teaches you how the Omarchy bidirectional Game Mode session switcher operates.

## Architecture
- **Canonical Setup:** The entire configuration is installed globally via `./install-gamemode.sh` and completely uninstalled via `./remove-gamemode.sh`.
- **SDDM Integration:** The system uses `steamos-session-select` to dynamically write to `/etc/sddm.conf.d/zz-steamos-autologin.conf`. This triggers SDDM to automatically log into the desired session (`gamescope` or `plasma`/`hyprland`) after terminating the current one.
- **Root Helper:** `steam-set-session` does the actual SDDM file writing. It is permitted via Polkit (`org.omarchy.set.session.policy`) so the user isn't prompted for a password.
- **Gamescope Session:** Handled by systemd user units (`gamescope-session.target`, `steam-launcher.service`, `gamescope-sxhkd.service`). Gamescope runs outside of standard window managers (DRM mode).

## Resolution & Refresh Rate Config
Gamescope defaults to 1080p@60. To use an ultrawide/high-refresh setup, edit `/etc/omarchy-gamemode.conf` or `~/.config/omarchy-gamemode.conf`:
```bash
GAME_WIDTH=3440
GAME_HEIGHT=1440
GAME_REFRESH=144
```

## Moonlight HDR Setup
To get Moonlight streaming HDR flawlessly inside Gamescope, it must run via X11 to utilize the Vulkan Gamescope WSI layer. 

**Steam Launch Options:**
```text
QT_QPA_PLATFORM=xcb SDL_VIDEO_DRIVER=x11 SDL_VIDEODRIVER=x11 PREFER_VULKAN=1 ENABLE_HDR_WSI=1 vblank_mode=0 __GL_SYNC_TO_VBLANK=0 %command%
```
*(Ensure Moonlight is using the Native package, not Flatpak, so it can access the host WSI layers).*
