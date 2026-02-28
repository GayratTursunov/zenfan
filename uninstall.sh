#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Zenfan uninstall script
# Removes all installed components, optionally preserving config
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

APPLET_DIR="$HOME/.local/share/cinnamon/applets/zenfan@ux31e"

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

info() { echo -e "${GREEN}[-]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
confirm() { read -r -p "$* [y/N] " ans; [[ "$ans" =~ ^[Yy]$ ]]; }

if [[ "$EUID" -eq 0 ]]; then
    echo "Do not run as root. Run as your normal user: bash uninstall.sh"
    exit 1
fi

echo ""
warn "This will remove all Zenfan components."
confirm "Proceed?" || { echo "Aborted."; exit 0; }

# Stop and disable service
info "Stopping zenfan service..."
sudo systemctl stop zenfan.service    2>/dev/null || true
sudo systemctl disable zenfan.service 2>/dev/null || true
sudo rm -f /lib/systemd/system/zenfan.service
sudo systemctl daemon-reload

# Restore auto fan control before removing binaries
info "Restoring BIOS auto fan control..."
for pwm_enable in /sys/class/hwmon/*/pwm1_enable; do
    echo 2 | sudo tee "$pwm_enable" > /dev/null 2>&1 || true
done

# Remove binaries
info "Removing binaries..."
for f in zenfan zenfan-night zenfan-night-effective zenfan-write-conf zenfan-config-gui zenbook-fan.sh; do
    sudo rm -f "/usr/local/bin/$f"
done

# Remove sudoers rule
info "Removing sudoers rule..."
sudo rm -f /etc/sudoers.d/zenfan

# Remove polkit policy
info "Removing polkit policy..."
sudo rm -f /usr/share/polkit-1/actions/org.zenfan.policy
sudo systemctl reload polkit

# Remove applet
info "Removing Cinnamon applet..."
rm -rf "$APPLET_DIR"

# Optionally remove config
echo ""
if confirm "Remove /etc/zenfan.conf (your settings will be lost)?"; then
    sudo rm -f /etc/zenfan.conf
    info "Config removed"
else
    warn "Config preserved at /etc/zenfan.conf"
fi

echo ""
info "Zenfan uninstalled. Fan control returned to BIOS."
