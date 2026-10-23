# Changelog

## v0.1.3 — 2026-10-24
- install: `--only intel-boot|kernel|reclocked` runs a subset of the phases; `--offline DIR` installs from a local
  apt repository, kernel debs and sources (the pop-mbp11-3 kit's bundle layout). Both exist so the kit can delegate
  here instead of carrying its own copy.
- install: `files/` is taken from next to the script when run from a checkout or tarball, so a pinned copy never
  mixes in files from `main`; it is downloaded only when piped through curl.
- README: points to the [pop-mbp11-3](https://github.com/onuraksoy3/pop-mbp11-3) kit for the all-in-one install.

## v0.1.2 — 2026-10-23
- kernel 7.0.11-7: new `kernel/patches/0018` enables runtime PM for the Falcon Ridge TB2 host router; the NHI reaches D3hot and idle draw drops ~1.7 W (15.5 → 13.8 W).
- install: boot entry adds `intel_iommu=igfx_off i915.enable_fbc=1`; downloads the -7 packages.
- reclocked: `interval-ms` 500 (was 200); config comments clarify 0e is the ladder max and 0f is boost-only.
- README: new Power section (TB runtime PM, NVMe ASPM / PC3 limit, FBC with 10-bit scanout, TB escape hatch).

## v0.1.1 — 2026-10-23
- reclocked: switchd enabled under the runpm backend — without it the daemon's polling kept the dGPU awake and it never reached DynOff.
- reclocked: [dgpu-active] busy-enter/busy-exit 60/30 (was 80/40) so ~80 % loads stay in 0e instead of flapping.
- reclocked: 0f is now a boost tier (boost-pstate) above the 07/0a/0e ladder; `--max-0f` enables it, default off.
- install: fixed a false "broadcom-sta did not build" warning (pipefail + SIGPIPE).

## v0.1.0 — 2026-10-23
- First release: rEFInd spoof + gpu-switch, COSMIC on Intel, dgpu-off service for the stock kernel, patched 7.0.11-mbp kernel from the GitHub release, reclocked daemon, verify/uninstall/build scripts.
