#!/bin/bash
set -euo pipefail

# Builds Ember.app the way Jot builds Jot.app: one swiftc invocation, no
# Xcode project, no package manager, ad-hoc signed. Universal (Apple Silicon
# and Intel), since there's no telling which Mac the other person has.

cd "$(dirname "$0")"

APP="Ember.app"
BUNDLE_ID="com.suryatejlalam.Ember"
MIN_MACOS="14.0"

# Same toolchain lookup as Jot's build.sh: prefer Xcode-beta, whose swiftc
# matches its own SDK, over a Command Line Tools pair that may not.
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
export DEVELOPER_DIR
SWIFTC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
echo "Toolchain: $DEVELOPER_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp resources/Info.plist "$APP/Contents/Info.plist"

# The icon is drawn by a script, not committed as a binary.
"$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" scripts/make-icon.swift "$WORK/AppIcon.iconset" >/dev/null
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

for ARCH in arm64 x86_64; do
    "$SWIFTC" \
        -sdk "$SDK" \
        -target "$ARCH-apple-macos$MIN_MACOS" \
        -O \
        src/*.swift \
        -o "$WORK/Ember-$ARCH"
done
lipo -create "$WORK/Ember-arm64" "$WORK/Ember-x86_64" -output "$APP/Contents/MacOS/Ember"

# Ad-hoc sign (required on Apple Silicon) and clear the quarantine flag.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
xattr -cr "$APP"

echo "Built $(pwd)/$APP. Run ./install.sh to put it in Applications."
