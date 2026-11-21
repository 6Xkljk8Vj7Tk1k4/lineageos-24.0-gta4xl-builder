#!/bin/bash
# tools/kernel-romtc-build.sh KSRC OUT [TARGET...] - builds a kernel tree the way the LineageOS build
# does (vendor/lineage/config/BoardConfigKernel.mk, build/tasks/kernel.mk), with the toolchain and
# the host tools of the Android tree in SRC (default src), but without building the ROM:
# AOSP clang, its make/flex/bison/dtc, HOSTCFLAGS with the glibc 2.17 sysroot, LLVM=1 LLVM_IAS=1,
# and the configuration made as kernel.mk makes it (defconfig copied to .config, olddefconfig).
# A kernel that only builds with the distribution's clang fails the ROM build hours in; this
# takes two minutes. The Android tree is only read (prebuilts and out/host/linux-x86/bin/dtc).
#   tools/kernel-romtc-build.sh kernel/android_kernel_samsung_gta4xl build_output/kernel-romtc   # Image dtbs
#   CLANG=clang-r584948 tools/kernel-romtc-build.sh kernel/android_kernel_samsung_gta4xl /tmp/o Image
# Variables: SRC, CLANG (directory under prebuilts/clang/host/linux-x86; default: the one the
# last ROM build used, clang-r596125), DEFCONFIG, JOBS.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 2 ] || { sed -n '2,14p' "$0"; exit 1; }
KSRC=$(realpath "$1"); OUT=$(realpath -m "$2"); shift 2
[ $# -gt 0 ] || set -- Image dtbs
T=$(realpath "${SRC:-src}")
CL="$T/prebuilts/clang/host/linux-x86/${CLANG:-clang-r596125}"
DEF="${DEFCONFIG:-exynos9611-gta4xl_defconfig}"
SYS="--sysroot=$T/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/sysroot"
KBT="$T/prebuilts/kernel-build-tools/linux-x86"
BT="$T/prebuilts/build-tools/linux-x86/bin"
for f in "$CL/bin/clang" "$BT/make" "$T/out/host/linux-x86/bin/dtc" "$KSRC/arch/arm64/configs/$DEF"; do
    [ -e "$f" ] || { echo "!!! missing $f"; exit 1; }
done
export PATH="$T/out/host/linux-x86/bin:$T/prebuilts/tools-lineage/linux-x86/bin:$BT:$CL/bin:$PATH"
export LD_LIBRARY_PATH="$CL/lib64:${LD_LIBRARY_PATH:-}" HIP_PATH=none
export PERL5LIB="$T/prebuilts/tools-lineage/common/perl-base" BISON_PKGDATADIR="$T/prebuilts/build-tools/common/bison"
mk() {
    "$BT/make" -j"${JOBS:-$(nproc)}" \
        HOSTCFLAGS="$SYS -I$KBT/include" \
        HOSTLDFLAGS="$SYS -Wl,-rpath,$KBT/lib64 -L $KBT/lib64 -fuse-ld=lld --rtlib=compiler-rt" \
        LLVM=1 LLVM_IAS=1 LZ4="$KBT/bin/lz4" LEX="$BT/flex" YACC="$BT/bison" M4="$BT/m4" \
        PAHOLE="$KBT/bin/pahole" LIBCLANG_PATH="$CL/lib" TARGET_BOARD_PLATFORM=universal9611 \
        DTC_EXT="$T/out/host/linux-x86/bin/dtc" \
        -C "$KSRC" O="$OUT" ARCH=arm64 CLANG_TRIPLE=aarch64-linux-gnu- CC=clang LD=ld.lld "$@"
}
mkdir -p "$OUT"
echo ">>> $(git -C "$KSRC" describe --always --dirty 2>/dev/null) | $DEF | $("$CL/bin/clang" --version | head -1 | cut -c1-70) | $*"
cp "$KSRC/arch/arm64/configs/$DEF" "$OUT/.config"
mk olddefconfig > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; echo "!!! olddefconfig failed"; exit 1; }
if mk "$@" >> "$OUT/build.log" 2>&1; then
    echo ">>> OK: $(ls -la "$OUT/arch/arm64/boot/Image" 2>/dev/null | awk '{print $5, $NF}')  warnings: $(grep -c 'warning:' "$OUT/build.log" || true)  (log: $OUT/build.log)"
else
    grep -E 'error:|Error [0-9]|undefined' "$OUT/build.log" | head -30
    echo "!!! build failed (log: $OUT/build.log)"; exit 1
fi
