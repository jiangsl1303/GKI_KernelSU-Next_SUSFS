#!/usr/bin/env bash
# Shared helpers for the GKI KernelSU-Next + SUSFS build scripts.
# Sourced by every scripts/*.sh; never executed directly.
#
# Derived from the helper set of xiaoleGun/KernelSU_Action (Apache-2.0), with
# additions for the KernelSU-Next SUSFS LKM (kallsyms guard, module build).

set -euo pipefail

# bash 4+ required (associative arrays, ${!var} indirection).
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
	printf '[x] bash 4 or newer is required (found %s at %s).\n' \
		"${BASH_VERSION:-unknown}" "${BASH:-bash}" >&2
	printf '    On macOS: brew install bash, then run with /opt/homebrew/bin/bash\n' >&2
	exit 1
fi

# ---------------------------------------------------------------- logging ---

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	_C_RED=$'\033[31m'; _C_GRN=$'\033[32m'; _C_YEL=$'\033[33m'
	_C_BLU=$'\033[34m'; _C_DIM=$'\033[2m'; _C_RST=$'\033[0m'
else
	_C_RED=''; _C_GRN=''; _C_YEL=''; _C_BLU=''; _C_DIM=''; _C_RST=''
fi

info() { printf '%s[*]%s %s\n' "$_C_BLU" "$_C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$_C_GRN" "$_C_RST" "$*"; }
warn() {
	printf '%s[!]%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2
	[ -n "${GITHUB_ACTIONS:-}" ] && printf '::warning::%s\n' "$*" || true
}
debug() { [ -n "${RUNNER_DEBUG:-}" ] && printf '%s[d] %s%s\n' "$_C_DIM" "$*" "$_C_RST" >&2 || true; }

die() {
	printf '%s[x]%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2
	[ -n "${GITHUB_ACTIONS:-}" ] && printf '::error::%s\n' "$*" || true
	exit 1
}

# group <title> -- collapsible section in the Actions log
group() {
	if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::group::%s\n' "$*"; else info "$*"; fi
}
endgroup() {
	if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::endgroup::\n'; fi
}

# ------------------------------------------------- GitHub Actions plumbing ---

# export_env KEY VALUE -- set for this shell *and* persist to later steps.
export_env() {
	local key=$1 val=${2-}
	export "$key=$val"
	if [ -n "${GITHUB_ENV:-}" ] && [ -w "${GITHUB_ENV}" ]; then
		{
			printf '%s<<__GHEOF_%s__\n' "$key" "$key"
			printf '%s\n' "$val"
			printf '__GHEOF_%s__\n' "$key"
		} >>"$GITHUB_ENV"
	fi
}

# summary <markdown...> -- append to the run's job summary (no-op locally).
summary() {
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -w "${GITHUB_STEP_SUMMARY}" ]; then
		printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
	fi
}

# ------------------------------------------------------------ true / false ---

is_true() {
	case "$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
	in
		true | yes | y | on | 1) return 0 ;;
		*) return 1 ;;
	esac
}

# ------------------------------------------------------------------ retry ---

retry() {
	local attempts=$1; shift
	local n=1 delay=5
	until "$@"; do
		if [ "$n" -ge "$attempts" ]; then
			warn "command failed after ${attempts} attempts: $*"
			return 1
		fi
		warn "attempt ${n}/${attempts} failed, retrying in ${delay}s: $*"
		sleep "$delay"
		n=$((n + 1)); delay=$((delay * 2))
		[ "$delay" -gt 60 ] && delay=60
	done
	return 0
}

# ------------------------------------------------------------- downloading ---

fetch() {
	local url=$1 dest=$2
	info "fetching ${url}"
	retry 4 curl -fsSL --connect-timeout 30 --retry 3 --retry-delay 3 -o "$dest" "$url" \
		|| die "failed to download ${url}"
	[ -s "$dest" ] || die "downloaded file is empty: ${url}"
}

fetch_stdout() {
	retry 4 curl -fsSL --connect-timeout 30 "$1"
}

extract_archive() {
	local file=$1 dest=$2
	mkdir -p "$dest"
	case "$file" in
		*.tar.gz | *.tgz)  tar -C "$dest" -xzf "$file" ;;
		*.tar.xz)          tar -C "$dest" -xJf "$file" ;;
		*.tar.zst)         tar -C "$dest" --zstd -xf "$file" ;;
		*.tar.bz2)         tar -C "$dest" -xjf "$file" ;;
		*.tar)             tar -C "$dest" -xf  "$file" ;;
		*.zip)             unzip -qo "$file" -d "$dest" ;;
		*) die "don't know how to extract ${file}" ;;
	esac
}

# ---------------------------------------------------------------- git refs ---

# ref_exists REPO_URL REF -- does this branch or tag actually exist?
#
# The single most important correctness check in this repo: every KernelSU
# variant's setup.sh ends its checkout with
#     git checkout "$1" ... || echo "[-] Checkout default branch"
# so an invalid ref does NOT fail the script -- it silently leaves the tree on
# the default branch. A build asking for KSN's 'dev' branch and typo-ing
# 'dev ' would quietly produce a kernel without SUSFS. Always validate first.
ref_exists() {
	local repo=$1 ref=$2
	[ -n "$ref" ] || return 1
	if git ls-remote --exit-code --heads --tags "$repo" "$ref" >/dev/null 2>&1; then
		return 0
	fi
	# Fall back to a raw commit-SHA lookup, which ls-remote cannot resolve.
	if printf '%s' "$ref" | grep -qE '^[0-9a-f]{7,40}$'; then
		return 0
	fi
	return 1
}

# ------------------------------------------------------------- Kconfig I/O ---
#
# Idempotent defconfig editing: setting an option twice leaves one line.

kconf_set() {
	local file=$1 key=$2 val=$3
	case "$key" in CONFIG_*) ;; *) key="CONFIG_${key}" ;; esac
	[ -f "$file" ] || die "defconfig not found: ${file}"
	sed -i -E "\%^[[:space:]]*(# )?${key}[[:space:]]*(=| is not set)%d" "$file"
	if [ "$val" = "n" ]; then
		printf '# %s is not set\n' "$key" >>"$file"
	else
		printf '%s=%s\n' "$key" "$val" >>"$file"
	fi
	debug "kconfig: ${key}=${val}"
}

kconf_enable()  { kconf_set "$1" "$2" y; }
kconf_disable() { kconf_set "$1" "$2" n; }

kconf_get() {
	local file=$1 key=$2
	case "$key" in CONFIG_*) ;; *) key="CONFIG_${key}" ;; esac
	sed -nE "s%^[[:space:]]*${key}=(.*)$%\1%p" "$file" | tail -n1
}

kconf_set_many() {
	local file=$1; shift
	local kv
	for kv in "$@"; do
		[ -n "$kv" ] || continue
		kconf_set "$file" "${kv%%=*}" "${kv#*=}"
	done
}

# --------------------------------------------------------------- patching ---

apply_patch() {
	local patch=$1 strip=${2:-1}
	[ -f "$patch" ] || die "patch not found: ${patch}"
	if patch -p"$strip" --dry-run --force --silent <"$patch" >/dev/null 2>&1; then
		patch -p"$strip" --force --no-backup-if-mismatch <"$patch" >/dev/null
		ok "applied $(basename "$patch")"
		return 0
	fi
	if patch -p"$strip" -R --dry-run --force --silent <"$patch" >/dev/null 2>&1; then
		warn "$(basename "$patch") is already applied, skipping"
		return 0
	fi
	if patch -p"$strip" --dry-run --force --fuzz=3 --silent <"$patch" >/dev/null 2>&1; then
		patch -p"$strip" --force --fuzz=3 --no-backup-if-mismatch <"$patch" >/dev/null
		warn "$(basename "$patch") applied with fuzz; verify the result"
		return 0
	fi
	warn "failed to apply $(basename "$patch")"
	return 1
}

# --------------------------------------------------------------- versions ---

ver_ge() {
	[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

kernel_version() {
	local dir=${1:-.} v p
	v=$(sed -nE 's/^VERSION[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "${dir}/Makefile" | head -n1)
	p=$(sed -nE 's/^PATCHLEVEL[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "${dir}/Makefile" | head -n1)
	[ -n "$v" ] && [ -n "$p" ] || return 1
	printf '%s.%s' "$v" "$p"
}

# ------------------------------------------------ KernelSU-Next SUSFS bits ---

# ksnext_root DIR -- KernelSU-Next clones itself as <dir>/KernelSU-Next and
# symlinks drivers/kernelsu -> KernelSU-Next/kernel. GKI 2.0 trees check out
# under common/, older trees directly.
ksnext_root() { printf '%s/KernelSU-Next' "$1"; }

# find_ko DIR -- locate the built SUSFS LKM, searching the susfs source dir
# and (for trees that redirect output) the kernel out dir.
find_ko() {
	local dir=$1 f
	for f in "${dir}/kernel/susfs/susfs_guard_lkm.ko" \
	         "${dir}/kernel/susfs/"*.ko \
	         "${dir}/susfs_guard_lkm.ko"; do
		[ -f "$f" ] && { printf '%s' "$f"; return 0; }
	done
	return 1
}
