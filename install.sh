#!/bin/bash
set -euo pipefail

# Downloads the latest Jot release from GitHub and installs it — no Xcode,
# no Homebrew, no build step required. Usage:
#
#   curl -fsSL https://raw.githubusercontent.com/lsuryatej/jot/main/install.sh | bash
#
# What this does and does not do:
#   - Downloads a prebuilt, ad-hoc-signed Jot.app from a GitHub release.
#   - Verifies its checksum against the one published alongside it.
#   - Installs to /Applications, falling back to ~/Applications if that is
#     not writable.
#   - Clears the quarantine attribute so Gatekeeper does not block first
#     launch. A plain `curl` download is never quarantined in the first
#     place — only browser-mediated downloads are — but this covers the case
#     where the archive passed through something that did tag it.
#   - Never asks for sudo. If /Applications is not writable and neither is
#     ~/Applications, it says so and stops rather than trying to work
#     around it.

REPO="lsuryatej/jot"
APP_NAME="Jot.app"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl is required"
command -v unzip >/dev/null || die "unzip is required"
[ "$(uname)" = "Darwin" ] || die "Jot is a macOS app"

say "Finding the latest release..."
RELEASE_JSON="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")" \
  || die "could not reach GitHub. Check your connection and try again."

VERSION="$(printf '%s' "$RELEASE_JSON" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/')"
ZIP_URL="$(printf '%s' "$RELEASE_JSON" | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | sed -E 's/.*"(https:[^"]+)".*/\1/')"
[ -n "$ZIP_URL" ] || die "no .zip asset found on the latest release"

say "Latest version: $VERSION"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

ZIP_PATH="$WORK_DIR/Jot.zip"
say "Downloading $ZIP_URL"
curl -fsSL "$ZIP_URL" -o "$ZIP_PATH" || die "download failed"

SUM_URL="$ZIP_URL.sha256"
if EXPECTED="$(curl -fsSL "$SUM_URL" 2>/dev/null | awk '{print $1}')" && [ -n "$EXPECTED" ]; then
    ACTUAL="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
    [ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch — the download may be corrupted or tampered with. Not installing."
    say "Checksum verified."
else
    say "warning: no checksum file found for this release; skipping verification."
fi

say "Unzipping..."
unzip -q "$ZIP_PATH" -d "$WORK_DIR"
[ -d "$WORK_DIR/$APP_NAME" ] || die "$APP_NAME not found in the archive"

if [ -w /Applications ]; then
    DEST="/Applications"
elif [ -w "$HOME/Applications" ] || mkdir -p "$HOME/Applications" 2>/dev/null; then
    DEST="$HOME/Applications"
else
    die "/Applications and ~/Applications are both unwritable. Move the app manually from $WORK_DIR/$APP_NAME."
fi

if [ -d "$DEST/$APP_NAME" ]; then
    say "Removing the previous install at $DEST/$APP_NAME"
    rm -rf "$DEST/$APP_NAME"
fi

say "Installing to $DEST/$APP_NAME"
ditto "$WORK_DIR/$APP_NAME" "$DEST/$APP_NAME"

# Belt and suspenders: strip quarantine even though a curl download should
# never carry it, so this is safe to re-run against a copy that came from
# somewhere else.
xattr -cr "$DEST/$APP_NAME" 2>/dev/null || true

say ""
say "Jot $VERSION installed to $DEST/$APP_NAME"
say "Launch it with: open \"$DEST/$APP_NAME\""
say "Or find it in Applications and double-click it."
