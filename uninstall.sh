#!/bin/bash
# uninstall.sh — reverts to the stock kernel as default and removes what install.sh added.
#   --purge-kernel   also apt-remove the 7.0.11-mbp packages
#   --keep-boot-gpu  leave rEFInd spoof and gpu-power-prefs (Intel boot) in place (recommended)
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
PURGE=0; KEEP_BOOT=0
for a in "$@"; do case "$a" in --purge-kernel) PURGE=1 ;; --keep-boot-gpu) KEEP_BOOT=1 ;; esac; done
ESP=/boot/efi; KVER=7.0.11-mbp
LC="$ESP/loader/loader.conf"
[ -f "$LC" ] && sed -i 's/^default .*/default Pop_OS-current/' "$LC"
rm -f "$ESP"/loader/entries/Pop_OS-mbp.conf "$ESP"/EFI/Pop_OS-*/vmlinuz-mbp.efi "$ESP"/EFI/Pop_OS-*/initrd-mbp.img "$ESP"/EFI/Pop_OS-*/refind_linux.conf
systemctl disable --now reclocked.service 2>/dev/null || true
rm -f /etc/systemd/system/reclocked.service /usr/local/bin/reclocked /usr/local/bin/reclockctl /etc/reclocked.conf
systemctl disable dgpu-off.service 2>/dev/null || true
rm -f /etc/systemd/system/dgpu-off.service; rm -rf /etc/systemd/system/dgpu-off.service.d
sed -i '/^COSMIC_RENDER_DEVICE=/d; /^WGPU_POWER_PREF=/d' /etc/environment
systemctl daemon-reload
if [ "$PURGE" = 1 ]; then apt-get remove -y -q "linux-image-$KVER" "linux-headers-$KVER" >/dev/null || true; fi
if [ "$KEEP_BOOT" = 0 ]; then
  [ -x /usr/local/bin/gpu-switch ] && /usr/local/bin/gpu-switch -d >/dev/null && echo "boot GPU back to NVIDIA (gpu-power-prefs)"
  echo "rEFInd left installed; to stop using it: sudo efibootmgr -o <Pop entry number>,…  (see: efibootmgr)"
fi
echo "Reverted. Reboot. The stock kernel is the default again; the dGPU will stay powered (no dgpu-off service)."
