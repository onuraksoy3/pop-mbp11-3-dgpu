#!/bin/bash
# verify.sh — run as your normal user after rebooting into the -mbp kernel.
# Shows whether the GT 750M sleeps, wakes for a DRI_PRIME app, and sleeps again; optional benchmark with --bench.
set -u
sw() { sudo cat /sys/kernel/debug/vgaswitcheroo/switch | sed -n 2p; }
echo "kernel:        $(uname -r)"
case "$(uname -r)" in *-mbp) ;; *) echo "not the -mbp kernel: nothing to verify here (reboot and pick Pop!_OS in rEFInd)"; exit 1 ;; esac
echo "dgpu-off:      $(systemctl is-active dgpu-off.service) (expected: inactive on this kernel)"
echo "reclocked:     $(systemctl is-active reclocked.service)"
echo "wifi:          $(nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -m1 wifi || echo 'no wifi device')"
echo
echo -n "idle 12 s… "; sleep 12; echo "dGPU: $(sw)"
echo -n "wake with DRI_PRIME… "; r=$(DRI_PRIME=pci-0000_01_00_0 glxinfo -B 2>/dev/null | awk -F': ' '/OpenGL renderer/ {print $2}'); echo "renderer: ${r:-FAILED}"
echo "during:        $(sw)"
echo -n "idle 12 s… "; sleep 12; echo "dGPU: $(sw)"
echo
echo "Expected: DynOff → NVE7 → DynPwr → DynOff."
if [ "${1:-}" = --bench ] && command -v glmark2-wayland >/dev/null; then
  echo; echo "glmark2 off-screen 1920x1200 — Intel, then GT 750M (2–3 min each):"
  glmark2-wayland --off-screen -s 1920x1200 2>/dev/null | tail -2 | head -1
  DRI_PRIME=pci-0000_01_00_0 glmark2-wayland --off-screen -s 1920x1200 2>/dev/null | tail -2 | head -1
  sleep 12; echo "after bench:   $(sw)"
fi
