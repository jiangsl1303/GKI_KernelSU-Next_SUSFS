# patches/

Extra kernel patches live here. Files are applied by the build in this order:

1. Numbered files `NN_*.patch` in lexicographic order, `patch -p1` relative to
   the kernel root, after KernelSU-Next is installed and before the build.

Convention borrowed from the SUSFS upstream layout:

    50_add_susfs_in_kernel-6.6.patch   # add support for a kernel not covered upstream

Already-applied patches are skipped; a patch that genuinely does not fit logs
a warning and continues so the rest of the build still runs — check the log
for `[!]` lines. Delete this README if you keep patches yourself.

Note: with KernelSU-Next `dev`, SUSFS 2.3 ships in-tree as an LKM, so you do
NOT need the classic susfs4ksu patch stack (`50_add_susfs_in_kernel-*.patch`,
`kernel_patches/...`) here. Those exist only when you bring SUSFS to a tree
that does not already contain it.
