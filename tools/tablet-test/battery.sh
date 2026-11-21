# Runs on the tablet (tools/tablet-test.sh, thermal_battery). Battery wear, and charging as LineageOS's
# device requirements put it: no forced fast charge over USB.
B=/sys/class/power_supply/battery
full=$(cat $B/charge_full 2>/dev/null); des=$(cat $B/charge_full_design 2>/dev/null); soh=$(cat $B/fg_asoc 2>/dev/null)
if [ "${des:-0}" -gt 0 ] 2>/dev/null; then
	pct=$(( full / (des / 100) ))
	[ "$pct" -ge 80 ] && ok "battery holds $((full / 1000)) mAh of $((des / 1000)) mAh when new ($pct %; the fuel gauge's own figure: ${soh:-?} %)" || no "battery holds only $pct % of its design capacity ($((full / 1000)) of $((des / 1000)) mAh)"
else
	nfo "battery capacity figures not available"
fi
cyc=$(cat $B/battery_cycle 2>/dev/null); [ "${cyc:--1}" -ge 0 ] 2>/dev/null && nfo "charge cycles: $cyc" || nfo "charge cycles: not counted by this fuel gauge"
st=$(cat $B/status); usb=$(cat /sys/class/power_supply/usb/online 2>/dev/null); ac=$(cat /sys/class/power_supply/ac/online 2>/dev/null)
cur=$(cat $B/batt_current_ua_avg 2>/dev/null); lim=$(cat /sys/class/power_supply/usb/current_max 2>/dev/null)
if [ "$usb" = 1 ] || [ "$ac" = 1 ]; then
	case "$st" in Charging|Full) ok "a supply is connected and the battery status is $st";; *) no "a supply is connected but the battery status is $st";; esac
	if [ "$usb" = 1 ]; then
		# a computer's data port: the USB specification allows 500 mA
		[ "${lim:-0}" -le 500000 ] 2>/dev/null && ok "input current limit on a USB data port: $((lim / 1000)) mA (USB allows 500)" || no "input current limit on a USB data port: $((lim / 1000)) mA, above what USB allows"
	else
		nfo "charger: input current limit $(( $(cat /sys/class/power_supply/ac/current_max 2>/dev/null) / 1000 )) mA"
	fi
	[ -n "$cur" ] && nfo "battery current, averaged: $((cur / 1000)) mA (negative: the supply does not cover what the tablet uses)"
else
	nfo "on battery: status $st, current $(( ${cur:-0} / 1000 )) mA"
fi
