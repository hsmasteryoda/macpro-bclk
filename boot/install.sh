#!/bin/bash
# install.sh - install the Mac Pro BCLK boot-persistence service on the Proxmox/Linux host (run as root).
# Applies the overclock at EARLY boot (before pve-guests), stepping 1 MHz at a time, crash-loop guarded.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
D=$(cd "$(dirname "$0")" && pwd)
install -m 0755 "$D/macpro-bclk-apply.sh" /usr/local/sbin/macpro-bclk-apply.sh
install -m 0644 "$D/macpro-bclk.service"  /etc/systemd/system/macpro-bclk.service
[ -e /etc/default/macpro-bclk ] || install -m 0644 "$D/macpro-bclk.default" /etc/default/macpro-bclk
mkdir -p /var/lib/macpro-bclk
echo ready > /var/lib/macpro-bclk/last-attempt
touch /var/lib/macpro-bclk/enabled
systemctl daemon-reload
systemctl enable macpro-bclk.service
echo "installed + enabled. Target: $(grep -E '^TARGET=' /etc/default/macpro-bclk). Applies on next boot."
echo "disable:  rm /var/lib/macpro-bclk/enabled   (or: systemctl disable macpro-bclk.service)"
echo "re-arm after a skipped boot:  echo ready > /var/lib/macpro-bclk/last-attempt"
