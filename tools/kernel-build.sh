#!/bin/bash
# tools/kernel-build.sh [BRANCH|COMMIT] - builds the gta4xl kernel fork on its own (pure LLVM,
# integrated assembler, the fork's defconfig) in a small clang/lld container. Host-side, no
# Android tree needed; takes a few minutes instead of a ROM build.
# Source: kernel/android_kernel_samsung_gta4xl (a clone of the fork, gitignored):
#   git clone -b gta4xl-4.19 https://github.com/6Xkljk8Vj7Tk1k4/android_kernel_samsung_gta4xl.git \
#       kernel/android_kernel_samsung_gta4xl
# Output: kernel/android_kernel_samsung_gta4xl/out/arch/arm64/boot/Image (and out/build.log).
# Test it on the tablet with tools/kernel-flash.sh; tools/kernel-cve-check.sh reads out/.
# The compiler is the distribution's clang, not the one the ROM build uses: a kernel that builds
# here can still fail there. tools/kernel-romtc-build.sh builds with the ROM's toolchain from a
# synced tree; run it before a ROM build with a changed kernel.
# After a change of the configuration delete out/ first: `make clean` does not work in this tree,
# and objects of the old configuration would stay.
#
# The container image (kbuild-llvm: Ubuntu 26.04 + clang/lld/llvm) is built on first use.
# Do not run it next to a ROM build on a machine with little RAM.
# Never enable CONFIG_DEBUG_INFO_BTF in this kernel (see CLAUDE.md): the build refuses it.
set -euo pipefail
cd "$(dirname "$0")/.."
KSRC="kernel/android_kernel_samsung_gta4xl"
DEFCONFIG="${DEFCONFIG:-exynos9611-gta4xl_defconfig}"
JOBS="${JOBS:-$(nproc)}"
IMG="kbuild-llvm"
[ -d "$KSRC/.git" ] || { echo "!!! No $KSRC - clone the fork first: git clone -b gta4xl-4.19 https://github.com/6Xkljk8Vj7Tk1k4/android_kernel_samsung_gta4xl.git $KSRC"; exit 1; }
if [ -n "${1:-}" ]; then git -C "$KSRC" checkout -q "$1"; fi
echo ">>> kernel: $(git -C "$KSRC" describe --always --dirty) ($(git -C "$KSRC" branch --show-current)) | $DEFCONFIG | -j$JOBS"
if ! podman image exists "$IMG"; then
    tmp=$(mktemp -d)
    cat > "$tmp/Containerfile" <<'EOF'
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    clang lld llvm make bc bison flex libssl-dev libelf-dev python3 \
    cpio kmod rsync git ca-certificates file xz-utils && rm -rf /var/lib/apt/lists/*
WORKDIR /src
EOF
    podman build -q -t "$IMG" "$tmp"; rm -rf "$tmp"
fi
# Rootless podman: root in the container is the host user, so out/ stays yours.
podman run --rm -v "$(pwd)/$KSRC:/src:Z" "$IMG" bash -c "
    set -e
    export ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu-
    make O=out $DEFCONFIG >/dev/null
    grep -q 'CONFIG_DEBUG_INFO_BTF=y' out/.config && { echo '!!! CONFIG_DEBUG_INFO_BTF is on - refusing'; exit 1; }
    rm -f out/arch/arm64/boot/Image
    make O=out -j$JOBS Image > out/build.log 2>&1 || { grep -E 'error:|Error ' out/build.log | head -20; echo '!!! kernel build failed (out/build.log)'; exit 1; }
    grep -E 'warning: .*(overflow|uninitialized|use-after)' out/build.log || true
    ls -la out/arch/arm64/boot/Image
"
echo ">>> OK: $KSRC/out/arch/arm64/boot/Image (log: $KSRC/out/build.log)"
