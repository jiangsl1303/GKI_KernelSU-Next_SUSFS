# GKI KernelSU-Next + SUSFS 2.3 for generic Android devices

One-click GitHub Actions builds of **KernelSU-Next (dev) + SUSFS 2.3.0** for
generic Android GKI devices.

- **Kernel source**: AOSP `aosp-mirror/kernel_common` GKI tree
  (profiles for 5.10 / 5.15 / 6.1 / 6.6 / 6.12)
- **Root**: KernelSU-Next `dev` branch (ships SUSFS 2.3.0-gki in-tree)
- **SUSFS 2.3**: built as an LKM (`susfs_guard_lkm.ko`), loaded with `ksud insmod` after boot
- **Output**: AnyKernel3 flashable zip (Image + dtbo + the LKM + notes), raw `Image`, raw `.ko`
- **New device**: copy a `config/*.env`, point `KERNEL_SOURCE` at your tree
  (non-GKI vendor trees work too — see [docs/device-adaptation.md](docs/device-adaptation.md))

中文说明见 [README.md](README.md)。

## Quick start

1. Fork this repo, enable Actions.
2. `Actions → Build Kernel → Run workflow`:
   - **Config file to build**: `config/android15-6.6.env` (default) or the one matching your Android version
   - **ksu_ref**: empty = auto (`dev` on ≥5.10, `legacy` below)
   - **susfs**: `true` (default) builds and bundles `susfs_guard_lkm.ko`
   - **publish_release**: publish a GitHub Release when done
3. Download `AnyKernel3-*.zip` from the run.

Local build (Linux, bash 4+, ≈40G free disk):

```bash
bash scripts/config.sh && bash scripts/toolchain.sh && bash scripts/source.sh \
  && bash scripts/kernelsu.sh && bash scripts/build.sh all && bash scripts/package.sh all
```

## Flash & enable SUSFS

Flash the AnyKernel3 zip from recovery, or with KernelFlasher (repacks your
stock boot). Unlocked bootloader required; the boot partition must accept a
GKI kernel flashed over stock.

After boot, load SUSFS once per boot (2.3 is an LKM):

```bash
adb shell su -c "ksud insmod /data/adb/ksu/susfs_guard_lkm.ko"
adb shell su -c "ls /proc/susfs_kstat"   # prints = active
```

The zip already stages the module at `/data/adb/ksu/susfs_guard_lkm.ko`, and
bundles `susfs-load.sh` which can install a boot-time hook.

## Configuration reference

See comments in [config/android15-6.6.env](config/android15-6.6.env) — every
key is documented there. The important ones:

| Key | Meaning | Default |
| --- | --- | --- |
| `KERNEL_SOURCE` / `KERNEL_SOURCE_BRANCH` | kernel tree + branch | `aosp-mirror/kernel_common` |
| `KSU_REF` | KernelSU-Next ref (carries SUSFS) | `dev` |
| `ENABLE_SUSFS` | build + bundle the SUSFS LKM | `true` |
| `FORCE_KALLSYMS_ALL` | required by the LKM symbol resolver | `true` |
| `REMOVE_PROTECTED_EXPORTS` | drop GKI ABI lists so vendor modules load | `true` (Android 14+) |
| `BUILD_MODULES` | also build vendor modules from out/ | `true` |
| `KERNEL_NAME_SUFFIX` | LOCALVERSION suffix in artifact names | `-GKI-KSUN-SUSFS` |

## Credits

- [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) — ships SUSFS 2.3.0
- [xiaoleGun/KernelSU_Action](https://github.com/xiaoleGun/KernelSU_Action) — generic build framework
- [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) — SUSFS upstream
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3)
