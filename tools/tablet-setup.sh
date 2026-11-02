#!/bin/bash
# tools/tablet-setup.sh - sets the tablet up after an installation: installs every APK from a
# folder and connects to Wi-Fi (the network is saved too). Runs on the computer, over adb: USB
# debugging on, this computer allowed on the tablet.
#
# Usage:
#   tools/tablet-setup.sh -a ~/apk                    # only apps
#   tools/tablet-setup.sh -w "MyNetwork"              # only Wi-Fi, the password is asked for
#   tools/tablet-setup.sh -a ~/apk -w "MyNetwork" -p "password"
#
# Options:
#   -a DIR      installs (or updates) every *.apk in DIR; a subfolder with several *.apk is one
#               app in parts (split APK)
#   -g          grant the apps every permission in their manifest right away
#   -w SSID     Wi-Fi network to save and connect to
#   -p PASS     network password; without -p it comes from WIFI_PASSWORD or is asked for
#               without echo (it does not end up in the shell history); empty = open network
#   -t TYPE     open | owe | wpa2 | wpa3 | wep - detected from a scan by default
#   -H          hidden network (does not broadcast its SSID)
#   -s SERIAL   adb serial of the tablet (or SERIAL=...); default: the only attached device
set -euo pipefail

usage() {
    sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit "${1:-1}"
}

APK_DIR="" SSID="" SEC="" GRANT=() HIDDEN=()
SERIAL="${SERIAL:-}"
PASS="${WIFI_PASSWORD-}"
PASS_SET=0
[ -n "${WIFI_PASSWORD+x}" ] && PASS_SET=1
while getopts "a:gw:p:t:Hs:h" opt; do
    case "$opt" in
        a) APK_DIR="$OPTARG" ;;
        g) GRANT=(-g) ;;
        w) SSID="$OPTARG" ;;
        p) PASS="$OPTARG"; PASS_SET=1 ;;
        t) SEC="$OPTARG" ;;
        H) HIDDEN=(-h) ;;
        s) SERIAL="$OPTARG" ;;
        h) usage 0 ;;
        *) usage ;;
    esac
done
[ -z "$APK_DIR$SSID" ] && usage
case "$SEC" in ""|open|owe|wpa2|wpa3|wep) ;; *) echo "!!! Unknown security type: $SEC"; exit 1 ;; esac

if [ -z "$SERIAL" ]; then
    SERIAL=$(adb devices | awk 'NR > 1 && $2 == "device" {print $1}')
    case "$(printf '%s\n' "$SERIAL" | grep -c . || true)" in
        1) ;;
        0) echo "!!! adb sees no tablet. Connect it, turn on USB debugging and allow this computer on the screen."; exit 1 ;;
        *) echo "!!! Several adb devices ($(echo $SERIAL)) - choose one with -s <serial>"; exit 1 ;;
    esac
fi
ADB=(adb -s "$SERIAL")
state=$("${ADB[@]}" get-state 2>&1 || true)
if [ "$state" != "device" ]; then
    echo "!!! Tablet $SERIAL not available over adb ($state)."
    echo "    Connect it, turn on USB debugging and allow this computer on the screen."
    exit 1
fi
echo ">>> Tablet: $("${ADB[@]}" shell getprop ro.product.model | tr -d '\r'), $("${ADB[@]}" shell getprop ro.lineage.version | tr -d '\r')"

FAILED=()

# --- Apps ----------------------------------------------------------------------
if [ -n "$APK_DIR" ]; then
    [ -d "$APK_DIR" ] || { echo "!!! $APK_DIR is not a folder"; exit 1; }
    shopt -s nullglob
    installed=0
    # install_apk LABEL FILE... - one file: adb install, several: install-multiple
    install_apk() {
        local label="$1"; shift
        local cmd=(install)
        [ "$#" -gt 1 ] && cmd=(install-multiple)
        printf '>>> %-50s ' "$label"
        local out
        out=$("${ADB[@]}" "${cmd[@]}" -r "${GRANT[@]}" "$@" 2>&1 || true)
        if grep -q '^Success' <<<"$out"; then
            echo "OK"
            installed=$((installed + 1))
        else
            echo "FAILED: $(grep -o -m1 -E 'INSTALL_[A-Z_]+|Failure.*|error:.*' <<<"$out" || echo "${out##*$'\n'}")"
            FAILED+=("$label")
        fi
    }
    for apk in "$APK_DIR"/*.apk; do
        install_apk "$(basename "$apk")" "$apk"
    done
    for dir in "$APK_DIR"/*/; do
        parts=("$dir"*.apk)
        [ "${#parts[@]}" -gt 0 ] && install_apk "$(basename "$dir")/ (${#parts[@]} parts)" "${parts[@]}"
    done
    [ "$installed" -eq 0 ] && [ "${#FAILED[@]}" -eq 0 ] && echo "!!! No *.apk files in $APK_DIR"
    echo ">>> Apps: $installed installed, ${#FAILED[@]} failed"
fi

# --- Wi-Fi ---------------------------------------------------------------------
# One argument for the tablet's shell (adb shell joins its arguments into one command line),
# with single quotes escaped, so that an SSID or password with any characters arrives unchanged.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

if [ -n "$SSID" ]; then
    if [ "$PASS_SET" -eq 0 ]; then
        read -r -s -p "Password for \"$SSID\" (Enter = open network): " PASS
        echo
    fi
    "${ADB[@]}" shell cmd wifi set-wifi-enabled enabled >/dev/null

    if [ -z "$SEC" ]; then
        if [ -z "$PASS" ]; then
            SEC=open
        else
            # Type from a scan: PSK (also WPA2/WPA3 transition mode) -> wpa2, SAE only -> wpa3.
            "${ADB[@]}" shell cmd wifi start-scan >/dev/null 2>&1 || true
            sleep 6
            flags=$("${ADB[@]}" shell cmd wifi list-scan-results | tr -d '\r' | awk -v s="$SSID" '
                NR > 1 { name = ""; for (i = 5; i < NF; i++) name = name (i > 5 ? " " : "") $i
                         if (name == s) print $NF }')
            if grep -q 'PSK' <<<"$flags"; then SEC=wpa2
            elif grep -q 'SAE' <<<"$flags"; then SEC=wpa3
            elif grep -q 'WEP' <<<"$flags"; then SEC=wep
            else
                SEC=wpa2
                echo "    (\"$SSID\" is not in the scan - assuming wpa2; other type: -t, hidden network: -H)"
            fi
        fi
    fi

    echo ">>> Wi-Fi: \"$SSID\" ($SEC)"
    remote="cmd wifi connect-network $(shq "$SSID") $SEC"
    [ -n "$PASS" ] && remote+=" $(shq "$PASS")"
    [ "${#HIDDEN[@]}" -gt 0 ] && remote+=" -h"
    out=$("${ADB[@]}" shell "$remote" 2>&1 | tr -d '\r' || true)
    [ -n "$out" ] && echo "    $out"

    connected=0
    for _ in $(seq 1 30); do
        if "${ADB[@]}" shell cmd wifi status 2>/dev/null | tr -d '\r' | grep -qF "connected to \"$SSID\""; then
            connected=1
            break
        fi
        sleep 1
    done
    if [ "$connected" -eq 1 ]; then
        ip=$("${ADB[@]}" shell ip -4 -o addr show wlan0 2>/dev/null | awk '{print $4}' | head -1)
        echo ">>> Connected to \"$SSID\"${ip:+, address $ip}"
    else
        echo "!!! Not connected to \"$SSID\" after 30 s - check the password and the type (-t);"
        echo "    the network is saved, so the tablet keeps trying when it is in range."
        FAILED+=("Wi-Fi \"$SSID\"")
    fi
fi

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "!!! Failed: ${FAILED[*]}"
    exit 1
fi
echo ">>> Done."
