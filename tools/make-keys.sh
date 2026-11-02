#!/bin/bash
# tools/make-keys.sh - own signing keys for the build instead of the public AOSP test keys.
#
# Generates the full key set into signing/keys/ (plain text) and writes it encrypted
# (AES-256-CBC, PBKDF2) to signing/signing-keys.enc. build.sh, given that file as a mount,
# asks for the password when it starts, decrypts the keys into vendor/lineage-priv/keys for the
# duration of the build and deletes them when it ends. Both files are gitignored.
#
# Usage: tools/make-keys.sh [-t TREE] [-o DIR] [-s SUBJECT] [-u]
#   -t  synced source tree (default: src/): source of the apex_key list and of
#       external/avb/avbtool.py. Sync it first: the build with -e SYNC_ONLY=true.
#   -o  output directory for keys/ and signing-keys.enc (default: signing/)
#   -s  certificate subject, e.g. '/C=../O=../CN=..' (default without personal data;
#       the CN of an APEX key is the APEX's name)
#   -u  only add missing keys to an existing keys/ (a new APEX after a LineageOS update -
#       build.sh lists the ones without a key) and encrypt the whole set again
#
# Needs openssl, python3 and tar. The set follows the LineageOS wiki ("Signing Builds"):
#   11 app certificates, RSA-2048 (releasekey, platform, shared, media, ...) + testkey ->
#   releasekey, and one RSA-4096 key per apex_key in the tree (.pem/.avbpubkey for the
#   payload, .pk8/.x509.pem for the APEX container).
#
# Losing the keys means no more updates without wiping the tablet's data, and switching
# keys on an installed tablet needs a data wipe too (or the wiki's key migration script):
# keep a copy of keys/ somewhere safe, off this machine. The password is not stored
# anywhere; SIGNING_KEYS_PASSWORD in the environment replaces the prompt (for tests and
# automation only - it is visible in `ps`).
set -euo pipefail

TREE=""; OUT=""; UPDATE=0
SUBJECT='/O=Android/OU=Android/CN=Android'
while getopts "t:o:s:uh" opt; do
    case "$opt" in
        t) TREE="$OPTARG" ;;
        o) OUT="$OPTARG" ;;
        s) SUBJECT="$OPTARG" ;;
        u) UPDATE=1 ;;
        *) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
    esac
done
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$REPO_DIR/signing}"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
KEYS="$OUT/keys"; ENC="$OUT/signing-keys.enc"

for t in openssl python3 tar; do command -v "$t" >/dev/null || { echo "!!! Missing tool: $t"; exit 1; }; done
TREE="${TREE:-$REPO_DIR/src}"
[ -f "$TREE/external/avb/avbtool.py" ] || { echo "!!! No synced source tree with external/avb/avbtool.py in $TREE - sync first (SYNC_ONLY=true) or pass -t DIR"; exit 1; }
TREE="$(cd "$TREE" && pwd)"; AVBTOOL="$TREE/external/avb/avbtool.py"
case "$SUBJECT" in */CN=*) ;; *) echo "!!! The subject needs a /CN= part"; exit 1 ;; esac

if [ -n "$(ls -A "$KEYS" 2>/dev/null)" ] && [ "$UPDATE" -eq 0 ]; then
    echo "!!! $KEYS already exists - not overwriting existing keys."
    echo "    -u adds missing ones; a new set from scratch (= wiping the tablet) means deleting the folder by hand."
    exit 1
fi
# Plain keys must never end up in git.
case "$KEYS" in "$REPO_DIR"/*)
    git -C "$REPO_DIR" check-ignore -q "$KEYS/x.pk8" || { echo "!!! .gitignore does not exclude $KEYS - stopping"; exit 1; } ;;
esac

APP_CERTS="bluetooth cyngn-app media networkstack nfc platform releasekey sdk_sandbox shared testcert verity"

echo ">>> Scanning $TREE for apex_key modules..."
# "name public_key_file" for apex_key modules with their keys in the module directory;
# references to modules (:x) and paths are AOSP-controlled test keys - skipped.
APEX_LIST=$(find "$TREE" -path "$TREE/out" -prune -o -path "$TREE/.repo" -prune -o -name Android.bp -print0 \
    | xargs -0 awk '
        /^apex_key[ \t]*\{/ { blk = 1; pub = ""; priv = ""; next }
        blk && /^[ \t]*public_key:/  { sub(/^[ \t]*public_key:[ \t]*"/, "");  sub(/".*$/, ""); pub = $0 }
        blk && /^[ \t]*private_key:/ { sub(/^[ \t]*private_key:[ \t]*"/, ""); sub(/".*$/, ""); priv = $0 }
        blk && /^\}/ {
            if (pub != "" && priv ~ /\.pem$/ && pub !~ /^:/ && pub !~ /\// && priv !~ /\//) { sub(/\.pem$/, "", priv); print priv, pub }
            blk = 0 }' \
    | sort -u)
[ -n "$APEX_LIST" ] || { echo "!!! No apex_key found in $TREE"; exit 1; }
echo "    $(echo "$APEX_LIST" | wc -l) APEX keys + $(echo $APP_CERTS | wc -w) app certificates"

umask 077
mkdir -p "$KEYS"
before=$(find "$KEYS" -maxdepth 1 -name "*.pk8" | wc -l)
gen_key() {   # name bits CN
    local n="$1" bits="$2" subj
    [ -e "$KEYS/$n.pk8" ] && return 0
    subj=$(printf '%s' "$SUBJECT" | sed "s|/CN=[^/]*|/CN=${3:0:64}|")   # X.509 limits the CN to 64 characters
    openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:$bits" -out "$KEYS/$n.pem" 2>/dev/null
    openssl req -new -x509 -sha256 -key "$KEYS/$n.pem" -out "$KEYS/$n.x509.pem" -days 10000 -subj "$subj"
    openssl pkcs8 -topk8 -in "$KEYS/$n.pem" -outform DER -nocrypt -out "$KEYS/$n.pk8"
}
echo ">>> App certificates (RSA-2048):"
for c in $APP_CERTS; do
    gen_key "$c" 2048 "$(printf '%s' "$SUBJECT" | sed 's|.*/CN=\([^/]*\).*|\1|')"
    rm -f "$KEYS/$c.pem"            # only the APEX keys keep a .pem
    printf '  %s' "$c"
done; echo
ln -sf releasekey.pk8 "$KEYS/testkey.pk8"; ln -sf releasekey.x509.pem "$KEYS/testkey.x509.pem"

echo ">>> APEX keys (RSA-4096, a few minutes):"
n=0
while read -r base pub; do
    gen_key "$base" 4096 "$base"
    [ -e "$KEYS/$pub" ] || python3 -I -B "$AVBTOOL" extract_public_key --key "$KEYS/$base.pem" --output "$KEYS/$pub"
    n=$((n + 1)); if [ $((n % 10)) -eq 0 ]; then printf '  %d' "$n"; fi
done <<< "$APEX_LIST"; echo "  $n"
after=$(find "$KEYS" -maxdepth 1 -name "*.pk8" | wc -l)
{
    echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "subject: $SUBJECT"
    echo "files:"; ls "$KEYS" | grep -v '^MANIFEST.txt$' | sed 's/^/  /'
} > "$KEYS/MANIFEST.txt"
chmod 700 "$KEYS"
echo ">>> New keys: $((after - before)) (in total $after .pk8)"

PASS_OPT=()
if [ -n "${SIGNING_KEYS_PASSWORD:-}" ]; then
    export SIGNING_KEYS_PASSWORD; PASS_OPT=(-pass env:SIGNING_KEYS_PASSWORD)
else
    echo ">>> Password for the archive (twice) - build.sh asks for it at every build:"
fi
tar -C "$KEYS" --owner=0 --group=0 --numeric-owner -cf - . \
    | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -salt "${PASS_OPT[@]}" -out "$ENC"
chmod 644 "$ENC"   # encrypted; the container reads it as "others"
[ "$(head -c 8 "$ENC")" = "Salted__" ] || { echo "!!! $ENC has no openssl enc header - stopping"; exit 1; }
[ -n "${SIGNING_KEYS_PASSWORD:-}" ] || echo ">>> Checking the archive - the password once more:"
count=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -in "$ENC" "${PASS_OPT[@]}" | tar -tf - | grep -vc '^\./$')
expected=$(find "$KEYS" -mindepth 1 | wc -l)
[ "$count" -eq "$expected" ] || { echo "!!! Archive incomplete ($count/$expected entries)"; exit 1; }

echo ">>> Done ($count files, $(stat -c %s "$ENC") bytes):"
echo "    $KEYS/  - PLAIN keys: copy them somewhere safe, off this machine, and delete them here"
echo "    $ENC  - mount it into the build:"
echo "    -v \"\$(pwd)/signing/signing-keys.enc\":/home/builder/signing-keys.enc:ro (README, 'Signing with your own keys')"
echo "    Install the first build with these keys through the recovery, with a data wipe (README)."
