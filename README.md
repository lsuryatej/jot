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

**Option+A** toggles the panel from anywhere. Registered through Carbon's
`RegisterEventHotKey`, which needs no Accessibility permission and consumes the
keystroke, so it will not also type `å` into whatever app is in front.

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

**Share.** The share button opens the standard macOS share sheet for the current
note (Notes, Mail, Messages, and so on).

## Storage

Notes are a JSON array at
`~/Library/Application Support/StickyNotes/notes.json`, written atomically and
debounced 600ms, then flushed on navigation and on quit. Notes written by the
earlier `UserDefaults`-backed build are migrated once, automatically, from the
`com.example.StickyNotes` domain.

## Layout

| Path | Role |
|---|---|
| `src/StickyNotes.swift` | `@main`, app delegate, floating panel, hot key, status item |
| `src/ContentView.swift` | Panel UI: header, editor, timer overlay, share |
| `src/PlainTextEditor.swift` | `NSTextView` wrapper plus the swipe-reading scroll view |
| `src/NotesManager.swift` | Note state, navigation, timer parsing, checklists |
| `src/NoteStore.swift` | Atomic file persistence and legacy migration |
| `tests/` | Logic tests, run by `./test.sh` |
| `resources/Info.plist` | Bundle metadata |

`NotesManager` and `NoteStore` are deliberately free of SwiftUI so they compile
into a plain test executable.

`StickyNotes.app/` is build output and is gitignored. `build.sh` deletes and
rebuilds it every run so a stale binary or signature cannot survive.

## Not done yet

- Display modes (Dock, menu bar dropdown, standard menu bar) and a Preferences
  window. The hot key and the checklist keyword are not configurable.
- Live word and character counts; sum and average over a selection.
- In-note search on Cmd+F. The `NSTextView` migration is the prerequisite and is
  now in place.
- No app icon, so the bundle shows a generic placeholder in share sheets.
- The build targets `arm64` only.
