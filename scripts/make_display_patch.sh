#!/bin/bash
# Package the ZL2 / FCL display fix as a self-contained artifact.
# This deliberately has no external downloads: it must succeed even when the
# full QEMU / ANGLE IPA build is blocked by an upstream source going away.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/husk-display-fix.zip"
STAGE="$ROOT/build/display-fix-patch"
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE"

FILES=(
  src/app/Husk/TLUnityView.swift
  src/java-framework/src/husk/ViewRoot.java
  src/java-framework/src/android/webkit/WebView.java
  scripts/package_ipa.sh
  scripts/ci_build.sh
  scripts/verify_java_framework.sh
  scripts/make_display_patch.sh
  .github/workflows/husk-build.yml
  docs/10-display-fix-zl2-fcl.md
)

for f in "${FILES[@]}"; do
    mkdir -p "$STAGE/$(dirname "$f")"
    cp "$ROOT/$f" "$STAGE/$f"
done

# A real, applyable diff when the checkout has the parent commit.
if git -C "$ROOT" rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    git -C "$ROOT" diff HEAD~1 HEAD -- \
        src/app/Husk/TLUnityView.swift \
        src/java-framework/src/husk/ViewRoot.java \
        src/java-framework/src/android/webkit/WebView.java \
        scripts/package_ipa.sh scripts/ci_build.sh \
        .github/workflows/husk-build.yml > "$STAGE/husk-display-fix.patch" || true
fi
cp "$ROOT/docs/10-display-fix-zl2-fcl.md" "$STAGE/README.md"

(cd "$STAGE" && zip -qry "$OUT" .)
echo "wrote $OUT ($(wc -c < "$OUT") bytes)"
