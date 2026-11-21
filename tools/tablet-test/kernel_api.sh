# Runs on the tablet (sourced by tools/tablet-test.sh through adb shell, after ok/no/nfo are defined).
# First part: what Android's VTS KernelApiSysfsTest asks of the kernel's sysfs
# (test/vts-testcase/kernel/api/sysfs in the Android tree). Second part: things that were wrong
# on this board at some point of the kernel port without any error message, and LineageOS's
# rules for kernels.
on=$(cat /sys/devices/system/cpu/online)
echo "$on" | grep -qE "^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$" && ok "cpu/online is a list of ranges ($on)" || no "cpu/online is \"$on\""
km=$(cat /sys/devices/system/cpu/kernel_max); [ "$km" -ge 0 ] 2>/dev/null && ok "cpu/kernel_max is an integer ($km)" || no "cpu/kernel_max is \"$km\""
miss=""; n=0
for c in /sys/devices/system/cpu/cpu[0-9]*; do
	n=$((n+1))
	for f in scaling_cur_freq scaling_min_freq scaling_max_freq scaling_available_frequencies stats/time_in_state; do
		[ -r $c/cpufreq/$f ] || miss="$miss ${c##*/}/$f"
	done
done
[ -z "$miss" ] && ok "cpufreq files of $n CPUs (current, min, max, available frequencies, time_in_state)" || no "cpufreq files missing:$miss"
[ -r /sys/kernel/wakeup_reasons/last_resume_reason ] && ok "wakeup_reasons/last_resume_reason readable" || no "wakeup_reasons/last_resume_reason missing"
bad=""; for d in /sys/class/net/*; do m=$(cat $d/mtu 2>/dev/null); [ "${m:-0}" -gt 0 ] 2>/dev/null || bad="$bad ${d##*/}"; done
[ -z "$bad" ] && ok "every network interface has an integer mtu" || no "mtu unreadable for:$bad"
want=$(zcat /proc/config.gz 2>/dev/null | sed -n "s/^CONFIG_RTC_HCTOSYS_DEVICE=\"\(.*\)\"/\1/p")
have=$(readlink -n /dev/rtc 2>/dev/null); [ -n "$have" ] || { [ -e /dev/rtc0 ] && have=rtc0; }; have=${have##*/}
[ -n "$want" ] && [ "$want" = "$have" ] && ok "/dev/rtc is CONFIG_RTC_HCTOSYS_DEVICE ($want)" || no "/dev/rtc is \"$have\", CONFIG_RTC_HCTOSYS_DEVICE is \"$want\""
l=tt_test_wakelock_$$
echo $l > /sys/power/wake_lock; a1=" $(cat /sys/power/wake_lock) "
echo $l > /sys/power/wake_unlock; a2=" $(cat /sys/power/wake_lock) "; u2=" $(cat /sys/power/wake_unlock) "
x=0; y=1; z=0
case "$a1" in *" $l "*) x=1;; esac; case "$a2" in *" $l "*) y=0;; esac; case "$u2" in *" $l "*) z=1;; esac
[ "$x$y$z" = 111 ] && ok "wake_lock and wake_unlock take and release a lock" || no "wake lock: active after locking $x, gone after unlocking $y, listed as inactive $z"
[ -w /sys/power/wakeup_count ] && ok "wakeup_count present" || no "wakeup_count missing"
st=$(cat /sys/power/state); bad=""; mem=0
for s in $st; do case $s in mem) mem=1;; freeze|disk|standby) ;; *) bad="$bad $s";; esac; done
[ -z "$bad" ] && [ $mem = 1 ] && ok "power states ($st)" || no "power states \"$st\" (unknown:$bad, mem: $mem)"
usb=$(cat /sys/class/android_usb/android0/state 2>/dev/null)
case "$usb" in ""|DISCONNECTED|CONNECTED|CONFIGURED) ok "android_usb state (${usb:-node absent})";; *) no "android_usb state \"$usb\"";; esac
[ -r /proc/config.gz ] && ok "/proc/config.gz readable" || no "/proc/config.gz missing"
zcat /proc/config.gz 2>/dev/null | grep -q "^CONFIG_INIT_STACK_ALL_ZERO=y" && ok "kernel stack initialisation (INIT_STACK_ALL_ZERO)" || no "CONFIG_INIT_STACK_ALL_ZERO is off"

# The board: with a wrong EMS binding every CPU has capacity 0, and schedutil sits on the lowest step.
caps=""; z=0
for c in /sys/devices/system/cpu/cpu[0-9]*; do v=$(cat $c/cpu_capacity 2>/dev/null); caps="$caps ${v:-?}"; [ "${v:-0}" -gt 0 ] 2>/dev/null || z=1; done
lit=$(cat /sys/devices/system/cpu/cpu0/cpu_capacity 2>/dev/null); big=$(cat /sys/devices/system/cpu/cpu7/cpu_capacity 2>/dev/null)
[ $z = 0 ] && [ "${big:-0}" -gt "${lit:-0}" ] && ok "CPU capacities, big above little ($caps )" || no "CPU capacities ($caps )"
# LineageOS device support requirements: governors and I/O schedulers from its lists only.
bad=""; govs=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_available_governors 2>/dev/null | tr " " "\n" | sort -u | tr "\n" " ")
for g in $govs; do case $g in conservative|energy_aware|energy_step|interactive|ondemand|performance|powersave|sched|sched_pixel|schedutil|userspace|walt) ;; *) bad="$bad $g";; esac; done
[ -z "$bad" ] && ok "cpufreq governors are on LineageOS's list ($govs)" || no "governors not on LineageOS's list:$bad"
bad=""; ios=""
for q in /sys/block/sd*/queue/scheduler /sys/block/mmcblk*/queue/scheduler; do
	[ -r $q ] || continue
	for s in $(tr -d "[]" < $q); do case " $ios " in *" $s "*) ;; *) ios="$ios $s";; esac; case $s in bfq|cfq|deadline|kyber|mq-deadline|noop|row|ssg|none) ;; *) bad="$bad $s";; esac; done
done
[ -z "$bad" ] && ok "I/O schedulers are on LineageOS's list ($ios )" || no "I/O schedulers not on LineageOS's list:$bad"
# Thermal: a zone without cooling devices bound is never throttled.
for t in BIG LITTLE G3D ISP; do
	f=0
	for zn in /sys/class/thermal/thermal_zone*; do
		[ "$(cat $zn/type)" = $t ] || continue
		f=1; cd=$(ls $zn | grep -c "^cdev[0-9]*$"); tr=$(ls $zn | grep -c "^trip_point_[0-9]*_temp$")
		[ "$cd" -gt 0 ] && [ "$tr" -gt 0 ] && ok "thermal zone $t: $tr trip points, $cd cooling devices bound, $(cat $zn/policy)" || no "thermal zone $t: $tr trip points, $cd cooling devices"
	done
	[ $f = 1 ] || no "thermal zone $t missing"
done
# eBPF: the loaders run against a kernel that claims 5.10 (ro.bpf.kver_override).
pl=$(getprop bpf.progs_loaded); np=$(ls /sys/fs/bpf /sys/fs/bpf/*/ 2>/dev/null | grep -c -E "^(prog|map)_")
[ "$pl" = 1 ] && [ "$np" -ge 50 ] && ok "eBPF programs loaded ($np pinned programs and maps, kver override $(getprop ro.bpf.kver_override))" || no "eBPF: bpf.progs_loaded=$pl, $np pinned objects"
zs=$(cat /sys/block/zram0/disksize 2>/dev/null); za=$(sed -E "s/.*\[([a-z0-9-]+)\].*/\1/" /sys/block/zram0/comp_algorithm 2>/dev/null)
# (the shell on the tablet counts in 32 bits: no arithmetic on byte counts)
case "$zs" in ""|0) no "zram disksize \"$zs\"";; *) ok "zram ${zs%??????} MB, $za";; esac
