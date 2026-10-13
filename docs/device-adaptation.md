# 设备 / 内核适配指南

本仓库的每台设备就是 `config/` 下的一个 profile 文件。脚本层与内核无关，
适配只改配置；只有极少数情况需要加补丁。

## 场景 A：换一个 GKI 内核版本（最常见）

1. `cp config/android15-6.6.env config/<名字>.env`
2. 改 4 个值：
   ```ini
   KERNEL_SOURCE_BRANCH=android14-6.1     # kernel_common 对应分支
   ```
   其余（`KERNEL_SOURCE`、`KERNEL_CONFIG=gki_defconfig`、`KERNEL_IMAGE_NAME=Image`）不用动。
3. 提交。CI 会自动校验 profile 合法性；Actions 里选新配置文件即可构建。

> 想给分支固定某个发布快照时把 `KERNEL_SOURCE_BRANCH` 换成带日期分支
> （如 `android15-6.6-2025-10`），或在 profile 里加 `KSU_REF=<tag>` 锁版本。

## 场景 B：适配非 GKI 厂商内核（小米/OPPO/vivo/三星等 OEM 树）

以你手里的一加 Ace 5 Pro（OOS16，android15-6.6.89）为例，把
`KERNEL_SOURCE` 指向厂商源码即可，例如：

```ini
# config/oneplus-ace5pro.env
KERNEL_SOURCE=https://github.com/<你的>/OnePlus-Actions-6.6.89
KERNEL_SOURCE_BRANCH=oneplus/ace5pro_oos16
KERNEL_CONFIG=vendor/pineapple_GKI.config   # 按厂商树实际 defconfig 改
KERNEL_IMAGE_NAME=Image                     # 厂商树多为 Image 或 Image.gz-dtb
ARCH=arm64

# 老版本 clang 兼容性更好的 OOS 树可锁定 toolchain
CLANG_BRANCH=master-kernel-build-2022
CLANG_VERSION=r450784e

# 厂商树常见修正
EXTRA_CMDS:KCFLAGS=-Wno-error=strict-prototypes

# 一加系 6.6 树不需要 GKI protected exports 处理，但厂商模块保留
BUILD_MODULES=true
REMOVE_PROTECTED_EXPORTS=false
```

按实际构建结果可能还要动：

| 现象 | 处理 |
| --- | --- |
| `Image.gz-dtb` 等别的产物名 | `KERNEL_IMAGE_NAME=Image.gz-dtb` |
| 需要 dtbo | `NEED_DTBO=true` |
| boot 不是标准 GKI 头 | 打开 `BUILD_BOOT_IMG=true`，配 `SOURCE_BOOT_IMAGE`，准备 `tools/`（见 scripts/package.sh 注释），产物为可直接 fastboot 的 `boot.img` |
| 编译报缺符号/头文件 | 在 `patches/` 放 `50_*.patch`，构建时自动应用；或用 `EXTRA_DEFCONFIG` 加配置 |

## 场景 C：往内核里打自己的补丁

把补丁放进 `patches/`，命名 `NN_描述.patch`（NN 两位数字越小越先打，保持
你仓库原有习惯，如 `50_add_susfs_in_kernel-<ver>.patch`）。
补丁相对内核根目录路径，`patch -p1` 应用；已打过的会自动跳过，打不上的
会 warning 但不中断构建（去日志里 grep `[!]`）。

## 场景 D：换 KernelSU 变体

本仓库默认只服务 KernelSU-Next（因为 SUSFS 2.3 在它里面）。`KSU_VARIANT`
支持：

- `kernelsu-next`（默认）：`KSU_REF=dev` 带 SUSFS 2.3.0 LKM
- `none`：纯净 GKI 无 root（用来定位是不是 KSU 引入的问题）

注意 `kernelsu-next` 之外的变体没有内置 SUSFS，profile 里 `ENABLE_SUSFS`
会被 config.sh 自动降级并给出 warning。

## 本地预检（提交前）

```bash
for f in scripts/*.sh anykernel/*.sh; do bash -n "$f" && echo "ok $f"; done
CONFIG_ENV=config/android15-6.6.env bash scripts/config.sh
```

`CONFIG_ENV` 指向你的新 profile 跑一遍 `scripts/config.sh`，能打印出
"kernel / kernelsu / susfs" 三行确认信息就说明配置合法。
