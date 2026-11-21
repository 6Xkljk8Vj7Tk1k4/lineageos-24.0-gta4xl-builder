# Runs on the tablet (tools/tablet-test.sh, wifi and bluetooth). LineageOS: a device must report the
# same Wi-Fi and Bluetooth addresses as on stock, i.e. the ones the factory stored, not a default
# of the driver. Only the manufacturer part (first three bytes) is printed.
lower() { echo "$1" | tr "A-F" "a-f"; }
if [ "$1" = wifi ]; then
	f=$(lower "$(dumpsys wifi 2>/dev/null | grep -m1 -o "wifi_sta_factory_mac_address=[0-9a-fA-F:]*" | cut -d= -f2)")
	e=$(cat /mnt/vendor/efs/wifi/.mac.info 2>/dev/null || cat /mnt/vendor/efs/wifi/.mac.cob 2>/dev/null)
	e=$(lower "$(echo "$e" | head -1 | tr -d "\r\n " | cut -c1-17)")
	case "$f" in
	"") nfo "Wi-Fi factory address not in the Wi-Fi service's dump (Wi-Fi never switched on in this boot?)";;
	?[26ae]:*|00:00:00:*|ff:ff:ff:*) no "Wi-Fi factory address ${f%:*:*:*}:.. is not a manufacturer-assigned address";;
	*) if [ -z "$e" ]; then ok "Wi-Fi factory address is manufacturer-assigned (${f%:*:*:*}:..)"
	   elif [ "$f" = "$e" ]; then ok "Wi-Fi factory address is the one stored at the factory (${f%:*:*:*}:..)"
	   else no "Wi-Fi factory address ${f%:*:*:*}:.. differs from the one stored at the factory (${e%:*:*:*}:..)"; fi;;
	esac
else
	s=$(lower "$(settings get secure bluetooth_address)"); e=$(lower "$(cat /mnt/vendor/efs/bluetooth/bt_addr 2>/dev/null | head -1 | tr -d "\r\n " | cut -c1-17)")
	case "$s" in
	""|null) nfo "Bluetooth address not known to Android yet";;
	?[26ae]:*|00:00:00:*|ff:ff:ff:*) no "Bluetooth address ${s%:*:*:*}:.. is not a manufacturer-assigned address";;
	*) if [ -z "$e" ]; then ok "Bluetooth address is manufacturer-assigned (${s%:*:*:*}:..)"
	   elif [ "$s" = "$e" ]; then ok "Bluetooth address is the one stored at the factory (${s%:*:*:*}:..)"
	   else no "Bluetooth address ${s%:*:*:*}:.. differs from the one stored at the factory (${e%:*:*:*}:..)"; fi;;
	esac
fi
