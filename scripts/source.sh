#!/usr/bin/env bash
# Fetch the kernel source tree (shallow clone of the branch in the profile).

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKSPACE=${WORKSPACE:?WORKSPACE must be set}
KERNEL_DIR="${WORKSPACE}/android-kernel"

group "Cloning kernel source"
info "${KERNEL_SOURCE} @ ${KERNEL_SOURCE_BRANCH}"

retry 3 git clone -q --depth=1 -b "$KERNEL_SOURCE_BRANCH" "$KERNEL_SOURCE" "$KERNEL_DIR" \
	|| die "failed to clone ${KERNEL_SOURCE} (${KERNEL_SOURCE_BRANCH})"

export_env KERNEL_DIR "$KERNEL_DIR"

KV=$(kernel_version "$KERNEL_DIR") || die "could not read kernel version from ${KERNEL_DIR}/Makefile"
info "kernel version: ${KV}"
export_env KERNEL_VERSION "$KV"
export_env KSU_FETCHED_REF ""

# Android 14+ GKI trees carry the protected-exports ABI lists; loading vendor
# modules (WiFi, audio) against a modified kernel trips them, and a custom
# flash does not need GKI ABI verification. Drop the files when they exist.
if is_true "${REMOVE_PROTECTED_EXPORTS:-false}" && ver_ge "$KV" "5.15"; then
	for f in "${KERNEL_DIR}/android/abi_gki_protected_exports_aarch64" \
	         "${KERNEL_DIR}/android/abi_gki_protected_exports_x86_64"; do
		if [ -f "$f" ]; then
			rm -f "$f"
			info "removed $(basename "$f")"
		fi
	done
fi

ok "kernel source ready at ${KERNEL_DIR} (v${KV})"
endgroup
