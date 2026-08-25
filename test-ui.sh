#!/bin/bash
set -euo pipefail

# Opt-in window harness. Not run by ./test.sh, and not meant to be.
#
# ./test.sh compiles the logic layer and runs hundreds of pure checks in a
# couple of seconds. This one brings up a real NSApplication, real NSWindows,
# and a real run loop, then sends real mouse events through AppKit hit-testing
# into real SwiftUI buttons. That is the only way to see the class of bug that
# has shipped repeatedly here — unclickable sidebar rows, a pane that traps the
# window, a header button dispatching through a responder chain that only
# exists when a window is key — and it costs seconds per run, so it stays
# separate.
#
# Still swiftc only. No Xcode project, no SwiftPM, no XCTest, no dependencies.

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

SWIFTC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(mktemp -d)"
OUT="$BUILD_DIR/JotUITests"

# These tests put a real window on screen and ask AppKit to make it key, which
# is a machine-wide competition: two runs at once both ask to be frontmost, and
# the loser's synthetic clicks land in a window that is not key, where SwiftUI
# treats the first click as activation rather than as a press. That is not
# hypothetical. Running several of these concurrently produced a 30/40 run
# whose ten failures were all downstream of one window never coming up. A lock
# directory is the atomic primitive available everywhere; macOS has no flock.
LOCK_DIR="${TMPDIR:-/tmp}/jot-ui-tests.lock"
LOCK_WAIT=${JOT_UI_TEST_LOCK_WAIT:-600}
lock_held=""
waited=0
until mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ "$waited" -ge "$LOCK_WAIT" ]; then
        echo "error: another UI test run has held $LOCK_DIR for ${LOCK_WAIT}s." >&2
        echo "If no run is active, remove that directory and try again." >&2
        exit 1
    fi
    [ "$waited" = 0 ] && echo "waiting for another UI test run to finish..."
    sleep 2
    waited=$((waited + 2))
done
lock_held=1

cleanup() {
    rm -rf "$BUILD_DIR"
    [ -n "$lock_held" ] && rmdir "$LOCK_DIR" 2>/dev/null
    return 0
}
trap cleanup EXIT

# The whole app, minus src/main.swift, which carries its own top-level code and
# would collide with tests/ui/main.swift.
SRC=()
for f in "$ROOT"/src/*.swift; do
    [ "$(basename "$f")" = "main.swift" ] && continue
    SRC+=("$f")
done

"$SWIFTC" \
    -sdk "$SDK" \
    -target arm64-apple-macos14.0 \
    "${SRC[@]}" \
    "$ROOT"/tests/ui/*.swift \
    -o "$OUT"

# Wall-clock guard. A window test that wedges on a run loop would otherwise
# hang a terminal or a CI job forever; 180s is far beyond a healthy run.
TIMEOUT=${JOT_UI_TEST_TIMEOUT:-180}

"$OUT" &
TEST_PID=$!

(
    sleep "$TIMEOUT"
    if kill -0 "$TEST_PID" 2>/dev/null; then
        echo "error: UI tests exceeded ${TIMEOUT}s, killing." >&2
        kill -9 "$TEST_PID" 2>/dev/null || true
    fi
) &
WATCHDOG_PID=$!

STATUS=0
wait "$TEST_PID" || STATUS=$?
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true

exit "$STATUS"
