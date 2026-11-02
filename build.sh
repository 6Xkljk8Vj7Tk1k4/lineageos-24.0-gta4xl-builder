#!/bin/bash
# LineageOS 24.0 (Android 17) for the Samsung Galaxy Tab S6 Lite LTE (gta4xl).
# Container entrypoint: syncs LineageOS into the bind-mounted /home/builder/android/lineage,
# swaps in the kernel fork, adds the proprietary files from vendor_blobs/, applies the port
# patches and the optional tweaks and runs `mka bacon`. All knobs are environment variables
# (`podman run -e NAME=value`), see README.md.
set -euo pipefail

TOP=/home/builder/android/lineage
REPO=/home/builder/repo
cd "$TOP"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DEVICE="${DEVICE:-gta4xl}"
BRANCH="${BRANCH:-lineage-24.0}"
# The device trees, the LineageOS kernel and TheMuppets' blobs stop at lineage-23.2:
# breakfast's roomservice falls back to these branches for repositories without $BRANCH.
export ROOMSERVICE_BRANCHES="${ROOMSERVICE_BRANCHES-lineage-23.2}"
# UNOFFICIAL, NIGHTLY, SNAPSHOT, EXPERIMENTAL or RELEASE; vendor/lineage turns anything
# it does not accept into UNOFFICIAL.
LINEAGE_BUILDTYPE="${LINEAGE_BUILDTYPE:-UNOFFICIAL}"
# Kernel: a fork with the eBPF backports Android 17 expects at the "5.10" level, the
# cgroup v2 freezer and security fixes (see README). Android 17 does not boot on the
# lineage-23.2 kernel, so the fork is the default for lineage-24.0. Empty = the kernel
# from the LineageOS manifest. Any git URL the container can reach works, including
# file:///home/builder/... for a mounted local clone.
if [ "$BRANCH" = "lineage-24.0" ]; then
    _kernel_default="https://github.com/6Xkljk8Vj7Tk1k4/android_kernel_samsung_gta4xl.git"
else
    _kernel_default=""
fi
KERNEL_REPO_URL="${KERNEL_REPO_URL-$_kernel_default}"
KERNEL_REVISION="${KERNEL_REVISION-gta4xl-24.0}"
# Kernel version reported to the BPF loaders (ro.bpf.kver_override). Only set together with
# the fork: the manifest kernel lacks the backports and would boot-loop with it.
KERNEL_BPF_KVER="${KERNEL_BPF_KVER-5.10.239}"

# Where the proprietary files and the patches come from (tools/fetch-blobs.sh fills
# vendor_blobs/ in the checkout).
BLOBS_DIR="${BLOBS_DIR:-$REPO/vendor_blobs}"
PATCHES_ROOT="${PATCHES_ROOT:-$REPO/patches}"
# Own signing keys: the encrypted archive from tools/make-keys.sh, mounted as a file.
SIGNING_KEYS_FILE="${SIGNING_KEYS_FILE:-/home/builder/signing-keys.enc}"

SYNC_JOBS="${SYNC_JOBS:-4}"
SYNC_RETRIES="${SYNC_RETRIES:-5}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
CCACHE_SIZE="${CCACHE_SIZE:-30G}"
# repo groups: the darwin and mips prebuilts are not needed on Linux and cost ~20 GB.
# Empty = repo's default groups.
REPO_GROUPS="${REPO_GROUPS-default,-darwin,-mips,-notdefault}"
# Stop when the source volume has less free space than this.
MIN_FREE_GB="${MIN_FREE_GB:-15}"
# true = only repo init + sync, no build (before the first tools/make-keys.sh, for example).
SYNC_ONLY="${SYNC_ONLY:-false}"
# true = no repo init/sync: build the tree as it is.
SKIP_SYNC="${SKIP_SYNC:-false}"
# true = `mka -k`: keep going after errors to collect all of them in one run.
KEEP_GOING="${KEEP_GOING:-false}"

# --- Update server (off by default) ---
# https://host[/path] of a server laid out like the one in ota/ (README, "Update server"):
# sets lineage.updater.uri and writes the update metadata next to the zip. Empty = the
# Updater app keeps LineageOS's own server, which has nothing for unofficial builds.
OTA_BASE_URL="${OTA_BASE_URL-}"

# --- Tweaks; an empty value (e.g. -e NTP_SERVER=) keeps LineageOS's behaviour ---
# DNS servers used only when DHCP hands out none (Android's fallback is Google's).
FALLBACK_DNS="${FALLBACK_DNS-1.1.1.1 1.0.0.1}"
# Optional: Private DNS (DNS over TLS, port 853) with this server as the default mode.
# Off by default: on a network that blocks port 853 there would be no DNS at all.
PRIVATE_DNS_HOST="${PRIVATE_DNS_HOST-}"
# Time server instead of Google's time.android.com.
NTP_SERVER="${NTP_SERVER-pool.ntp.org}"
# Optional: a host that answers "204 No Content" on /generate_204 over http AND https,
# used for Android's connectivity check instead of Google's servers. Checked before use.
CAPTIVE_PORTAL_HOST="${CAPTIVE_PORTAL_HOST-}"
# Apps left out of the image (Soong `overrides`): Recorder, Music, backup, wallpapers,
# screen savers and LineageOS's profiles.
DEBLOAT_PACKAGES="${DEBLOAT_PACKAGES-Recorder Twelve Seedvault Backgrounds LiveWallpapersPicker PhotoTable BasicDreams Profiles}"
# Trust rates the vendor security patch level from the device tree (2024-05-01, Samsung's
# last firmware for the Exynos 9611 in TheMuppets' blobs) as current instead of
# "out of date" forever. The date shown stays the real one.
TRUST_VENDOR_PATCH_FINAL="${TRUST_VENDOR_PATCH_FINAL-true}"
# Developer options visible without tapping the build number seven times.
DEVELOPER_OPTIONS_VISIBLE="${DEVELOPER_OPTIONS_VISIBLE-true}"
# "Advanced restart" (recovery and bootloader in the power menu) on by default.
ADVANCED_RESTART="${ADVANCED_RESTART-true}"

# Generated product additions (overlays, debloat list, properties); recreated every build.
GEN_DIR="vendor/gta4xl-builder"
DEVICE_MK="device/samsung/${DEVICE}/lineage_${DEVICE}.mk"

# ---------------------------------------------------------------------------
# Log, signals, disk space
# ---------------------------------------------------------------------------
LOG_DIR="$TOP/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/build-$(date -u +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo ">>> Log: $LOG_FILE"
echo ">>> ${BRANCH} for ${DEVICE} (fallback: ${ROOMSERVICE_BRANCHES:-none}) | kernel: ${KERNEL_REPO_URL:-from the manifest}${KERNEL_REPO_URL:+ @ $KERNEL_REVISION} | jobs=${BUILD_JOBS} | ccache=${CCACHE_SIZE}"
BUILD_START=$(date +%s)

# Decrypted keys live in vendor/lineage-priv/keys only while build.sh runs: removed on
# every exit, and a leftover from a killed container is removed at the next start.
KEYS_DIR="$TOP/vendor/lineage-priv/keys"
cleanup() { rm -rf "$TOP/vendor/lineage-priv"; }
# bash as PID 1 ignores signals without a handler, and runs a handler only after the
# foreground command has finished. Long commands therefore go through `run` (`wait`
# returns as soon as a signal arrives) and the handler stops the whole process group.
on_signal() { trap '' INT TERM; echo "!!! $1"; kill -TERM 0 2>/dev/null; exit "$2"; }
trap cleanup EXIT
trap 'on_signal interrupted 130' INT
trap 'on_signal terminated 143' TERM
run() { "$@" & wait $!; }

free_gb() { df -Pk "$TOP" | awk 'NR==2 {print int($4 / 1048576)}'; }
check_space() {
    local f; f=$(free_gb)
    if [ "$f" -lt "$MIN_FREE_GB" ]; then
        echo "!!! Only ${f} GB free on the source volume (minimum ${MIN_FREE_GB} GB) - stopping."
        return 1
    fi
}
# Background watchdog: a full disk corrupts the tree and can take the host down with it.
( while sleep 60; do
      if [ "$(free_gb)" -lt "$MIN_FREE_GB" ]; then
          echo "!!! Free space below ${MIN_FREE_GB} GB - aborting the build."
          kill -TERM 0
      fi
  done ) &
check_space

# ---------------------------------------------------------------------------
# 0. Checks before anything takes time
# ---------------------------------------------------------------------------
# The container user reads the bind-mounted checkout as "others": files written with a
# umask of 027 (mode 640) would otherwise only fail hours later, in `git am` or `cp`.
unreadable=$(find "$PATCHES_ROOT" "$BLOBS_DIR" \( -type f ! -readable \) -o \
    \( -type d \( ! -readable -o ! -executable \) \) 2>/dev/null | sed -n 1,5p || true)
if [ -n "$unreadable" ]; then
    echo "!!! The container cannot read these files from the host:"
    echo "$unreadable" | sed 's/^/    /'
    echo "    On the host, in the repository folder: chmod -R o+rX ."
    exit 1
fi
if [ "$SYNC_ONLY" != "true" ]; then
    for d in "$DEVICE" "$DEVICE-common"; do
        if [ ! -f "$BLOBS_DIR/$d/$d-vendor.mk" ]; then
            echo "!!! No proprietary files in $BLOBS_DIR/$d - run tools/fetch-blobs.sh on the host first."
            exit 1
        fi
    done
fi

# Own signing keys (tools/make-keys.sh): the password is asked for here, at the start,
# or taken from SIGNING_KEYS_PASSWORD (visible in `podman inspect`: automation only).
# Without the archive the build is signed with the public AOSP test keys.
cleanup
if [ -s "$SIGNING_KEYS_FILE" ]; then
    for attempt in 1 2 3; do
        if [ -n "${SIGNING_KEYS_PASSWORD:-}" ]; then
            pw="$SIGNING_KEYS_PASSWORD"
        elif [ -t 0 ]; then
            # IFS= keeps spaces at the ends of the password
            IFS= read -rs -p "Password for the signing keys ($SIGNING_KEYS_FILE): " pw < /dev/tty; echo
        else
            echo "!!! No terminal to ask for the key password: start podman with -it, or pass -e SIGNING_KEYS_PASSWORD."
            exit 1
        fi
        mkdir -p "$TOP/vendor"   # normal umask; 077 only for lineage-priv
        if ( umask 077; mkdir -p "$KEYS_DIR" \
                && SIGNING_KEYS_PASSWORD="$pw" openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
                    -in "$SIGNING_KEYS_FILE" -pass env:SIGNING_KEYS_PASSWORD 2>/dev/null \
                   | tar -C "$KEYS_DIR" -xf - 2>/dev/null ) \
            && [ -f "$KEYS_DIR/releasekey.pk8" ]; then
            unset pw
            break
        fi
        rm -rf "$KEYS_DIR"
        if [ -n "${SIGNING_KEYS_PASSWORD:-}" ]; then
            echo "!!! SIGNING_KEYS_PASSWORD does not open $SIGNING_KEYS_FILE."; exit 1
        fi
        echo "!!! Wrong password or damaged archive (attempt $attempt/3)."
        [ "$attempt" -lt 3 ] || exit 1
    done
    unset SIGNING_KEYS_PASSWORD   # Soong dumps the whole environment into out/soong.log
    echo ">>> Signing keys: own, $(ls "$KEYS_DIR" | wc -l) files (release-keys)"
else
    echo ">>> WARNING: no $SIGNING_KEYS_FILE - the build is signed with the public AOSP test keys (test-keys)."
    echo "    Own keys: tools/make-keys.sh and the signing-keys.enc mount (README, 'Signing with your own keys')."
fi

# ---------------------------------------------------------------------------
# 1. Sources
# ---------------------------------------------------------------------------
# Files this script edits in synced projects go back to their git state first: repo sync
# refuses to check out a new revision over local changes, and the edits are re-applied
# below on every build anyway.
TWEAKED_FILES=(
    "lineage-sdk:sdk/src/java/org/lineageos/internal/util/PowerMenuUtils.java"
    "lineage-sdk:lineage/lib/main/java/org/lineageos/platform/internal/TrustInterfaceService.java"
    "frameworks/base:packages/SettingsLib/src/com/android/settingslib/development/DevelopmentSettingsEnabler.java"
    "packages/modules/Connectivity:staticlibs/framework/com/android/net/module/util/ConnectivitySettingsUtils.java"
    "packages/modules/Connectivity:service/src/com/android/server/connectivity/DnsManager.java"
    "device/samsung/${DEVICE}:lineage_${DEVICE}.mk"
)
for entry in "${TWEAKED_FILES[@]}"; do
    git -C "${entry%%:*}" checkout -q -- "${entry#*:}" 2>/dev/null || true
done

# An interrupted sync poisons the next one: a project whose first fetch did not finish
# has no `shallow` file, so repo takes it for a manually unshallowed clone and fetches its
# complete history (tens of GB for prebuilts/clang); a project whose checkout did not
# finish has HEAD at the right revision, so repo skips it and leaves a half-empty
# worktree; stale locks of killed git processes make later fetches of that project fail.
# Remove such projects (repo re-creates them), the locks and temporary packs.
# Nothing else may use the tree while build.sh runs.
clean_interrupted_sync() {
    local g wt
    [ -d .repo/projects ] && [ -d .repo/project-objects ] || return 0
    find .repo/projects .repo/project-objects -type f \
        \( -name '*.lock' -o -name 'tmp_pack_*' -o -name 'tmp_idx_*' \) -delete
    while IFS= read -r -d '' g; do
        wt="${g#.repo/projects/}"; wt="${wt%.git}"
        if [ ! -e "$g/shallow" ] && [ -z "$(git --git-dir="$g" for-each-ref --count=1)" ]; then
            echo ">>> ${wt}: first fetch was interrupted, re-cloning"
            rm -rf "$g"
            if [ -L "$wt/.git" ]; then rm "$wt/.git"; fi
        elif [ ! -e "$g/index" ] && [ -L "$wt/.git" ]; then
            echo ">>> ${wt}: checkout was interrupted, checking out again"
            rm "$wt/.git"
        fi
    done < <(find .repo/projects -type d -name '*.git' -prune -print0)
}

sync_tree() {
    local attempt groups=()
    [ -n "$REPO_GROUPS" ] && groups=(-g "$REPO_GROUPS")
    # repo init on every run, so that a changed BRANCH really switches the manifest.
    # Retried like the sync: a short DNS outage should not end the build (and a typed
    # key password with it).
    echo ">>> repo init ${BRANCH}"
    attempt=1
    until run repo init -u https://github.com/LineageOS/android.git -b "$BRANCH" --git-lfs --depth=1 "${groups[@]}"; do
        if [ "$attempt" -ge "$SYNC_RETRIES" ]; then
            echo "!!! repo init failed ${SYNC_RETRIES} times - giving up."
            exit 1
        fi
        echo ">>> repo init failed (attempt ${attempt}/${SYNC_RETRIES} - network/DNS?), retrying in $(( attempt * 30 ))s"
        run sleep $(( attempt * 30 ))
        attempt=$(( attempt + 1 ))
    done

    # Kernel fork: a local manifest replaces kernel/samsung/<DEVICE>. LineageOS's entry comes
    # from roomservice.xml (written by breakfast); "zz-" sorts after it, so remove-project
    # wins, and roomservice still finds the repository in a manifest and does not add it
    # again. On a fresh tree the entry does not exist yet, hence optional="true".
    local kernel_manifest=".repo/local_manifests/zz-kernel.xml"
    if [ -n "$KERNEL_REPO_URL" ]; then
        local kernel_fetch="${KERNEL_REPO_URL%/*}/" kernel_name="${KERNEL_REPO_URL##*/}"
        kernel_name="${kernel_name%.git}"
        echo ">>> Kernel: ${KERNEL_REPO_URL} @ ${KERNEL_REVISION}"
        mkdir -p .repo/local_manifests
        cat > "$kernel_manifest" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="kernel-fork" fetch="${kernel_fetch}" />
  <remove-project name="LineageOS/android_kernel_samsung_${DEVICE}" optional="true" />
  <project path="kernel/samsung/${DEVICE}" remote="kernel-fork" name="${kernel_name}" revision="${KERNEL_REVISION}" />
</manifest>
EOF
    else
        rm -f "$kernel_manifest"
    fi

    # A fetch whose connection stays open while the server sends nothing would hang
    # forever; let git abort it so that repo retries the project.
    export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1000}"
    export GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-600}"
    echo ">>> repo sync"
    attempt=1
    while :; do
        clean_interrupted_sync
        run repo sync -c -j"$SYNC_JOBS" --fail-fast --force-sync --no-clone-bundle --no-tags \
            --retry-fetches=5 && break
        check_space
        if [ "$attempt" -ge "$SYNC_RETRIES" ]; then
            echo "!!! repo sync failed ${SYNC_RETRIES} times - giving up."
            exit 1
        fi
        echo ">>> repo sync failed (attempt ${attempt}/${SYNC_RETRIES}), retrying in $(( attempt * 30 ))s"
        run sleep $(( attempt * 30 ))
        attempt=$(( attempt + 1 ))
    done
}
if [ "$SKIP_SYNC" = "true" ]; then
    echo ">>> SKIP_SYNC=true - building the tree as it is"
else
    sync_tree
fi
check_space
if [ "$SYNC_ONLY" = "true" ]; then
    echo ">>> SYNC_ONLY=true - sources synced in $(( ($(date +%s) - BUILD_START) / 60 )) min, not building."
    exit 0
fi

# 2. Proprietary files: vendor_blobs/ is the source of truth, whatever the tree had before.
echo ">>> Proprietary files from ${BLOBS_DIR}"
mkdir -p vendor/samsung
rm -rf "vendor/samsung/${DEVICE}" "vendor/samsung/${DEVICE}-common"
cp -r "$BLOBS_DIR/${DEVICE}" "$BLOBS_DIR/${DEVICE}-common" vendor/samsung/

# 3. Port patches: patches/<BRANCH>/<project path>/*.patch. Each patched project is reset to
#    its manifest revision (m/<BRANCH>) and the patches go in with `git am`, so the result
#    does not depend on what a previous run left behind. A marker in the project's .git
#    (hash of the patches + m/<BRANCH> + HEAD) skips projects already in exactly that
#    state. The device trees only appear with breakfast (roomservice), so projects that do
#    not exist yet are skipped here and patched after breakfast.
PATCHES_DIR="${PATCHES_ROOT}/${BRANCH}"
apply_patches() {
    [ -d "$PATCHES_DIR" ] || return 0
    local pdir project gitdir want old f mtimes
    for pdir in $(find "$PATCHES_DIR" -name '*.patch' -printf '%h\n' | sort -u); do
        project="${pdir#"$PATCHES_DIR"/}"
        if [ "$(git -C "$project" rev-parse --show-toplevel 2>/dev/null)" != "$PWD/$project" ]; then
            echo ">>> Patches: $project is not in the tree yet - later"
            continue
        fi
        gitdir=$(git -C "$project" rev-parse --absolute-git-dir)
        want="$(cat "$pdir"/*.patch | sha256sum | cut -d' ' -f1) $(git -C "$project" rev-parse "m/${BRANCH}")"
        if [ "$(cat "$gitdir/applied-patches" 2>/dev/null)" = "$want $(git -C "$project" rev-parse HEAD)" ] \
            && [ -z "$(git -C "$project" status --porcelain)" ]; then
            continue
        fi
        echo ">>> Patches: $project ($(ls "$pdir"/*.patch | wc -l) files)"
        # Re-applying rewrites every patched file. Files whose content ends up unchanged
        # get their old mtime back, so that a new patch does not make Soong and Kati
        # re-read every patched Android.bp/*.mk (a 30-minute analysis on a small host).
        old=$(git -C "$project" rev-parse HEAD)
        mtimes=()
        while IFS= read -r -d '' f; do
            if [ -e "$project/$f" ]; then mtimes+=("$(stat -c %Y "$project/$f") $f"); fi
        done < <(git -C "$project" diff -z --name-only "m/${BRANCH}" "$old")
        git -C "$project" am --abort >/dev/null 2>&1 || true
        git -C "$project" reset -q --hard "m/${BRANCH}"
        if ! git -C "$project" am -q --3way "$pdir"/*.patch; then
            git -C "$project" am --abort >/dev/null 2>&1 || true
            echo "!!! The patches for $project no longer apply to m/${BRANCH} (upstream changed) -"
            echo "    refresh patches/${BRANCH}/${project}/."
            exit 1
        fi
        for f in "${mtimes[@]}"; do
            if git -C "$project" diff --quiet "$old" HEAD -- "${f#* }"; then
                touch -c -d "@${f%% *}" "$project/${f#* }"
            fi
        done
        echo "$want $(git -C "$project" rev-parse HEAD)" > "$gitdir/applied-patches"
    done
}
apply_patches

# 4. Signing configuration for the own keys (step 0). keys.mk (included by
#    vendor/lineage/config/common.mk) makes releasekey the default certificate: apps take
#    platform/shared/media/... from this directory, a path under vendor/lineage-priv/ gives
#    the release-keys tag, and Soong takes the APEX payload keys from the same directory
#    (ApexKeyDir). An APEX container certificate is a separate android_app_certificate
#    module resolved in the APEX's own directory, so every apex module in the tree gets a
#    PRODUCT_CERTIFICATE_OVERRIDES entry pointing at our certificate of that name (variants
#    such as com.android.virt_avf_enabled by the longest matching prefix). Apps signed with
#    a certificate from their module directory (certificate: ":x", the APKs inside APEXes)
#    get releasekey, as in the LineageOS wiki. A missing APEX key does not stop the build:
#    that APEX keeps its AOSP test key (listed below; tools/make-keys.sh -u adds it).
if [ -d "$KEYS_DIR" ]; then
    bp_list=$(mktemp); apex_scan=$(mktemp); app_scan=$(mktemp)
    find . -path ./out -prune -o -path ./.repo -prune -o -path ./vendor/lineage-priv -prune \
        -o -name Android.bp -print0 > "$bp_list"
    xargs -0 awk '
        /^[A-Za-z0-9_]*apex[A-Za-z0-9_]*[ \t]*\{/ && !/^apex_key[ \t]*\{/ { blk = 1; name = ""; cert = ""; next }
        blk && /^[ \t]*name:/        { sub(/^[ \t]*name:[ \t]*"/, "");        sub(/".*$/, ""); name = $0 }
        blk && /^[ \t]*certificate:/ { sub(/^[ \t]*certificate:[ \t]*"/, ""); sub(/".*$/, ""); cert = $0 }
        blk && /^\}/ { if (name != "") print name, cert; blk = 0 }' < "$bp_list" | sort -u > "$apex_scan"
    xargs -0 awk '
        /^(android_app|android_app_import|override_android_app)[ \t]*\{/ { blk = 1; name = ""; cert = ""; next }
        blk && /^[ \t]*name:/        { sub(/^[ \t]*name:[ \t]*"/, "");        sub(/".*$/, ""); name = $0 }
        blk && /^[ \t]*certificate:/ { sub(/^[ \t]*certificate:[ \t]*"/, ""); sub(/".*$/, ""); cert = $0 }
        blk && /^\}/ { if (name != "" && cert ~ /^:/) print name; blk = 0 }' < "$bp_list" | sort -u > "$app_scan"
    # Key names tools/make-keys.sh can generate (apex_key with its key in the module directory).
    keyable=$(xargs -0 awk '
        /^apex_key[ \t]*\{/ { blk = 1; priv = ""; next }
        blk && /^[ \t]*private_key:/ { sub(/^[ \t]*private_key:[ \t]*"/, ""); sub(/".*$/, ""); priv = $0 }
        blk && /^\}/ { if (priv ~ /\.pem$/ && priv !~ /^:/ && priv !~ /\//) { sub(/\.pem$/, "", priv); print priv }; blk = 0 }' < "$bp_list" | sort -u | tr '\n' ' ')
    rm -f "$bp_list"
    bases=""
    for f in "$KEYS_DIR"/*.pem; do
        b="${f##*/}"; b="${b%.pem}"
        if [ "${b%.x509}" = "$b" ] && [ -f "$KEYS_DIR/$b.pk8" ] && [ -f "$KEYS_DIR/$b.x509.pem" ]; then
            bases="$bases $b"
        fi
    done
    overrides=""; used=""; missing=""
    while read -r mod cert; do
        c=""
        case "$cert" in
            :*.certificate) c="${cert#:}"; c="${c%.certificate}" ;;
            "") for b in $bases; do
                    case "$mod" in "$b"|"$b".*|"$b"_*|"$b"-*) [ ${#b} -gt ${#c} ] && c="$b" ;; esac
                done ;;
            *) continue ;;
        esac
        [ -n "$c" ] || continue
        case " $bases " in
            *" $c "*)
                overrides="$overrides $mod:$c.certificate.override"
                case " $used " in *" $c "*) ;; *) used="$used $c" ;; esac ;;
            *)  case " $keyable " in *" $c "*) missing="$missing $c" ;; esac ;;   # the rest are AOSP test keys outside our set
        esac
    done < "$apex_scan"
    case " $bases " in *" com.android.vndk "*) overrides="$overrides com.android.vndk:com.android.vndk.certificate.override" ;; esac
    apps=0
    while read -r app; do
        [ -n "$app" ] || continue
        overrides="$overrides $app:releasekey.certificate.override"; apps=$((apps + 1))
    done < "$app_scan"
    [ "$apps" -gt 0 ] && used="$used releasekey"
    rm -f "$apex_scan" "$app_scan"
    {
        echo "# Generated by build.sh on every build - do not edit."
        echo "PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/lineage-priv/keys/releasekey"
        echo "PRODUCT_CERTIFICATE_OVERRIDES += \\"
        for o in $overrides; do echo "    $o \\"; done
        echo
    } > "$KEYS_DIR/keys.mk"
    {
        echo "// Generated by build.sh on every build - do not edit."
        for c in $used; do
            printf '\nandroid_app_certificate {\n    name: "%s.certificate.override",\n    certificate: "%s",\n}\n' "$c" "$c"
        done
    } > "$KEYS_DIR/Android.bp"
    echo ">>> Keys: keys.mk + Android.bp ($(echo $overrides | wc -w) certificate overrides: $apps apps -> releasekey, the rest APEX containers; $(echo $used | wc -w) certificates)"
    if [ -n "$missing" ]; then
        echo ">>> WARNING: no key for these APEXes, they keep the AOSP test keys: $(echo $missing | tr ' ' '\n' | sort -u | tr '\n' ' ')(tools/make-keys.sh -u)"
    fi
fi

# 5. UX defaults, edited into the freshly synced source on every build (reverted above).
#    "Advanced restart": LineageOS has no setting for it in this branch, only the hidden
#    LineageSettings.Secure.ADVANCED_REBOOT, which defaults to 0.
POWERMENU_UTILS="lineage-sdk/sdk/src/java/org/lineageos/internal/util/PowerMenuUtils.java"
if [ -n "$ADVANCED_RESTART" ] && [ -f "$POWERMENU_UTILS" ] && ! grep -q "ADVANCED_REBOOT, 1)" "$POWERMENU_UTILS"; then
    echo ">>> Advanced restart (recovery in the power menu) on by default"
    sed -i 's/LineageSettings\.Secure\.ADVANCED_REBOOT, 0)/LineageSettings.Secure.ADVANCED_REBOOT, 1)/' "$POWERMENU_UTILS"
fi
#    Developer options: DevelopmentSettingsEnabler shows them by default only on eng builds.
DEV_SETTINGS_ENABLER="frameworks/base/packages/SettingsLib/src/com/android/settingslib/development/DevelopmentSettingsEnabler.java"
if [ -n "$DEVELOPER_OPTIONS_VISIBLE" ] && [ -f "$DEV_SETTINGS_ENABLER" ] && grep -q 'Build.TYPE.equals("eng") ? 1 : 0' "$DEV_SETTINGS_ENABLER"; then
    echo ">>> Developer options visible by default"
    sed -i 's/Build\.TYPE\.equals("eng") ? 1 : 0/1/' "$DEV_SETTINGS_ENABLER"
fi

# ---------------------------------------------------------------------------
# 6. Build environment. AOSP's shell tooling (envsetup.sh, breakfast, mka) uses variables
#    before setting them, so nounset stays off from here on; -e and pipefail stay on.
# ---------------------------------------------------------------------------
ccache -M "$CCACHE_SIZE" >/dev/null
set +u
source build/envsetup.sh
# breakfast fetches the device trees (roomservice). On the first build of a new tree they
# are not patched yet; if lunch fails on them, patch and try again.
breakfast "$DEVICE" || { apply_patches; breakfast "$DEVICE"; }
apply_patches

# 7. Private DNS (optional). The default mode "opportunistic" without a server is hard-coded
#    in Connectivity, not a resource, so the code is edited - here, after the last
#    apply_patches (resetting a patched project would wipe the edit). ConnectivitySettingsUtils
#    also feeds Settings; DnsManager read the server around it and is routed through it.
CS_UTILS="packages/modules/Connectivity/staticlibs/framework/com/android/net/module/util/ConnectivitySettingsUtils.java"
DNS_MANAGER="packages/modules/Connectivity/service/src/com/android/server/connectivity/DnsManager.java"
if [ -n "$PRIVATE_DNS_HOST" ]; then
    echo ">>> Default Private DNS: ${PRIVATE_DNS_HOST}"
    PRIVATE_DNS_HOST="$PRIVATE_DNS_HOST" perl -0pi -e '
        s/(\n([ \t]*)if \(TextUtils\.isEmpty\(mode\)\) mode = Settings\.Global\.getString\(cr, PRIVATE_DNS_DEFAULT_MODE\);)/$1\n$2if (TextUtils.isEmpty(mode)) mode = PRIVATE_DNS_MODE_PROVIDER_HOSTNAME_STRING;/;
        s/([ \t]*)return Settings\.Global\.getString\(context\.getContentResolver\(\), PRIVATE_DNS_SPECIFIER\);/$1final String specifier = Settings.Global.getString(context.getContentResolver(), PRIVATE_DNS_SPECIFIER);\n$1return TextUtils.isEmpty(specifier) ? "$ENV{PRIVATE_DNS_HOST}" : specifier;/;
    ' "$CS_UTILS"
    perl -0pi -e 's/getStringSetting\(context\.getContentResolver\(\),\s*PRIVATE_DNS_SPECIFIER\)/ConnectivitySettingsManager.getPrivateDnsHostname(context)/' "$DNS_MANAGER"
    if ! grep -q "mode = PRIVATE_DNS_MODE_PROVIDER_HOSTNAME_STRING;" "$CS_UTILS" \
        || ! grep -qF "\"${PRIVATE_DNS_HOST}\" : specifier;" "$CS_UTILS" \
        || ! grep -q "ConnectivitySettingsManager.getPrivateDnsHostname(context)" "$DNS_MANAGER"; then
        echo "!!! Could not set the default Private DNS - the Connectivity code changed."
        exit 1
    fi
fi

# 8. Trust: Samsung will not release newer firmware for this SoC, so the vendor patch
#    level of the device tree (VENDOR_SECURITY_PATCH) is final. Trust rates exactly that
#    value as current instead of a permanent "out of date"; an older level still is not.
if [ -n "$TRUST_VENDOR_PATCH_FINAL" ]; then
    TRUST_FILE="lineage-sdk/lineage/lib/main/java/org/lineageos/platform/internal/TrustInterfaceService.java"
    final_patch=$(sed -n 's/^VENDOR_SECURITY_PATCH *:= *//p' "device/samsung/${DEVICE}-common/BoardConfigCommon.mk" "device/samsung/${DEVICE}/BoardConfig.mk" 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
    if [ -n "$final_patch" ]; then
        perl -0pi -e 's/(\n(\s*)String patchLevel = SystemProperties\.get\(target\);\n)/$1$2\/\/ gta4xl-builder: Samsung'"'"'s last firmware for this SoC, this vendor patch level is final\n$2if (VENDOR_SECURITY_PATCHES.equals(target) \&\& "'"$final_patch"'".equals(patchLevel)) {\n$2    return TrustInterface.TRUST_FEATURE_LEVEL_GOOD;\n$2}\n/' "$TRUST_FILE"
        grep -q "gta4xl-builder: Samsung's last firmware" "$TRUST_FILE" || { echo "!!! Trust: the edit of $TRUST_FILE did not apply (upstream changed)"; exit 1; }
        echo ">>> Trust: vendor patch level $final_patch rated as current"
    else
        echo ">>> WARNING: Trust: no VENDOR_SECURITY_PATCH in the device tree - skipped"
    fi
fi

# 9. Product additions, generated from scratch in $GEN_DIR on every build and pulled in by
#    a line appended to lineage_<DEVICE>.mk (reverted to its git state before the sync).
#    Properties go to the product partition: vendor_init may not set properties without a
#    vendor. prefix, and a property set from the vendor partition silently never exists.
rm -rf "$GEN_DIR"
mkdir -p "$GEN_DIR"
GEN_MK="$GEN_DIR/gta4xl-builder.mk"
echo "# Generated by build.sh - do not edit." > "$GEN_MK"
GEN_PACKAGES=""

# Update server: the Updater app asks <OTA_BASE_URL>/api/v1/<device>/<type>/ (https only).
if [ -n "$OTA_BASE_URL" ]; then
    case "$OTA_BASE_URL" in https://*) ;; *) echo "!!! OTA_BASE_URL must start with https:// (the Updater refuses anything else)"; exit 1 ;; esac
    OTA_URI="${OTA_BASE_URL%/}/api/v1/{device}/{type}/"
    echo ">>> Update server: ${OTA_URI}"
    echo "PRODUCT_PRODUCT_PROPERTIES += lineage.updater.uri=${OTA_URI}" >> "$GEN_MK"
fi

# NTP: config_ntpServers (an array since Android 14). The device tree still sets the old,
# ignored config_ntpServer, which is why stock builds use time.android.com.
if [ -n "$NTP_SERVER" ]; then
    echo ">>> NTP: ${NTP_SERVER}"
    mkdir -p "$GEN_DIR/overlay/frameworks/base/core/res/res/values"
    cat > "$GEN_DIR/overlay/frameworks/base/core/res/res/values/config.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by build.sh: time server instead of time.android.com. -->
<resources>
    <string-array translatable="false" name="config_ntpServers">
        <item>ntp://${NTP_SERVER}</item>
    </string-array>
</resources>
EOF
    echo "PRODUCT_PACKAGE_OVERLAYS += $GEN_DIR/overlay" >> "$GEN_MK"
fi

# NetworkStack lives in an APEX, so only a runtime resource overlay works (overlayable
# "NetworkStackConfig"), with a higher priority than LineageOS's own overlay (100).
# - Fallback DNS: config_default_dns_servers, which DhcpClient adds only to a lease
#   without any DNS server.
# - Connectivity check: the host must answer 204 without a redirect over http and https,
#   otherwise every Wi-Fi network would look like it had no internet. Without a 204 the
#   default check (Google) stays and the build only warns.
NS_ITEMS=""
if [ -n "$FALLBACK_DNS" ]; then
    echo ">>> Fallback DNS (only when DHCP hands out none): ${FALLBACK_DNS}"
    NS_ITEMS+='    <string-array name="config_default_dns_servers" translatable="false">'$'\n'
    for dns in $FALLBACK_DNS; do NS_ITEMS+="        <item>${dns}</item>"$'\n'; done
    NS_ITEMS+='    </string-array>'$'\n'
fi
captive_portal_ok() {
    local scheme code
    for scheme in http https; do
        code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "${scheme}://$1/generate_204" || true)
        if [ "$code" != "204" ]; then
            echo "    ${scheme}://$1/generate_204 -> ${code:-no answer} (expected 204)"
            return 1
        fi
    done
}
if [ -n "$CAPTIVE_PORTAL_HOST" ]; then
    if captive_portal_ok "$CAPTIVE_PORTAL_HOST"; then
        echo ">>> Connectivity check: ${CAPTIVE_PORTAL_HOST}/generate_204"
        NS_ITEMS+="    <string name=\"config_captive_portal_http_url\" translatable=\"false\">http://${CAPTIVE_PORTAL_HOST}/generate_204</string>"$'\n'
        NS_ITEMS+="    <string name=\"config_captive_portal_https_url\" translatable=\"false\">https://${CAPTIVE_PORTAL_HOST}/generate_204</string>"$'\n'
        NS_ITEMS+='    <string-array name="config_captive_portal_fallback_urls" translatable="false">'$'\n'
        NS_ITEMS+="        <item>http://${CAPTIVE_PORTAL_HOST}/generate_204</item>"$'\n'
        NS_ITEMS+='    </string-array>'$'\n'
    else
        echo "!!! ${CAPTIVE_PORTAL_HOST} does not answer 204 on /generate_204 - keeping the"
        echo "    default connectivity check (Google). See README, 'Update server'."
    fi
fi
if [ -n "$NS_ITEMS" ]; then
    RRO="$GEN_DIR/NetworkStackOverlay"
    mkdir -p "$RRO/res/values"
    cat > "$RRO/Android.bp" <<'EOF'
// Generated by build.sh: fallback DNS and/or the connectivity check host.
runtime_resource_overlay {
    name: "Gta4xlBuilderNetworkStackOverlay",
    product_specific: true,
}
EOF
    cat > "$RRO/AndroidManifest.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.android.networkstack.overlay.gta4xlbuilder">
    <overlay
        android:isStatic="true"
        android:priority="200"
        android:targetPackage="com.android.networkstack"
        android:targetName="NetworkStackConfig" />
</manifest>
EOF
    printf '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n%s</resources>\n' "$NS_ITEMS" \
        > "$RRO/res/values/config.xml"
    GEN_PACKAGES+=" Gta4xlBuilderNetworkStackOverlay"
fi

# Debloat: a module whose `overrides` keeps the listed modules out of the image, without
# touching LineageOS's makefiles. Make honours overrides only for apps, executables,
# libraries and ETC (module-overrides in build/make/core/main.mk) - a `phony` drops them -
# so it is a prebuilt_etc that installs the list as /product/etc/gta4xl_builder_debloat.txt.
if [ -n "$DEBLOAT_PACKAGES" ]; then
    echo ">>> Left out: ${DEBLOAT_PACKAGES}"
    mkdir -p "$GEN_DIR/debloat"
    printf '%s\n' $DEBLOAT_PACKAGES > "$GEN_DIR/debloat/gta4xl_builder_debloat.txt"
    {
        echo "// Generated by build.sh: modules left out of the image."
        echo "prebuilt_etc {"
        echo "    name: \"Gta4xlBuilderDebloat\","
        echo "    src: \"gta4xl_builder_debloat.txt\","
        echo "    filename_from_src: true,"
        echo "    product_specific: true,"
        echo "    overrides: ["
        for p in $DEBLOAT_PACKAGES; do echo "        \"$p\","; done
        echo "    ],"
        echo "}"
    } > "$GEN_DIR/debloat/Android.bp"
    GEN_PACKAGES+=" Gta4xlBuilderDebloat"
fi

# Kernel fork with the eBPF backports: Android has to see kernel 5.10, like the other
# LineageOS 24.0 devices on 4.14/4.19 kernels.
if [ -n "$KERNEL_REPO_URL" ] && [ -n "$KERNEL_BPF_KVER" ]; then
    echo ">>> ro.bpf.kver_override=${KERNEL_BPF_KVER}"
    echo "PRODUCT_PRODUCT_PROPERTIES += ro.bpf.kver_override=${KERNEL_BPF_KVER}" >> "$GEN_MK"
fi
if [ -n "$GEN_PACKAGES" ]; then echo "PRODUCT_PACKAGES +=$GEN_PACKAGES" >> "$GEN_MK"; fi
if [ -f "$DEVICE_MK" ]; then
    cat >> "$DEVICE_MK" <<EOF

# --- Added by build.sh ---
\$(call inherit-product, $GEN_MK)
EOF
else
    echo "!!! $DEVICE_MK not found - cannot add $GEN_MK (kernel version override, tweaks)."
    exit 1
fi

# 10. A different set of additions than at the last successful build: files of removed
#     modules would stay in the out/ staging directories and end up in the images, so
#     `m installclean` first.
TWEAKS_STAMP="out/.build-sh-tweaks"
TWEAKS_STATE=$(find "$GEN_DIR" -type f | sort | xargs cat | sha256sum | cut -d' ' -f1)
if [ -d out ] && [ "$(cat "$TWEAKS_STAMP" 2>/dev/null)" != "$TWEAKS_STATE" ]; then
    echo ">>> Product additions changed since the last build - m installclean"
    run mka installclean
fi
export LINEAGE_BUILDTYPE

# 11. Build
keep=()
if [ "$KEEP_GOING" = "true" ]; then keep=(-k); fi
echo ">>> mka ${keep[*]} bacon -j${BUILD_JOBS}"
run mka "${keep[@]}" bacon -j"$BUILD_JOBS"
echo "$TWEAKS_STATE" > "$TWEAKS_STAMP"

version=$(sed -n 's/^ro\.lineage\.version=//p' "$OUT/product/etc/build.prop" 2>/dev/null | sed -n 1p || true)
zip="$OUT/lineage-${version}.zip"
echo ">>> Build finished in $(( ($(date +%s) - BUILD_START) / 60 )) min:"
if [ -n "$version" ] && [ -f "$zip" ]; then
    ( cd "$OUT" && sha256sum "lineage-${version}.zip" recovery.img ) | sed "s|  |  ${OUT#"$TOP"/}/|" || true
    grep -q '^ro\.build\.tags=release-keys' "$OUT/product/etc/build.prop" \
        || echo ">>> Signed with the public AOSP test keys (test-keys)."
else
    ls -1 "$OUT"/lineage-*-"${DEVICE}".zip "$OUT"/recovery.img 2>/dev/null || true
fi

# 12. Update server metadata (only with OTA_BASE_URL): JSON for the Updater app and a copy
#     of the package in $OUT/ota/; tools/ota-upload.sh (on the host) uploads both.
if [ -n "$OTA_BASE_URL" ]; then
    "$REPO/tools/generate-ota-json.sh" "out/target/product/${DEVICE}" "$DEVICE" "$OTA_BASE_URL"
fi
