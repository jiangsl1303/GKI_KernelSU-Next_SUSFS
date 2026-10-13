# NOTICE

## This repository

Build scripts in `scripts/`, `config/`, `.github/workflows/`, `anykernel/`
were written for this project. They follow the design of
[xiaoleGun/KernelSU_Action](https://github.com/xiaoleGun/KernelSU_Action)
(Apache-2.0), from which helper functions in `scripts/lib.sh` and the
profile/workflow conventions were adapted. Where code was adapted, the
original retains its Apache-2.0 license.

## Built software (built, not authored here)

- KernelSU-Next: https://github.com/KernelSU-Next/KernelSU-Next (GPL-2.0)
- SUSFS (upstream): https://gitlab.com/simonpunk/susfs4ksu (GPL-2.0)
- AOSP kernel_common: https://github.com/aosp-mirror/kernel_common (GPL-2.0)
- AnyKernel3: https://github.com/osm0sis/AnyKernel3 (GPL-3.0)

Build outputs (kernel images, modules, AnyKernel3 zips) inherit the GPL-2.0
license of the kernel sources they were built from.

## GKI trademark / partitioning note

"GKI" refers to Google's Generic Kernel Image program. This is an independent
build pipeline; it is not affiliated with or endorsed by Google.
