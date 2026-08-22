#!/bin/bash
set -euo pipefail

APP="Jot.app"
BUNDLE_ID="com.suryatejlalam.Jot"

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

echo "Toolchain: $DEVELOPER_DIR"

# The bundle is build output. Assemble it from scratch every time so a stale
# binary or signature can never survive a rebuild.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp resources/Info.plist "$APP/Contents/Info.plist"
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

"$SWIFTC" \
    -sdk "$SDK" \
    -target arm64-apple-macos14.0 \
    -O \
    src/*.swift \
    -o "$APP/Contents/MacOS/Jot"

# Ad-hoc sign (required on Apple Silicon) and clear the quarantine flag.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
xattr -cr "$APP"

echo "Build complete. Run 'open $APP' to launch."
