#!/bin/bash
# Produce a ready-to-install IPA without a macOS runner or a QEMU/ANGLE build.
#
# The ZL2 / FCL display fix lives entirely in Husk's Java framework (dex). The
# upstream 3.4 IPA already contains the native runtime, ANGLE, QEMU dylib,
# guest images and the Xcode-built app binary. So: download that release,
# recompile the Java framework from THIS checkout, replace the dex files inside
# the app bundle, zip it back up. No Xcode, no cross-compilation, no 2GB guest.
#
# Runs on Linux / macOS. Requires: curl, unzip, zip, python3, a JDK (javac),
# and r8.jar for d8. HUSK_JDK / HUSK_D8 override the defaults.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="${HUSK_UPSTREAM_IPA:-https://github.com/Leviidev/Husk/releases/download/3.4/Husk.ipa}"
BUILD="$ROOT/build"
JRT="$BUILD/java-runtime"
WORK="$BUILD/ipa-repack"
OUT_IPA="$BUILD/Husk-fixed.ipa"
OUT_TIPA="$BUILD/Husk-fixed-a11.tipa"

if [ -z "${HUSK_JDK:-}" ]; then
    if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/javac" ]; then
        HUSK_JDK="$JAVA_HOME"
    elif command -v /usr/libexec/java_home >/dev/null 2>&1; then
        HUSK_JDK="$(/usr/libexec/java_home -v 17 2>/dev/null || /usr/libexec/java_home)"
    elif command -v javac >/dev/null 2>&1; then
        HUSK_JDK="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
    else
        echo 'no JDK found; set HUSK_JDK or install a JDK' >&2
        exit 1
    fi
fi
JDK="$HUSK_JDK"
D8="${HUSK_D8:-$BUILD/r8.jar}"

mkdir -p "$BUILD" "$JRT"

step() { printf '\n==> %s\n' "$*"; }

step "download upstream release IPA"
if [ ! -s "$BUILD/upstream.ipa" ]; then
    curl -fL --retry 4 --retry-delay 5 -o "$BUILD/upstream.ipa" "$UPSTREAM"
fi
stat -c 'upstream: %s bytes' "$BUILD/upstream.ipa" 2>/dev/null || stat -f 'upstream: %z bytes' "$BUILD/upstream.ipa"

step "fetch d8 (R8) if needed"
if [ ! -s "$D8" ]; then
    curl -fL --retry 4 -o "$D8" \
        https://dl.google.com/dl/android/maven2/com/android/tools/r8/8.5.10/r8-8.5.10.jar
fi
test -s "$D8"

step "compile Husk's Java framework into dex"
HUSK_JDK="$JDK" HUSK_D8="$D8" bash "$ROOT/src/java-framework/build.sh" "$JRT/husk-framework.dex"
ls -lh "$JRT"

step "unpack IPA"
rm -rf "$WORK"
mkdir -p "$WORK"
unzip -q "$BUILD/upstream.ipa" -d "$WORK"
APP="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
[ -n "$APP" ] || { echo 'no .app inside Payload' >&2; exit 1; }
echo "app: $APP"
echo '--- java-runtime before ---'
ls -lh "$APP/java-runtime" | head -30

step "replace dex files with the freshly compiled ones"
replaced=0
for dex in "$JRT"/*.dex; do
    name="$(basename "$dex")"
    found=0
    # Replace every same-named dex inside the app bundle (normally java-runtime/).
    while IFS= read -r target; do
        cp "$dex" "$target"
        echo "  replaced ${target#$APP/}"
        replaced=$((replaced + 1)); found=$((found + 1))
    done < <(find "$APP" -name "$name" -type f)
    if [ "$found" -eq 0 ]; then
        # Upstream renamed the dex: still put ours next to it so the fix ships.
        cp "$dex" "$APP/java-runtime/$name"
        echo "  added java-runtime/$name (no same-named dex upstream)"
        replaced=$((replaced + 1))
    fi
done
[ "$replaced" -gt 0 ] || { echo 'no dex could be placed inside the app' >&2; exit 1; }

step "stamp the build identity"
PLIST="$APP/Info.plist"
if command -v python3 >/dev/null 2>&1; then
    python3 - "$PLIST" <<'PY'
import plistlib, sys, datetime
p = sys.argv[1]
with open(p, 'rb') as f:
    d = plistlib.load(f)
d['HuskBuildCommit'] = 'display-fix-dex'
d['HuskBuildDate'] = datetime.datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')
with open(p, 'wb') as f:
    plistlib.dump(d, f)
print('   Info.plist stamped')
PY
fi

step "repackage"
(cd "$WORK" && zip -qry "$OUT_IPA" Payload)
cp "$OUT_IPA" "$OUT_TIPA"     # A11 TrollStore Lite: same bytes, .tipa extension
ls -lh "$OUT_IPA" "$OUT_TIPA"

step "verify the archive"
unzip -t "$OUT_IPA" | tail -2
python3 - "$OUT_IPA" <<'PY'
import sys, zipfile, hashlib
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
assert any(n.endswith('.app/Info.plist') for n in names), 'missing Info.plist'
assert any('java-runtime' in n and n.endswith('.dex') for n in names), 'missing dex'
print('   OK: %d entries, Info.plist + dex present' % len(names))
PY
echo "==> done: $OUT_IPA"
