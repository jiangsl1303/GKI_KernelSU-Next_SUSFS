#!/usr/bin/env bash
# Package build output.
#
# Produces:
#   1) AnyKernel3 zip  -> Image (+ dtbo) + susfs_guard_lkm.ko + flash notes.
#      Flashable from a custom recovery, or with KernelFlasher (which only
#      needs the zip on internal storage).
#   2) (optional) raw Image / boot.img artifacts (UPLOAD_RAW_IMAGES).

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
BOOT_OUT="${KERNEL_DIR}/out/arch/${ARCH}/boot"
AK3="${WORKSPACE}/AnyKernel3"
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

make_anykernel3() {
	group "Building AnyKernel3 package"
	rm -rf "$AK3"

	retry 3 git clone -q --depth=1 https://github.com/osm0sis/AnyKernel3 "$AK3" \
		|| die "failed to clone AnyKernel3"

	# This zip is flashed deliberately by the person who built it; the
	# device's ro.product.device is unknown at build time.
	sed -i 's/do.devicecheck=1/do.devicecheck=0/g' "${AK3}/anykernel.sh"
	sed -i 's!BLOCK=/dev/block/platform/omap/omap_hsmmc.0/by-name/boot;!BLOCK=auto;!g' "${AK3}/anykernel.sh"
	sed -i 's/IS_SLOT_DEVICE=0;/is_slot_device=auto;/g' "${AK3}/anykernel.sh"

	cp "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${AK3}/" \
		|| die "kernel image missing at ${BOOT_OUT}/${KERNEL_IMAGE_NAME}"
	if is_true "${CHECK_DTBO_IS_OK:-false}"; then
		cp "${BOOT_OUT}/dtbo.img" "${AK3}/"
	fi

	# Bundle the SUSFS LKM next to the kernel so one zip carries everything.
	if is_true "${ENABLE_SUSFS:-false}"; then
		[ -f "${SUSFS_KO:-}" ] || die "SUSFS_KO not set; build the module first (scripts/susfs.sh)"
		cp "${SUSFS_KO}" "${AK3}/susfs_guard_lkm.ko"
		cp "${REPO_ROOT}/anykernel/susfs-load.sh" "${AK3}/susfs-load.sh"

		# AnyKernel3 extracts the zip root into /tmp/anykernel and runs in
		# recovery with /data mounted; copy the module where ksud can load it.
		cat >>"${AK3}/anykernel.sh" <<'AK3EOF'

# ---- GKI_KernelSU-Next_SUSFS: stage the SUSFS LKM ---------------------------
ui_print "- Staging susfs_guard_lkm.ko"
mkdir -p /data/adb/ksu
if [ -f /tmp/anykernel/susfs_guard_lkm.ko ]; then
  cp -f /tmp/anykernel/susfs_guard_lkm.ko /data/adb/ksu/susfs_guard_lkm.ko
  chmod 0644 /data/adb/ksu/susfs_guard_lkm.ko
  chown root:root /data/adb/ksu/susfs_guard_lkm.ko 2>/dev/null || true
  chcon u:object_r:system_data_file:s0 /data/adb/ksu/susfs_guard_lkm.ko 2>/dev/null || true
  ui_print "- Copied to /data/adb/ksu/susfs_guard_lkm.ko"
else
  ui_print "! susfs_guard_lkm.ko missing from this zip"
fi
# ---- end staging -------------------------------------------------------------
AK3EOF

		cat >"${AK3}/README.txt" <<EOF
GKI kernel with KernelSU-Next + SUSFS ${SUSFS_VERSION:-2.3.x}
Kernel release: ${KERNEL_RELEASE:-unknown}

How to flash:
  1. Flash this zip from a custom recovery, or open KernelFlasher and flash
     the zip directly (it repacks your stock boot).
  2. Reboot. Open the KernelSU-Next manager; the kernel should be reported
     and root should work.

How to enable SUSFS at runtime (once per boot):
  adb shell su -c "ksud insmod /data/adb/ksu/susfs_guard_lkm.ko"

  The zip already staged the module at /data/adb/ksu/susfs_guard_lkm.ko.
  Verify with:  adb shell su -c "ls /proc/susfs_kstat"
  (the file only exists while the module is loaded)

A convenience wrapper is bundled: sh /sdcard/susfs-load.sh [ko-path]
EOF
	fi

	rm -rf "${AK3}/.git" "${AK3}/.github" "${AK3}/README.md" "${AK3}/LICENSE"
	ok "AnyKernel3 package assembled"
	endgroup
}

# Boot image repacking is opt-in (BUILD_BOOT_IMG=true); it needs an unpack/
# repack tool. We shell out to the widely-used mkbootimg scripts and keep the
# step honest about what it needs.
make_boot_image() {
	is_true "${BUILD_BOOT_IMG:-false}" || return 0
	group "Repacking boot image"

	local tools="${WORKSPACE}/tools"
	[ -f "${tools}/unpack_bootimg.py" ] || [ -f "${tools}/mkbootimg.py" ] \
		|| die "mkbootimg tools not found at ${tools} (fetch them yourself:
       git clone https://github.com/cclaude77/mkbootimg_tools ${tools})"

	fetch "${SOURCE_BOOT_IMAGE:?SOURCE_BOOT_IMAGE required}" "${WORKSPACE}/boot-source.img"

	local fmt
	cd "$WORKSPACE"
	fmt=$(python3 "${tools}/unpack_bootimg.py" --boot_img boot-source.img --format mkbootimg) \
		|| die "failed to read the source boot image"
	info "source boot image args: ${fmt}"

	python3 "${tools}/unpack_bootimg.py" --boot_img boot-source.img >/dev/null \
		|| die "failed to unpack the source boot image"

	cp "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${WORKSPACE}/out/kernel" \
		|| die "could not stage the new kernel into the unpacked ramdisk"

	# shellcheck disable=SC2086
	python3 "${tools}/mkbootimg.py" $fmt -o boot.img || die "mkbootimg failed"
	[ -s "${WORKSPACE}/boot.img" ] || die "boot.img was not produced"

	ok "boot.img built ($(du -h "${WORKSPACE}/boot.img" | cut -f1))"
	export_env MAKE_BOOT_IMAGE_IS_OK true
	endgroup
}

write_summary() {
	summary ""
	summary "### Build artifacts"
	summary ""
	summary "| Artifact | Size |"
	summary "| --- | --- |"
	local f
	for f in "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${BOOT_OUT}/dtbo.img" "${WORKSPACE}/boot.img" \
	         "${SUSFS_KO:-}"; do
		[ -f "$f" ] && summary "| \`$(basename "$f")\` | $(du -h "$f" | cut -f1) |"
	done
	[ -d "$AK3" ] && summary "| \`AnyKernel3\` (flashable zip) | $(du -sh "$AK3" | cut -f1) |"
	summary ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		anykernel3) make_anykernel3 ;;
		bootimg)    make_boot_image ;;
		all)       make_anykernel3; make_boot_image; write_summary ;;
		*) die "unknown package step '$1'" ;;
	esac
fi
