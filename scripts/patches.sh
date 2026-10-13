#!/usr/bin/env bash
# Apply extra kernel patches from patches/ (NN_*.patch in lexicographic order).
#
# Runs after KernelSU-Next is installed (so patches can tack onto its tree)
# and before the build. Idempotent: already-applied patches are skipped;
# a patch that genuinely does not fit warns but does not abort the build, so a
# half-failing custom patch cannot block everything else.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PATCH_DIR="${REPO_ROOT}/patches"

group "Applying kernel patches"

shopt -s nullglob
found=0
for patch in "$PATCH_DIR"/NN_*.patch; do
	found=1
	(
		cd "$KERNEL_DIR"
		apply_patch "$patch" || exit 1
	)
done

[ "$found" = "1" ] || info "no patches in ${PATCH_DIR} (NN_*.patch), nothing to do"
ok "patch stage complete"
endgroup
