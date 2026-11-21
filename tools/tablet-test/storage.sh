# Runs on the tablet (tools/tablet-test.sh, storage). Wear of the UFS chip, room for an update, SD card.
H=$(ls -d /sys/devices/platform/*.ufs/health_descriptor 2>/dev/null | head -1)
if [ -n "$H" ]; then
	la=$(($(cat $H/life_time_estimation_a))); lb=$(($(cat $H/life_time_estimation_b))); eol=$(($(cat $H/eol_info)))
	# JEDEC: 1 = up to 10 % of the rated life used ... 10 = up to 100 %, 11 = exceeded; pre-EOL 1 = normal
	if [ $eol -le 1 ] && [ $la -le 8 ] && [ $lb -le 8 ]; then
		ok "UFS wear: up to $((la * 10)) % (type A) and $((lb * 10)) % (type B) of the rated life used, spare blocks normal"
	else
		no "UFS wear: life time estimation A $la, B $lb (10 = end of rated life), pre-EOL info $eol (1 = normal)"
	fi
else
	nfo "no UFS health descriptor in sysfs"
fi
set -- $(df -k /data | tail -1)
[ "$4" -ge 3145728 ] 2>/dev/null && ok "free space on /data: $(($4 / 1048576)) GB ($5 used); an update needs about 2.5 GB" || no "only $(($4 / 1024)) MB free on /data; downloading and installing an update needs about 2.5 GB"
v=$(sm list-volumes public 2>/dev/null | head -1)
if [ -n "$v" ]; then
	case "$v" in *" mounted "*) ok "SD card mounted (${v%% *})";; *) no "SD card present but not mounted: $v";; esac
else
	nfo "no SD card in the slot (card reader: $(ls /sys/class/mmc_host 2>/dev/null | tr "\n" " "))"
fi
