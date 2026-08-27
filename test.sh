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
    src/NoteFont.swift \
    src/Headings.swift \
    src/Highlight.swift \
    src/GlobalSearch.swift \
    src/LinkShrink.swift \
    src/Attachments.swift \
    src/AppleNotesSync.swift \
    src/TextRecognition.swift \
    src/Units.swift \
    src/CurrencyRates.swift \
    src/MathExpression.swift \
    src/UpdateChecker.swift \
    src/NoteStore.swift \
    src/ReminderDirective.swift \
    src/ReminderScheduler.swift \
    src/NotesManager.swift \
    src/TextStatistics.swift \
    src/Checklist.swift \
    src/CodeBlock.swift \
    src/OrderedList.swift \
    src/KeyCombo.swift \
    src/SettingsManager.swift \
    src/GlassTint.swift \
    src/ThemeNote.swift \
    src/Celebration.swift \
    src/PlainTextEditor.swift \
    src/PreferencesView.swift \
    tests/NotesManagerTests.swift \
    tests/ReminderDirectiveTests.swift \
    tests/ResizableCardTests.swift \
    tests/UpdateCheckerTests.swift \
    tests/GlassTintTests.swift \
    tests/ThemeNoteTests.swift \
    tests/CelebrationTests.swift \
    tests/InteractionTests.swift \
    tests/OrderedListTests.swift \
    tests/UILayerTests.swift \
    tests/HighlightTests.swift \
    tests/PerNoteFontTests.swift \
    tests/CodeBlockTests.swift \
    tests/main.swift \
    -o "$OUT"

"$OUT"
