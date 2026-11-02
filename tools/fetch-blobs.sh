#!/bin/bash
# tools/fetch-blobs.sh - Samsung's proprietary files for the gta4xl into vendor_blobs/ (gitignored),
# where build.sh takes them from. Source: TheMuppets, the repositories official LineageOS builds
# use; gta4xl has no lineage-24.0 branch there, so lineage-23.2.
#
#   tools/fetch-blobs.sh                     # branch lineage-23.2
#   BLOBS_REVISION=<branch|commit> tools/fetch-blobs.sh
#
# Left out on purpose: radio/ (Samsung's bootloader and modem firmware, P615XXS8FXE4) and the
# lines in Android.mk that put it into the zip. Official LineageOS zips flash that firmware when
# the tablet's is older; this build expects the firmware to be up to date already and never
# writes the bootloader (README, "Requirements" and "Firmware"). Run it again to update.
# Needs git.
set -euo pipefail
cd "$(dirname "$0")/.."
REV="${BLOBS_REVISION:-lineage-23.2}"
DEST=vendor_blobs
NEW="$DEST.new"

command -v git >/dev/null || { echo "!!! git is not installed"; exit 1; }
rm -rf "$NEW"
trap 'rm -rf "$NEW"' EXIT
mkdir -p "$NEW"
: > "$NEW/source.txt"
for r in gta4xl gta4xl-common; do
    url="https://github.com/TheMuppets/proprietary_vendor_samsung_${r}.git"
    git init -q "$NEW/$r"
    git -C "$NEW/$r" fetch -q --depth 1 "$url" "$REV"
    git -C "$NEW/$r" checkout -q FETCH_HEAD
    line="$r $(git -C "$NEW/$r" log -1 --format='%H %cd %s' --date=short)"
    echo ">>> $line"
    echo "$line" >> "$NEW/source.txt"
    rm -rf "$NEW/$r/.git" "$NEW/$r/radio"
    sed -i '/add-radio-file-sha1-checked/d' "$NEW/$r/Android.mk"
done
# The build container reads the checkout as "others".
chmod -R a+rX "$NEW"
rm -rf "$DEST"
mv "$NEW" "$DEST"
trap - EXIT
echo ">>> $DEST/: $(find "$DEST" -type f | wc -l) files, $(du -sh "$DEST" | cut -f1) (radio/ left out)"
