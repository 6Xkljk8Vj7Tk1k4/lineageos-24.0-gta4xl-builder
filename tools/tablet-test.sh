#!/bin/bash
# tools/tablet-test.sh - functional test of the tablet over adb, one component at a time, with a
# logcat/dmesg/SELinux/crash delta after every test. Host-side; needs root adb (Developer
# options -> Rooted debugging) for dmesg, sysfs and /data. Nothing is installed on the device;
# temporary files go to /data/local/tmp and /sdcard/Movies/tt_test.mp4 and are removed. It
# switches Wi-Fi, Bluetooth, airplane mode, location and the media volume and puts them back, and
# deletes the photos and the clip its camera test takes.
#
#   tools/tablet-test.sh                 # everything; camera, video and apps wait up to UI_WAIT s for an unlocked screen
#   tools/tablet-test.sh wifi bluetooth  # only the named tests (names: see the run_test lines at the bottom)
#
# Env: SERIAL (adb serial; default: the only attached device, which must be a gta4xl), UI_WAIT
# (default 90), DNS_TEST_HOST (default lineageos.org), HOTSPOT=1 (also start/stop the Wi-Fi hotspot,
# off by default: the SCSC AP path is the least tested part of the driver), USB=1 (also switch the
# USB port to MTP and to tethering and back; adb drops for a moment at every switch), REBOOT=1
# (restart at the end and check how the restart went; the tablet then waits for its PIN), OUT
# (report directory, default build_output/tablet-test/<timestamp>/ with report.md, one raw log
# delta per test and the pictures and clips the tests looked into).
#
# What is tested comes from three places: LineageOS's device support requirements (what has to
# work, and equal stock, on a device it supports), Android's VTS (the kernel's sysfs interface;
# VINTF: manifests, compatibility matrices, the kernel configuration), and what has broken on this
# tablet during the port. The checks that run on the tablet are tools/tablet-test/*.sh. A kernel option or
# a HAL that is missing on purpose is listed with its reason in kernel-config-waivers.txt or
# hal-waivers.txt there, so that anything else that goes missing fails. The Java tools
# (tools/tablet-enctest: sensors, codecs, speaker and microphone, GNSS) run with app_process from
# enctest.dex. Host tools besides adb: python3 with Pillow and numpy, ffmpeg and ffprobe; the
# checks of what a photo, a clip or a codec produced are skipped without them. The exit code is
# the number of failed checks.
set -u   # no pipefail: greps that close the pipe early (grep -q, -m1) would turn every big dumpsys into a failure
cd "$(dirname "$0")/.."
SERIAL="${SERIAL:-}"
DNS_TEST_HOST="${DNS_TEST_HOST:-lineageos.org}"
UI_WAIT="${UI_WAIT:-90}"
OUT="${OUT:-build_output/tablet-test/$(date +%Y%m%d-%H%M%S)}"
ONLY="$*"
mkdir -p "$OUT"
REPORT="$OUT/report.md"
# Lines that are known and harmless on this build (counted, but not reported as new errors).
KNOWN='dac_override.*comm="irq/[0-9]+-1198000|gpsd.*handle_sgee_aiding_request|RILD.*(Oem OnRequestComplete|OemClient::ProcessBuffer)|GnssUtilsJni.*setSetId|E/ConstraintLayout|WifiBlocklistMonitor|Cannot abort scan|RILD.*(NeedChnNullApn|SecGetFd|FillQosFlowInfo)|RILC.*RIL_GetFd|SST-0.*handlePollStateResult|NRM-I-0.*service not connected|WifiStaIfaceAidlImpl.*getTwtCapabilities|WifiChipAidlImpl.*getMode|wifi-service.*(DFS flag|radio mode change callback|SupportedIfaceCombinations)|E/DhcpClient|SmsApplication.*\(fixing\)|bluetooth.*is not declared|enableSwbNative|keystore2|ConfigCommonOutputCrop|SensorsHub.*Meta event|addFrozenStateChangeCallback|retrieve passpoint|pixel-thermal.*(AIDL Stats service|thermal stats)|WifiStaIfaceAidlImpl.*(stopRssiMonitoring|setDtimMultiplier)|CASS_DEBUG|RILClient|comm="cass"|charger_vendor|AppOps.*attributionTag|pixel-thermal.*cooling device|ImeiPreference|setState is called with an earlier timestamp|updateValue is called with a value|/sys/kernel/dmabuf|prog_dmabufIter|Passpoint|Wiphy index not recorded|trace_pipe|WindowOrganizerController|a96t3x6|gpio_to_desc|Unrecognized and/or unsupported format|audit: rate limit|audit_lost|ConnectivityService is null in handleBindApplication|wifiaware|WifiShellCommand|E/lshal|libbinder.Parcel.*NULL string|GetServerConfigurableFlag|Satellite|DlbDlbEffect|comm="vaultkeeperd"|comm="ESAR"|comm="OCR"|RILD.*(IO channel write error|SehChannelCallback == null|send SSAC info to IMS)|wifi-service.*Unknown iface name|WifiChipAidlImpl.*getUsableChannels|comm="rild".*(default_prop|system_prop)|comm="cbd"|servicemanager.*hal_power_default|OMXNodeInstance.*UnsupportedIndex|Failed to get surface config from BQ|ScreenRecorder.*getUniqueId|RILD.*nlmsg_type|SystemServiceRegistry|mediaprovider_app.*shell_data_file|mali_winsys.*chroma siting|libcsc.*csc_deinit|SensorListener.*not enabled yet|Failed to query component interface|ExynosCameraStreamManagerSec|Codec2-ComponentInterface.*failed config|Binder transaction failure.*BR_(FROZEN|DEAD)_REPLY|FeatureFlagsImplExport|BpTransactionCompletedListener|ConsumerBase.*abandoned'

a() { adb -s "$SERIAL" shell "$@" 2>/dev/null | tr -d '\r'; }
PASSN=0; FAILN=0; FAILS=""
pass() { echo "  PASS $*"; PASSN=$((PASSN+1)); echo "- PASS $*" >> "$REPORT"; }
fail() { echo "  FAIL $*"; FAILN=$((FAILN+1)); FAILS="$FAILS\n  $CUR: $*"; echo "- **FAIL** $*" >> "$REPORT"; }
info() { echo "  info $*"; echo "- $*" >> "$REPORT"; }
chk() { [ "$2" = "$3" ] && pass "$1 ($2)" || fail "$1 (is '$2', expected '$3')"; }
chk_ge() { [ "${2:-0}" -ge "$3" ] 2>/dev/null && pass "$1 ($2)" || fail "$1 (is '$2', expected >= $3)"; }
wait_for() {   # wait_for <seconds> <command producing expected> <expected>  -> prints elapsed, returns 0/1
    local n=0; while [ $n -lt "$1" ]; do [ "$(a "$2")" = "$3" ] && { echo $n; return 0; }; sleep 1; n=$((n+1)); done; echo $n; return 1
}
# Seconds on the kernel log's clock now. Not /proc/uptime: that one counts the time spent in
# suspend, the log's clock does not, so after a day the two are hours apart and a cut at the
# uptime would drop every line.
kclock() { a 'dmesg | tail -n 1' | sed -E 's/^\[ *([0-9]+)\..*/\1/' | grep -E '^[0-9]+$' || echo 0; }
keyguard_showing() { [ "$(a 'dumpsys window policy' | grep -m1 -oE 'showing=(true|false)')" = "showing=true" ]; }
pull() { adb -s "$SERIAL" pull "$1" "$2" >/dev/null 2>&1 </dev/null; }
push() { adb -s "$SERIAL" push "$1" "$2" >/dev/null 2>&1 </dev/null; }
TT=tools/tablet-test
# dev FILE [ARG]: runs tools/tablet-test/FILE on the tablet. The script there reports through
# ok, no and nfo; every line becomes a PASS, a FAIL or an info line here.
dev() {
    local l
    while IFS= read -r l; do
        case "$l" in
            "PASS "*) pass "${l#PASS }";;
            "FAIL "*) fail "${l#FAIL }";;
            "INFO "*) info "${l#INFO }";;
            "") ;;
            *) info "$1 printed: $l";;
        esac
    done < <(a "ok() { echo \"PASS \$*\"; }; no() { echo \"FAIL \$*\"; }; nfo() { echo \"INFO \$*\"; }; set -- ${2:-}; $(cat "$TT/$1")")
}
# cpu_busy SECONDS: what kept the CPUs busy over that time, busiest first, one line per thread
# with at least 2 % of one core: "<percent> <k|u> <name> <tid>" (k = kernel thread).
cpu_busy() {
    a "echo T \$(cut -d' ' -f1 /proc/uptime); cat /proc/[0-9]*/task/[0-9]*/stat 2>/dev/null; sleep $1; echo T \$(cut -d' ' -f1 /proc/uptime); cat /proc/[0-9]*/task/[0-9]*/stat 2>/dev/null" | awk '
        $1 == "T" && NF == 2 { if (seen) secs = $2 - t1; else t1 = $2; seen++; next }
        {   o = index($0, "("); c = 0
            for (i = length($0); i > o; i--) if (substr($0, i, 1) == ")") { c = i; break }
            if (!o || !c) next
            tid = $1; name = substr($0, o + 1, c - o - 1); gsub(/ /, "_", name); split(substr($0, c + 2), f, " ")
            t = f[12] + f[13]                         # utime + stime in 1/100 s: percent of one core per second
            if (seen < 2) { t0[tid] = t; next }
            if ((tid in t0) && t > t0[tid] && secs > 0) printf "%d %s %s %s\n", (t - t0[tid]) / secs, (f[2] == 2 ? "k" : "u"), name, tid
        }' | awk '$1 >= 2' | sort -rn
}
# busy_check SECONDS WHEN: fails when a kernel thread kept half a core busy over that time. Seen
# once on this tablet: a TrustZone worker thread ran at 100 % for 38 minutes after an unlock (the
# secure world kept asking for one core), and the battery discharged on the cable.
busy_check() {
    local b k
    b=$(cpu_busy "$1")
    k=$(awk '$2 == "k" && $1 >= 50 { printf "%s %s %%, ", $3, $1 }' <<<"$b")
    [ -z "$k" ] && pass "no kernel thread keeps a core busy $2" || fail "kernel thread busy $2: ${k%, } of one core"
    [ -n "$b" ] && info "busiest threads $2: $(head -4 <<<"$b" | awk '{ printf "%s %s %%, ", $3, $1 }' | sed 's/, $//')" || info "no thread used 2 % of a core $2"
}
# The Java tools run with app_process from one dex file; nothing is installed on the tablet.
DEX=tools/tablet-enctest/enctest.dex; DEX_ON=0
need_dex() {
    [ "$DEX_ON" = 1 ] && return 0
    [ -r "$DEX" ] || { info "SKIPPED: $DEX is missing (tools/tablet-enctest/build.sh builds it)"; return 1; }
    push "$DEX" /data/local/tmp/tt_enctest.dex || { fail "could not copy $DEX to the tablet"; return 1; }
    DEX_ON=1
}
jrun() { a "CLASSPATH=/data/local/tmp/tt_enctest.dex app_process /system/bin $*"; }
MEDIA=""
media_tools() {   # what media_check.py and the codec round trip need on this side
    [ -n "$MEDIA" ] || { if command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null && python3 -c 'import PIL, numpy' 2>/dev/null; then MEDIA=yes; else MEDIA=no; fi; }
    [ "$MEDIA" = yes ]
}
media_check() { python3 "$TT/media_check.py" "$1" "$2" 2>/dev/null | tail -1; }
field() { grep -oE "(^| )$1=[^ ]+" <<<"$2" | head -1 | cut -d= -f2; }   # field NAME "a=1 b=2" -> value of NAME
CUR=""; WIFI_WAS_ON=1; LOC_WAS=""; VOL_WAS=""
run_test() {
    local name=$1 title=$2
    [ -z "$ONLY" ] || grep -qw "$name" <<<"$ONLY" || return 0
    CUR=$name
    echo; echo "### $name: $title"; printf '\n## %s: %s\n' "$name" "$title" >> "$REPORT"
    local ts up; ts=$(a "date '+%m-%d %H:%M:%S.000'"); up=$(kclock)
    "t_$name"
    log_delta "$name" "$ts" "$up"
}
log_delta() {
    local name=$1 ts=$2 up=$3 f="$OUT/$name.log"
    {   echo "## logcat E/F since $ts"
        a "logcat -d -b main,system,radio -v brief -T '$ts' '*:E'" | grep -E '^[EF]/'
        echo "## events"; a "logcat -d -b events -v brief -T '$ts'" | grep -E 'am_crash|am_anr|am_native_crash|am_wtf'
        echo "## crash"; a "logcat -d -b crash -v brief -T '$ts'" | grep -vE '^-+ beginning'
        echo "## dmesg since $up s on its clock"
        a dmesg | awk -v s="$up" '{ t=$1; gsub(/[\[\]]/,"",t); if (t+0 >= s) print }'
    } > "$f"
    local e eu avc avcu crash kern
    e=$(grep -cE '^[EF]/' "$f"); eu=$(grep -E '^[EF]/' "$f" | grep -vcE "$KNOWN")
    avc=$(grep -c 'avc: *denied' "$f"); avcu=$(grep 'avc: *denied' "$f" | grep -vcE "$KNOWN")
    crash=$(grep -cE 'am_crash|am_native_crash|am_anr|FATAL|signal [0-9]' "$f")
    kern=$(grep -E '^\[' "$f" | grep -cE 'WARNING: CPU|BUG:|Oops|Call trace|Unable to handle|hung task|soft lockup|I/O error|EXT4-fs error|F2FS-fs.*error')
    local line="logs: logcat E/F $e (new/unknown $eu), avc $avc (unknown $avcu), crashes/ANR $crash, kernel WARN/BUG/fs errors $kern"
    echo "  $line"; echo "- $line" >> "$REPORT"
    [ "$crash" = 0 ] || fail "crash/ANR during this test (see $f)"
    [ "$kern" = 0 ] || fail "kernel warning/bug during this test (see $f)"
    if [ "$eu" != 0 ] || [ "$avcu" != 0 ]; then
        echo '  unknown lines:'; echo '  unknown lines:' >> "$REPORT"
        { grep -E '^[EF]/' "$f"; grep 'avc: *denied' "$f"; } | grep -vE "$KNOWN" | sed -E 's/[0-9]{3,}/N/g' | sort | uniq -c | sort -rn | head -8 | while read -r l; do echo "    $l"; echo "      $l" >> "$REPORT"; done
    fi
}

# ---------------------------------------------------------------- tests
t_system() {
    info "lineage $(a getprop ro.lineage.version), patch $(a getprop ro.build.version.security_patch) / vendor $(a getprop ro.vendor.build.security_patch), kernel $(a uname -r)"
    info "boot reason $(a getprop sys.boot.reason), uptime $(a 'cut -d. -f1 /proc/uptime') s, build $(a getprop ro.build.type) $(a getprop ro.build.tags), adb secure=$(a getprop ro.adb.secure) debuggable=$(a getprop ro.debuggable)"
    chk "boot_completed" "$(a getprop sys.boot_completed)" 1
    chk "SELinux" "$(a getenforce)" Enforcing
    chk "dm-verity" "$(a getprop ro.boot.veritymode)" enforcing
    chk "FBE" "$(a getprop ro.crypto.state)/$(a getprop ro.crypto.type)" encrypted/file
    chk "CPUs online" "$(a cat /sys/devices/system/cpu/online)" 0-7
    chk "zram swap" "$(a 'grep -c zram /proc/swaps')" 1
    # LineageOS asks for a userdebug build without su
    chk "build type" "$(a getprop ro.build.type)" userdebug
    local su; su=$(a 'ls /system/bin/su /system/xbin/su /system_ext/bin/su /product/bin/su /vendor/bin/su /sbin/su 2>/dev/null' | paste -sd ' ')
    [ -z "$su" ] && pass "no su binary in the build" || fail "su binary in the build: $su"
    local bt; bt=$(a 'bootstat -p' | awk '$1 == "absolute_boot_time" { print $2 }')
    if [ -n "$bt" ]; then [ "$bt" -le 60 ] && pass "this start took $bt s from power-on to boot completed" || fail "this start took $bt s from power-on to boot completed (more than 60)"; else info "bootstat has no boot time"; fi
    # How the start before this one ended: the bootloader's reset reason, and the end of that start's kernel log
    local rr; rr=$(a 'cat /proc/reset_reason 2>/dev/null')
    case "$rr" in
        RPON|PPON|NPON) pass "reset reason $rr (a restart or a power-on)";;
        KPON) fail "reset reason KPON: the start before this one ended in a kernel panic (/proc/gta4xl_last_kmsg has its log)";;
        DPON|WPON) fail "reset reason $rr: the watchdog reset the tablet (/proc/gta4xl_last_kmsg and /proc/last_kmsg have the logs)";;
        SPON) fail "reset reason SPON: the power was lost for a moment";;
        TPON) fail "reset reason TPON: thermal shutdown";;
        "") info "/proc/reset_reason is not readable";;
        *) info "reset reason $rr (MPON: reset with the keys)";;
    esac
    if [ "$(a 'wc -c < /proc/gta4xl_last_kmsg 2>/dev/null')" -gt 1000 ] 2>/dev/null; then
        local lk w; lk=$(a 'tail -n 15 /proc/gta4xl_last_kmsg')
        if grep -qiE 'exynos_reboot|sec_set_reboot_magic|Restarting system|Power down|power.?off|System halted' <<<"$lk"; then pass "the kernel log of the start before ends with a restart or a power-off"
        else fail "the kernel log of the start before does not end with a restart or a power-off: $(tail -1 <<<"$lk" | cut -c1-110)"; fi
        w=$(a 'grep -E "WARNING: CPU|BUG:|Unable to handle kernel|Kernel panic" /proc/gta4xl_last_kmsg' | grep -vcE 'device_create_file|gpio_to_desc')
        chk "warnings, bugs and panics in the kernel log of the start before (the two known ones aside)" "$w" 0
    else
        info "no kernel log of the start before (/proc/gta4xl_last_kmsg; the memory does not keep it through a power-off)"
    fi
    # Android's crash store: entries since this start
    local boot db bad
    boot=$(a 'date -d @$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) )) "+%Y-%m-%d %H:%M:%S"')
    db=$(a 'dumpsys dropbox' | awk -v b="$boot" '$1 ~ /^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && ($1 " " $2) >= b { print $3 }' | sort | uniq -c | awk '{ printf "%s x%s, ", $2, $1 }' | sed 's/, $//')
    bad=$(grep -oE '(system_server_(crash|native_crash|watchdog|anr|lowmem)|system_app_(crash|native_crash|anr)|SYSTEM_RESTART) x[0-9]+' <<<"$db" | paste -sd ',')
    [ -z "$bad" ] && pass "no crash of the system or of a system app since this start (crash store: ${db:-empty})" || fail "crash store entries since this start: $bad (adb shell dumpsys dropbox --print <tag>)"
    local pd; pd=$(a 'ls -l --time-style=+%s /sys/fs/pstore/dmesg-ramoops-* 2>/dev/null' | awk '{print $6}' | sort -n | tail -1)
    if [ -z "$pd" ]; then pass "no kernel oops dump in pstore"; elif [ "$pd" -lt "$(( $(a date +%s) - $(a 'cut -d. -f1 /proc/uptime') ))" ]; then info "pstore holds an oops dump from before this boot ($(date -d @$pd '+%F %T')); it stays until deleted (/sys/fs/pstore/dmesg-ramoops-*)"; else fail "pstore has an oops dump from this boot"; fi
}
t_services() {
    local s
    for s in netd keystore2 surfaceflinger audioserver cameraserver vendor.keymaster-4-0 vendor.gralloc-2-0 vendor.hwcomposer-3 vendor.camera.provider vendor.drm-widevine-hal-1-4 vendor.wifi_hal_legacy vendor.bluetooth-1-0 ril-daemon cass tz_service tzts_service; do
        chk "init service $s" "$(a getprop init.svc.$s)" running
    done
    info "hwbinder HALs: $(a lshal 2>/dev/null | grep -cE '@[0-9]+\.[0-9]+::'), binder services: $(a 'service list | tail -n +2 | wc -l'), dumpsys services: $(a 'dumpsys -l | tail -n +2 | wc -l')"
    chk "no service in restarting state" "$(a 'getprop | grep -c "init.svc.*\]: \[restarting\]"')" 0
}
t_storage() {
    info "$(a 'df -h /data' | tail -1 | awk '{print "/data "$2" total, "$4" free ("$5" used)"}'), $(a 'mount | grep -m1 " /data " | awk "{print \$5}"') + $(a 'mount | grep -m1 "/storage/emulated" | awk "{print \$5}"') on /sdcard"
    if a 'logcat -d -b main | grep -q "Using FUSE passthrough"'; then pass "FUSE passthrough enabled (logcat since boot)"; else info "FUSE passthrough line not in the logcat buffer any more (buffer rotated)"; fi
    local w r w2 r2
    w=$(a 'dd if=/dev/zero of=/sdcard/Movies/.tt_write bs=4M count=32 conv=fsync 2>&1 | tail -1 | grep -oE "[0-9.]+ ?[MG]B?/s"')
    a 'echo 3 > /proc/sys/vm/drop_caches'
    r=$(a 'dd if=/sdcard/Movies/.tt_write of=/dev/null bs=4M 2>&1 | tail -1 | grep -oE "[0-9.]+ ?[MG]B?/s"')
    w2=$(a 'dd if=/dev/zero of=/data/local/tmp/.tt_write bs=4M count=32 conv=fsync 2>&1 | tail -1 | grep -oE "[0-9.]+ ?[MG]B?/s"')
    a 'echo 3 > /proc/sys/vm/drop_caches'
    r2=$(a 'dd if=/data/local/tmp/.tt_write of=/dev/null bs=4M 2>&1 | tail -1 | grep -oE "[0-9.]+ ?[MG]B?/s"')
    a 'rm -f /sdcard/Movies/.tt_write /data/local/tmp/.tt_write'
    info "128 MB via /sdcard (FUSE): write $w, read $r; via /data directly: write $w2, read $r2"
    [ -n "$r" ] && pass "sdcard write/read works" || fail "sdcard dd failed"
    chk "fs errors in dmesg since boot" "$(a 'dmesg | grep -cE "EXT4-fs error|F2FS-fs.*error|I/O error|Buffer I/O"')" 0
    dev storage.sh
}
t_memory_cpu() {
    info "$(a 'grep -E "^(MemTotal|MemAvailable|SwapTotal|SwapFree)" /proc/meminfo' | awk '{printf "%s %d MB, ", $1, $2/1024}')"
    info "lmkd kills since boot: $(a 'logcat -d -b events | grep -c am_kill'), oom in dmesg: $(a 'dmesg | grep -ci "out of memory"')"
    info "governor $(a cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)/$(a cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_governor), cur MHz: $(a 'cat /sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq' | awk '{printf "%d ", $1/1000}'), max: $(a 'cat /sys/devices/system/cpu/cpufreq/policy*/cpuinfo_max_freq' | awk '{printf "%d ", $1/1000}')"
    busy_check 5 "with the screen on"
    # Four busy loops for 4 s. The frequency two seconds in is compared with the cluster's
    # lowest step, not with the frequency before: the cluster goes from 40 to 80 C within a
    # second and the thermal governor then caps it below what an idle-time burst reached.
    local lowest after cap
    lowest=$(a 'cat /sys/devices/system/cpu/cpufreq/policy4/cpuinfo_min_freq')
    a 'for i in 1 2 3 4; do (timeout 4 sh -c "while :; do :; done" &) ; done; sleep 2; cat /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq /sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq' > "$OUT/.load" ; cap=$(head -1 "$OUT/.load"); after=$(tail -1 "$OUT/.load"); sleep 3
    chk_ge "big cluster clocks up under load (kHz; lowest step $lowest, thermal cap at that moment $cap)" "$after" "$((lowest + 1))"
}
t_thermal_battery() {
    info "temps: $(a 'dumpsys thermalservice' | grep -oE 'mValue=[0-9.]+, mType=[0-9]+, mName=[A-Za-z0-9_]+' | sed -E 's/mValue=([0-9]+)[0-9.]*, mType=[0-9]+, mName=([A-Za-z0-9_]+)/\2=\1/' | paste -sd ' ')"
    chk "thermal status (0 = none)" "$(a 'dumpsys thermalservice' | grep -m1 -oE 'Thermal Status: [0-9]' | awk '{print $3}')" 0
    info "battery: $(a 'dumpsys battery' | grep -E '^ +(level|status|health|temperature|voltage|AC powered|USB powered):' | sed -E 's/^ +//' | paste -sd ',' | sed 's/,/, /g')"
    chk "battery health (2 = good)" "$(a 'dumpsys battery' | grep -m1 -oE 'health: [0-9]' | awk '{print $2}')" 2
    dev battery.sh
}
t_display() {
    info "display: $(a 'dumpsys display' | grep -m1 -oE 'mScreenState=[A-Z_]+|mState=[A-Z]+'), $(a 'dumpsys display' | grep -m1 -oE 'fps=[0-9.]+|refreshRate=[0-9.]+' ), panel $(a 'dumpsys SurfaceFlinger' | grep -a -m1 -oE '[0-9]+x[0-9]+' )"
    local mode b0 blo bhi png
    mode=$(a settings get system screen_brightness_mode); b0=$(a settings get system screen_brightness)
    a 'settings put system screen_brightness_mode 0; settings put system screen_brightness 20'; sleep 2; blo=$(a cat /sys/class/backlight/panel/brightness)
    a 'settings put system screen_brightness 250'; sleep 2; bhi=$(a cat /sys/class/backlight/panel/brightness)
    a "settings put system screen_brightness $b0; settings put system screen_brightness_mode $mode"
    [ "${bhi:-0}" -gt "${blo:-0}" ] 2>/dev/null && pass "backlight follows brightness setting (sysfs $blo -> $bhi)" || fail "backlight did not change ($blo -> $bhi)"
    chk "panel resolution, as on stock" "$(a 'wm size' | awk '/Physical size/ { print $3 }')" 1200x2000
    chk "display density, as on stock" "$(a 'wm density' | awk '/Physical density/ { print $3 }')" 240
    a 'screencap -p /data/local/tmp/tt.png'; png=$(a 'stat -c %s /data/local/tmp/tt.png 2>/dev/null')
    chk_ge "screencap PNG size (bytes)" "${png:-0}" 20000
    if media_tools && pull /data/local/tmp/tt.png "$OUT/screen.png"; then
        local r; r=$(media_check screen "$OUT/screen.png")
        case "$(field size "$r")" in
            2000x1200|1200x2000) awk -v s="$(field std "$r")" 'BEGIN { exit !(s >= 1) }' && pass "screenshot decodes and shows something ($(field size "$r"), brightness mean $(field mean "$r") of 255, spread $(field std "$r"))" || fail "screenshot is one flat colour ($r)";;
            *) fail "screenshot: $r";;
        esac
    fi
    a 'rm -f /data/local/tmp/tt.png'
    info "GPU: $(a 'dumpsys SurfaceFlinger' | grep -a -m1 -iE 'GLES|renderer' | sed -E 's/^ +//' | cut -c1-100)"
}
t_input() {
    local devs d
    devs=$(a 'getevent -il' | grep -oE 'name: +"[^"]+"' | sed -E 's/name: +"//; s/"//' | paste -sd ',')
    info "input devices: $devs"
    for d in sec_touchscreen sec_e-pen gpio_keys hall grip_sensor; do grep -q "$d" <<<"$devs" && pass "input device $d present" || fail "input device $d missing"; done
    # a key that does nothing: a tap could hit an icon when the screen is unlocked
    a 'input keyevent KEYCODE_UNKNOWN' && pass "input injection (key event) accepted" || fail "input injection failed"
    info "S-Pen HAL: $(a lshal 2>/dev/null | grep -ciE 'spen'), touch HAL: $(a lshal 2>/dev/null | grep -ciE 'touch')"
    dev input.sh
}
t_sensors() {
    local list
    list=$(a 'dumpsys sensorservice' | grep -oE '^[0-9a-fx]+\) [^|]+\|' | sed -E 's/^[0-9a-fx]+\) //; s/ +\|$//')
    info "sensors ($(echo "$list" | grep -c .)): $(echo "$list" | paste -sd ',' | cut -c1-300)"
    local s; for s in Accelerometer Gyroscope Light; do grep -q "$s" <<<"$list" && pass "sensor $s present" || fail "sensor $s missing"; done
    info "active sensors: $(a 'dumpsys sensorservice' | grep -cE 'active-count = [1-9]'), events: $(a 'dumpsys sensorservice' | grep -m1 -A1 -E 'Recent events|Last [0-9]+ events' | tail -1 | sed -E 's/^ +//' | cut -c1-80)"
    # Registered like an app would: two seconds of events from each sensor (tools/tablet-enctest/SensorTest.java)
    need_dex || return
    local so l t n v mag; so=$(jrun 'SensorTest 2000')
    while read -r l; do
        t=$(field type "$l"); n=$(field events "$l"); v=$(field last "$l")
        case "$t" in
            1)  mag=$(awk -F, '{ printf "%.2f", sqrt($1 * $1 + $2 * $2 + $3 * $3) }' <<<"$v")
                if [ "${n:-0}" -ge 20 ] && awk -v m="$mag" 'BEGIN { exit !(m >= 7.8 && m <= 11.8) }'; then pass "accelerometer delivers: $n events in 2 s, $mag m/s2 in total (gravity is 9.81)"
                else fail "accelerometer: $n events in 2 s, $mag m/s2 in total (a tablet at rest shows 9.81)"; fi;;
            4)  chk_ge "gyroscope delivers (events in 2 s)" "${n:-0}" 20;;
            5)  [ "${n:-0}" -ge 1 ] && pass "light sensor delivers ($v lx)" || fail "light sensor delivered nothing";;
            *)  info "sensor type $t ($(field name "$l")): $n events, last value $v";;
        esac
    done < <(grep '^SENSOR ' <<<"$so")
    grep -q '^RESULT ' <<<"$so" || fail "SensorTest did not finish: $(tail -1 <<<"$so" | cut -c1-120)"
}
t_wifi() {
    local st gw rssi t n
    st=$(a 'cmd wifi status'); info "$(grep -m1 -oE "Wifi is [a-z]+( to \"[^\"]*\")?" <<<"$st" | tail -1)"
    grep -q "Wifi is connected" <<<"$st" && pass "Wi-Fi connected" || fail "Wi-Fi not connected"
    info "link: $(a 'cmd wifi status' | grep -oE 'RSSI: -?[0-9]+|Link speed: [0-9]+ Mbps|Frequency: [0-9]+ MHz|Standard: [a-z0-9]+' | paste -sd ',' )"
    gw=$(a 'ip route show table all' | awk '/^default via/{print $3; exit}'); info "gateway $gw, ip $(a 'ip -4 -o addr show wlan0' | awk '{print $4}'), IPv6 global addrs: $(a 'ip -6 -o addr show wlan0 scope global | wc -l')"
    t=$(a "ping -c 3 -W 2 $gw" | grep -oE 'rtt .*' ); [ -n "$t" ] && pass "ping gateway ($t)" || fail "ping gateway"
    t=$(a 'ping -c 3 -W 2 1.1.1.1' | grep -oE 'rtt .*' ); [ -n "$t" ] && pass "ping 1.1.1.1 ($t)" || fail "ping 1.1.1.1"
    t=$(a "ping -c 1 -W 3 $DNS_TEST_HOST" | grep -m1 -oE 'PING [^ ]+ \([0-9.]+\)'); [ -n "$t" ] && pass "DNS resolves ($t)" || fail "DNS resolution of $DNS_TEST_HOST"
    local v=0; while [ $v -lt 20 ]; do a 'dumpsys connectivity' | grep -m1 "Capabilities:" | grep -q "VALIDATED" && break; sleep 2; v=$((v+2)); done
    [ $v -lt 20 ] && pass "network VALIDATED (captive-portal probes ok, after $v s)" || fail "network not VALIDATED after 20 s: $(a 'dumpsys connectivity' | grep -m1 -oE "Capabilities: [^ ]*" | cut -c1-120)"
    info "last probes: $(a 'dumpsys network_stack' | grep -oE "PROBE_HTTPS? [^ ]+ time=[0-9]+ms ret=[0-9]+" | tail -2 | paste -sd ";")"
    a 'cmd wifi start-scan' >/dev/null; sleep 5
    n=$(a 'cmd wifi list-scan-results' | grep -cE '^ *[0-9a-f]{2}:[0-9a-f]{2}:'); chk_ge "scan results" "$n" 1
    a 'svc wifi disable'; t=$(wait_for 15 'cmd wifi status | head -1' 'Wifi is disabled') && pass "Wi-Fi off in $t s" || fail "Wi-Fi did not turn off ($(a 'cmd wifi status' | head -1))"
    a 'svc wifi enable'; n=0; while [ $n -lt 45 ]; do a 'cmd wifi status' | grep -q 'Wifi is connected' && break; sleep 1; n=$((n+1)); done
    [ $n -lt 45 ] && pass "Wi-Fi on and reconnected in $n s" || fail "Wi-Fi did not reconnect within 45 s"
    sleep 3; t=$(a 'ping -c 2 -W 2 1.1.1.1' | grep -oE 'rtt .*'); [ -n "$t" ] && pass "internet after reconnect ($t)" || fail "no internet after reconnect"
    info "networks seen: $(a 'cmd wifi list-scan-results' | awk '$2 ~ /^[0-9]+$/ { if ($2 < 3000) a++; else if ($2 < 5925) b++; else c++ } END { printf "%d on 2.4 GHz, %d on 5 GHz, %d on 6 GHz", a, b, c }')"
    dev identity.sh wifi
}
t_network_services() {
    info "private DNS mode: $(a settings get global private_dns_mode) (null = Android's default), ro.bpf.kver_override=$(a getprop ro.bpf.kver_override), build.sh overlays: $(a 'cmd overlay list 2>/dev/null' | grep -c gta4xlbuilder)"
    chk "NTP refresh" "$(a 'cmd network_time_update_service force_refresh')" true
    info "NTP: $(a 'dumpsys network_time_update_service' | grep -iE 'server|cached|result|mLastRefresh' | sed -E 's/^ +//' | paste -sd ';' | cut -c1-200)"
    local d; d=$(( $(date +%s) - $(a 'date +%s') )); [ "${d#-}" -le 2 ] && pass "clock within 2 s of host (delta $d s)" || fail "clock delta $d s"
    info "captive portal URLs: $(a 'dumpsys network_stack' | grep -oiE 'captive_portal_https?_url[^,]*|generate_204[^ ,]*' | sort -u | paste -sd ';' | cut -c1-200)"
}
t_bluetooth() {
    local orig t
    orig=$(a settings get global bluetooth_on); info "bluetooth initially on=$orig, name $(a settings get secure bluetooth_name)"
    a 'cmd bluetooth_manager enable' >/dev/null
    t=$(wait_for 25 'settings get global bluetooth_on' 1) && pass "Bluetooth enabled in $t s" || fail "Bluetooth did not enable"
    sleep 3; info "adapter: $(a 'dumpsys bluetooth_manager' | grep -m1 -oE '(state|enabled)[:=] *[A-Za-z_]+' | paste -sd ',')"
    chk "bluetooth HAL still running" "$(a getprop init.svc.vendor.bluetooth-1-0)" running
    dev identity.sh bluetooth
    if [ "$orig" != 1 ]; then a 'cmd bluetooth_manager disable' >/dev/null; t=$(wait_for 20 'settings get global bluetooth_on' 0) && pass "Bluetooth disabled again in $t s" || fail "Bluetooth did not disable"; fi
}
regstate() { a 'dumpsys telephony.registry' | grep -m1 -oE "m${1}RegState=[0-9]\([A-Z_]+\)" | sed -E 's/.*\(([A-Z_]+)\)/\1/'; }   # regstate Voice|Data
t_cellular() {
    local sim rtt n; sim=$(a getprop gsm.sim.state)
    info "SIM $sim, baseband $(a getprop gsm.version.baseband), voice $(regstate Voice), data $(regstate Data)"
    [ -n "$(a getprop gsm.version.baseband)" ] && pass "the modem reports its firmware version" || fail "no baseband version: the modem did not come up"
    chk "rild running" "$(a getprop init.svc.ril-daemon)" running
    if [ "$sim" = LOADED ]; then
        # A SIM is in: registration, signal, and mobile data as the only way out
        chk "registered for voice" "$(regstate Voice)" IN_SERVICE
        chk "registered for data" "$(regstate Data)" IN_SERVICE
        info "network $(a getprop gsm.operator.numeric) $(a getprop gsm.network.type), $(a 'dumpsys telephony.registry' | grep -m1 -oE 'rsrp=-?[0-9]+ rsrq=-?[0-9]+ rssnr=-?[0-9]+')"
        if [ "$(a settings get global mobile_data)" = 1 ]; then
            a 'svc wifi disable'; n=0
            while [ $n -lt 30 ]; do [ "$(a 'ip -4 -o addr show' | grep -c rmnet)" -ge 1 ] && break; sleep 2; n=$((n+2)); done
            sleep 3; rtt=$(a 'ping -c 3 -W 3 1.1.1.1' | grep -oE 'rtt .*')
            [ -n "$rtt" ] && pass "mobile data with Wi-Fi off: ping 1.1.1.1 over $(a 'ip -4 -o addr show' | grep -oE 'rmnet[0-9]+' | head -1) ($rtt)" || fail "no internet over mobile data with Wi-Fi off (mobile interface up after $n s: $(a 'ip -4 -o addr show' | grep -c rmnet))"
            a 'svc wifi enable'
        else
            info "mobile data is switched off in the settings: not tested"
        fi
    else
        info "no usable SIM (state $sim): registration and mobile data not tested"
    fi
    a 'cmd connectivity airplane-mode enable' >/dev/null; sleep 6
    chk "airplane mode on" "$(a settings get global airplane_mode_on)" 1
    chk "rild survives airplane mode" "$(a getprop init.svc.ril-daemon)" running
    a 'cmd connectivity airplane-mode disable' >/dev/null; a 'svc wifi enable'
    n=0; while [ $n -lt 45 ]; do a 'cmd wifi status' | grep -q 'Wifi is connected' && break; sleep 1; n=$((n+1)); done
    [ $n -lt 45 ] && pass "Wi-Fi back after airplane mode in $n s" || fail "Wi-Fi not back after airplane mode"
    if [ "$sim" = LOADED ]; then
        n=0; while [ $n -lt 60 ]; do [ "$(regstate Voice)" = IN_SERVICE ] && break; sleep 2; n=$((n+2)); done
        [ $n -lt 60 ] && pass "registered again $n s after airplane mode" || fail "not registered 60 s after airplane mode ($(regstate Voice))"
    fi
}
t_gps() {
    local orig r; orig=$(a 'cmd location is-location-enabled'); LOC_WAS=$orig
    a 'cmd location set-location-enabled true' >/dev/null; sleep 3
    info "location was $orig; gps provider: $(a 'dumpsys location' | grep -m1 -A3 -iE '^ *gps provider' | grep -oE 'enabled=[a-z]+|allowed=[a-z]+|properties=[^,]*' | paste -sd ',')"
    chk "GNSS HAL registered" "$(a lshal 2>/dev/null | grep -ciE 'gnss' | awk '{print ($1>0)?"yes":"no"}')" yes
    # The receiver itself, asked for positions the way an app asks, for 20 s (tools/tablet-enctest/GnssTest.java)
    if need_dex; then
        r=$(jrun 'GnssTest 20' | grep '^RESULT ' | tail -1)
        [ "$(field ok "$r")" = 1 ] && [ "$(field reports "$r")" -ge 5 ] 2>/dev/null && pass "the GNSS receiver starts and reports satellite status ($(field reports "$r") reports in 20 s)" || fail "GNSS receiver: ${r:-no result}"
        if [ "$(field satellites "$r")" -ge 1 ] 2>/dev/null; then pass "satellites received: up to $(field satellites "$r") at once, the strongest at $(field cn0_max "$r") dB-Hz$([ "$(field fix "$r")" = 1 ] && echo ", position after $(( $(field ttff_ms "$r") / 1000 )) s")"
        else info "no satellite received in 20 s (indoors, away from a window?)"; fi
    fi
    info "gpsd log tail: $(a 'logcat -d -s gpsd:* GnssLocationProvider:* GnssNative:*' | tail -2 | sed -E 's/^[0-9: .-]+ +//' | cut -c1-100 | paste -sd ';')"
    [ "$orig" = true ] || a 'cmd location set-location-enabled false' >/dev/null
    LOC_WAS=""
}
t_audio() {
    local up v max out r g; up=$(kclock)
    info "audio HAL: $(a 'getprop | grep -oE "init.svc.vendor.audio[^]]*\]: \[[a-z]+"' | sed -E 's/init.svc.//; s/\]: \[/=/' | paste -sd ','), outputs: $(a 'dumpsys media.audio_flinger' | grep -a -m2 -oE 'AUDIO_DEVICE_OUT_[A-Z_]+' | sort -u | paste -sd ',')"
    # The media volume is put back afterwards: the two key presses below do not always cancel out
    v=$(a 'cmd media_session volume --stream 3 --get 2>&1' | grep -oE 'volume is [0-9]+ in range \[0\.\.[0-9]+\]')
    VOL_WAS=$(awk '{ print $3 }' <<<"$v"); max=$(grep -oE '[0-9]+\]' <<<"$v" | tr -d ']')
    a 'input keyevent KEYCODE_VOLUME_UP'; sleep 1; a 'input keyevent KEYCODE_VOLUME_DOWN'; sleep 2
    local n; n=$(a dmesg | awk -v s="$up" '{ t=$1; gsub(/[\[\]]/,"",t); if (t+0 >= s) print }' | grep -c 'abox.*pm qos')
    [ "$n" -gt 0 ] && pass "audio path woke up for the volume tone (ABOX qos requests: $n)" || info "no ABOX activity on volume keys (tone may be disabled)"
    chk "audioserver running" "$(a getprop init.svc.audioserver)" running
    # Speaker and microphone together, without a person listening: a 1 kHz tone on the media
    # stream has to arrive at the microphone (tools/tablet-enctest/AudioLoop.java)
    out=$(a 'dumpsys media.audio_flinger' | grep -a -m3 -oE 'AUDIO_DEVICE_OUT_[A-Z_]+' | sort -u | paste -sd ,)
    if [ -z "$VOL_WAS" ] || [ -z "$max" ]; then info "media volume not readable: speaker and microphone are not tested"; VOL_WAS=""; return; fi
    if [ "$out" != AUDIO_DEVICE_OUT_SPEAKER ]; then info "sound does not go to the speaker ($out): speaker and microphone are not tested"
    elif need_dex; then
        a "cmd media_session volume --stream 3 --set $(( max * 4 / 10 ))" >/dev/null
        r=$(jrun 'AudioLoop 1000 1500' | grep '^RESULT ' | tail -1); g=$(field gain_db "$r")
        if [ "$(field ok "$r")" = 1 ] && awk -v g="${g:--99}" 'BEGIN { exit !(g >= 20) }'; then pass "speaker and microphone: a 1 kHz tone played at 40 % volume arrives at the microphone at $(field tone_during_dbfs "$r") dBFS, $g dB above that frequency's level before it"
        else fail "speaker to microphone: ${r:-no result} (the tone has to stand 20 dB above its level before)"; fi
    fi
    a "cmd media_session volume --stream 3 --set $VOL_WAS" >/dev/null; VOL_WAS=""
}
t_screenrecord() {
    local ts; ts=$(a "date '+%m-%d %H:%M:%S.000'")
    a 'rm -f /sdcard/Movies/tt_test.mp4; screenrecord --time-limit 5 --size 1280x800 --bit-rate 4000000 /sdcard/Movies/tt_test.mp4' >/dev/null
    local sz; sz=$(a 'stat -c %s /sdcard/Movies/tt_test.mp4 2>/dev/null')
    chk_ge "screenrecord mp4 size (bytes; a static screen gives ~15 KB per 5 s)" "${sz:-0}" 5000
    local enc; enc=$(a "logcat -d -T '$ts' -s OMXNodeInstance:* CCodec:* CCodecConfig:* MediaCodec:* ACodec:*" | grep -m1 -oiE '(c2|OMX)\.[A-Za-z0-9.]*enc[a-z]*')
    [ -n "$enc" ] && pass "encoder used: $enc" || info "encoder name not seen in logcat"
}
UNLOCK_FAILED=0
wait_unlock() {
    keyguard_showing || return 0
    [ "$UNLOCK_FAILED" = 0 ] || return 1
    echo "  >>> screen is locked: unlock the tablet for the camera/video tests (waiting up to $UI_WAIT s)"
    local n=0; while [ $n -lt "$UI_WAIT" ]; do keyguard_showing || return 0; sleep 2; n=$((n+2)); done
    UNLOCK_FAILED=1; return 1
}
CAM_COMP=""; CAM_FILE=""; CAM_ID=""; CAM_MADE=""
# cam_capture ACTION FRONT HOLD: starts Aperture for ACTION with the front camera or not (true or
# false), presses the shutter, and for a video again after HOLD seconds. CAM_FILE gets the name of
# the new file, CAM_ID the camera the service opened for it; CAM_MADE collects what to delete.
cam_capture() {
    local before after
    a 'am force-stop org.lineageos.aperture'; sleep 1   # a running Aperture keeps its mode and its camera
    before=$(a 'ls /sdcard/DCIM/Camera 2>/dev/null | wc -l')
    a "am start -W -n $CAM_COMP -a $1 --ez android.intent.extra.USE_FRONT_CAMERA $2" >/dev/null; sleep 5
    CAM_ID=$(a 'dumpsys media.camera' | grep -m1 -oE 'CONNECT device [0-9]+ client for package org.lineageos.aperture' | awk '{ print $3 }')
    a 'input keyevent KEYCODE_CAMERA'
    if [ -n "$3" ]; then sleep "$3"; a 'input keyevent KEYCODE_CAMERA'; sleep 5; else sleep 4; fi
    after=$(a 'ls /sdcard/DCIM/Camera 2>/dev/null | wc -l')
    if [ -z "$3" ] && [ "$after" -le "$before" ]; then a 'input keyevent KEYCODE_VOLUME_UP'; sleep 4; after=$(a 'ls /sdcard/DCIM/Camera 2>/dev/null | wc -l'); fi
    CAM_FILE=""; [ "$after" -gt "$before" ] && CAM_FILE=$(a 'ls -t /sdcard/DCIM/Camera 2>/dev/null | head -1')
    [ -z "$CAM_FILE" ] || CAM_MADE="$CAM_MADE $CAM_FILE"
}
t_camera() {
    if ! wait_unlock; then info "SKIPPED: screen locked"; return; fi
    local side front r long min id_rear=""
    CAM_COMP=$(a 'cmd package resolve-activity --brief -a android.media.action.STILL_IMAGE_CAMERA -p org.lineageos.aperture' | tail -1)
    for side in rear front; do
        front=false; min=3000; [ $side = front ] && { front=true; min=2400; }
        cam_capture android.media.action.STILL_IMAGE_CAMERA $front ""
        if [ -z "$CAM_FILE" ]; then fail "$side camera: no new photo in DCIM/Camera"; continue; fi
        pass "$side camera: photo taken ($CAM_FILE, $(a "stat -c %s /sdcard/DCIM/Camera/$CAM_FILE") bytes, camera device ${CAM_ID:-?})"
        if [ $side = rear ]; then id_rear=$CAM_ID
        elif [ -n "$CAM_ID" ] && [ "$CAM_ID" != "$id_rear" ]; then pass "the front camera is another camera device than the rear one ($CAM_ID, rear $id_rear)"
        else fail "asked for the front camera, the camera service opened device '${CAM_ID}' (rear: '$id_rear')"; fi
        if media_tools && pull "/sdcard/DCIM/Camera/$CAM_FILE" "$OUT/camera-$side.jpg"; then
            r=$(media_check photo "$OUT/camera-$side.jpg"); long=$(field size "$r" | tr x '\n' | sort -n | tail -1)
            [ "$(field ok "$r")" = 1 ] && [ "${long:-0}" -ge $min ] && pass "$side photo decodes at the sensor's size ($(field size "$r"); brightness mean $(field mean "$r") of 255, spread $(field std "$r"))" || fail "$side photo: $r (expected $min pixels or more on the long side)"
        fi
    done
    cam_capture android.media.action.VIDEO_CAMERA false 6
    if [ -n "$CAM_FILE" ] && [[ "$CAM_FILE" == *.mp4 ]]; then
        pass "video recorded: $CAM_FILE ($(a "stat -c %s /sdcard/DCIM/Camera/$CAM_FILE") bytes)"; CAM_VIDEO=$CAM_FILE
        if media_tools && pull "/sdcard/DCIM/Camera/$CAM_FILE" "$OUT/camera-video.mp4"; then
            r=$(media_check video "$OUT/camera-video.mp4")
            local vw dur rms; vw=$(grep -oE ' [0-9]+x[0-9]+ ' <<<"$r" | tr -d ' ' | cut -dx -f1); dur=$(grep -oE ' [0-9.]+s ' <<<"$r" | tr -d ' s'); rms=$(field rms_dbfs "$r")
            if [ "$(field ok "$r")" = 1 ] && [ "${vw:-0}" -ge 1280 ] && awk -v d="${dur:-0}" 'BEGIN { exit !(d >= 3) }'; then pass "the clip decodes: $(field video "$r") ${vw} pixels wide, $dur s"; else fail "the clip: $r"; fi
            # a dead microphone path records digital silence (below -85 dBFS); a quiet room is around -60
            if [ "$(field audio "$r")" = none ] || [ -z "$rms" ]; then fail "the clip has no sound track ($r)"
            elif awk -v v="$rms" 'BEGIN { exit !(v > -85) }'; then pass "the clip's sound is not silence: the microphone recorded ($(field audio "$r"), $rms dBFS on average, peak $(field peak_dbfs "$r"))"
            else fail "the clip's sound track is digital silence ($rms dBFS): nothing arrives from the microphone"; fi
        fi
    else fail "no new .mp4 in DCIM/Camera (newest: ${CAM_FILE:-none})"; fi
    a 'am force-stop org.lineageos.aperture'
    chk "camera provider still running" "$(a getprop init.svc.vendor.camera.provider)" running
    info "active sensors during camera: $(a 'dumpsys sensorservice' | grep -cE 'active-count = [1-9]')"
}
CAM_VIDEO=""
t_video() {
    if ! wait_unlock; then info "SKIPPED: screen locked"; return; fi
    local path uri ts; ts=$(a "date '+%m-%d %H:%M:%S.000'")
    if [ -n "$CAM_VIDEO" ]; then path="/storage/emulated/0/DCIM/Camera/$CAM_VIDEO"; else
        path=/storage/emulated/0/Movies/tt_test.mp4
        [ "$(a 'stat -c %s /sdcard/Movies/tt_test.mp4 2>/dev/null')" -gt 0 ] 2>/dev/null || a 'screenrecord --time-limit 5 --size 1280x800 /sdcard/Movies/tt_test.mp4' >/dev/null
    fi
    uri=$(a "content call --uri content://media/external/file --method scan_file --arg $path" | grep -oE 'content://media/[^ ,}]+' | head -1)
    [ -n "$uri" ] || uri=$(a "content query --uri content://media/external/video/media --projection _id --where \"_data='$path'\"" | grep -oE '_id=[0-9]+' | head -1 | sed 's/_id=/content:\/\/media\/external\/video\/media\//')
    info "playing $path as ${uri:-?}"
    [ -n "$uri" ] || { fail "MediaStore has no entry for the test video"; return; }
    a "am start -W -a android.intent.action.VIEW -d '$uri' -t video/mp4 --grant-read-uri-permission -p org.lineageos.glimpse" >/dev/null || a "am start -W -a android.intent.action.VIEW -d '$uri' -t video/mp4 --grant-read-uri-permission" >/dev/null
    sleep 4   # sample while the 5-6 s clip is still playing
    local af pl; af=$(a 'dumpsys media.audio_flinger' | grep -m1 -oE "[0-9]+ Tracks of which [0-9]+ are active"); pl=$(a 'dumpsys audio' | grep -c "type:android.media.AudioTrack.*state:started")
    local dec; dec=$(a "logcat -d -T '$ts' -s CCodec:* CCodecConfig:* MediaCodec:* OMXNodeInstance:* ACodec:* MediaCodecList:*" | grep -oiE '(c2|OMX)\.[A-Za-z0-9.]*(avc|h264|hevc|vp8|vp9|mpeg4)[A-Za-z0-9.]*' | grep -i dec | sort -u | paste -sd ,)
    [ -n "$dec" ] && pass "video decoder: $dec" || fail "no video decoder seen in logcat"
    if [ -n "$CAM_VIDEO" ]; then [ "${pl:-0}" -gt 0 ] && pass "audio playing (AudioTrack started; mixer: $af)" || fail "no started AudioTrack during playback (mixer: $af)"; else info "clip has no audio (screenrecord); mixer: $af"; fi
    sleep 3
    a 'am force-stop org.lineageos.glimpse'
}
t_updater() {
    local uri; uri=$(a getprop lineage.updater.uri); info "lineage.updater.uri=$uri"
    if [ -z "$uri" ]; then info "SKIPPED: no update server in this build (OTA_BASE_URL)"; return; fi
    grep -q '^https://' <<<"$uri" && pass "updater URI is https" || fail "updater URI not https"
    # A forced stop ("am force-stop", Settings -> Force stop) leaves an app in the stopped state:
    # its scheduled jobs are cancelled and no broadcast reaches it, BOOT_COMPLETED included, so
    # there is no update check and no unattended install until somebody opens the app. Read the
    # state before the app is opened here, which ends it.
    case "$(a 'dumpsys package org.lineageos.updater' | grep -m1 -oE 'stopped=(true|false)')" in
        stopped=false) pass "the Updater is not in the stopped state";;
        stopped=true) fail "the Updater was in the stopped state (after a forced stop): no update check and no unattended install since then; this test opens the app, which ends that state";;
        *) fail "the Updater's package state could not be read";;
    esac
    a 'am start -W -n org.lineageos.updater/.UpdatesActivity' >/dev/null; sleep 10
    local l; l=$(a 'logcat -d -s UpdatesActivity:* UpdaterService:* UpdatesCheckReceiver:* Utils:* UpdatesDbHelper:*' | tail -4 | sed -E 's/^[0-9: .-]+ +//' | cut -c1-120 | paste -sd ';')
    info "updater log: $l"
    grep -qiE 'Could not|Failed|IOException|SSL' <<<"$l" && fail "updater reported an error" || pass "updater check-in without error"
    # Leave through the home screen, never with "am force-stop" (see above).
    a 'am start -a android.intent.action.MAIN -c android.intent.category.HOME' >/dev/null
    if a 'dumpsys jobscheduler' | grep -qE '^ *JOB .*UpdatesCheckWorker'; then pass "periodic update check scheduled"
    else info "no periodic update check scheduled (switched off in the Updater's preferences?)"; fi
}
t_packages() {
    info "packages: $(a 'pm list packages | wc -l') total, $(a 'pm list packages -e | wc -l') enabled, $(a 'pm list packages --apex-only | wc -l') APEX"
    local p; for p in org.lineageos.aperture org.lineageos.jelly org.lineageos.updater org.lineageos.glimpse; do
        a "pm path $p" | grep -q package: && pass "installed $p" || info "not installed $p"
    done
    info "left out by build.sh (DEBLOAT_PACKAGES): $(a 'cat /product/etc/gta4xl_builder_debloat.txt 2>/dev/null' | paste -sd ',' | cut -c1-200)"
    info "disabled packages: $(a 'pm list packages -d' | sed s/package:// | paste -sd ,)"
}
t_security() {
    local v
    chk "kernel.dmesg_restrict" "$(a cat /proc/sys/kernel/dmesg_restrict)" 1
    chk "kernel.kptr_restrict" "$(a cat /proc/sys/kernel/kptr_restrict)" 2
    chk "randomize_va_space" "$(a cat /proc/sys/kernel/randomize_va_space)" 2
    info "fs.protected_symlinks/hardlinks=$(a cat /proc/sys/fs/protected_symlinks)/$(a cat /proc/sys/fs/protected_hardlinks) (Android does not set them), tcp_syncookies: $(a 'cat /proc/sys/net/ipv4/tcp_syncookies 2>/dev/null || echo "sysctl missing: CONFIG_SYN_COOKIES is off in this kernel"')"
    info "perf_event_paranoid=$(a cat /proc/sys/kernel/perf_event_paranoid) (AOSP sets -1), unprivileged_bpf_disabled=$(a cat /proc/sys/kernel/unprivileged_bpf_disabled) (NetBpfLoad sets 0), ptrace_scope=$(a 'cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo n/a')"
    v=$(a getprop ro.build.tags)
    if [ "$v" = release-keys ]; then pass "signed with own keys ($v)"; else info "signed with the public AOSP test keys ($v): anyone can sign updates and apps this tablet trusts"; fi
    chk "ro.adb.secure" "$(a getprop ro.adb.secure)" 1
    chk "ro.debuggable" "$(a getprop ro.debuggable)" 0
    info "verifiedbootstate=$(a getprop ro.boot.verifiedbootstate), flash.locked=$(a getprop ro.boot.flash.locked), vbmeta.device_state=$(a getprop ro.boot.vbmeta.device_state)"
    v=$(a 'dmesg | grep "avc: *denied"' | grep -vcE "$KNOWN"); [ "$v" = 0 ] && pass "no unknown SELinux denials since boot (known ones: $(a 'dmesg | grep -c "avc: *denied"'))" || { fail "$v unknown SELinux denials since boot"; a 'dmesg | grep "avc: *denied"' | grep -vE "$KNOWN" | sed -E 's/.*avc: //; s/pid=[0-9]+ //' | sort | uniq -c | sort -rn | head -5 | sed 's/^/    /'; }
    info "TEE/keys HALs: $(a lshal 2>/dev/null | grep -oiE '(keymaster|gatekeeper|drm|weaver)[^ ]*@[0-9.]+' | sort -u | paste -sd ',')"
}
t_suspend() {
    local s0 f0 s1 f1 up r n
    s0=$(a cat /sys/power/suspend_stats/success); f0=$(a cat /sys/power/suspend_stats/fail); up=$(kclock)
    a 'input keyevent KEYCODE_SLEEP'; sleep 3
    chk "screen off" "$(a 'dumpsys power' | grep -m1 -oE 'mWakefulness=[A-Za-z]+' | cut -d= -f2)" Asleep
    sleep 30
    busy_check 15 "with the screen off"
    s1=$(a cat /sys/power/suspend_stats/success); f1=$(a cat /sys/power/suspend_stats/fail)
    if [ "$s1" -gt "$s0" ]; then pass "SoC suspended while screen off (suspend success $s0 -> $s1, fail $f0 -> $f1)"; else info "no suspend in 45 s with USB/adb attached (success $s1, fail $f1); PowerManager: $(a 'dumpsys power' | grep -m1 -oE "Wake Locks: size=[0-9]+"), active kernel wakeup sources: $(a 'mount -t debugfs none /sys/kernel/debug 2>/dev/null; awk "NR>1 && \$6>0 {print \$1}" /sys/kernel/debug/wakeup_sources 2>/dev/null' | paste -sd , )"; fi
    info "wakeup_count readable within 3 s: $(a 'timeout 3 cat /sys/power/wakeup_count >/dev/null 2>&1 && echo yes || echo "no - a kernel wakeup source stays active (USB gadget while adb is attached?)"'); on battery since last unplug: $(a 'dumpsys batterystats' | grep -m1 -oE "Time on battery: [^\n]{0,80}")"
    # With the cable in, Android does not suspend. The kernel's test mode runs every driver's
    # suspend and resume callbacks without powering anything down (5 s in between); a driver that
    # waits for another one there hangs the tablet. USB goes away for those seconds, so it runs detached.
    local try=0 alarms=0 kl
    while :; do
        try=$((try+1)); kl=$(kclock)
        a 'rm -f /data/local/tmp/tt_pm; setsid sh -c "echo devices > /sys/power/pm_test; echo mem > /sys/power/state; echo \$? > /data/local/tmp/tt_pm; echo none > /sys/power/pm_test" > /dev/null 2>&1 < /dev/null &'
        sleep 12; timeout 60 adb -s "$SERIAL" wait-for-device; n=0; r=""
        while [ $n -lt 30 ]; do r=$(a 'cat /data/local/tmp/tt_pm 2>/dev/null'); [ -n "$r" ] && break; sleep 2; n=$((n+2)); done
        a 'rm -f /data/local/tmp/tt_pm; echo none > /sys/power/pm_test'
        # alarmtimer refuses a suspend when an alarm is due within two seconds: not a fault, try again
        if [ "$r" != 0 ] && [ $try -lt 3 ] && a dmesg | awk -v s="$kl" '{ t=$1; gsub(/[\[\]]/,"",t); if (t+0 >= s) print }' | grep -q 'Callback failed on alarmtimer'; then alarms=$((alarms+1)); sleep 4; continue; fi
        break
    done
    [ $alarms = 0 ] || info "the kernel refused $alarms attempt(s) because an alarm was due within two seconds; tried again"
    chk "drivers' suspend and resume callbacks, one cycle in the kernel's test mode (exit status)" "${r:-no answer}" 0
    chk "errors of that cycle in the kernel log" "$(a dmesg | awk -v s="$kl" '{ t=$1; gsub(/[\[\]]/,"",t); if (t+0 >= s) print }' | grep -ciE 'failed to (suspend|resume)|dpm_run_callback.*(error|returns -)|Some devices failed to suspend|Abort: ')" 0
    a 'input keyevent KEYCODE_WAKEUP'; sleep 3
    chk "screen back on" "$(a 'dumpsys power' | grep -m1 -oE 'mWakefulness=[A-Za-z]+' | cut -d= -f2)" Awake
    sleep 4; a 'cmd wifi status' | grep -q 'Wifi is connected' && pass "Wi-Fi still connected after wake" || fail "Wi-Fi not connected after wake"
}
t_hotspot() {
    [ "${HOTSPOT:-0}" = 1 ] || { info "SKIPPED (HOTSPOT=1 enables it)"; return; }
    # This Wi-Fi chip does not run a client and an access point at once: Android switches the
    # client off for the hotspot and on again afterwards.
    local sta n; sta=0; a 'cmd wifi status' | grep -q 'Wifi is connected' && sta=1
    a 'cmd wifi start-softap tt_test wpa2 tt_password_1 -b 2' >/dev/null; sleep 10
    tether_up 'swlan[0-9]+|ap[0-9]+|wlan[1-9]' "hotspot"
    a 'cmd wifi stop-softap' >/dev/null; sleep 5
    chk "hotspot interface gone from the tethering service after the stop" "$(a 'dumpsys tethering' | grep -cE '(swlan[0-9]+|ap[0-9]+|wlan[1-9]) - TetheredState')" 0
    if [ $sta = 1 ]; then
        n=0; while [ $n -lt 45 ]; do a 'cmd wifi status' | grep -q 'Wifi is connected' && break; sleep 1; n=$((n+1)); done
        [ $n -lt 45 ] && pass "Wi-Fi client connected again $n s after the hotspot stopped" || fail "Wi-Fi client not connected 45 s after the hotspot stopped"
    else
        info "Wi-Fi was not connected before the hotspot: reconnection not checked"
    fi
}

t_kernel_api() {
    dev kernel_api.sh
}
t_vintf() {
    local v q r
    v=$(a vintf)
    for q in "Device Manifest?" "Device Matrix?" "Framework Manifest?" "Framework Matrix?" "Device HAL Manifest <==> Framework Compatibility Matrix?" "Framework HAL Manifest <==> Device Compatibility Matrix?" "CheckDeprecation"; do
        r=$(grep -F -m1 "$q" <<<"$v" | sed -E 's/^.*\? +//')
        [ "$r" = GOOD ] && pass "${q%\?}: GOOD" || fail "${q%\?}: ${r:-no answer from vintf}"
    done
    # The kernel against the framework's requirements. Options this kernel leaves out on purpose
    # are in kernel-config-waivers.txt with their reasons; anything else that is missing fails.
    local errs miss other unw stale waived
    r=$(grep -F -m1 "Runtime info <==> Framework Compatibility Matrix?" <<<"$v" | sed -E 's/^.*\? +//')
    errs=$(grep -E '^ +(Missing config|For config) ' <<<"$v" | sed -E 's/^ +//' | LC_ALL=C sort -u)
    miss=$(sed -n 's/^Missing config //p' <<<"$errs")
    other=$(grep -v '^Missing config ' <<<"$errs" | paste -sd ';')
    waived=$(awk '!/^#/ && NF { print $1 }' "$TT/kernel-config-waivers.txt" | LC_ALL=C sort -u)
    unw=$(LC_ALL=C comm -23 <(echo "$miss") <(echo "$waived") | paste -sd ' ')
    stale=$(LC_ALL=C comm -13 <(echo "$miss") <(echo "$waived") | paste -sd ' ')
    if [ "$r" = GOOD ]; then pass "kernel version and configuration against the framework's requirements: GOOD"
    elif [ -n "$miss" ] && [ -z "$unw" ] && [ -z "$other" ]; then pass "kernel configuration: the $(grep -c . <<<"$miss") options the framework asks for and this kernel lacks are all listed with their reasons ($TT/kernel-config-waivers.txt)"
    else fail "kernel against the framework's requirements: ${r:-no answer from vintf}; not accounted for: ${unw:+missing $unw} $other"; fi
    [ -z "$stale" ] || info "no longer missing, their lines in kernel-config-waivers.txt can go: $stale"
    stale=$(awk '!/^#/ && $2 == "PENDING" { print $1 }' "$TT/kernel-config-waivers.txt" | LC_ALL=C sort | LC_ALL=C comm -12 - <(echo "$miss") | paste -sd ' ')
    [ -z "$stale" ] || info "missing by mistake, fixed in the kernel source, not in this kernel yet: $stale"
    # Every HAL the device manifest declares has to be there: HIDL in lshal, AIDL in the service manager
    local dm reg h pat ok n=0 un=""
    dm=$(grep -E '^ +DM ' <<<"$v" | sed -E 's/^ +DM +(FM +)?(FCM +)?(DCM +)?//; s/ +\(@[0-9]+\)$//' | sort -u)
    reg=$( { a 'lshal --types=b,c -i --neat'; a 'service list' | sed -E 's/^[0-9]+[[:space:]]+(.*): \[.*$/\1/'; } | sort -u)
    while read -r h; do
        [ -n "$h" ] || continue
        n=$((n+1)); grep -qxF "$h" <<<"$reg" && continue
        ok=0
        while read -r pat _; do
            case "$pat" in ""|"#"*) continue;; esac
            # shellcheck disable=SC2254
            case "$h" in $pat) ok=1; break;; esac
        done < "$TT/hal-waivers.txt"
        [ $ok = 1 ] || un="$un $h"
    done <<<"$dm"
    [ "$n" -gt 0 ] && [ -z "$un" ] && pass "the $n HALs the device manifest declares are registered, or listed with a reason in $TT/hal-waivers.txt" || fail "declared in the device manifest ($n HALs) but not registered:${un:- (none read)}"
}
t_cpu_hotplug() {
    # Thermal protection (at 95 C) and suspend take cores offline. A kernel that powers a cluster
    # down under its running cores hangs at the first big core that goes offline.
    local c
    for c in 7 3; do
        a "echo 0 > /sys/devices/system/cpu/cpu$c/online"; sleep 1
        chk "cpu$c goes offline" "$(a "cat /sys/devices/system/cpu/cpu$c/online")" 0
        a "echo 1 > /sys/devices/system/cpu/cpu$c/online"; sleep 1
        chk "cpu$c comes back" "$(a "cat /sys/devices/system/cpu/cpu$c/online")" 1
    done
    a 'for c in 4 5 6 7; do echo 0 > /sys/devices/system/cpu/cpu$c/online; done'; sleep 2
    chk "the big cluster goes offline as a whole (CPUs left)" "$(a cat /sys/devices/system/cpu/online)" 0-3
    a 'for c in 4 5 6 7; do echo 1 > /sys/devices/system/cpu/cpu$c/online; done'; sleep 2
    chk "all CPUs online again" "$(a cat /sys/devices/system/cpu/online)" 0-7
    chk "one TrustZone worker thread per CPU afterwards" "$(a 'pgrep tz_worker | wc -l')" 8
    chk "big cluster frequency policy back (CPUs of policy4)" "$(a cat /sys/devices/system/cpu/cpufreq/policy4/related_cpus)" "4 5 6 7"
}
t_tee() {
    # Keys in the TEE through keystore2 and Samsung's keymaster 4.0 trustlet, as apps get them
    local n="tt_test_$$" r c
    chk "keystore: generate an RSA key (exit status)" "$(a "keystore_cli_v2 generate --name=$n >/dev/null 2>&1; echo \$?")" 0
    c=$(a "keystore_cli_v2 get-chars --name=$n 2>&1" | awk '/^Hardware:/ { hw = 1; next } /^Software:/ { hw = 0 } hw { print }' | paste -sd ' ')
    grep -q ALGORITHM <<<"$c" && grep -q KEY_SIZE <<<"$c" && pass "the key is enforced by hardware (TEE): $(wc -w <<<"$c") properties, among them algorithm, size, origin and patch levels" || fail "the key's properties are not hardware-enforced: ${c:-none}"
    r=$(a "keystore_cli_v2 sign-verify --name=$n 2>&1" | paste -sd ' ')
    grep -q 'Verify: OK' <<<"$r" && pass "sign and verify with it ($(grep -oE 'Sign: [0-9]+ bytes' <<<"$r"))" || fail "sign-verify: $(cut -c1-160 <<<"$r")"
    r=$(a "keystore_cli_v2 delete --name=$n 2>&1" | tail -1)
    grep -q 'Successfully deleted' <<<"$r" && pass "key deleted" || fail "delete: $(cut -c1-160 <<<"$r")"
    chk "BoringSSL self test, system copy (exit status)" "$(a '/system/bin/boringssl_self_test64 >/dev/null 2>&1; echo $?')" 0
    chk "BoringSSL self test, vendor copy (exit status)" "$(a '/vendor/bin/boringssl_self_test64 >/dev/null 2>&1; echo $?')" 0
    # The kernel threads that carry the secure world must go back to sleep after use
    local b; b=$(cpu_busy 4 | awk '$3 ~ /^tz_worker/ && $1 >= 50 { printf "%s %s %%, ", $3, $1 }')
    [ -z "$b" ] && pass "TrustZone worker threads idle after use" || fail "TrustZone worker thread keeps running: ${b%, } of one core (the secure world keeps asking for that core; taking that core offline and online again, then one keystore operation, has stopped it before)"
}
t_codecs() {
    # Each hardware encoder makes 30 frames, the matching hardware decoder has to turn them back
    # into pictures. In between, ffmpeg on this side only puts the stream into a container.
    need_dex || return
    local d="$OUT/codecs" mime enc dec raw fmt opt cont size r f
    mkdir -p "$d"
    media_tools || info "ffmpeg is missing on this side: the encoders are tested, the decoders are not"
    while read -r mime enc dec raw fmt opt cont size <&3; do
        f=/data/local/tmp/tt_codec
        r=$(jrun "EncTest $mime $enc ${size%x*} ${size#*x} 30 $f.$raw" | grep '^RESULT ' | tail -1)
        if [ "$(field ok "$r")" != 1 ]; then fail "$enc: ${r:-no result}"; continue; fi
        pass "$enc: 30 frames $size encoded ($(field bytes "$r") bytes, $(field ms "$r") ms)"
        media_tools || { a "rm -f $f.$raw"; continue; }
        pull "$f.$raw" "$d/$enc.$raw"; case "$opt" in -) opt="";; fr*) opt="-framerate ${opt#fr}";; esac
        # shellcheck disable=SC2086
        if ! ffmpeg -nostdin -v error -y -f "$fmt" $opt -i "$d/$enc.$raw" -c copy "$d/$enc.$cont" </dev/null 2>"$d/$enc.ffmpeg.log"; then
            fail "$enc: ffmpeg cannot read the stream ($(head -1 "$d/$enc.ffmpeg.log" | cut -c1-120))"; a "rm -f $f.$raw"; continue
        fi
        push "$d/$enc.$cont" "$f.$cont"
        r=$(jrun "DecTest $f.$cont $dec 25" | grep '^RESULT ' | tail -1)
        [ "$(field ok "$r")" = 1 ] && pass "$dec: decoded them back ($(field frames_out "$r") frames $(field size "$r"), $(field ms "$r") ms)" || fail "$dec: ${r:-no result}"
        a "rm -f $f.$raw $f.$cont"
    done 3<<'EOF'
video/avc OMX.Exynos.AVC.Encoder OMX.Exynos.avc.dec h264 h264 fr30 mp4 640x480
video/hevc OMX.Exynos.HEVC.Encoder OMX.Exynos.hevc.dec hevc hevc fr30 mp4 640x480
video/x-vnd.on2.vp8 OMX.Exynos.VP8.Encoder OMX.Exynos.vp8.dec ivf ivf - webm 640x480
video/x-vnd.on2.vp9 OMX.Exynos.VP9.Encoder OMX.Exynos.vp9.dec ivf ivf - webm 640x480
video/mp4v-es OMX.Exynos.MPEG4.Encoder OMX.Exynos.mpeg4.dec m4v m4v fr30 mp4 640x480
video/3gpp OMX.Exynos.H263.Encoder OMX.Exynos.h263.dec h263 h263 fr30 3gp 352x288
EOF
}
t_apps() {
    # Every app the ROM ships with a launcher icon has to start. Only those: never the apps the owner installed.
    if ! wait_unlock; then info "SKIPPED: screen locked"; return; fi
    local sys comp pkg r st ms top n=0
    sys=$(a 'pm list packages -s' | sed 's/^package://')
    while read -r comp <&3; do
        pkg=${comp%%/*}
        grep -qxF "$pkg" <<<"$sys" || continue
        [ "$pkg" = org.lineageos.aperture ] && continue      # the camera test starts it
        r=$(a "am start -W -n '$comp'"); st=$(grep -m1 -oE 'Status: [a-z]+' <<<"$r" | cut -d' ' -f2); ms=$(grep -m1 -oE 'TotalTime: [0-9]+' <<<"$r" | cut -d' ' -f2)
        sleep 2; top=$(a 'dumpsys activity activities' | grep -m1 -E 'topResumedActivity=' | grep -oE '[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+' | head -1)
        n=$((n+1))
        case "${top%%/*}" in
            "$pkg") pass "$pkg starts (${ms:-?} ms)";;
            com.android.permissioncontroller|com.google.android.permissioncontroller) pass "$pkg starts and asks for a permission (${ms:-?} ms)";;
            *) fail "$pkg: status ${st:-none}, on top afterwards: ${top:-nothing}";;
        esac
        a 'input keyevent KEYCODE_HOME'; sleep 1
    done 3< <(a 'cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER' | grep / | sed 's/^ *//' | sort -u)
    chk_ge "apps of the ROM with a launcher icon" "$n" 5
}
# tether_up IFACE-PATTERN WHAT: the tethering service has to have the interface in TetheredState
# without an error, with forwarding rules to the upstream network. netd sets those up in one
# batch with two connection tracking helpers (ftp, pptp): a kernel without one of them fails it
# all ("lastError = 8").
tether_up() {
    local st ifc fw
    st=$(a 'dumpsys tethering' | grep -m1 -oE "($1) - [A-Za-z]+ - lastError = [0-9]+"); ifc=${st%% *}
    case "$st" in
        *"TetheredState - lastError = 0") pass "$2: the tethering service serves $ifc ($(a "ip -4 -o addr show $ifc" | awk '{ print $4 }'))";;
        *) fail "$2: tethering did not come up (${st:-the tethering service does not know the interface}; lastError 8: forwarding could not be enabled, see the iptables errors of netd in the log)"; return;;
    esac
    if a 'dumpsys connectivity' | grep -q 'Active default network: [0-9]'; then
        fw=$(a 'iptables -w -S tetherctrl_FORWARD' | grep -c -- "-i $ifc "); chk_ge "$2: forwarding rules from $ifc to the upstream network" "$fw" 1
        info "$2: connection tracking helpers netd attached for $ifc: $(a 'iptables -w -t raw -S tetherctrl_raw_PREROUTING' | grep -- "-i $ifc " | grep -oE -- '--helper [a-z0-9]+' | awk '{ print $2 }' | sort -u | paste -sd ' ')"
    else
        info "$2: no upstream network at the moment, forwarding rules not checked"
    fi
}
t_usb() {
    [ "${USB:-0}" = 1 ] || { info "SKIPPED (USB=1 enables it; adb drops for a moment at every switch)"; return; }
    usbfn() { a 'dumpsys usb' | grep -m1 -oE 'current_functions=[A-Z_,]*' | cut -d= -f2; }
    usbset() { a "svc usb setFunctions $1" >/dev/null; sleep 6; timeout 40 adb -s "$SERIAL" wait-for-device; sleep "${2:-1}"; }
    usbset mtp
    chk "USB function MTP set and adb back" "$(usbfn)" MTP
    a 'ls -l /config/usb_gadget/g1/configs/b.1/' | grep -q 'functions/ffs.mtp' && pass "the gadget carries the MTP function" || fail "no MTP function in the gadget configuration"
    local before hif="" n=0 rtt
    before=$(ip -br link 2>/dev/null | awk '{ print $1 }')
    usbset rndis 6
    chk "USB function tethering (RNDIS) set and adb back" "$(usbfn)" RNDIS
    tether_up 'rndis[0-9]+|usb[0-9]+' "USB tethering"
    # The other end: this computer is the tethered device. If its network manager takes the new
    # interface (it gets an address from the tablet), send a few packets through it.
    while [ $n -lt 12 ]; do
        hif=$(ip -4 -br addr 2>/dev/null | awk '$3 != "" { print $1 }' | grep -vxF "$before" | head -1)
        [ -n "$hif" ] && break; sleep 1; n=$((n+1))
    done
    if [ -n "$hif" ]; then
        rtt=$(ping -4 -I "$hif" -c 3 -W 3 1.1.1.1 2>/dev/null | grep -oE 'rtt .*')
        [ -n "$rtt" ] && pass "this computer reaches the internet through the tablet's USB tethering ($rtt)" || fail "this computer got an address on the tethered link but reaches nothing through it"
    else
        info "this computer did not take an address on the tethered link: a client's traffic is not tested"
    fi
    usbset ""
    chk "USB back to adb alone (functions)" "$(usbfn)" ""
    chk "adb is root again after the switches" "$(a id -u)" 0
}
t_reboot() {
    [ "${REBOOT:-0}" = 1 ] || { info "SKIPPED (REBOOT=1 enables it; the tablet then waits for its PIN)"; return; }
    local t0 n=0
    adb -s "$SERIAL" reboot; t0=$(date +%s); sleep 5
    timeout 180 adb -s "$SERIAL" wait-for-device || { fail "the tablet is not back on adb 180 s after the restart command"; return; }
    while [ $n -lt 120 ] && [ "$(a getprop sys.boot_completed)" != 1 ]; do sleep 2; n=$((n+2)); done
    chk "boot completed after the restart" "$(a getprop sys.boot_completed)" 1
    info "boot completed $(( $(date +%s) - t0 )) s after the restart command"
    adb -s "$SERIAL" root >/dev/null 2>&1; sleep 3; timeout 60 adb -s "$SERIAL" wait-for-device
    case "$(a getprop sys.boot.reason)" in reboot*) pass "boot reason $(a getprop sys.boot.reason)";; *) fail "boot reason $(a getprop sys.boot.reason), expected reboot";; esac
    t_system    # reset reason, the end of the kernel log of the start before, boot time, crash store
}

cleanup() {
    local f
    for f in $CAM_MADE; do a "content delete --uri content://media/external/file --where \"_display_name='$f'\" >/dev/null 2>&1; rm -f '/sdcard/DCIM/Camera/$f'"; done
    a 'cmd connectivity airplane-mode disable; svc wifi enable; input keyevent KEYCODE_WAKEUP; svc power stayon false; am force-stop org.lineageos.aperture; am force-stop org.lineageos.glimpse; echo none > /sys/power/pm_test; for c in 1 2 3 4 5 6 7; do echo 1 > /sys/devices/system/cpu/cpu$c/online; done; rm -f /sdcard/Movies/tt_test.mp4 /sdcard/Movies/.tt_write /data/local/tmp/.tt_write /data/local/tmp/tt.png /data/local/tmp/tt.mp4 /data/local/tmp/tt_enctest.dex /data/local/tmp/tt_codec.* /data/local/tmp/tt_pm' >/dev/null
    [ "$WIFI_WAS_ON" = 1 ] || a 'svc wifi disable'     # as it was
    [ "$LOC_WAS" != false ] || a 'cmd location set-location-enabled false'
    [ -z "$VOL_WAS" ] || a "cmd media_session volume --stream 3 --set $VOL_WAS"
}
trap cleanup EXIT

# ---------------------------------------------------------------- main
if [ -z "$SERIAL" ]; then
    SERIAL=$(adb devices | awk 'NR > 1 && $2 == "device" {print $1}')
    case "$(printf '%s\n' "$SERIAL" | grep -c .)" in
        1) ;;
        0) echo "!!! adb sees no device (USB debugging on, this computer allowed?)"; exit 1 ;;
        *) echo "!!! Several adb devices ($(echo $SERIAL)) - choose one with SERIAL=<serial>"; exit 1 ;;
    esac
fi
[ "$(a getprop ro.product.device)" = gta4xl ] || { echo "!!! $SERIAL is not a gta4xl (ro.product.device=$(a getprop ro.product.device))"; exit 1; }
adb -s "$SERIAL" root >/dev/null 2>&1 || true; adb -s "$SERIAL" wait-for-device
WIFI_WAS_ON=1; a 'cmd wifi status' | head -1 | grep -q 'Wifi is disabled' && WIFI_WAS_ON=0
a 'svc power stayon true; input keyevent KEYCODE_WAKEUP'; sleep 2
[ "$(a id -u)" = 0 ] || { echo "!!! adb is not root (Developer options -> Rooted debugging)"; exit 1; }
echo "# Tablet test $(date '+%Y-%m-%d %H:%M') - $(a getprop ro.lineage.version) / $(a uname -r)" > "$REPORT"
echo ">>> report: $REPORT"
if [ "$WIFI_WAS_ON" = 0 ]; then
    echo ">>> Wi-Fi is switched off: switching it on for the tests, off again at the end"
    a 'svc wifi enable'; n=0; while [ $n -lt 40 ]; do a 'cmd wifi status' | grep -q 'Wifi is connected' && break; sleep 1; n=$((n+1)); done
fi
run_test system           "build, boot state, how the start before ended, SELinux, verity, encryption"
run_test services         "init services and HALs"
run_test kernel_api       "kernel interface: VTS sysfs rules, CPU capacities, thermal zones, eBPF"
run_test vintf            "manifests, compatibility matrices, kernel configuration, declared HALs"
run_test storage          "/data and /sdcard (FUSE passthrough) throughput, fs errors, wear, SD card"
run_test memory_cpu       "RAM/swap, lmkd, idle CPUs, cpufreq under load"
run_test cpu_hotplug      "cores offline and online, the big cluster as a whole"
run_test thermal_battery  "thermal zones, battery, wear, charging"
run_test display          "panel state, resolution, backlight control, screencap"
run_test input            "touchscreen, S-Pen, keys, hall, grip sensors, controller self tests"
run_test sensors          "sensor HAL list, events from each sensor"
run_test wifi             "link, ping, DNS, validation, scan, off/on, factory address"
run_test network_services "private DNS, NTP, clock, captive portal config"
run_test bluetooth        "enable/disable, factory address"
run_test cellular         "RIL, registration and mobile data with a SIM, airplane mode on/off"
run_test gps              "location switch, GNSS HAL"
run_test audio            "volume tone through the audio HAL"
run_test tee              "keystore keys in the TEE, crypto self tests, TrustZone workers"
run_test codecs           "the six hardware video encoders and their decoders, round trip"
run_test screenrecord     "display capture + hardware H.264 encoder"
run_test camera           "photo with both cameras, video with sound (needs unlocked screen)"
run_test video            "hardware decode + audio playback (needs unlocked screen)"
run_test apps             "every app of the ROM starts (needs unlocked screen)"
run_test updater          "Updater check-in against the update server (only with OTA_BASE_URL)"
run_test packages         "installed apps, debloat list"
run_test security         "sysctls, build props, SELinux denials since boot"
run_test suspend          "screen off, idle CPUs, driver suspend/resume cycle, wake, Wi-Fi after wake"
run_test hotspot          "Wi-Fi hotspot (optional, HOTSPOT=1)"
run_test usb              "USB functions MTP and tethering (optional, USB=1)"
run_test reboot           "restart and how it went (optional, REBOOT=1)"

echo; echo "=== $PASSN PASS, $FAILN FAIL"; printf '\n## Summary: %d PASS, %d FAIL\n' "$PASSN" "$FAILN" >> "$REPORT"
[ -z "$FAILS" ] || { printf "$FAILS\n"; printf "$FAILS\n" | sed 's/^  /- /' >> "$REPORT"; }
echo "=== unknown error lines over the whole run (top 12):"
cat "$OUT"/*.log 2>/dev/null | { grep -E '^[EF]/'; } | grep -vE "$KNOWN" | sed -E 's/[0-9]{3,}/N/g' | sort | uniq -c | sort -rn | head -12 | sed 's/^/  /'
echo "report: $REPORT"
exit $(( FAILN > 125 ? 125 : FAILN ))
