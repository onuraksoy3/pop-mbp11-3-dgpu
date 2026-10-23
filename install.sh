#!/bin/bash
# pop-mbp11-3-dgpu — macOS-style GPU switching for the 15" MacBook Pro (Late 2013 / Mid 2014,
# MacBookPro11,3: Intel Iris Pro + NVIDIA GT 750M) on Pop!_OS 24.04 with COSMIC.
#
#   curl -fsSL https://github.com/onuraksoy3/pop-mbp11-3-dgpu/raw/main/install.sh | sudo bash
#
# What it does, in phases (each is checked and safe to re-run):
#   1  rEFInd with the macOS spoof (Apple's EFI powers the iGPU only for "macOS"), gpu-switch -i (Intel
#      becomes the firmware boot GPU), rEFInd first in the boot order.
#   2  COSMIC rendering on Intel (env vars), switcheroo-control, and dgpu-off.service for the stock kernel.
#   3  The patched kernel 7.0.11-mbp (vanilla 7.0.11 + reclocked's gmux/nouveau power-cycle patches) from the
#      GitHub release, a separate boot entry with nouveau.runpm=1, rEFInd fallback to the stock kernel.
#   4  reclocked (pstate governor + fans) built from source, tuned config, service gated to the -mbp kernel.
#      --max-0f adds the 0f boost tier (Apple's factory memory clock) on top of the 07/0a/0e ladder.
#
# Flags:  --max-0f      let reclocked use pstate 0f (Apple's factory memory clock; small lock-up risk)
#         --no-kernel   skip phase 3 and 4 (Intel-only setup, dGPU off at boot)
#         --kernel-dir D  use .deb files from directory D instead of downloading
#
# Undo: uninstall.sh. Verify after reboot: verify.sh.
set -euo pipefail

REPO="onuraksoy3/pop-mbp11-3-dgpu"
RELEASE_TAG="kernel-7.0.11-mbp"
KVER="7.0.11-mbp"
RECLOCKED_REPO="https://github.com/IgorChicherin/reclocked.git"
RECLOCKED_BRANCH="patch/linux-6.18.54-kernel"
GPU_SWITCH_REPO="https://github.com/0xbb/gpu-switch"

MAX_0F=0; NO_KERNEL=0; KERNEL_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --max-0f) MAX_0F=1 ;;
    --no-kernel) NO_KERNEL=1 ;;
    --kernel-dir) KERNEL_DIR="$2"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
ESP=/boot/efi
WORK=$(mktemp -d /tmp/mbp-dgpu.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------------ 0. guards
PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
case "$PRODUCT" in
  MacBookPro11,3) ;;
  *) die "this is for MacBookPro11,3 only (found: '${PRODUCT:-unknown}')" ;;
esac
. /etc/os-release
[ "${ID:-}" = pop ] && [ "${VERSION_ID:-}" = 24.04 ] || die "this is for Pop!_OS 24.04 (found: ${PRETTY_NAME:-unknown})"
lspci -nn | grep -q '10de:0fe9\|GT 750M' || die "no GeForce GT 750M found"
mountpoint -q "$ESP" || die "$ESP is not mounted"
ROOT_UUID=$(findmnt -no UUID /)
POP_DIR=$(ls -d "$ESP"/EFI/Pop_OS-* 2>/dev/null | head -1)
[ -n "$POP_DIR" ] || die "no Pop_OS-* directory on the ESP (is this a systemd-boot Pop install?)"
POP_REL=${POP_DIR#"$ESP"}
log "MacBookPro11,3 · Pop!_OS 24.04 · root UUID $ROOT_UUID · ESP dir $POP_REL"

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q refind efibootmgr git curl switcheroo-control mesa-utils build-essential libglib2.0-bin >/dev/null

# ------------------------------------------------------- 1. boot GPU: rEFInd + gpu-switch
log "Phase 1: rEFInd with macOS spoof, Intel as boot GPU"
if [ ! -f "$ESP/EFI/refind/refind_x64.efi" ]; then
  refind-install --yes >/dev/null || die "refind-install failed"
fi
CONF="$ESP/EFI/refind/refind.conf"
if grep -q '^spoof_osx_version' "$CONF"; then
  sed -i 's/^spoof_osx_version.*/spoof_osx_version 10.9/' "$CONF"
elif grep -q '^#spoof_osx_version' "$CONF"; then
  sed -i 's/^#spoof_osx_version.*/spoof_osx_version 10.9/' "$CONF"
else
  echo 'spoof_osx_version 10.9' >> "$CONF"
fi
REFIND_NUM=$(efibootmgr | awk '/rEFInd/ {sub("Boot","",$1); sub("\\*","",$1); print $1; exit}')
if [ -n "$REFIND_NUM" ]; then
  ORDER=$(efibootmgr | awk -F': ' '/BootOrder/ {print $2}')
  NEW="$REFIND_NUM,$(echo "$ORDER" | tr ',' '\n' | grep -v "^$REFIND_NUM$" | paste -sd, -)"
  efibootmgr -o "${NEW%,}" >/dev/null
  log "rEFInd is boot entry $REFIND_NUM, first in order"
else
  warn "could not find a rEFInd boot entry; hold Option at the chime and choose rEFInd/EFI Boot"
fi
if [ ! -x /usr/local/bin/gpu-switch ]; then
  git clone -q "$GPU_SWITCH_REPO" "$WORK/gpu-switch"
  install -m755 "$WORK/gpu-switch/gpu-switch" /usr/local/bin/gpu-switch
fi
/usr/local/bin/gpu-switch -i >/dev/null && log "gpu-power-prefs set: Intel drives the panel from the next boot"

# ------------------------------------------------------- 2. desktop on Intel
log "Phase 2: COSMIC on the Intel GPU, dGPU off on the stock kernel"
INTEL_RENDER=$(readlink -f /dev/dri/by-path/pci-0000:00:02.0-render 2>/dev/null | xargs -r basename)
[ -n "$INTEL_RENDER" ] || INTEL_RENDER=renderD128
grep -q '^COSMIC_RENDER_DEVICE=' /etc/environment && sed -i "s/^COSMIC_RENDER_DEVICE=.*/COSMIC_RENDER_DEVICE=$INTEL_RENDER/" /etc/environment || echo "COSMIC_RENDER_DEVICE=$INTEL_RENDER" >> /etc/environment
grep -q '^WGPU_POWER_PREF=' /etc/environment || echo 'WGPU_POWER_PREF=low' >> /etc/environment
curl -fsSL "https://github.com/$REPO/raw/main/files/dgpu-off.service" -o /etc/systemd/system/dgpu-off.service \
  || cp "$(dirname "$0")/files/dgpu-off.service" /etc/systemd/system/dgpu-off.service
systemctl daemon-reload
systemctl enable dgpu-off.service >/dev/null 2>&1
systemctl enable switcheroo-control >/dev/null 2>&1 || true

if [ "$NO_KERNEL" = 1 ]; then
  log "Skipping kernel and reclocked (--no-kernel). Reboot to finish."; exit 0
fi

# ------------------------------------------------------- 3. patched kernel
log "Phase 3: kernel $KVER"
if ! dpkg -s "linux-image-$KVER" >/dev/null 2>&1; then
  if [ -n "$KERNEL_DIR" ]; then
    cp "$KERNEL_DIR"/linux-image-"$KVER"_*.deb "$KERNEL_DIR"/linux-headers-"$KVER"_*.deb "$WORK/"
  else
    BASE="https://github.com/$REPO/releases/download/$RELEASE_TAG"
    for f in linux-image-${KVER}_7.0.11-7_amd64.deb linux-headers-${KVER}_7.0.11-7_amd64.deb; do
      log "downloading $f"
      curl -fL --progress-bar "$BASE/$f" -o "$WORK/$f" || die "download failed: $BASE/$f"
    done
  fi
  apt-get install -y -q "$WORK"/linux-image-"$KVER"_*.deb "$WORK"/linux-headers-"$KVER"_*.deb >/dev/null || die "kernel install failed"
fi
[ -f "/boot/vmlinuz-$KVER" ] || die "/boot/vmlinuz-$KVER missing after install"
if dpkg -s broadcom-sta-dkms >/dev/null 2>&1; then
  DKMS_STATUS=$(dkms status 2>/dev/null || true)
  if grep -q "broadcom-sta.*$KVER.*installed" <<<"$DKMS_STATUS"; then
    log "Wi-Fi (broadcom-sta) built for $KVER"
  else
    warn "broadcom-sta did not build for $KVER — Wi-Fi may be missing on that kernel; run: dkms autoinstall -k $KVER"
  fi
fi
cp "/boot/vmlinuz-$KVER" "$POP_DIR/vmlinuz-mbp.efi"
cp "/boot/initrd.img-$KVER" "$POP_DIR/initrd-mbp.img"
cat > "$ESP/loader/entries/Pop_OS-mbp.conf" <<EOF
title Pop!_OS $KVER (nouveau runpm)
linux $POP_REL/vmlinuz-mbp.efi
initrd $POP_REL/initrd-mbp.img
options root=UUID=$ROOT_UUID ro quiet splash nouveau.runpm=1 intel_iommu=igfx_off i915.enable_fbc=1
EOF
STOCK_OPTS=$(awk '/^options/ {sub("^options ",""); print; exit}' "$ESP/loader/entries/Pop_OS-current.conf" 2>/dev/null || true)
[ -n "$STOCK_OPTS" ] || STOCK_OPTS="root=UUID=$ROOT_UUID ro quiet splash"
printf '"Pop!_OS stock kernel" "%s"\n' "$STOCK_OPTS" > "$POP_DIR/refind_linux.conf"
LC="$ESP/loader/loader.conf"
grep -q '^default' "$LC" && sed -i 's/^default .*/default Pop_OS-mbp.conf/' "$LC" || echo 'default Pop_OS-mbp.conf' >> "$LC"
grep -q '^timeout' "$LC" && sed -i 's/^timeout.*/timeout 5/' "$LC" || echo 'timeout 5' >> "$LC"
log "boot entry Pop_OS-mbp.conf written and set as default; rEFInd fallback to the stock kernel in place"

# ------------------------------------------------------- 4. reclocked
log "Phase 4: reclocked"
git clone -q --depth 1 -b "$RECLOCKED_BRANCH" "$RECLOCKED_REPO" "$WORK/reclocked"
make -s -C "$WORK/reclocked/src" >/dev/null || die "reclocked build failed"
install -m755 "$WORK/reclocked/src/reclocked" "$WORK/reclocked/src/reclockctl" /usr/local/bin/
if [ ! -f /etc/reclocked.conf ]; then
  curl -fsSL "https://github.com/$REPO/raw/main/files/reclocked.conf" -o /etc/reclocked.conf \
    || cp "$(dirname "$0")/files/reclocked.conf" /etc/reclocked.conf
fi
if [ "$MAX_0F" = 0 ]; then
  # Conservative: disable the 0f boost tier (keeps the 07/0a/0e ladder only).
  sed -i '/^\[profile default\]/,/^$/ s/^boost-pstate = 0f/boost-pstate = -1/' /etc/reclocked.conf
else
  warn "0f boost enabled (Apple's factory memory clock under sustained load). If the GPU ever freezes, set boost-pstate = -1 in /etc/reclocked.conf"
fi
curl -fsSL "https://github.com/$REPO/raw/main/files/reclocked.service" -o /etc/systemd/system/reclocked.service \
  || cp "$(dirname "$0")/files/reclocked.service" /etc/systemd/system/reclocked.service
systemctl daemon-reload
systemctl enable reclocked.service >/dev/null 2>&1

cat <<EOF

$(printf '\033[1;32mDone.\033[0m') Reboot now. At rEFInd choose Pop!_OS; systemd-boot boots $KVER by default.
After logging in, run verify.sh (or: sudo cat /sys/kernel/debug/vgaswitcheroo/switch — the DIS line
should read DynOff after ~10 s idle, DynPwr while a DRI_PRIME app runs).

If the patched kernel misbehaves: at rEFInd pick the "vmlinuz.efi" entry (stock kernel), then
  sudo sed -i 's/^default .*/default Pop_OS-current/' $LC

Run apps on the GT 750M: right-click → "Run with…" in COSMIC, or DRI_PRIME=pci-0000_01_00_0 <app>.
After any macOS session: sudo gpu-switch -i, then reboot (macOS resets the boot GPU).
EOF
