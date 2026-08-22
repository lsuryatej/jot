# StickyNotes

A plain-text floating scratchpad for macOS, in the spirit of Antinote.

Swift + SwiftUI + AppKit, compiled directly with `swiftc`. There is no Xcode
project and no SwiftPM manifest; `build.sh` assembles the `.app` bundle itself.

## Build and run

```bash
./build.sh && open StickyNotes.app
```

```bash
./test.sh
```

Both scripts locate a toolchain themselves, checking `/Applications/Xcode-beta.app`,
then `/Applications/Xcode.app`, then `~/Downloads/Xcode-beta.app`.

Xcode is required, not just the Command Line Tools. The macOS 27 beta CLT ships
a `swiftc` (6.2.3) that cannot read its own SDK (built with 6.2 effective-5.10);
any `import SwiftUI` hangs and aborts while building the CoreFoundation module.
Xcode bundles a matched toolchain and SDK pair, so the scripts pass `-sdk`
explicitly rather than trusting `xcode-select`.

## What it does

**Floating panel.** An `NSPanel` at floating level that stays above other
windows, joins all Spaces, and uses `NSVisualEffectView` for native translucency.
The close button hides the panel rather than destroying it.

**Option+A** toggles the note from anywhere, and is rebindable in Settings.
Registered through Carbon's `RegisterEventHotKey`, which needs no Accessibility
permission and consumes the keystroke, so it will not also type `å` into
whatever app is in front.

**Four display modes**, switchable in Settings:

| Mode | Behaviour |
|---|---|
| Floating | Always on top, no Dock icon. Does not steal focus. |
| Menu Bar | Ordinary window level, shown and hidden from the menu bar icon. |
| Menu Bar Dropdown | Drops down under the icon and hides when you click away. |
| Dock | Dock icon and app switcher entry, like a normal app. |
| Screen Edge | Docked full-height to the left or right edge, revealed by resting the cursor against that edge. |

**Menu bar icon.** Left click toggles the panel, right click opens Show/Hide and
Quit. The app is `LSUIElement` with no Dock icon, so this is the fallback if the
hot key is ever claimed by another app.

**Swipe between notes.** A horizontal two-finger swipe over the editor moves
through note history. Swipe right to go back. Blank notes are dropped when you
navigate away or quit, except the one you are currently in.

**Timers.** Typing `5m timer`, `30s timer`, or `2h timer` starts a countdown in
the top-right corner and plays a sound when it finishes. A timer belongs to the
note that started it, and an expired directive does not restart itself.

**Checklists.** The Toggle Checklist button flips `[ ]` and `[x]` on the line
containing the caret. A line with no checkbox gains one, indentation preserved.

**Screen edge.** In Screen Edge mode a thin bar sits against your chosen edge.
Rest the cursor there for a moment and the note slides out; move away and it
slides back. Revealing by hover deliberately does not take keyboard focus, so
brushing the edge never redirects your typing. Clicking the bar, or using the
shortcut, reveals it *and* hands it focus. Edge and width are configurable.

**Search.** Cmd+F opens the native find bar with match highlighting; Cmd+G and
Shift+Cmd+G step through matches.

**Counts and totals.** A footer shows live word, character, and line counts.
Select text containing two or more numbers and it also shows their sum and
average, so "rent $1,240.50 and food $310.25" totals without leaving the note.

**Share.** The share button opens the standard macOS share sheet for the current
note (Notes, Mail, Messages, and so on).

**Settings** (Cmd+, or the menu bar icon's right-click menu) covers the display
mode, the shortcut, the timer keyword, and whether the footer is shown.

## Storage

Notes are a JSON array at
`~/Library/Application Support/StickyNotes/notes.json`, written atomically and
debounced 600ms, then flushed on navigation and on quit. Notes written by the
earlier `UserDefaults`-backed build are migrated once, automatically, from the
`com.example.StickyNotes` domain.

Each launch copies the last known-good contents to `notes.backup.json` beside
it. A note was lost to a clobbered save during development; a copy per launch is
cheap insurance against the next bug doing the same thing quietly.

Preferences stay in `UserDefaults` under `com.suryatejlalam.StickyNotes`. They
are small and reconstructible, unlike the notes.

## Layout

| Path | Role |
|---|---|
| `src/main.swift` | AppKit entry point |
| `src/StickyNotes.swift` | App delegate, display modes, panel, status item |
| `src/MainMenu.swift` | Menu bar, including the Find items that drive Cmd+F |
| `src/SettingsManager.swift` | Preferences and the display-mode definitions |
| `src/PreferencesView.swift` | Settings window and the shortcut recorder |
| `src/HotKeyController.swift` | Global shortcut registration |
| `src/KeyCombo.swift` | Shortcut model and its display form |
| `src/TextStatistics.swift` | Word counts and selection sum/average |
| `src/Checklist.swift` | Checklist parsing and rewriting |
| `src/EdgeTrigger.swift` | Screen-edge trigger strip and hot side |
| `src/ContentView.swift` | Panel UI: header, editor, timer overlay, share |
| `src/PlainTextEditor.swift` | `NSTextView` wrapper plus the swipe-reading scroll view |
| `src/NotesManager.swift` | Note state, navigation, timer parsing, checklists |
| `src/NoteStore.swift` | Atomic file persistence and legacy migration |
| `tests/` | Logic tests, run by `./test.sh` |
| `resources/Info.plist` | Bundle metadata |
| `resources/AppIcon.icns` | App icon, regenerated by `scripts/make-icon.swift` |

`NotesManager` and `NoteStore` are deliberately free of SwiftUI so they compile
into a plain test executable.

`StickyNotes.app/` is build output and is gitignored. `build.sh` deletes and
rebuilds it every run so a stale binary or signature cannot survive.

## Not done yet

- Checklist markers are fixed at `[ ]` and `[x]`; only the timer keyword is
  configurable.
- The note window has one size per mode; it is resizable but the size is not
  remembered between launches.
- Notes cannot be reordered, titled, or deleted except by emptying them.
- The build targets `arm64` only.
