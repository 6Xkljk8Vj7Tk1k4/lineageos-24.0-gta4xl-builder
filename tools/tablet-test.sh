#!/bin/bash
# tools/tablet-test.sh - functional test of the tablet over adb, one component at a time, with a
# logcat/dmesg/SELinux/crash delta after every test. Host-side; needs root adb (Developer
# options -> Rooted debugging) for dmesg, sysfs and /data. Nothing is installed on the device;
# temporary files go to /data/local/tmp and /sdcard/Movies/tt_test.mp4 and are removed. It
# toggles Wi-Fi, Bluetooth, airplane mode and the location switch and restores them afterwards,
# and the camera test leaves a photo and a short video in DCIM/Camera.
#
#   tools/tablet-test.sh                 # everything; camera/video wait up to UI_WAIT s for an unlocked screen
#   tools/tablet-test.sh wifi bluetooth  # only the named tests (names: see the run_test lines at the bottom)
#
# Env: SERIAL (adb serial; default: the only attached device, which must be a gta4xl), UI_WAIT
# (default 90), HOTSPOT=1 (also start/stop the Wi-Fi hotspot, off by default: the SCSC AP path is
# the least tested part of the driver), DNS_TEST_HOST (default lineageos.org), OUT (report
# directory, default build_output/tablet-test/<timestamp>/ with report.md and one raw log delta
# per test). The exit code is the number of failed checks.
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
KNOWN='CASS_DEBUG|RILClient|comm="cass"|charger_vendor|AppOps.*attributionTag|pixel-thermal.*cooling device|ImeiPreference|setState is called with an earlier timestamp|updateValue is called with a value|/sys/kernel/dmabuf|prog_dmabufIter|Passpoint|Wiphy index not recorded|trace_pipe|WindowOrganizerController|a96t3x6|gpio_to_desc|Unrecognized and/or unsupported format|audit: rate limit|audit_lost|ConnectivityService is null in handleBindApplication|wifiaware|WifiShellCommand|E/lshal|libbinder.Parcel.*NULL string|GetServerConfigurableFlag|Satellite|DlbDlbEffect|comm="vaultkeeperd"|comm="ESAR"|comm="OCR"|RILD.*(IO channel write error|SehChannelCallback == null|send SSAC info to IMS)|wifi-service.*Unknown iface name|WifiChipAidlImpl.*getUsableChannels|comm="rild".*(default_prop|system_prop)|comm="cbd"|servicemanager.*hal_power_default|OMXNodeInstance.*UnsupportedIndex|Failed to get surface config from BQ|ScreenRecorder.*getUniqueId|RILD.*nlmsg_type|SystemServiceRegistry|mediaprovider_app.*shell_data_file|mali_winsys.*chroma siting|libcsc.*csc_deinit|SensorListener.*not enabled yet|Failed to query component interface|ExynosCameraStreamManagerSec|Codec2-ComponentInterface.*failed config|Binder transaction failure.*BR_(FROZEN|DEAD)_REPLY|FeatureFlagsImplExport|BpTransactionCompletedListener|ConsumerBase.*abandoned'

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
keyguard_showing() { [ "$(a 'dumpsys window policy' | grep -m1 -oE 'showing=(true|false)')" = "showing=true" ]; }
CUR=""
run_test() {
    local name=$1 title=$2
    [ -z "$ONLY" ] || grep -qw "$name" <<<"$ONLY" || return 0
    CUR=$name
    echo; echo "### $name: $title"; printf '\n## %s: %s\n' "$name" "$title" >> "$REPORT"
    local ts up; ts=$(a "date '+%m-%d %H:%M:%S.000'"); up=$(a 'cut -d. -f1 /proc/uptime')
    "t_$name"
    log_delta "$name" "$ts" "$up"
}
log_delta() {
    local name=$1 ts=$2 up=$3 f="$OUT/$name.log"
    {   echo "## logcat E/F since $ts"
        a "logcat -d -b main,system,radio -v brief -T '$ts' '*:E'" | grep -E '^[EF]/'
        echo "## events"; a "logcat -d -b events -v brief -T '$ts'" | grep -E 'am_crash|am_anr|am_native_crash|am_wtf'
        echo "## crash"; a "logcat -d -b crash -v brief -T '$ts'" | grep -vE '^-+ beginning'
        echo "## dmesg since uptime $up"
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
    info "boot to screen: $(a 'logcat -d -b events | grep -m1 -oE "boot_progress_enable_screen: [0-9]+"' | awk '{printf "%.1f s", $2/1000}')"
    chk "boot_completed" "$(a getprop sys.boot_completed)" 1
    chk "SELinux" "$(a getenforce)" Enforcing
    chk "dm-verity" "$(a getprop ro.boot.veritymode)" enforcing
    chk "FBE" "$(a getprop ro.crypto.state)/$(a getprop ro.crypto.type)" encrypted/file
    chk "CPUs online" "$(a cat /sys/devices/system/cpu/online)" 0-7
    chk "zram swap" "$(a 'grep -c zram /proc/swaps')" 1
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
}
t_memory_cpu() {
    info "$(a 'grep -E "^(MemTotal|MemAvailable|SwapTotal|SwapFree)" /proc/meminfo' | awk '{printf "%s %d MB, ", $1, $2/1024}')"
    info "lmkd kills since boot: $(a 'logcat -d -b events | grep -c am_kill'), oom in dmesg: $(a 'dmesg | grep -ci "out of memory"')"
    info "governor $(a cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)/$(a cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_governor), cur MHz: $(a 'cat /sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq' | awk '{printf "%d ", $1/1000}'), max: $(a 'cat /sys/devices/system/cpu/cpufreq/policy*/cpuinfo_max_freq' | awk '{printf "%d ", $1/1000}')"
    local before after
    before=$(a 'cat /sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq')
    a 'for i in 1 2 3 4; do (timeout 4 sh -c "while :; do :; done" &) ; done; sleep 2; cat /sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq' > "$OUT/.load" ; after=$(tail -1 "$OUT/.load"); sleep 3
    chk_ge "big cluster clocks up under load (kHz)" "$after" "$before"
}
t_thermal_battery() {
    info "temps: $(a 'dumpsys thermalservice' | grep -oE 'mValue=[0-9.]+, mType=[0-9]+, mName=[A-Za-z0-9_]+' | sed -E 's/mValue=([0-9]+)[0-9.]*, mType=[0-9]+, mName=([A-Za-z0-9_]+)/\2=\1/' | paste -sd ' ')"
    chk "thermal status (0 = none)" "$(a 'dumpsys thermalservice' | grep -m1 -oE 'Thermal Status: [0-9]' | awk '{print $3}')" 0
    info "battery: $(a 'dumpsys battery' | grep -E 'level|status|health|temperature|voltage|AC powered|USB powered' | sed -E 's/^ +//' | paste -sd ',' | sed 's/,/, /g')"
    chk "battery health (2 = good)" "$(a 'dumpsys battery' | grep -m1 -oE 'health: [0-9]' | awk '{print $2}')" 2
}
t_display() {
    info "display: $(a 'dumpsys display' | grep -m1 -oE 'mScreenState=[A-Z_]+|mState=[A-Z]+'), $(a 'dumpsys display' | grep -m1 -oE 'fps=[0-9.]+|refreshRate=[0-9.]+' ), panel $(a 'dumpsys SurfaceFlinger' | grep -m1 -oE '[0-9]+x[0-9]+' )"
    local mode b0 blo bhi png
    mode=$(a settings get system screen_brightness_mode); b0=$(a settings get system screen_brightness)
    a 'settings put system screen_brightness_mode 0; settings put system screen_brightness 20'; sleep 2; blo=$(a cat /sys/class/backlight/panel/brightness)
    a 'settings put system screen_brightness 250'; sleep 2; bhi=$(a cat /sys/class/backlight/panel/brightness)
    a "settings put system screen_brightness $b0; settings put system screen_brightness_mode $mode"
    [ "${bhi:-0}" -gt "${blo:-0}" ] 2>/dev/null && pass "backlight follows brightness setting (sysfs $blo -> $bhi)" || fail "backlight did not change ($blo -> $bhi)"
    a 'screencap -p /data/local/tmp/tt.png'; png=$(a 'stat -c %s /data/local/tmp/tt.png 2>/dev/null'); a 'rm -f /data/local/tmp/tt.png'
    chk_ge "screencap PNG size (bytes)" "${png:-0}" 20000
    info "GPU: $(a 'dumpsys SurfaceFlinger' | grep -m1 -iE 'GLES|renderer' | sed -E 's/^ +//' | cut -c1-100)"
}
t_input() {
    local devs d
    devs=$(a 'getevent -il' | grep -oE 'name: +"[^"]+"' | sed -E 's/name: +"//; s/"//' | paste -sd ',')
    info "input devices: $devs"
    for d in sec_touchscreen sec_e-pen gpio_keys hall grip_sensor; do grep -q "$d" <<<"$devs" && pass "input device $d present" || fail "input device $d missing"; done
    # a key that does nothing: a tap could hit an icon when the screen is unlocked
    a 'input keyevent KEYCODE_UNKNOWN' && pass "input injection (key event) accepted" || fail "input injection failed"
    info "S-Pen HAL: $(a lshal 2>/dev/null | grep -ciE 'spen'), touch HAL: $(a lshal 2>/dev/null | grep -ciE 'touch')"
}
t_sensors() {
    local list
    list=$(a 'dumpsys sensorservice' | grep -oE '^[0-9a-fx]+\) [^|]+\|' | sed -E 's/^[0-9a-fx]+\) //; s/ +\|$//')
    info "sensors ($(echo "$list" | grep -c .)): $(echo "$list" | paste -sd ',' | cut -c1-300)"
    local s; for s in Accelerometer Gyroscope Light; do grep -q "$s" <<<"$list" && pass "sensor $s present" || fail "sensor $s missing"; done
    info "active sensors: $(a 'dumpsys sensorservice' | grep -cE 'active-count = [1-9]'), events: $(a 'dumpsys sensorservice' | grep -m1 -A1 -E 'Recent events|Last [0-9]+ events' | tail -1 | sed -E 's/^ +//' | cut -c1-80)"
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
    orig=$(a settings get global bluetooth_on); info "bluetooth initially on=$orig, address $(a settings get secure bluetooth_address), name $(a settings get secure bluetooth_name)"
    a 'cmd bluetooth_manager enable' >/dev/null
    t=$(wait_for 25 'settings get global bluetooth_on' 1) && pass "Bluetooth enabled in $t s" || fail "Bluetooth did not enable"
    sleep 3; info "adapter: $(a 'dumpsys bluetooth_manager' | grep -m1 -oE '(state|enabled)[:=] *[A-Za-z_]+' | paste -sd ',')"
    chk "bluetooth HAL still running" "$(a getprop init.svc.vendor.bluetooth-1-0)" running
    if [ "$orig" != 1 ]; then a 'cmd bluetooth_manager disable' >/dev/null; t=$(wait_for 20 'settings get global bluetooth_on' 0) && pass "Bluetooth disabled again in $t s" || fail "Bluetooth did not disable"; fi
}
t_cellular() {
    info "SIM $(a getprop gsm.sim.state), baseband $(a getprop gsm.version.baseband), $(a 'dumpsys telephony.registry' | grep -m1 -oE 'mVoiceRegState=[0-9]\([A-Z_]+\)|mDataRegState=[0-9]\([A-Z_]+\)' | paste -sd ',')"
    chk "rild running" "$(a getprop init.svc.ril-daemon)" running
    a 'cmd connectivity airplane-mode enable' >/dev/null; sleep 6
    chk "airplane mode on" "$(a settings get global airplane_mode_on)" 1
    chk "rild survives airplane mode" "$(a getprop init.svc.ril-daemon)" running
    a 'cmd connectivity airplane-mode disable' >/dev/null; a 'svc wifi enable'
    local n=0; while [ $n -lt 45 ]; do a 'cmd wifi status' | grep -q 'Wifi is connected' && break; sleep 1; n=$((n+1)); done
    [ $n -lt 45 ] && pass "Wi-Fi back after airplane mode in $n s" || fail "Wi-Fi not back after airplane mode"
}
t_gps() {
    local orig; orig=$(a 'cmd location is-location-enabled')
    a 'cmd location set-location-enabled true' >/dev/null; sleep 3
    info "location was $orig; gps provider: $(a 'dumpsys location' | grep -m1 -A3 -iE '^ *gps provider' | grep -oE 'enabled=[a-z]+|allowed=[a-z]+|properties=[^,]*' | paste -sd ',')"
    chk "GNSS HAL registered" "$(a lshal 2>/dev/null | grep -ciE 'gnss' | awk '{print ($1>0)?"yes":"no"}')" yes
    info "gpsd log tail: $(a 'logcat -d -s gpsd:* GnssLocationProvider:* GnssNative:*' | tail -2 | sed -E 's/^[0-9: .-]+ +//' | cut -c1-100 | paste -sd ';')"
    [ "$orig" = true ] || a 'cmd location set-location-enabled false' >/dev/null
}
t_audio() {
    local up; up=$(a 'cut -d. -f1 /proc/uptime')
    info "audio HAL: $(a 'getprop | grep -oE "init.svc.vendor.audio[^]]*\]: \[[a-z]+"' | sed -E 's/init.svc.//; s/\]: \[/=/' | paste -sd ','), outputs: $(a 'dumpsys media.audio_flinger' | grep -m2 -oE 'AUDIO_DEVICE_OUT_[A-Z_]+' | sort -u | paste -sd ',')"
    a 'input keyevent KEYCODE_VOLUME_UP'; sleep 1; a 'input keyevent KEYCODE_VOLUME_DOWN'; sleep 2
    local n; n=$(a dmesg | awk -v s="$up" '{ t=$1; gsub(/[\[\]]/,"",t); if (t+0 >= s) print }' | grep -c 'abox.*pm qos')
    [ "$n" -gt 0 ] && pass "audio path woke up for the volume tone (ABOX qos requests: $n)" || info "no ABOX activity on volume keys (tone may be disabled); audio is also exercised by the video test"
    chk "audioserver running" "$(a getprop init.svc.audioserver)" running
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
t_camera() {
    if ! wait_unlock; then info "SKIPPED: screen locked"; return; fi
    local comp before after f
    comp=$(a 'cmd package resolve-activity --brief -a android.media.action.STILL_IMAGE_CAMERA -p org.lineageos.aperture' | tail -1)
    before=$(a 'ls /sdcard/DCIM/Camera 2>/dev/null | wc -l')
    a "am start -W -n $comp -a android.media.action.STILL_IMAGE_CAMERA" >/dev/null; sleep 5
    a 'input keyevent KEYCODE_CAMERA'; sleep 4; after=$(a 'ls /sdcard/DCIM/Camera 2>/dev/null | wc -l')
    if [ "$after" -le "$before" ]; then a 'input keyevent KEYCODE_VOLUME_UP'; sleep 4; after=$(a 'ls /sdcard/DCIM/Camera 2>/dev/null | wc -l'); fi
    f=$(a 'ls -t /sdcard/DCIM/Camera 2>/dev/null | head -1')
    [ "$after" -gt "$before" ] && pass "photo taken: $f ($(a "stat -c %s /sdcard/DCIM/Camera/$f") bytes)" || fail "no new photo in DCIM/Camera"
    a 'am force-stop org.lineageos.aperture'; sleep 1   # a running Aperture keeps its mode, the VIDEO_CAMERA intent would not switch it
    a "am start -W -n $comp -a android.media.action.VIDEO_CAMERA" >/dev/null; sleep 5
    before=$after; a 'input keyevent KEYCODE_CAMERA'; sleep 6; a 'input keyevent KEYCODE_CAMERA'; sleep 5
    after=$(a 'ls /sdcard/DCIM/Camera 2>/dev/null | wc -l'); f=$(a 'ls -t /sdcard/DCIM/Camera 2>/dev/null | head -1')
    if [ "$after" -gt "$before" ] && [[ "$f" == *.mp4 ]]; then pass "video recorded: $f ($(a "stat -c %s /sdcard/DCIM/Camera/$f") bytes)"; CAM_VIDEO=$f; else fail "no new .mp4 in DCIM/Camera (newest: $f)"; fi
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
    a 'am start -W -n org.lineageos.updater/.UpdatesActivity' >/dev/null; sleep 10
    local l; l=$(a 'logcat -d -s UpdatesActivity:* UpdaterService:* UpdatesCheckReceiver:* Utils:* UpdatesDbHelper:*' | tail -4 | sed -E 's/^[0-9: .-]+ +//' | cut -c1-120 | paste -sd ';')
    info "updater log: $l"
    grep -qiE 'Could not|Failed|IOException|SSL' <<<"$l" && fail "updater reported an error" || pass "updater check-in without error"
    a 'am force-stop org.lineageos.updater'
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
    local s0 f0 s1 f1 w up
    s0=$(a cat /sys/power/suspend_stats/success); f0=$(a cat /sys/power/suspend_stats/fail); up=$(a 'cut -d. -f1 /proc/uptime')
    a 'input keyevent KEYCODE_SLEEP'; sleep 3
    chk "screen off" "$(a 'dumpsys power' | grep -m1 -oE 'mWakefulness=[A-Za-z]+' | cut -d= -f2)" Asleep
    sleep 45
    s1=$(a cat /sys/power/suspend_stats/success); f1=$(a cat /sys/power/suspend_stats/fail)
    if [ "$s1" -gt "$s0" ]; then pass "SoC suspended while screen off (suspend success $s0 -> $s1, fail $f0 -> $f1)"; else info "no suspend in 45 s with USB/adb attached (success $s1, fail $f1); PowerManager: $(a 'dumpsys power' | grep -m1 -oE "Wake Locks: size=[0-9]+"), active kernel wakeup sources: $(a 'mount -t debugfs none /sys/kernel/debug 2>/dev/null; awk "NR>1 && \$6>0 {print \$1}" /sys/kernel/debug/wakeup_sources 2>/dev/null' | paste -sd , )"; fi
    info "wakeup_count readable within 3 s: $(a 'timeout 3 cat /sys/power/wakeup_count >/dev/null 2>&1 && echo yes || echo "no - a kernel wakeup source stays active (USB gadget while adb is attached?)"'); on battery since last unplug: $(a 'dumpsys batterystats' | grep -m1 -oE "Time on battery: [^\n]{0,80}")"
    a 'input keyevent KEYCODE_WAKEUP'; sleep 3
    chk "screen back on" "$(a 'dumpsys power' | grep -m1 -oE 'mWakefulness=[A-Za-z]+' | cut -d= -f2)" Awake
    sleep 4; a 'cmd wifi status' | grep -q 'Wifi is connected' && pass "Wi-Fi still connected after wake" || fail "Wi-Fi not connected after wake"
    info "resume errors in dmesg: $(a dmesg | awk -v s="$up" '{ t=$1; gsub(/[\[\]]/,"",t); if (t+0 >= s) print }' | grep -ciE 'failed to (suspend|resume)|dpm_run_callback.*error')"
}
t_hotspot() {
    [ "${HOTSPOT:-0}" = 1 ] || { info "SKIPPED (HOTSPOT=1 enables it)"; return; }
    a 'cmd wifi start-softap tt_test wpa2 tt_password_1 -b 2' >/dev/null; sleep 10
    local n; n=$(a 'ip -o link' | grep -cE 'swlan0|ap0'); chk_ge "softap interface up" "$n" 1
    a 'cmd wifi stop-softap' >/dev/null; sleep 5
    a 'cmd wifi status' | grep -q 'Wifi is connected' && pass "STA still connected after hotspot" || fail "STA lost after hotspot"
}

cleanup() {
    a 'cmd connectivity airplane-mode disable; svc wifi enable; input keyevent KEYCODE_WAKEUP; svc power stayon false; am force-stop org.lineageos.aperture; am force-stop org.lineageos.glimpse; am force-stop org.lineageos.updater; rm -f /sdcard/Movies/tt_test.mp4 /sdcard/Movies/.tt_write /data/local/tmp/.tt_write /data/local/tmp/tt.png /data/local/tmp/tt.mp4' >/dev/null
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
a 'svc power stayon true; input keyevent KEYCODE_WAKEUP'; sleep 2
[ "$(a id -u)" = 0 ] || { echo "!!! adb is not root (Developer options -> Rooted debugging)"; exit 1; }
echo "# Tablet test $(date '+%Y-%m-%d %H:%M') - $(a getprop ro.lineage.version) / $(a uname -r)" > "$REPORT"
echo ">>> report: $REPORT"
run_test system           "build, boot state, SELinux, verity, encryption"
run_test services         "init services and HALs"
run_test storage          "/data and /sdcard (FUSE passthrough) throughput, fs errors"
run_test memory_cpu       "RAM/swap, lmkd, cpufreq under load"
run_test thermal_battery  "thermal zones, battery"
run_test display          "panel state, backlight control, screencap"
run_test input            "touchscreen, S-Pen, keys, hall, grip sensors"
run_test sensors          "sensor HAL list"
run_test wifi             "link, ping, DNS, validation, scan, off/on"
run_test network_services "private DNS, NTP, clock, captive portal config"
run_test bluetooth        "enable/disable"
run_test cellular         "RIL, airplane mode on/off"
run_test gps              "location switch, GNSS HAL"
run_test audio            "volume tone through the audio HAL"
run_test screenrecord     "display capture + hardware H.264 encoder"
run_test camera           "photo and video with Aperture (needs unlocked screen)"
run_test video            "hardware decode + audio playback (needs unlocked screen)"
run_test updater          "Updater check-in against the update server (only with OTA_BASE_URL)"
run_test packages         "installed apps, debloat list"
run_test security         "sysctls, build props, SELinux denials since boot"
run_test suspend          "screen off, SoC suspend, wake, Wi-Fi after wake"
run_test hotspot          "Wi-Fi hotspot (optional, HOTSPOT=1)"

echo; echo "=== $PASSN PASS, $FAILN FAIL"; printf '\n## Summary: %d PASS, %d FAIL\n' "$PASSN" "$FAILN" >> "$REPORT"
[ -z "$FAILS" ] || { printf "$FAILS\n"; printf "$FAILS\n" | sed 's/^  /- /' >> "$REPORT"; }
echo "=== unknown error lines over the whole run (top 12):"
cat "$OUT"/*.log 2>/dev/null | { grep -E '^[EF]/'; } | grep -vE "$KNOWN" | sed -E 's/[0-9]{3,}/N/g' | sort | uniq -c | sort -rn | head -12 | sed 's/^/  /'
echo "report: $REPORT"
exit $(( FAILN > 125 ? 125 : FAILN ))
