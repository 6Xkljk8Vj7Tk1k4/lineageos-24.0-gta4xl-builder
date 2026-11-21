# Runs on the tablet (tools/tablet-test.sh, input). The controllers' own answers: the queries Samsung's
# factory test menu sends. Only queries: the open/short and raw-data tests take the panel out of
# normal operation and are not used here.
c=$(cat /sys/class/sec/sec_epen/epen_connection 2>/dev/null)
case "$c" in OK*) ok "S Pen digitizer answers its connection test ($c)";; *) no "S Pen digitizer connection test: \"$c\"";; esac
set -- $(cat /sys/class/sec/sec_epen/epen_firm_version 2>/dev/null)
[ -n "$1" ] && [ "$1" = "$2" ] && ok "S Pen digitizer firmware $1, the version this build carries" || nfo "S Pen digitizer firmware: chip \"$1\", build \"$2\""
tsp() { echo "$1" > /sys/class/sec/tsp/cmd 2>/dev/null; r=$(cat /sys/class/sec/tsp/cmd_result 2>/dev/null); echo "${r#*:}"; }
r=$(tsp check_connection); [ "$r" = OK ] && ok "touch controller answers its connection test ($(tsp get_chip_vendor) $(tsp get_chip_name), $(tsp get_x_num)x$(tsp get_y_num) channels)" || no "touch controller connection test: \"$r\""
i=$(tsp get_fw_ver_ic); b=$(tsp get_fw_ver_bin)
[ -n "$i" ] && [ "$i" = "$b" ] && ok "touch controller firmware $i, the version this build carries" || nfo "touch controller firmware: chip \"$i\", build \"$b\""
