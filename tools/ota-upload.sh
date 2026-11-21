#!/bin/bash
# tools/ota-upload.sh - uploads the update package and metadata of the last build (made with
# OTA_BASE_URL) to the update server. Runs on the host, not in the build container, so SSH
# credentials never enter the build environment.
#
#   OTA_REMOTE=user@host:/srv/ota tools/ota-upload.sh
#
# Environment: OTA_REMOTE (required; rsync/ssh target, the folder the web server serves as
# OTA_BASE_URL), OTA_SSH_PORT (default 22), OUT_DIR (default src/out/target/product/gta4xl/ota),
# OTA_KEEP_OLD=1 (do not delete the older packages from the server).
# Layout on the server, as the Updater expects it for OTA_BASE_URL:
#   <remote>/gta4xl/lineage-*.zip (+ .sha256)          the package
#   <remote>/api/v1/gta4xl/<type>/index.json           the metadata, <type> = unofficial etc.
# Needs rsync and ssh.
#
# Order: the small files first, the package (by far the largest file) last. Whatever can ask for
# attention - an unknown host key, a key's passphrase, a wrong path - then happens in the first
# seconds, and the long transfer needs nobody. All steps share one SSH connection, so the server
# asks for authentication once.
# The Updater must never see an entry for a package that is not on the server yet. So the
# metadata goes up under a temporary name and becomes index.json (one rename on the server) only
# after the package has arrived completely. An upload that breaks off leaves the server offering
# the previous build, and the next run continues the package where the last one stopped.
# At the end the older packages are deleted from the server: the metadata names only the newest
# one, so the others are dead weight (a gigabyte each). OTA_KEEP_OLD=1 leaves them.
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
PKG_DIR="${REMOTE_PATH}/${DEVICE}"
API_DIR="${REMOTE_PATH}/api/v1/${DEVICE}/${RELEASE_TYPE}"
echo ">>> Target: $REMOTE (port $PORT, type: $RELEASE_TYPE, package: $FILENAME)"

# One SSH connection for every step: the first command opens it, the others reuse its socket.
CTL=$(mktemp -d /tmp/ota-upload.XXXXXX)
SSH_OPTS=(-p "$PORT" -o ControlMaster=auto -o "ControlPath=$CTL/%C" -o ControlPersist=300)
RSH="ssh ${SSH_OPTS[*]}"
cleanup() { ssh "${SSH_OPTS[@]}" -O exit "$SSH_TARGET" >/dev/null 2>&1 || true; rm -rf "$CTL"; }
trap cleanup EXIT

# 1. Directories
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "mkdir -p '$PKG_DIR' '$API_DIR'"
ssh "${SSH_OPTS[@]}" -O check "$SSH_TARGET" >/dev/null 2>&1 \
    || echo ">>> WARNING: the SSH connection could not be shared: every step authenticates again, the last one after the package"

# 2. The small files: the checksum, and the metadata under a temporary name
rsync -avh -e "$RSH" "$OUT_DIR/$FILENAME.sha256" "${SSH_TARGET}:${PKG_DIR}/"
rsync -avh -e "$RSH" "$JSON_FILE" "${SSH_TARGET}:${API_DIR}/index.json.new"

# 3. The package, last. It appears under its name only when it is complete; what an interrupted
#    transfer got across stays in .rsync-partial/ and the next run continues from there.
rsync -avh --progress --partial-dir=.rsync-partial -e "$RSH" "$OUT_DIR/$FILENAME" "${SSH_TARGET}:${PKG_DIR}/"

# 4. Publish: from this rename on the Updater sees the new build
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "mv -f '$API_DIR/index.json.new' '$API_DIR/index.json'"

# 5. Only the newest package stays: older ones, their checksums, and what an abandoned upload
#    left in .rsync-partial/. Nothing else in that directory is touched.
if [ "${OTA_KEEP_OLD:-0}" != 1 ]; then
    removed=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "find '$PKG_DIR' -maxdepth 2 -type f \\( -name 'lineage-*.zip' -o -name 'lineage-*.zip.sha256' \\) ! -name '$FILENAME' ! -name '$FILENAME.sha256' -print -delete; rmdir '$PKG_DIR/.rsync-partial' 2>/dev/null; true")
    if [ -n "$removed" ]; then
        echo ">>> Removed from the server:"; echo "$removed" | sed 's/^/    /'
    else
        echo ">>> No older package on the server."
    fi
fi

echo ">>> Done. The Updater asks <OTA_BASE_URL>/api/v1/${DEVICE}/${RELEASE_TYPE}/"
