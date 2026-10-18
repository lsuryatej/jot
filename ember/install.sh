#!/bin/bash
set -euo pipefail

# Installs Ember.app into Applications and opens it.
#
#   bash install.sh                  # the Ember-*.zip next to this script, or ./Ember.app after build.sh
#   bash install.sh path/to/Ember-0.1.0.zip
#
# Ember is ad-hoc signed, not notarized (no paid Apple Developer account), so
# a copy that came through a browser, AirDrop, or Messages is quarantined and
# Gatekeeper refuses to open it. This strips that flag, which is the whole
# reason to use this script rather than dragging the app across yourself.
# Never asks for sudo.

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "Ember is a macOS app"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SOURCE="${1:-}"
if [ -z "$SOURCE" ]; then
    SOURCE="$(ls -t "$HERE"/Ember-*.zip 2>/dev/null | head -1 || true)"
    [ -n "$SOURCE" ] || SOURCE="$HERE/Ember.app"
fi

case "$SOURCE" in
    *.zip)
        [ -f "$SOURCE" ] || die "$SOURCE not found"
        if [ -f "$SOURCE.sha256" ]; then
            EXPECTED="$(awk '{print $1}' "$SOURCE.sha256")"
            ACTUAL="$(shasum -a 256 "$SOURCE" | awk '{print $1}')"
            [ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch, the download may be corrupted. Not installing."
            say "Checksum verified."
        fi
        ditto -x -k "$SOURCE" "$WORK"
        APP="$WORK/Ember.app"
        ;;
    *)
        APP="$SOURCE"
        ;;
esac
[ -d "$APP" ] || die "no Ember.app found (looked at $SOURCE). Download the build or run ./build.sh first."

if [ -w /Applications ]; then
    DEST="/Applications"
elif mkdir -p "$HOME/Applications" 2>/dev/null && [ -w "$HOME/Applications" ]; then
    DEST="$HOME/Applications"
else
    die "/Applications and ~/Applications are both unwritable."
fi

# A running copy would keep the old binary alive.
osascript -e 'tell application id "com.suryatejlalam.Ember" to quit' >/dev/null 2>&1 || true
pkill -x Ember 2>/dev/null || true

if [ -d "$DEST/Ember.app" ]; then
    say "Replacing the previous install. Your pairing and history are kept (they live in ~/Library/Application Support/Ember)."
    rm -rf "$DEST/Ember.app"
fi
ditto "$APP" "$DEST/Ember.app"
xattr -cr "$DEST/Ember.app" 2>/dev/null || true

say "Installed to $DEST/Ember.app"
open "$DEST/Ember.app"
say "Ember is running: look for the flame in your menu bar."
