#!/usr/bin/env bash
# Install KernelSU-Next (dev branch, which ships SUSFS 2.3.x) into the tree.
#
# KernelSU-Next's kernel/setup.sh:
#   * detects GKI 2.0 layout ($ROOT/common/drivers) vs classic ($ROOT/drivers),
#   * clones https://github.com/KernelSU-Next/KernelSU-Next into $ROOT,
#   * checks out its latest tag when given no ref, so we always pass one,
#   * symlinks drivers/kernelsu -> KernelSU-Next/kernel,
#   * inserts `source "drivers/kernelsu/Kconfig"` before endmenu.
#
# The critical safety property, same as upstream: setup.sh ends its checkout
# with `git checkout "$1" || echo "[-] Checkout default branch"`, so an invalid
# ref does NOT fail the script. We validate the ref first and verify the
# checkout afterwards.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}

KSU_REPO=https://github.com/KernelSU-Next/KernelSU-Next

# Which ref carries the SUSFS 2.3 LKM: dev (modern, >= 5.10) or legacy (< 5.10).
ksu_ref_for_version() {
	local requested=${1:-} kver
	kver=$(kernel_version "$KERNEL_DIR" || echo "5.10")
	if [ -z "$requested" ]; then
		if ver_ge "$kver" "5.10"; then
			echo dev
		else
			echo legacy
		fi
	else
		echo "$requested"
	fi
}

# hook mode: KernelSU-Next dev Kconfig depends on KPROBES && EXT4_FS; its
# hooking is kprobes-based on modern trees and patch-based on pre-GKI trees.
ksu_resolve_hook_mode() {
	local mode=${1:-auto} kver=$2
	if [ "$mode" = "auto" ]; then
		if ver_ge "$kver" "5.10"; then
			mode="kprobes"
		else
			mode="manual"
		fi
		info "hook mode 'auto' resolved to '${mode}' for kernel ${kver}"
	fi
	export_env KSU_HOOK_MODE_RESOLVED "$mode"
}

install_ksun() {
	local ref
	ref=$(ksu_ref_for_version "${KSU_REF:-}")

	group "Installing KernelSU-Next"
	info "repository: ${KSU_REPO}"
	info "ref: ${ref}"

	ref_exists "$KSU_REPO" "$ref" \
		|| die "ref '${ref}' does not exist in ${KSU_REPO}.
       setup.sh would silently fall back to the latest tag and you would
       lose the SUSFS 2.3 code that lives on the dev branch.
       Available branches: $(git ls-remote --heads "$KSU_REPO" 2>/dev/null | awk '{print $2}' | sed 's@refs/heads/@@' | grep -v dependabot | tr '\n' ' ')"

	local setup_url="https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/${ref}/kernel/setup.sh"
	info "running ${setup_url}"
	(
		cd "$KERNEL_DIR"
		fetch_stdout "$setup_url" | bash -s "$ref"
	) || die "KernelSU-Next setup.sh failed"

	# --- verify the installer did what it claims ---------------------------
	local ksu_dir dirmake dir kconfig
	ksu_dir="$KERNEL_DIR/KernelSU-Next"
	[ -d "$ksu_dir" ] || die "setup.sh finished but KernelSU-Next/ is missing"

	if [ -d "$KERNEL_DIR/common/drivers" ]; then
		dirmake="$KERNEL_DIR/common/drivers/Makefile"
		kconfig="$KERNEL_DIR/common/drivers/Kconfig"
	else
		dirmake="$KERNEL_DIR/drivers/Makefile"
		kconfig="$KERNEL_DIR/drivers/Kconfig"
	fi

	# setup.sh only wires the Kconfig; the Makefile hook is NOT guaranteed.
	if ! grep -qE '^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$dirmake"; then
		if grep -qE '^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$' "$dirmake"; then
			sed -i -E 's@^[[:space:]]*obj-\$\(CONFIG_[A-Z0-9_]+\)[[:space:]]*\+=[[:space:]]*kernelsu/?[[:space:]]*$@obj-$(CONFIG_KSU) += kernelsu/@' "$dirmake"
			warn "normalized stale drivers/Makefile KernelSU guard to CONFIG_KSU"
		else
			printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >>"$dirmake"
			warn "added missing CONFIG_KSU rule to drivers/Makefile"
		fi
	fi

	grep -q 'drivers/kernelsu/Kconfig' "$kconfig" \
		|| die "drivers/Kconfig was not wired up for kernelsu"

	# Confirm we landed on the ref we asked for (silent-fallback check).
	local head_desc head_sha want
	head_sha=$(git -C "$ksu_dir" rev-parse --short HEAD)
	head_desc=$(git -C "$ksu_dir" describe --tags --always 2>/dev/null || echo "$head_sha")
	want=$(git -C "$ksu_dir" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null || true)
	[ -n "$want" ] || die "could not resolve ${ref}^{commit} in ${ksu_dir}"
	[ "$want" = "$(git -C "$ksu_dir" rev-parse HEAD)" ] \
		|| die "KernelSU-Next is checked out at ${head_desc}, not the requested ref '${ref}'"

	ok "KernelSU-Next installed at ${head_desc} (${head_sha})"

	# --- pin KSU source paths against relative-srctree kbuild -----------------
	# Two separate breakages, both from resolving paths through the
	# drivers/kernelsu symlink with a *relative* srctree (6.12 keeps srctree
	# relative inside sub-makes, older trees make it absolute):
	#
	#   a) `#include "uapi/app_profile.h"` -> not found, because
	#      kernel/include/uapi is itself a relative symlink to ../../uapi and
	#      the lexical `..` lands on KernelSU-Next/kernel/uapi.
	#   b) the preinit rule's prerequisite $(KSU_KERNEL_DIR)/preinit/runner/
	#      runner.c expands to ../../drivers/kernelsu/... , which from the
	#      object directory points into out/ and has no rule:
	#      "No rule to make target '../../drivers/kernelsu/preinit/runner/runner.c'"
	#
	# Pinning KSU_KERNEL_DIR to the real absolute source directory fixes both
	# upstream of the flags, and adding the concrete include dirs covers (a)
	# even if the pin is ever reverted. Both steps are idempotent.
	local ksu_kbuild="$ksu_dir/kernel/Kbuild"
	if [ -f "$ksu_kbuild" ]; then
		sed -i -E "s@^KSU_KERNEL_DIR := .*@KSU_KERNEL_DIR := ${ksu_dir}/kernel@" "$ksu_kbuild"
		grep -q 'KSU_KERNEL_DIR := ' "$ksu_kbuild" \
			|| die "could not pin KSU_KERNEL_DIR in ${ksu_kbuild}"
		if ! grep -q 'KSU_EXTRA_INC' "$ksu_kbuild"; then
			{
				printf '\n# KSU_EXTRA_INC: concrete include dirs appended by the build script\n'
				printf 'ccflags-y += -I%s -I%s/kernel -I%s/kernel/include\n' \
					"$ksu_dir" "$ksu_dir" "$ksu_dir"
			} >>"$ksu_kbuild"
		fi
		info "pinned KSU_KERNEL_DIR and include dirs in $(basename "$ksu_kbuild")"
	fi

	# --- publish facts later steps need ------------------------------------
	local version_label
	version_label=$(git -C "$ksu_dir" describe --exact-match --tags 2>/dev/null || echo "${ref}-${head_sha}")
	export_env KSU_REF_RESOLVED "$ref"
	export_env KSU_NAME "KernelSU-Next"
	export_env KSU_VERSION_LABEL "$version_label"
	export_env KSU_DIR "$KERNEL_DIR/KernelSU-Next"
	export_env UPLOADNAME "-KernelSU-Next_${version_label}"

	# SUSFS version from source (kernel/susfs/susfs.h: SUSFS_LKM_VERSION)
	local susfs_h="${ksu_dir}/kernel/susfs/susfs.h"
	if [ -f "$susfs_h" ]; then
		export_env SUSFS_VERSION "$(sed -nE 's/^#define[[:space:]]+SUSFS_LKM_VERSION[[:space:]]+"([^"]+)".*/\1/p' "$susfs_h" | head -n1)"
	fi

	ksu_resolve_hook_mode "${KSU_HOOK_MODE:-auto}" "$(kernel_version "$KERNEL_DIR")"

	summary "| KernelSU | \`KernelSU-Next\` @ \`${head_desc}\` |"
	summary "| SUSFS | \`${SUSFS_VERSION:-n/a}\` (built-in LKM) |"
	endgroup
}

if [ "${KSU_VARIANT:-none}" = "none" ]; then
	info "KernelSU integration disabled"
else
	install_ksun
fi
