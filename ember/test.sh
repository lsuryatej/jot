#!/bin/bash
set -euo pipefail

# Compiles every source file except the app entry point into a test
# executable, the way Jot's test.sh does: no Xcode project, no SwiftPM.
# Compiling the UI files too means a broken view fails here, not just in
# build.sh.
#
#   ./test.sh          unit tests (offline)
#   ./test.sh --live   round-trips real messages through ntfy.sh instead

cd "$(dirname "$0")"

find_developer_dir() {
    for candidate in \
        "/Applications/Xcode-beta.app/Contents/Developer" \
        "/Applications/Xcode.app/Contents/Developer" \
        "$HOME/Downloads/Xcode-beta.app/Contents/Developer"
    do
        [ -x "$candidate/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" ] && echo "$candidate" && return 0
    done
    return 1
}

DEVELOPER_DIR="$(find_developer_dir)" || {
    echo "error: no Xcode toolchain found." >&2
    exit 1
}
export DEVELOPER_DIR
SWIFTC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
TARGET="$(uname -m)-apple-macos14.0"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

SOURCES=()
for file in src/*.swift; do
    [ "$file" = "src/main.swift" ] || SOURCES+=("$file")
done

if [ "${1:-}" != "--live" ]; then
    "$SWIFTC" -sdk "$SDK" -target "$TARGET" "${SOURCES[@]}" tests/*.swift -o "$OUT/EmberTests"
    "$OUT/EmberTests"
else
    "$SWIFTC" -sdk "$SDK" -target "$TARGET" \
        src/Wire.swift src/PairSecret.swift src/Engine.swift src/NtfyTransport.swift \
        tests/live/main.swift -o "$OUT/EmberLive"
    "$OUT/EmberLive"
fi
