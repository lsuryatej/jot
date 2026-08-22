#!/bin/bash
set -euo pipefail

# NotesManager and NoteStore carry the app's real logic and are free of SwiftUI,
# so they compile straight into a test executable with swiftc. No Xcode project
# and no SwiftPM manifest needed, matching how build.sh works.

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
OUT="$(mktemp -d)/NotesManagerTests"

"$SWIFTC" \
    -sdk "$SDK" \
    -target arm64-apple-macos14.0 \
    src/Note.swift \
    src/NoteStore.swift \
    src/NotesManager.swift \
    src/TextStatistics.swift \
    src/Checklist.swift \
    src/KeyCombo.swift \
    tests/NotesManagerTests.swift \
    tests/main.swift \
    -o "$OUT"

"$OUT"
