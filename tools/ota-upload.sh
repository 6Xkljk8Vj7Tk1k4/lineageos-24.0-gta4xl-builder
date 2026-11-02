#!/bin/bash
# tools/ota-upload.sh - uploads the update package and metadata of the last build (made with
# OTA_BASE_URL) to the update server. Runs on the host, not in the build container, so SSH
# credentials never enter the build environment.
#
#   OTA_REMOTE=user@host:/srv/ota tools/ota-upload.sh
#
# Environment: OTA_REMOTE (required; rsync/ssh target, the folder the web server serves as
# OTA_BASE_URL), OTA_SSH_PORT (default 22), OUT_DIR (default src/out/target/product/gta4xl/ota).
# Layout on the server, as the Updater expects it for OTA_BASE_URL:
#   <remote>/gta4xl/lineage-*.zip (+ .sha256)          the package
#   <remote>/api/v1/gta4xl/<type>/index.json           the metadata, <type> = unofficial etc.
# Needs rsync and ssh.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${DEVICE:-gta4xl}"
OUT_DIR="${OUT_DIR:-src/out/target/product/${DEVICE}/ota}"
REMOTE="${OTA_REMOTE:?set OTA_REMOTE=user@host:/path (the folder served as OTA_BASE_URL)}"
PORT="${OTA_SSH_PORT:-22}"

JSON_FILE="$OUT_DIR/${DEVICE}.json"
if [ ! -f "$JSON_FILE" ]; then
    echo "!!! No $JSON_FILE - build with -e OTA_BASE_URL=https://... first."
    exit 1
fi
json_field() { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$JSON_FILE" | head -n1 | sed -E 's/.*"([^"]+)"$/\1/'; }
RELEASE_TYPE=$(json_field type | tr '[:upper:]' '[:lower:]')
FILENAME=$(json_field filename)
if [ -z "$RELEASE_TYPE" ] || [ -z "$FILENAME" ]; then
    echo "!!! Could not read 'type'/'filename' from $JSON_FILE"
    exit 1
fi
# Exactly the package from the JSON, checked before it leaves.
( cd "$OUT_DIR" && sha256sum -c --quiet "${FILENAME}.sha256" ) \
    || { echo "!!! $FILENAME does not match ${FILENAME}.sha256 - not uploading"; exit 1; }

SSH_TARGET="${REMOTE%%:*}"
REMOTE_PATH="${REMOTE#*:}"
echo ">>> Target: $REMOTE (port $PORT, type: $RELEASE_TYPE, package: $FILENAME)"

# 1. Package + sha256 -> <remote>/<device>/ (before the JSON, so that the Updater never sees an
#    entry for a file that is not there yet)
ssh -p "$PORT" "$SSH_TARGET" "mkdir -p '${REMOTE_PATH}/${DEVICE}' '${REMOTE_PATH}/api/v1/${DEVICE}/${RELEASE_TYPE}'"
rsync -avh --progress -e "ssh -p $PORT" "$OUT_DIR/$FILENAME" "$OUT_DIR/$FILENAME.sha256" "${REMOTE}/${DEVICE}/"

# 2. JSON -> <remote>/api/v1/<device>/<type>/index.json
rsync -avh -e "ssh -p $PORT" "$JSON_FILE" "${REMOTE}/api/v1/${DEVICE}/${RELEASE_TYPE}/index.json"

echo ">>> Done. The Updater asks <OTA_BASE_URL>/api/v1/${DEVICE}/${RELEASE_TYPE}/"
