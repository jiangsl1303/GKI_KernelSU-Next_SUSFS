#!/usr/bin/env bash
# Build the KernelSU-Next SUSFS LKM (susfs_guard_lkm.ko).
#
# KernelSU-Next ships SUSFS in-tree since v2.x as a loadable kernel module:
#   KernelSU-Next/kernel/susfs/  -> obj-m += susfs_guard_lkm.ko
# It is loaded at runtime with `ksud insmod <path>` and relocates unexported
# symbols itself through kallsyms (hence CONFIG_KALLSYMS_ALL=y in the kernel).
#
# The module must be built against the exact same out/ tree as the kernel,
# after `make modules_prepare`. This script runs after the kernel build.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
OUT="${KERNEL_DIR}/out"
KSU_TREE="${KERNEL_DIR}/KernelSU-Next"
SUSFS_SRC="${KSU_TREE}/kernel/susfs"

build_susfs_lkm() {
	group "Building SUSFS LKM"

	[ -d "$SUSFS_SRC" ] || die "SUSFS sources not found at ${SUSFS_SRC}
       KernelSU-Next (dev branch) ships SUSFS under kernel/susfs/; make sure
       KSU_REF points at a ref that contains it (dev)."

	export PATH="${CLANG_PATH:?CLANG_PATH must be set}/bin:${PATH}"
	local cc="${CLANG_PATH}/bin/clang"

	# 1. modules_prepare: prepares the out/ tree for external module builds
	#    (Module.symvers, .config, scripts rebuilt).
	(
		cd "$KERNEL_DIR"
		info "make modules_prepare"
		make -j"$(nproc --all)" O="$OUT" ARCH="$ARCH" CC="$cc" LLVM=1 LLVM_IAS=1 \
			modules_prepare
	) || die "modules_prepare failed"

	# 2. Build the module itself against the prepared out/ tree.
	#    KernelSU-Next's Makefile expects exactly this invocation:
	#      make -C $KDIR M=$PWD ARCH=arm64 CC=clang LLVM=1 LLVM_IAS=1 modules
	(
		cd "$KERNEL_DIR"
		info "building susfs_guard_lkm.ko against ${OUT}"
		make -j"$(nproc --all)" -C "$OUT" M="$SUSFS_SRC" ARCH="$ARCH" \
			CC="$cc" LLVM=1 LLVM_IAS=1 modules
	) || die "SUSFS LKM build failed"

	# 3. Collect the artifact and record its version.
	local ko
	ko=$(find_ko "$SUSFS_SRC") || die "susfs_guard_lkm.ko was not produced"
	mkdir -p "${WORKSPACE}/artifacts"
	cp -f "$ko" "${WORKSPACE}/artifacts/susfs_guard_lkm.ko"
	ok "SUSFS LKM: ${ko} ($(du -h "$ko" | cut -f1))"

	if [ -f "${SUSFS_SRC}/susfs.h" ]; then
		export_env SUSFS_VERSION "$(sed -nE 's/^#define[[:space:]]+SUSFS_LKM_VERSION[[:space:]]+"([^"]+)".*/\1/p' "${SUSFS_SRC}/susfs.h" | head -n1)"
	fi

	export_env SUSFS_KO "${WORKSPACE}/artifacts/susfs_guard_lkm.ko"
	summary "| SUSFS module | \`susfs_guard_lkm.ko\` (\`${SUSFS_VERSION:-unknown}\`) |"
	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	is_true "${ENABLE_SUSFS:-false}" || { info "SUSFS disabled in profile"; exit 0; }
	build_susfs_lkm
fi
