#!/bin/bash
# tools/kernel-flash.sh - tests a kernel on the tablet without building the ROM: puts the Image
# from tools/kernel-build.sh into the boot.img of the last ROM build in src/, computes vbmeta the
# way the ROM build does (algorithm NONE: the bootloader is unlocked) and writes both through
# root adb (Samsung has no fastboot). The first flash on an installed build backs up the boot and
# vbmeta partitions to build_output/kernel-flash/backup/<ro.build.date.utc>/ - one backup per
# installed build, because after an update the old vbmeta no longer matches system/vendor and
# restoring it would boot-loop.
#
#   tools/kernel-flash.sh pack [Image]    # only build_output/kernel-flash/{boot,vbmeta}-new.img
#   tools/kernel-flash.sh flash [Image]   # pack + write; Image defaults to kernel/.../out/arch/arm64/boot/Image
#   tools/kernel-flash.sh restore         # writes the backup for the installed build back (works
#                                         # from the recovery too, when the new kernel does not boot)
#   tools/kernel-flash.sh check           # checklist after the boot (sysctls, interfaces, HALs, dmesg, crashes)
#
# Needs root adb: Developer options -> Rooted debugging (the recovery's adb is root anyway).
# The tablet must run exactly the build in src/out: the vbmeta computed here carries that build's
# system/vendor descriptors. The recovery partition keeps the build's own kernel, so a kernel
# that does not boot leaves the recovery working; a 4.19 kernel that panics in its first two
# minutes or does not come up restarts into the recovery by itself. Environment: SERIAL (adb serial; default: the only attached device,
# which must be a gta4xl), SRC (tree with out/, default src).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${SRC:-src}"
KSRC="kernel/android_kernel_samsung_gta4xl"
OUT="$SRC/out/target/product/gta4xl"
WORK="build_output/kernel-flash"
BK="$WORK/backup"
# -B: no __pycache__ in the tree (a changed glob there costs a full Soong analysis)
AVB="python3 -B $SRC/external/avb/avbtool.py"
MKBOOT="python3 -B $SRC/system/tools/mkbootimg/mkbootimg.py"
UNPACK="python3 -B $SRC/system/tools/mkbootimg/unpack_bootimg.py"
BOOT_PART_SIZE=61865984   # BOARD_BOOTIMAGE_PARTITION_SIZE = blockdev --getsize64 /dev/block/by-name/boot

pick_device() {   # $SERIAL, or the only device adb sees (in Android or in the recovery)
    if [ -z "${SERIAL:-}" ]; then
        local list
        list=$(adb devices | awk 'NR > 1 && ($2 == "device" || $2 == "recovery") {print $1}')
        case "$(printf '%s\n' "$list" | grep -c . || true)" in
            1) SERIAL=$list ;;
            0) echo "!!! adb sees no device (USB debugging on, this computer allowed?)"; exit 1 ;;
            *) echo "!!! Several adb devices ($(echo $list)) - choose one with SERIAL=<serial>"; exit 1 ;;
        esac
    fi
    local dev; dev=$(adb -s "$SERIAL" shell getprop ro.product.device 2>/dev/null | tr -d '\r' || true)
    [ "$dev" = gta4xl ] || { echo "!!! $SERIAL is '${dev:-not reachable}', not a gta4xl - stopping"; exit 1; }
}
a() { adb -s "$SERIAL" shell "$@"; }
dev_build() { a getprop ro.build.date.utc | tr -d '\r'; }
out_build() { sed -n 's/^ro.build.date.utc=//p' "$OUT/system/build.prop"; }

root_adb() {
    pick_device
    adb -s "$SERIAL" root >/dev/null 2>&1 || true
    # adbd restarts as root; `wait-for-device` would never return in the recovery (state "recovery")
    local i
    for i in $(seq 1 30); do
        case "$(adb -s "$SERIAL" get-state 2>/dev/null)" in device|recovery) break ;; esac
        sleep 1
    done
    [ "$(a id -u | tr -d '\r')" = 0 ] || { echo "!!! adb is not root (Developer options -> Rooted debugging)"; exit 1; }
}

backup() {   # once per installed build, at its first flash
    local d; d="$BK/$(dev_build)"
    [ -s "$d/boot.img" ] && return
    mkdir -p "$d"
    echo ">>> Backing up the boot and vbmeta partitions -> $d/"
    a 'mkdir -p /data/local/tmp/kf; dd if=/dev/block/by-name/boot of=/data/local/tmp/kf/boot.img bs=4M 2>/dev/null; dd if=/dev/block/by-name/vbmeta of=/data/local/tmp/kf/vbmeta.img bs=64k 2>/dev/null'
    adb -s "$SERIAL" pull /data/local/tmp/kf/boot.img /data/local/tmp/kf/vbmeta.img "$d/" >/dev/null
    a 'rm -rf /data/local/tmp/kf'
    sha256sum "$d"/*.img
}

write_parts() {   # $1 boot.img  $2 vbmeta.img
    adb -s "$SERIAL" push "$1" /data/local/tmp/kf-boot.img >/dev/null
    adb -s "$SERIAL" push "$2" /data/local/tmp/kf-vbmeta.img >/dev/null
    local want have
    want=$(sha256sum "$1" | cut -c1-64)
    have=$(a 'sha256sum /data/local/tmp/kf-boot.img' | cut -c1-64)
    [ "$want" = "$have" ] || { echo "!!! boot.img arrived damaged"; exit 1; }
    a 'dd if=/data/local/tmp/kf-boot.img of=/dev/block/by-name/boot bs=4M conv=fsync 2>/dev/null; dd if=/dev/zero of=/dev/block/by-name/vbmeta bs=64k count=1 2>/dev/null; dd if=/data/local/tmp/kf-vbmeta.img of=/dev/block/by-name/vbmeta bs=64k conv=fsync 2>/dev/null; sync; rm -f /data/local/tmp/kf-boot.img /data/local/tmp/kf-vbmeta.img'
    echo ">>> Written, rebooting"
    adb -s "$SERIAL" reboot
}

case "${1:-}" in
pack|flash)
    IMG="${2:-$KSRC/out/arch/arm64/boot/Image}"
    [ -s "$IMG" ] || { echo "!!! No $IMG (tools/kernel-build.sh)"; exit 1; }
    [ -s "$OUT/boot.img" ] || { echo "!!! No $OUT/boot.img - this needs a ROM build in $SRC"; exit 1; }
    mkdir -p "$WORK"; rm -rf "$WORK/unpacked"
    # Image parameters from the ROM's boot.img (header v2, offsets, os_version/patch level).
    ARGS=$($UNPACK --boot_img "$OUT/boot.img" --out "$WORK/unpacked" --format mkbootimg)
    ARGS=${ARGS//--kernel $WORK\/unpacked\/kernel/--kernel $IMG}
    eval $MKBOOT $ARGS --output "$WORK/boot-new.img"
    # AVB footer as in build/make (salt = sha256 of the kernel, the same properties).
    $AVB add_hash_footer --image "$WORK/boot-new.img" --partition_name boot --partition_size $BOOT_PART_SIZE \
        --algorithm NONE --salt "$(sha256sum "$IMG" | cut -d' ' -f1)" \
        --prop com.android.build.boot.os_version:"$(grep -oE 'os_version 0x[0-9a-f]+|--os_version [0-9.]+' <<<"$ARGS" | awk '{print $2}' | cut -d. -f1)" \
        --prop com.android.build.boot.fingerprint:"$(cat "$OUT/build_fingerprint-lineage_gta4xl.txt")"
    VB=""
    for p in boot-new; do VB="$VB --include_descriptors_from_image $WORK/$p.img"; done
    for p in system vendor product system_ext odm dtbo; do VB="$VB --include_descriptors_from_image $OUT/$p.img"; done
    RB=$($AVB info_image --image "$OUT/vbmeta.img" | awk '/Rollback Index:/{print $3; exit}')
    $AVB make_vbmeta_image $VB --algorithm NONE --padding_size 4096 --rollback_index "$RB" --output "$WORK/vbmeta-new.img"
    echo ">>> $(strings -n 20 "$IMG" | grep -m1 -oE 'Linux version [^ ]+') -> $WORK/boot-new.img + vbmeta-new.img"
    [ "$1" = pack ] && exit 0
    root_adb
    # The vbmeta computed from the images in $SRC/out only fits exactly that build.
    [ "$(dev_build)" = "$(out_build)" ] || { echo "!!! The tablet runs build $(dev_build), $SRC/out has build $(out_build): the vbmeta would not match system/vendor. Install that build first."; exit 1; }
    backup; write_parts "$WORK/boot-new.img" "$WORK/vbmeta-new.img"
    echo ">>> After the boot: tools/kernel-flash.sh check ; if it does not boot: recovery (Power + Volume Up) -> tools/kernel-flash.sh restore"
    ;;
restore)
    root_adb
    d=$(dev_build)
    if [ -s "$BK/$d/boot.img" ]; then
        write_parts "$BK/$d/boot.img" "$BK/$d/vbmeta.img"
    elif [ "$d" = "$(out_build)" ]; then
        # the build's own images: boot is identical to the one in the zip, vbmeta has the same
        # digests (the zip only orders the property descriptors differently)
        write_parts "$OUT/boot.img" "$OUT/vbmeta.img"
    else
        echo "!!! No images for build $d (neither in $BK/$d/ nor in $SRC/out)"; exit 1
    fi
    ;;
check)
    root_adb
    ok() { [ "$1" = "$2" ] && echo "PASS $3 ($1)" || echo "FAIL $3 (is '$1', expected '$2')"; }
    echo "kernel: $(a uname -r | tr -d '\r')  uptime: $(a 'cut -d" " -f1 /proc/uptime' | tr -d '\r') s  boot.reason: $(a getprop sys.boot.reason | tr -d '\r')"
    ok "$(a getprop sys.boot_completed | tr -d '\r')" 1 boot_completed
    ok "$(a cat /proc/sys/kernel/dmesg_restrict | tr -d '\r')" 1 dmesg_restrict
    ok "$(a 'ls -d /sys/kernel/mm/ksm 2>/dev/null | wc -l' | tr -d '\r')" 0 no_ksm
    ok "$(a 'ip -o link | grep -cE "sit0|ip6tnl0|ip_vti0|ip6_vti0"' | tr -d '\r')" 0 no_tunnel_devs
    ok "$(a 'ip -o link | grep -c wlan0' | tr -d '\r')" 1 wlan0
    ok "$(a 'grep -c zram /proc/swaps' | tr -d '\r')" 1 zram_swap
    ok "$(a 'ls /sys/fs/bpf/netd_shared 2>/dev/null | wc -l | awk "{print (\$1>40)?\"ok\":\"few\"}"' | tr -d '\r')" ok bpf_maps
    for s in netd keystore2 surfaceflinger vendor.keymaster-4-0 vendor.gralloc-2-0 vendor.hwcomposer-3 vendor.camera.provider vendor.drm-widevine-hal-1-4 vendor.wifi_hal_legacy vendor.bluetooth-1-0; do
        ok "$(a getprop init.svc.$s | tr -d '\r')" running "$s"
    done
    ok "$(a 'dumpsys wifi 2>/dev/null | grep -m1 -oE "Wi-Fi is [a-z]+" | head -1' | tr -d '\r')" "Wi-Fi is enabled" wifi
    echo "wifi: $(a 'dumpsys wifi 2>/dev/null | grep -m1 -oE "Supplicant state: [A-Z]+" | head -1' | tr -d '\r')  bt: $(a settings get global bluetooth_on | tr -d '\r')"
    echo "dmesg WARNING/BUG/Oops/Call trace (known at every boot: 3 WARNING with their call traces, a96t3x6 device_create_file and rt5665 gpio_to_desc twice): $(a 'dmesg | grep -cE "WARNING: CPU|BUG:|Oops|Call trace"' | tr -d '\r')"
    a 'dmesg | grep -E "WARNING: CPU" | sed "s/.*at //" | sort | uniq -c'
    echo "avc denied: $(a 'dmesg | grep -c "avc: *denied"' | tr -d '\r')   crash: $(a 'logcat -d -b crash | grep -cE "FATAL|signal [0-9]"' | tr -d '\r')"
    a 'logcat -d | grep -wiE "ion|gralloc|mfc|omx" | grep -iE "fail|error|fatal" | grep -v "Unrecognized and/or unsupported format" | head -5'
    ;;
*)
    sed -n 2,20p "$0" | sed 's/^# \{0,1\}//'; exit 1;;
esac
