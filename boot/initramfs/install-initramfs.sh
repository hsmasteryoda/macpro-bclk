#!/bin/bash
# Install the initramfs pre-mount BCLK apply (the fully-clean method). Run as root on the host.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
D=$(cd "$(dirname "$0")" && pwd)
[ -r /etc/default/macpro-bclk ] || printf 'TARGET=104\n' > /etc/default/macpro-bclk
install -m 0755 "$D/hook-macpro-bclk"     /etc/initramfs-tools/hooks/macpro-bclk
install -m 0755 "$D/premount-macpro-bclk" /etc/initramfs-tools/scripts/init-premount/macpro-bclk
update-initramfs -u
echo "installed. Verify: lsinitramfs /boot/initrd.img-\$(uname -r) | grep -E 'i2cset|i2c_i801|macpro'"
echo "escape hatch if a boot ever hangs: add 'bclk=off' to the kernel cmdline at the GRUB edit screen."
