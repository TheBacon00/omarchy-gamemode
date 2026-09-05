pkgname=omarchy-gamemode
pkgver=1.0.0
pkgrel=1
pkgdesc="SteamOS-like bidirectional Game Mode switcher with Gamescope and Moonlight HDR support"
arch=('any')
url="https://github.com/TODO/omarchy-gamemode"
license=('GPL')
depends=('gamescope' 'steam' 'sddm' 'polkit')
source=()
install='omarchy-gamemode.install'

package() {
    cd "$srcdir"

    # Core SteamOS helper scripts
    install -Dm755 src/gamescope-session "$pkgdir/usr/lib/steamos/gamescope-session"
    install -Dm755 src/steam-launcher "$pkgdir/usr/lib/steamos/steam-launcher"
    install -Dm755 src/steam-set-session "$pkgdir/usr/lib/steamos/steam-set-session"
    install -Dm755 src/steam-short-session-tracker "$pkgdir/usr/lib/steamos/steam-short-session-tracker"
    
    # User-facing commands
    install -Dm755 src/steamos-session-select "$pkgdir/usr/bin/steamos-session-select"
    # Provide the standard start-gamescope-session target
    mkdir -p "$pkgdir/usr/bin"
    ln -s /usr/lib/steamos/gamescope-session "$pkgdir/usr/bin/start-gamescope-session"

    # Polkit policy for passwordless session switching
    install -Dm644 src/org.omarchy.set.session.policy "$pkgdir/usr/share/polkit-1/actions/org.omarchy.set.session.policy"

    # Configuration file (default resolution/refresh)
    install -Dm644 src/omarchy-gamemode.conf "$pkgdir/etc/omarchy-gamemode.conf"

    # SDDM Wayland session
    install -Dm644 src/gamescope-session.desktop "$pkgdir/usr/share/wayland-sessions/gamescope-session.desktop"

    # Systemd User Units
    install -Dm644 src/gamescope-session.service "$pkgdir/usr/lib/systemd/user/gamescope-session.service"
    install -Dm644 src/gamescope-session.target "$pkgdir/usr/lib/systemd/user/gamescope-session.target"
    install -Dm644 src/steam-launcher.service "$pkgdir/usr/lib/systemd/user/steam-launcher.service"
    
    # Override moonlight desktop file globally for Game Mode optimizations
    install -Dm644 src/moonlight-gamemode.desktop "$pkgdir/usr/share/applications/moonlight-gamemode.desktop"
}
