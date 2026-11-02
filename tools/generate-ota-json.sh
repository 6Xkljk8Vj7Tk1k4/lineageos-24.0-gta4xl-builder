#!/bin/bash
# tools/generate-ota-json.sh OUT_DIR DEVICE BASE_URL - update metadata for LineageOS's Updater app:
# writes $OUT_DIR/ota/<device>.json and copies this build's package (+ .sha256) to $OUT_DIR/ota/.
# build.sh runs it inside the container after `mka bacon` when OTA_BASE_URL is set;
# tools/ota-upload.sh (on the host) uploads the result.
#
# The format follows the Updater's sources (lineage-23.2, UpdatesNetworkDataSource.kt /
# NetworkUpdate.kt): a JSON array of builds. Every value is read from the build's own
# build.prop files.
set -euo pipefail

OUT_DIR="$1"     # e.g. out/target/product/gta4xl
DEVICE="$2"      # gta4xl
BASE_URL="$3"    # https://ota.example.org

# The build properties are spread over the build.prop files of the partitions.
BUILD_PROP_FILES=$(find "$OUT_DIR" -maxdepth 3 -name "build.prop" 2>/dev/null)
get_prop() {
    local key="$1" f val
    for f in $BUILD_PROP_FILES; do
        val=$(grep -m1 "^${key}=" "$f" 2>/dev/null | cut -d= -f2- || true)
        if [ -n "$val" ]; then
            echo "$val"
            return
        fi
    done
}

DATETIME=$(get_prop "ro.build.date.utc")
SDK_LEVEL=$(get_prop "ro.build.version.sdk")
PATCH_LEVEL=$(get_prop "ro.build.version.security_patch")
RELEASE_TYPE=$(get_prop "ro.lineage.releasetype")
BUILD_VERSION=$(get_prop "ro.lineage.build.version")
LINEAGE_VERSION=$(get_prop "ro.lineage.version")

for name in DATETIME SDK_LEVEL RELEASE_TYPE BUILD_VERSION LINEAGE_VERSION; do
    if [ -z "${!name}" ]; then
        echo "!!! Could not read $name from the build.prop files in $OUT_DIR"
        exit 1
    fi
done

# The package of this build by its name from ro.lineage.version, not "the newest" (ls -t): bacon
# hard-links lineage-<version>.zip to lineage_<device>-ota.zip and a later build overwrites that
# file in place, so packages with older dates in their names can show the newest content and
# modification time.
ZIP_PATH="$OUT_DIR/lineage-${LINEAGE_VERSION}.zip"
if [ ! -f "$ZIP_PATH" ]; then
    echo "!!! No package $ZIP_PATH (ro.lineage.version=$LINEAGE_VERSION)"
    exit 1
fi
FILENAME=$(basename "$ZIP_PATH")
SIZE=$(stat -c%s "$ZIP_PATH")
SHA256=$(sha256sum "$ZIP_PATH" | cut -d' ' -f1)

# ota/ holds only the current package: tools/ota-upload.sh uploads exactly the one in the JSON.
mkdir -p "$OUT_DIR/ota"
find "$OUT_DIR/ota" -maxdepth 1 -name 'lineage-*.zip*' ! -name "${FILENAME}" ! -name "${FILENAME}.sha256" -delete
rm -f "$OUT_DIR/ota/$FILENAME"
cp "$ZIP_PATH" "$OUT_DIR/ota/$FILENAME"
echo "$SHA256  $FILENAME" > "$OUT_DIR/ota/${FILENAME}.sha256"

jq -n \
    --argjson datetime "$DATETIME" \
    --arg filename "$FILENAME" \
    --arg patch "$PATCH_LEVEL" \
    --argjson sdk "$SDK_LEVEL" \
    --arg sha256 "$SHA256" \
    --argjson size "$SIZE" \
    --arg url "${BASE_URL%/}/${DEVICE}/${FILENAME}" \
    --arg type "$RELEASE_TYPE" \
    --arg version "$BUILD_VERSION" \
    '[{
        datetime: $datetime,
        files: [{
            filename: $filename,
            os_patch_level: $patch,
            os_sdk_level: $sdk,
            sha256: $sha256,
            size: $size,
            url: $url
        }],
        type: $type,
        version: $version
    }]' > "$OUT_DIR/ota/${DEVICE}.json"

echo ">>> Update metadata: $OUT_DIR/ota/${DEVICE}.json (type=${RELEASE_TYPE}, version=${BUILD_VERSION})"
echo ">>> Package:         $OUT_DIR/ota/$FILENAME"
echo ">>> Upload it from the host with tools/ota-upload.sh"
