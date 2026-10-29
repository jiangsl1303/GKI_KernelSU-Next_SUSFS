#!/usr/bin/env bash
# Prepare the defconfig, compile the kernel, and verify the output.
#
# GKI-specific knobs handled here:
#   * gki_defconfig + the options KernelSU-Next dev depends on
#     (CONFIG_KPROBES, CONFIG_EXT4_FS, CONFIG_MODULES ...),
#   * CONFIG_KALLSYMS_ALL (required by the SUSFS LKM symbol resolver),
#   * optional vendor modules (BUILD_MODULES runs `make modules`),
#   * -dirty stripping for a predictable LOCALVERSION.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scripts/susfs.sh
. "$(dirname "${BASH_SOURCE[0]}")/susfs.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
OUT="${KERNEL_DIR}/out"
DEFCONFIG_PATH="${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}"

prepare_defconfig() {
	group "Preparing defconfig"
	[ -f "$DEFCONFIG_PATH" ] \
		|| die "defconfig not found: arch/${ARCH}/configs/${KERNEL_CONFIG}
       Available: $(ls "${KERNEL_DIR}/arch/${ARCH}/configs/" 2>/dev/null | head -20 | tr '\n' ' ')"

	cp "$DEFCONFIG_PATH" "${WORKSPACE}/defconfig.orig"

	local kver
	kver=$(kernel_version "$KERNEL_DIR")

	if [ "${KSU_VARIANT:-none}" != "none" ]; then
		kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU

		# KernelSU-Next dev Kconfig: `depends on KPROBES && EXT4_FS`
		kconf_enable "$DEFCONFIG_PATH" CONFIG_KPROBES
		kconf_enable "$DEFCONFIG_PATH" CONFIG_HAVE_KPROBES
		kconf_enable "$DEFCONFIG_PATH" CONFIG_KPROBE_EVENTS
		kconf_enable "$DEFCONFIG_PATH" CONFIG_KRETPROBES
		kconf_enable "$DEFCONFIG_PATH" CONFIG_EXT4_FS
		kconf_enable "$DEFCONFIG_PATH" CONFIG_MODULES

		local mode=${KSU_HOOK_MODE_RESOLVED:-${KSU_HOOK_MODE:-auto}}
		case "$mode" in
			kprobes)
				kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU_KPROBES_HOOK
				;;
			manual)
				kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU_MANUAL_HOOK
				;;
			none) ;;
			*) warn "hook mode '${mode}' has no defconfig mapping; leaving defaults" ;;
		esac
	fi

	# SUSFS LKM: the module resolves unexported symbols via kallsyms at load
	# time (symbol_resolver.c). Without KALLSYMS_ALL the insmod fails.
	if is_true "${ENABLE_SUSFS:-false}"; then
		if is_true "${FORCE_KALLSYMS_ALL:-true}"; then
			kconf_set_many "$DEFCONFIG_PATH" \
				CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y CONFIG_KALLSYMS_BASE_RELATIVE=y
			info "enabled CONFIG_KALLSYMS_ALL for the SUSFS LKM symbol resolver"
		fi
	fi

	is_true "${ADD_OVERLAYFS_CONFIG:-false}" && kconf_enable "$DEFCONFIG_PATH" CONFIG_OVERLAY_FS

	if is_true "${DISABLE_LTO:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_LTO=n CONFIG_LTO_CLANG=n CONFIG_LTO_CLANG_FULL=n \
			CONFIG_LTO_CLANG_THIN=n CONFIG_THINLTO=n CONFIG_LTO_NONE=y
	fi

	is_true "${DISABLE_CC_WERROR:-false}" && kconf_disable "$DEFCONFIG_PATH" CONFIG_CC_WERROR

	# CONFIG_DEBUG_INFO_BTF needs pahole (dwarves). Without it the build dies
	# at `vmlinux` with "pahole is not available", so degrade instead of fail.
	#
	# Version matters too: 6.12 emits BTF that pahole 1.25 (Ubuntu noble)
	# cannot round-trip, and `BTFIDS vmlinux` then aborts with
	# "FAILED: load BTF from vmlinux: Invalid argument". The workflow builds a
	# newer pahole for 6.12; if that build ever fails we still want a kernel,
	# so drop BTF rather than the whole job.
	local pahole_ver
	pahole_ver=$(pahole --version 2>/dev/null | head -n1 | sed 's/^v//' || true)
	if ! command -v pahole >/dev/null 2>&1; then
		warn "pahole not found; disabling CONFIG_DEBUG_INFO_BTF for this build"
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_DEBUG_INFO_BTF=n CONFIG_DEBUG_INFO_BTF_MODULES=n
	elif [ -z "$pahole_ver" ]; then
		# Present but not runnable (e.g. a shared lib it links against went
		# missing). kconfig calls pahole on init/Kconfig and turns the failure
		# into a bogus "init/Kconfig: syntax error", so catch it here first.
		warn "pahole is installed but not runnable; disabling CONFIG_DEBUG_INFO_BTF"
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_DEBUG_INFO_BTF=n CONFIG_DEBUG_INFO_BTF_MODULES=n
	elif ver_ge "$kver" "6.12" && ! ver_ge "$pahole_ver" "1.26"; then
		warn "pahole '${pahole_ver}' is too old for kernel ${kver}; disabling CONFIG_DEBUG_INFO_BTF"
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_DEBUG_INFO_BTF=n CONFIG_DEBUG_INFO_BTF_MODULES=n
	fi

	if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
		local kv
		for kv in $(printf '%s' "$EXTRA_DEFCONFIG" | tr '\n' ' '); do
			[ -n "$kv" ] || continue
			case "$kv" in
				*=*) kconf_set "$DEFCONFIG_PATH" "${kv%%=*}" "${kv#*=}" ;;
				*) warn "ignoring malformed EXTRA_DEFCONFIG entry '${kv}' (want CONFIG_X=y)" ;;
			esac
		done
	fi

	if [ -n "${KERNEL_NAME_SUFFIX:-}" ]; then
		kconf_set "$DEFCONFIG_PATH" CONFIG_LOCALVERSION "\"${KERNEL_NAME_SUFFIX}\""
	fi

	info "defconfig changes:"
	diff -u "${WORKSPACE}/defconfig.orig" "$DEFCONFIG_PATH" | sed -n '4,$p' | sed 's/^/    /' || true
	endgroup
}

make_args() {
	printf '%s' "O=${OUT} ARCH=${ARCH}"
	[ -n "${CUSTOM_CMDS:-}" ] && printf ' %s' "$CUSTOM_CMDS"
	[ -n "${EXTRA_CMDS:-}" ]  && printf ' %s' "$EXTRA_CMDS"
	if is_true "${USE_LLVM:-false}"; then
		printf ' LLVM=1 LLVM_IAS=1'
	fi
}

build_kernel() {
	group "Building kernel ${KERNEL_SOURCE_BRANCH}"
	export PATH="${CLANG_PATH:?CLANG_PATH must be set}/bin:${PATH}"
	export_env PATH "$PATH"
	export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-Github-Action}
	export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-ksun-susfs-builder}

	# Use the absolute clang path so ccache and make subprocesses (/bin/sh)
	# always find the compiler, even when free-disk-space removed system clang.
	local cc="${CLANG_PATH}/bin/clang" args
	args=$(make_args)
	if is_true "${ENABLE_CCACHE:-true}" && command -v ccache >/dev/null; then
		export CCACHE_DIR="${CCACHE_DIR:-${WORKSPACE}/.ccache}"
		export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}"
		# Hardlinking the cached object into the build tree fails with
		# EPERM when cache and out/ live on different filesystems.
		export CCACHE_HARDLINK=false
		mkdir -p "$CCACHE_DIR"
		# End-to-end smoke test of the wrapper. A broken cache must degrade to
		# plain clang instead of turning into a failed kernel build, but print
		# why: a silent skip once cost a whole build cycle to diagnose.
		local ccache_out
		if ccache_out=$(ccache "${CLANG_PATH}/bin/clang" --version 2>&1); then
			cc="ccache ${CLANG_PATH}/bin/clang"
			info "ccache enabled (dir: ${CCACHE_DIR})"
		else
			warn "ccache smoke test failed; continuing without ccache"
			printf '%s\n' "$ccache_out" | tail -n 5 | sed 's/^/    /' >&2
		fi
	fi

	cd "$KERNEL_DIR"

	# Keep the release string clean: strip the "-dirty" suffix that kbuild
	# appends once the KernelSU-Next installer touches tracked files.
	if is_true "${REMOVE_DIRTY_STRING:-true}"; then
		sed -i 's/-dirty//g' "${KERNEL_DIR}/scripts/setlocalversion" 2>/dev/null || true
	fi

	# Several vendor trees reuse the DISABLE_LTO make variable for compiler
	# flags ("-fno-lto"); leave Kbuild to own the name after the defconfig step.
	unset DISABLE_LTO || true

	info "make ${args} ${KERNEL_CONFIG}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC="$cc" $args "${KERNEL_CONFIG}" || die "defconfig generation failed"

	info "make ${args}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC="$cc" $args || die "kernel build failed"

	# GKI devices need the vendor modules too (WiFi / audio / touch).
	if is_true "${BUILD_MODULES:-false}"; then
		info "make modules"
		# shellcheck disable=SC2086
		make -j"$(nproc --all)" CC="$cc" $args modules || die "modules build failed"
	fi

	# KernelSU-Next SUSFS comes as an LKM; build it now against this tree.
	if is_true "${ENABLE_SUSFS:-false}"; then
		build_susfs_lkm
	fi
	endgroup
}

check_output() {
	group "Checking build output"
	local boot="${OUT}/arch/${ARCH}/boot"
	local image="${boot}/${KERNEL_IMAGE_NAME}"

	[ -f "$image" ] || die "expected kernel image not found: ${image}
       Built files: $(ls "$boot" 2>/dev/null | tr '\n' ' ')
       Check that KERNEL_IMAGE_NAME matches what your kernel produces."

	ok "kernel image: ${KERNEL_IMAGE_NAME} ($(du -h "$image" | cut -f1))"
	export_env CHECK_FILE_IS_OK true

	if is_true "${NEED_DTBO:-false}"; then
		[ -f "${boot}/dtbo.img" ] || die "NEED_DTBO=true but ${boot}/dtbo.img was not produced"
		export_env CHECK_DTBO_IS_OK true
		ok "dtbo.img present"
	fi

	if [ -f "${OUT}/include/generated/utsrelease.h" ]; then
		local rel
		rel=$(sed -nE 's/.*UTS_RELEASE[[:space:]]+"([^"]+)".*/\1/p' "${OUT}/include/generated/utsrelease.h")
		export_env KERNEL_RELEASE "$rel"
		ok "kernel release: ${rel}"
		summary "| Kernel release | \`${rel}\` |"
	fi

	# sanity: the SUSFS module must match the kernel it was built against
	if is_true "${ENABLE_SUSFS:-false}"; then
		local want
		want=$(strings "${SUSFS_KO:-/nonexistent}" 2>/dev/null | grep -E '^6\.(1|6|12|15)\.[0-9]+' | head -n1 || true)
		[ -n "$want" ] && info "susfs_guard_lkm.ko vermagic: ${want}"
	fi
	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		defconfig) prepare_defconfig ;;
		compile)   build_kernel ;;
		check)     check_output ;;
		all)       prepare_defconfig; build_kernel; check_output ;;
		*) die "unknown build step '$1'" ;;
	esac
fi
