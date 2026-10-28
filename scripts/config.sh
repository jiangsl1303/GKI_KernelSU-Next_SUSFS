#!/usr/bin/env bash
# Resolve configuration: load the profile, apply workflow-input overrides,
# derive defaults, and sanity-check the result. Run before everything else.
#
# Precedence: built-in defaults < profile file < IN_* overrides (workflow form).

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The config file to use: CONFIG_ENV env var (set by the workflow input), or
# the repo-root config.env pointer file.
PROFILE=${CONFIG_ENV:-config.env}

[ -f "$PROFILE" ] || die "config file not found: ${PROFILE} (available profiles: $(ls config/*.env 2>/dev/null | tr '\n' ' '))"

# A pointer file (root config.env) just names another profile; follow it.
if grep -qE '^[[:space:]]*CONFIG_ENV[[:space:]]*=' "$PROFILE"; then
	TARGET=$(sed -nE 's/^[[:space:]]*CONFIG_ENV[[:space:]]*=[[:space:]]*//p' "$PROFILE" | tr -d '"'"'"' ' | head -n1)
	[ -n "$TARGET" ] && [ "$TARGET" != "$PROFILE" ] && [ -f "$TARGET" ] && PROFILE=$TARGET
fi

group "Loading configuration"

# Profiles are read with a tiny parser instead of `source`, because values
# use the KernelSU-Action convention `KEY:value` (an append-only flag block)
# which is not valid shell. Rules: '#' comments, blank lines ignored,
# `KEY=value` and `KEY:value` both assign (the ':' form is convention for
# optional make-flag blocks and behaves identically here).
load_profile() {
	local file=$1 line key val
	while IFS= read -r line || [ -n "$line" ]; do
		line=${line%%$'\r'}
		case "$line" in
			''|'#'*) continue ;;
		esac
		line="${line#"${line%%[![:space:]]*}"}"   # ltrim
		line="${line%"${line##*[![:space:]]}"}"   # rtrim (also drops CRLF's \r)
		[ -n "$line" ] || continue
		# The separator is the FIRST ':' for KEY:value lines, else the first
		# '=' for plain KEY=value. Values may themselves contain '='
		# (make flags like KCFLAGS=-Wno-error=...). Pure bash, no subprocesses.
		if [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*: ]]; then
			key=${line%%:*}; val=${line#*:}
		elif [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
			key=${line%%=*}; val=${line#*=}
		else
			continue
		fi
		key="${key%%[[:space:]]}"
		val="${val#"${val%%[![:space:]]*}"}"        # ltrim the value
		val="${val%"${val##*[![:space:]]}"}"        # rtrim the value
		# strip one layer of surrounding quotes, keep the rest literal
		case "$val" in
			\"*\"|\'*\') val=${val:1:${#val}-2} ;;
		esac
		export "${key}=${val}"
		# Persist to $GITHUB_ENV so the variable survives into later
		# workflow steps (export alone only lives within this shell).
		if [ -n "${GITHUB_ENV:-}" ] && [ -w "${GITHUB_ENV}" ]; then
			printf '%s=%s\n' "$key" "$val" >>"$GITHUB_ENV"
		fi
	done <"$file"
}

load_profile "$PROFILE"
ok "profile: ${PROFILE}"
# --------------------------------------------------------- input overrides ---
# The workflow form passes values through IN_* env vars. "config" means "keep
# whatever the profile says".

if [ "${IN_KSU_VARIANT:-config}" != "config" ]; then
	KSU_VARIANT=$IN_KSU_VARIANT
fi
if [ -n "${IN_KSU_REF+x}" ] && [ "$IN_KSU_REF" != "config" ]; then
	KSU_REF=$IN_KSU_REF
fi
if [ "${IN_KSU_HOOK_MODE:-config}" != "config" ]; then
	KSU_HOOK_MODE=$IN_KSU_HOOK_MODE
fi
if [ "${IN_ENABLE_SUSFS:-config}" != "config" ]; then
	ENABLE_SUSFS=$IN_ENABLE_SUSFS
fi
if [ "${IN_FORCE_KALLSYMS_ALL:-config}" != "config" ]; then
	FORCE_KALLSYMS_ALL=$IN_FORCE_KALLSYMS_ALL
fi
if [ "${IN_EXTRA_DEFCONFIG:-}" != "" ]; then
	# append to the profile value so both survive
	EXTRA_DEFCONFIG="${EXTRA_DEFCONFIG:-} ${IN_EXTRA_DEFCONFIG}"
fi

# ------------------------------------------------------- derived defaults ----

: "${KERNEL_SOURCE:?KERNEL_SOURCE not set in ${PROFILE}}"
: "${KERNEL_SOURCE_BRANCH:=main}"
: "${KERNEL_CONFIG:=defconfig}"
: "${KERNEL_IMAGE_NAME:=Image}"
: "${ARCH:=arm64}"
: "${KSU_VARIANT:=kernelsu-next}"
: "${KSU_HOOK_MODE:=auto}"

# Derive a device label from the config filename when KERNEL_NAME is empty.
if [ -z "${KERNEL_NAME:-}" ]; then
	KERNEL_NAME=$(basename "${PROFILE%.env}")
	KERNEL_NAME=${KERNEL_NAME//[^a-zA-Z0-9._-]/_}
fi
export_env DEVICE "$KERNEL_NAME"

# Resolve SUSFS switch: SUSFS is a property of KernelSU-Next here, so it is
# only meaningful when that variant is selected.
if [ "$KSU_VARIANT" != "kernelsu-next" ]; then
	ENABLE_SUSFS=false
	warn "SUSFS 2.3 LKM is only shipped by KernelSU-Next; disabling for ${KSU_VARIANT}"
fi

# Kernel release suffix used in artifact names.
LOCALVERSION=""
if is_true "${ADD_LOCALVERSION_TO_FILENAME:-false}" && [ -n "${KERNEL_NAME_SUFFIX:-}" ]; then
	LOCALVERSION="$KERNEL_NAME_SUFFIX"
fi
export_env LOCALVERSION "$LOCALVERSION"

BUILD_TIME=$(date -u +%Y%m%d-%H%M%S)
export_env BUILD_TIME "$BUILD_TIME"

export_env PROFILE "$PROFILE"

# Persist all profile + derived variables to $GITHUB_ENV so later workflow
# steps (toolchain.sh, source.sh, etc.) can see them. load_profile and the
# ${VAR:=default} assignments above only export within this shell process.
for _v in \
	KERNEL_SOURCE KERNEL_SOURCE_BRANCH KERNEL_CONFIG KERNEL_IMAGE_NAME \
	ARCH KERNEL_NAME KERNEL_NAME_SUFFIX ADD_LOCALVERSION_TO_FILENAME \
	CLANG_BRANCH CLANG_VERSION USE_LLVM USE_CUSTOM_CLANG CUSTOM_CLANG_SOURCE \
	EXTRA_CMDS CUSTOM_CMDS \
	KSU_VARIANT KSU_REF KSU_HOOK_MODE \
	ENABLE_SUSFS FORCE_KALLSYMS_ALL REMOVE_DIRTY_STRING \
	BUILD_MODULES REMOVE_PROTECTED_EXPORTS ADD_OVERLAYFS_CONFIG \
	EXTRA_DEFCONFIG DISABLE_CC_WERROR DISABLE_LTO \
	NEED_DTBO BUILD_BOOT_IMG SOURCE_BOOT_IMAGE UPLOAD_RAW_IMAGES \
	ENABLE_CCACHE REMOVE_UNUSED_PACKAGES \
; do
	if [ -n "${!_v+x}" ]; then
		export_env "$_v" "${!_v}"
	fi
done
unset _v

# ------------------------------------------------------------ validation ----

case "$KSU_VARIANT" in
	kernelsu-next | none) ;;
	*) die "unknown KSU_VARIANT '${KSU_VARIANT}' (this repo supports: kernelsu-next, none)" ;;
esac

case "$ARCH" in
	arm64 | x86_64) ;;
	*) die "unsupported ARCH '${ARCH}' (arm64 | x86_64)" ;;
esac

ok "kernel: ${KERNEL_SOURCE} @ ${KERNEL_SOURCE_BRANCH}"
ok "defconfig: ${KERNEL_CONFIG}  image: ${KERNEL_IMAGE_NAME}  arch: ${ARCH}"
ok "kernelsu: ${KSU_VARIANT} @ ${KSU_REF:-<setup.sh default>}  susfs: ${ENABLE_SUSFS:-false}"

summary "## Build configuration"
summary ""
summary "| Setting | Value |"
summary "| --- | --- |"
summary "| Profile | \`${PROFILE}\` |"
summary "| Kernel source | \`${KERNEL_SOURCE}\` @ \`${KERNEL_SOURCE_BRANCH}\` |"
summary "| KernelSU | \`${KSU_VARIANT}\` @ \`${KSU_REF:-default}\` |"
summary "| SUSFS | \`${ENABLE_SUSFS:-false}\` |"

endgroup
