# Omarchy Game Mode

This repository contains the canonical scripts to install and remove the Omarchy bidirectional Game Mode, which provides a seamless SteamOS-like experience on desktop Linux using Hyprland and Gamescope.

## Setup

1. **Install Dependencies:**
   Ensure you have the following installed on your system:
   `gamescope`, `steam`, `sddm`, and `sxhkd`.

2. **Install Game Mode:**
   Run the installation script with `sudo`:
   ```bash
   sudo ./install-gamemode.sh
   ```
   *This script sets up the systemd user units, polkit rules, the gamescope session entry, boot-loop protections, and hotkeys for media controls.*

3. **Configure Keybindings:**
   In your Hyprland configuration (e.g., `~/.config/hypr/bindings.lua`), map a key to switch to Game Mode. For example:
   ```lua
   o.bind("SUPER + ALT + G", "Enter Game Mode", "omarchy-launch-floating-terminal-with-presentation /usr/lib/steamos/steamos-session-select-interactive")
   ```

4. **Usage:**
   - Press the assigned shortcut to switch to Game Mode. This gracefully terminates your desktop session and auto-logs into Gamescope + Steam Big Picture.
   - From within Steam, select **Power** > **Switch to Desktop** to return to your Omarchy/Hyprland session.

## Removal

To completely remove the Game Mode setup, run:
```bash
sudo ./remove-gamemode.sh
```
