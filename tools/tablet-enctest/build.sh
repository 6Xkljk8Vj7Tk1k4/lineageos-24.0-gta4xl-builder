#!/bin/bash
# Builds the Java tools here (*.java: video encoders and decoders, sensors, speaker and microphone,
# GNSS, clock read) into enctest.dex with the JDK, android.jar and d8 of a synced and built tree
# (SRC, default src). Nothing is installed on the tablet: the dex is pushed to /data/local/tmp
# and run with app_process (see the header of each file). The dex is committed next to the
# sources, so that tools/tablet-test.sh works without a tree; run this after changing a .java file.
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC="${SRC:-src}"
JDK="$SRC/prebuilts/jdk/jdk21/linux-x86/bin"
ANDROID_JAR="$SRC/prebuilts/sdk/current/public/android.jar"
D8_JAR="$SRC/out/host/linux-x86/framework/d8.jar"
for f in "$JDK/javac" "$ANDROID_JAR" "$D8_JAR"; do
    [ -e "$f" ] || { echo "missing $f (needs a synced and built tree in $SRC)" >&2; exit 1; }
done
OUT=build_output/tablet-enctest
rm -rf "$OUT"; mkdir -p "$OUT/classes"
"$JDK/javac" -Xlint:-options --release 8 -cp "$ANDROID_JAR" -d "$OUT/classes" tools/tablet-enctest/*.java
"$JDK/java" -cp "$D8_JAR" com.android.tools.r8.D8 --min-api 29 --lib "$ANDROID_JAR" --output "$OUT" "$OUT"/classes/*.class
mv "$OUT/classes.dex" "$OUT/enctest.dex"
cp "$OUT/enctest.dex" tools/tablet-enctest/enctest.dex
ls -la tools/tablet-enctest/enctest.dex
