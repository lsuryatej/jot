#!/bin/bash
set -e

# The macOS 27 beta Command Line Tools ship a swiftc (6.2.3) that cannot read the
# installed SDK (built with 6.2 effective-5.10) — any `import SwiftUI` hangs and
# aborts while building the CoreFoundation module. Xcode beta bundles a matching
# toolchain + SDK pair, so we compile with that instead.
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
    echo "error: no Xcode toolchain found. Install Xcode (or Xcode-beta) into /Applications." >&2
    exit 1
}

SWIFTC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

echo "Using toolchain: $DEVELOPER_DIR"

mkdir -p StickyNotes.app/Contents/MacOS
mkdir -p StickyNotes.app/Contents/Resources

"$SWIFTC" \
    -sdk "$SDK" \
    -target arm64-apple-macos14.0 \
    src/StickyNotes.swift src/ContentView.swift \
    -o StickyNotes.app/Contents/MacOS/StickyNotes

if [ ! -f StickyNotes.app/Contents/Info.plist ]; then
    echo "warning: StickyNotes.app/Contents/Info.plist is missing" >&2
fi

# Ad-hoc sign (required on Apple Silicon) and clear the quarantine flag.
codesign --force --deep --sign - StickyNotes.app
xattr -cr StickyNotes.app

echo "Build complete. Run 'open StickyNotes.app' to launch."
