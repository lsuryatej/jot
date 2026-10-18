#!/bin/bash
set -euo pipefail

# Launches the built Ember.app against a throwaway paired state file and has
# a probe play the other Mac over ntfy.sh. Needs ./build.sh first, and the
# network. Your real pairing is never touched (EMBER_STATE points elsewhere).

cd "$(dirname "$0")"
[ -x Ember.app/Contents/MacOS/Ember ] || { echo "error: run ./build.sh first" >&2; exit 1; }

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
DEVELOPER_DIR="$(find_developer_dir)" || { echo "error: no Xcode toolchain found." >&2; exit 1; }
export DEVELOPER_DIR
SWIFTC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

WORK="$(mktemp -d)"
APP_PID=""
cleanup() {
    [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

SOURCES=()
for file in src/*.swift; do
    [ "$file" = "src/main.swift" ] || SOURCES+=("$file")
done
"$SWIFTC" -sdk "$SDK" -target "$(uname -m)-apple-macos14.0" "${SOURCES[@]}" tests/probe/main.swift -o "$WORK/EmberProbe"

STATE="$WORK/state.json"
"$WORK/EmberProbe" prepare "$STATE"

EMBER_STATE="$STATE" Ember.app/Contents/MacOS/Ember >"$WORK/app.log" 2>&1 &
APP_PID=$!

STATUS=0
"$WORK/EmberProbe" exchange "$STATE" || STATUS=$?

if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "  FAIL the app quit or crashed during the test"
    STATUS=1
else
    echo "  ok   the app is still running"
fi
echo "--- app log ---"
cat "$WORK/app.log" || true
exit "$STATUS"
