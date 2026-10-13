#!/usr/bin/env bash
# Set up the clang toolchain (AOSP prebuilt, from the branch/version pair in
# the active profile).
#
# AOSP publishes per-branch archives:
#   https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86
#     /+archive/<CLANG_BRANCH>/clang-<CLANG_VERSION>.tar.gz
#
# Verified working pairs against aosp-mirror/kernel_common (2026-07):
#   main-kernel-2025        r547379   -> 5.10 / 5.15 / 6.1 / 6.6 / 6.12
#   main-kernel-build-2024  r510928   -> fallback
#
# Set USE_CUSTOM_CLANG=true + CUSTOM_CLANG_SOURCE=<zip|tar.xz|tar.gz URL> to
# use your own toolchain instead.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKSPACE=${WORKSPACE:?WORKSPACE must be set}
CLANG_PATH="${WORKSPACE}/clang"

group "Setting up clang toolchain"

if is_true "${USE_CUSTOM_CLANG:-false}"; then
	: "${CUSTOM_CLANG_SOURCE:?CUSTOM_CLANG_SOURCE required when USE_CUSTOM_CLANG=true}"
	info "custom clang: ${CUSTOM_CLANG_SOURCE}"
	mkdir -p "$CLANG_PATH"
	fetch "$CUSTOM_CLANG_SOURCE" "${WORKSPACE}/clang-archive"
	extract_archive "${WORKSPACE}/clang-archive" "$CLANG_PATH"
else
	: "${CLANG_BRANCH:?CLANG_BRANCH not set in profile}"
	: "${CLANG_VERSION:?CLANG_VERSION not set in profile}"

	url="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/${CLANG_BRANCH}/clang-${CLANG_VERSION}.tar.gz"
	info "clang ${CLANG_VERSION} from ${CLANG_BRANCH}"

	# The archive top level IS bin/lib/lib64, so extract into CLANG_PATH itself.
	mkdir -p "$CLANG_PATH"
	fetch "$url" "${WORKSPACE}/clang.tar.gz"
	tar -C "$CLANG_PATH" -xzf "${WORKSPACE}/clang.tar.gz"
	rm -f "${WORKSPACE}/clang.tar.gz"
fi

# Normalize: if the binary ended up nested one level deeper, point at that.
if [ ! -x "${CLANG_PATH}/bin/clang" ]; then
	found=$(find "$CLANG_PATH" -maxdepth 3 -type f -name clang -perm -u+x | head -n1)
	[ -n "$found" ] || die "no clang binary under ${CLANG_PATH}"
	CLANG_PATH=$(dirname "$(dirname "$found")")
fi

export_env CLANG_PATH "$CLANG_PATH"
ok "clang ready: ${CLANG_PATH}/bin/clang"
"${CLANG_PATH}/bin/clang" --version | head -n2 || true
endgroup
