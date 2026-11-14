#!/bin/bash
# Compile every class of Husk's Java framework (android.* + husk.*) with javac.
#
# This is the fast CI gate for changes under src/java-framework/src: it checks
# the whole framework for syntax and type errors without needing R8/d8, Xcode or
# a QEMU build. src/java-framework/build.sh is the real dex build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JDK="${HUSK_JDK:-$(/usr/libexec/java_home -v 17 2>/dev/null || /usr/libexec/java_home)}"
JAVAC="$JDK/bin/javac"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# javac's own JDK does not ship org.xmlpull, which libcore's classes reference.
find "$ROOT/src/java-framework/stubs" -name '*.java' > "$TMP/stubs.txt"
"$JAVAC" -nowarn --release 8 -encoding UTF-8 -d "$TMP/stubs" @"$TMP/stubs.txt"

find "$ROOT/src/java-framework/src" "$ROOT/src/java-framework/gen-src" -name '*.java' > "$TMP/sources.txt"
echo "==> compiling $(wc -l < "$TMP/sources.txt" | tr -d ' ') Java sources"
"$JAVAC" -nowarn --release 8 -encoding UTF-8 -Xmaxerrs 200 \
    -cp "$TMP/stubs" -d "$TMP/classes" @"$TMP/sources.txt"

echo "OK: $(find "$TMP/classes" -name '*.class' | wc -l | tr -d ' ') classes compiled"
