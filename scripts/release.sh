#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Builds Jot.app via build.sh, then packages it for a GitHub release: a zip
# next to a checksum file, named by the version in resources/Info.plist.
#
# This never runs on CI — see the note in .github/workflows/release.yml about
# why. It's meant to be run by hand on a Mac that has the Xcode toolchain
# build.sh needs, by whoever is cutting the release.

VERSION="$(plutil -extract CFBundleShortVersionString raw resources/Info.plist)"
[ -n "$VERSION" ] || { echo "error: could not read CFBundleShortVersionString" >&2; exit 1; }

echo "Building Jot $VERSION..."
./build.sh

OUT_DIR="dist"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

ZIP_NAME="Jot-$VERSION.zip"
# ditto, not zip: it preserves the code signature, resource fork, and
# extended attributes the way Finder's own "Compress" does. A plain `zip`
# of an .app can silently invalidate the signature.
ditto -c -k --sequesterRsrc --keepParent Jot.app "$OUT_DIR/$ZIP_NAME"

shasum -a 256 "$OUT_DIR/$ZIP_NAME" > "$OUT_DIR/$ZIP_NAME.sha256"

echo
echo "Built $OUT_DIR/$ZIP_NAME"
cat "$OUT_DIR/$ZIP_NAME.sha256"
echo
echo "Next:"
echo "  gh release create v$VERSION $OUT_DIR/$ZIP_NAME --title \"Jot $VERSION\" --notes-file <notes>"
