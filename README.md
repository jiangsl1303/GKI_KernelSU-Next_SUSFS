# GKI KernelSU-Next + SUSFS 2.3 · 通用安卓内核编译

给**通用安卓设备**（GKI 内核可刷机设备）一键编译 **KernelSU-Next（dev）+ SUSFS 2.3.0** 的 GitHub Actions 仓库。

- **内核源码**：AOSP `aosp-mirror/kernel_common` 官方 GKI 通用树（5.10 / 5.15 / 6.1 / 6.6 / 6.12 均有内置配置）
- **Root**：KernelSU-Next `dev` 分支（**内置 SUSFS 2.3.0-gki**，源码在 `KernelSU-Next/kernel/susfs/`）
- **SUSFS 形态**：2.3 起 SUSFS 是 **LKM**（`susfs_guard_lkm.ko`），随内核一同编译，刷机后 `ksud insmod` 加载
- **产物**：AnyKernel3 可刷入 zip（Image + dtbo + susfs_guard_lkm.ko + 说明）+ 原始 Image + .ko
- **适配**：新增设备 = 复制一份 `config/*.env`，改 `KERNEL_SOURCE` / `KERNEL_CONFIG` / `KERNEL_IMAGE_NAME` 即可（含非 GKI 厂商树模板，见 [docs/device-adaptation.md](docs/device-adaptation.md)）

## 快速开始

1. Fork 本仓库（或直接在你自己的仓库里启用 Actions）。
2. `Actions → Build Kernel → Run workflow`：
   - **Config file to build**：选 `config/android15-6.6.env`（默认）或你的 Android 版本对应文件
   - **ksu_ref**：留空 = 自动（≥5.10 用 `dev`，<5.10 用 `legacy`）
   - **susfs**：`true`（默认）会编译并打包 `susfs_guard_lkm.ko`
   - **publish_release**：勾选后自动发布 GitHub Release
3. 构建完成后下载 `AnyKernel3-*.zip`。

> 本地构建：`bash scripts/config.sh && bash scripts/toolchain.sh && bash scripts/source.sh && bash scripts/kernelsu.sh && bash scripts/build.sh all && bash scripts/package.sh all`（需要 Linux + bash 4+；磁盘预留 ≥ 40G）。

## 内置配置（GKI）

| 配置文件 | Android | Linux | kernel_common 分支 | 备注 |
| --- | --- | --- | --- | --- |
| `config/android13-5.10.env` | 13 | 5.10 | `android13-5.10` | 老设备 / GSI |
| `config/android13-5.15.env` | 13 | 5.15 | `android13-5.15` | |
| `config/android14-6.1.env` | 14 | 6.1 | `android14-6.1` | Pixel 6/7/8 系 |
| `config/android15-6.6.env` | 15 | 6.6 | `android15-6.6` | **默认** |
| `config/android16-6.12.env` | 16 | 6.12 | `android16-6.12` | 最新 |

所有配置共用同一套构建脚本；改配置不需要改脚本。

## 刷入与启用 SUSFS

**刷内核（AnyKernel3 zip）**

-  recovery：直接刷 `AnyKernel3-*.zip`；或
-  KernelFlasher：把 zip 拷到手机内部存储，App 内选择刷入（自动 repack 你机型的 stock boot）；
-  设备需处于"可接受第三方 GKI 内核"状态：已解锁 BL、boot 分区可写。

**开机后启用 SUSFS**（2.3 为 LKM，每次开机加载一次）：

```bash
adb shell su -c "ksud insmod /data/adb/ksu/susfs_guard_lkm.ko"
adb shell su -c "ls /proc/susfs_kstat"   # 有输出即生效
```

zip 在刷机时已自动把 `susfs_guard_lkm.ko` 拷到 `/data/adb/ksu/`，zip 内附 `susfs-load.sh` 可写开机加载钩子。

## 关键实现说明（为什么这么做）

- **为什么要 `dev` 分支**：SUSFS 2.3.0 只存在于 KernelSU-Next `dev`（现代树）。`legacy` 分支是给 <5.10 老内核的，没有新版 SUSFS。仓库会对 `ksu_ref` 做存在性校验——KernelSU 系 `setup.sh` 遇到无效 ref 会**静默回落到默认分支**，不校验就会得到没有 SUSFS 的内核。
- **`CONFIG_KALLSYMS_ALL=y`**：SUSFS LKM 用 kallsyms 自行重定位未导出符号，缺这一项 `ksud insmod` 会失败。默认自动开启（`FORCE_KALLSYMS_ALL=true`）。
- **KSN dev 的 Kconfig 依赖 `KPROBES && EXT4_FS`**：defconfig 阶段自动补上。
- **`REMOVE_PROTECTED_EXPORTS=true`**：Android 14+ GKI 树里的 `android/abi_gki_protected_exports_*` 会让改动过的内核加载不了厂商模块（WiFi/音频）；自用刷机不需要 GKI ABI 校验，故默认删除。
- **`-dirty` 清理**：KSN 安装器改过内核文件后 kbuild 会追加 `-dirty`，默认去掉，版本字符串干净。

## 目录结构

```
├── config.env                  # 默认 profile 指针
├── config/*.env                 # 每个内核版本一个 profile（复制即新增设备）
├── scripts/
│   ├── config.sh                # 加载 profile + workflow 覆盖 + 校验
│   ├── source.sh                # 浅克隆 kernel_common
│   ├── toolchain.sh             # AOSP clang（已验证组合 r547379）
│   ├── kernelsu.sh              # 安装 KernelSU-Next（ref 校验 + 落盘校验）
│   ├── build.sh                 # defconfig + make + modules_prepare
│   ├── susfs.sh                 # 编译 susfs_guard_lkm.ko
│   └── package.sh               # AnyKernel3 打包 + .ko 入 zip
├── anykernel/susfs-load.sh     # 设备端 SUSFS 加载/自启脚本
├── patches/                     # 额外内核补丁放这里（50_*.patch 会被自动应用）
└── docs/device-adaptation.md    # 新设备/新内核适配指南
```

## 致谢与参考

- [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next)（SUSFS 2.3.0 内置）
- [xiaoleGun/KernelSU_Action](https://github.com/xiaoleGun/KernelSU_Action)（通用构建框架参考）
- [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu)（SUSFS 上游）
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3)
