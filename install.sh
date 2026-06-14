#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Zenfan install script v1.3
# Installs all components for ASUS Zenbook UX31e on LMDE 7 / Cinnamon
# Run as a normal user with sudo privileges: bash install.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin"
APPLET_DIR="$HOME/.local/share/cinnamon/applets/zenfan@ux31e"
CONF_DIR="/etc"
POLKIT_DIR="/usr/share/polkit-1/actions"
SUDOERS_DIR="/etc/sudoers.d"
SYSTEMD_DIR="/lib/systemd/system"
VERSION="1.3"

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

info()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
confirm() { read -r -p "$* [y/N] " ans; [[ "$ans" =~ ^[Yy]$ ]]; }

# ── Preflight checks ──────────────────────────────────────────────────────────

echo ""
echo "  Zenfan v${VERSION} — Adaptive fan control for ASUS Zenbook UX31e"
echo "  ─────────────────────────────────────────────────────────────────"
echo ""

if [[ "$EUID" -eq 0 ]]; then
    error "Do not run as root. Run as your normal user: bash install.sh"
fi

if ! sudo -v; then
    error "sudo access required"
fi

# Check Python3 + GTK for config GUI
if ! python3 -c "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk" 2>/dev/null; then
    warn "Python3 GTK bindings not found — config GUI will not work"
    warn "Install with: sudo apt install python3-gi gir1.2-gtk-3.0"
fi

# Detect hwmon paths
TEMP_PATH=$(find /sys/class/hwmon/*/temp1_input 2>/dev/null | head -1)
PWM_PATH=$(find /sys/class/hwmon/*/pwm1 2>/dev/null | head -1)
RPM_PATH=$(find /sys/class/hwmon/*/fan1_input 2>/dev/null | head -1)

if [[ -z "$TEMP_PATH" || -z "$PWM_PATH" ]]; then
    warn "Could not auto-detect hwmon paths."
    warn "You may need to edit /usr/local/bin/zenbook-fan.sh and applet/applet.js manually."
else
    HWMON_TEMP=$(dirname "$TEMP_PATH" | xargs basename)
    HWMON_PWM=$(dirname "$PWM_PATH" | xargs basename)
    if [[ "$HWMON_TEMP" != "hwmon2" || "$HWMON_PWM" != "hwmon4" ]]; then
        warn "Detected hwmon paths differ from defaults:"
        warn "  TEMP: $TEMP_PATH  (default: hwmon2)"
        warn "  PWM:  $PWM_PATH  (default: hwmon4)"
        [[ -n "$RPM_PATH" ]] && warn "  RPM:  $RPM_PATH"
        warn "Update SYS paths in bin/zenbook-fan.sh and applet/applet.js before installing."
        confirm "Continue anyway?" || exit 0
    fi
fi

info "This will install:"
echo "   • Binaries       → $BIN_DIR"
echo "   • Config         → $CONF_DIR/zenfan.conf"
echo "   • sudoers rule   → $SUDOERS_DIR/zenfan"
echo "   • polkit policy  → $POLKIT_DIR/org.zenfan.policy"
echo "   • systemd unit   → $SYSTEMD_DIR/zenfan.service"
echo "   • Cinnamon applet→ $APPLET_DIR"
echo ""

confirm "Proceed?" || { echo "Aborted."; exit 0; }

# ── Binaries ──────────────────────────────────────────────────────────────────

info "Installing binaries..."
for f in zenfan zenfan-night zenfan-night-effective zenfan-write-conf zenfan-config-gui zenbook-fan.sh; do
    sudo install -m 755 "$REPO_DIR/bin/$f" "$BIN_DIR/$f"
done
info "Binaries installed to $BIN_DIR"

# ── Config ────────────────────────────────────────────────────────────────────

if [[ -f "$CONF_DIR/zenfan.conf" ]]; then
    warn "$CONF_DIR/zenfan.conf already exists — skipping (preserving your settings)"
else
    sudo install -m 644 "$REPO_DIR/config/zenfan.conf" "$CONF_DIR/zenfan.conf"
    info "Config installed: $CONF_DIR/zenfan.conf"
fi

# ── sudoers ───────────────────────────────────────────────────────────────────

info "Installing sudoers rule..."
if sudo visudo -c -f "$REPO_DIR/config/zenfan-sudoers" 2>/dev/null; then
    sudo install -m 440 "$REPO_DIR/config/zenfan-sudoers" "$SUDOERS_DIR/zenfan"
    info "sudoers rule installed: $SUDOERS_DIR/zenfan"
else
    error "sudoers file failed validation — aborting"
fi

# ── polkit ────────────────────────────────────────────────────────────────────

info "Installing polkit policy..."
sudo install -m 644 "$REPO_DIR/config/org.zenfan.policy" "$POLKIT_DIR/org.zenfan.policy"
sudo systemctl reload polkit
info "polkit policy installed and reloaded"

# ── systemd ───────────────────────────────────────────────────────────────────

# Migrate legacy unit: versions before the rename installed the daemon as
# "zenbook-fan.service". Leaving it enabled would run a second copy of the daemon
# alongside zenfan.service, with both fighting over the same PWM channel.
# Detect with `systemctl cat` (no pipe): `list-unit-files | grep -q` is racy under
# `set -o pipefail` — grep closes the pipe on match and systemctl dies with SIGPIPE,
# so the pipeline can report failure even when the unit exists.
if systemctl cat zenbook-fan.service >/dev/null 2>&1; then
    warn "Found legacy zenbook-fan.service — migrating to zenfan.service"
    sudo systemctl disable --now zenbook-fan.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/zenbook-fan.service /lib/systemd/system/zenbook-fan.service
    sudo systemctl daemon-reload
fi

info "Installing systemd service..."
sudo install -m 644 "$REPO_DIR/systemd/zenfan.service" "$SYSTEMD_DIR/zenfan.service"
sudo systemctl daemon-reload
sudo systemctl enable zenfan.service
sudo systemctl restart zenfan.service
info "systemd service enabled and started"

# ── Cinnamon applet ───────────────────────────────────────────────────────────

info "Installing Cinnamon applet..."
mkdir -p "$APPLET_DIR"
install -m 644 "$REPO_DIR/applet/applet.js"       "$APPLET_DIR/applet.js"
install -m 644 "$REPO_DIR/applet/metadata.json"   "$APPLET_DIR/metadata.json"
info "Applet installed: $APPLET_DIR"

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
info "Zenfan v${VERSION} installed successfully!"
echo ""
echo "  Next steps:"
echo "  1. Add the applet to your Cinnamon panel:"
echo "     Right-click panel → Applets → search 'Zenfan' → Add"
echo "  2. Check service status:  systemctl status zenfan"
echo "  3. Check logs:            journalctl -u zenfan -f"
echo "  4. Switch profiles:       zenfan quiet|balanced|performance"
echo ""
