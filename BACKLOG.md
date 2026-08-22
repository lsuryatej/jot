# Backlog

Working list. Roughly ordered within each section; nothing here is committed to
a schedule. Items marked **[bug]** are defects in shipped behaviour.

## Next up

- [ ] **Link shrink** — collapse a long URL to its domain, Cmd-click to expand.
      TextKit 2 rendering attributes, so the full URL stays in the file.
      The last of the three originally-scoped Antinote features; math and
      currency/unit conversion are both done (see Done).

## Bugs

- [x] **[bug] Apple Notes sync duplicated every note on each edit.** osascript
      echoes a trailing newline after a returned value; the note id went into
      the mapping with it attached, the next lookup failed, and the code did
      the reasonable thing for a note that no longer exists — made a new one.
      Identifiers are now trimmed, and existing mappings are repaired on read.
- [ ] **[bug] Apple Notes sync does not carry images — reopened.** The
      base64-`<img>`-in-body approach was implemented and unit tested, but
      real-machine verification (2026-08-22) showed it does NOT work as
      intended: the note shows the literal markdown text
      `![320](Attachments/…)` as visible, spellcheck-flagged text, plus a
      separate generic "File · 464 KB" attachment box with a plain document
      icon — not an inline image. Two distinct problems, either of which
      alone would explain part of this:

      1. The literal markdown appearing as text means `htmlForLine`'s
         image-only-line detection did not fire for this line, or the base64
         encode/HTML-embed path failed and silently fell back to the escaped-
         text branch (`imgTag(for:base:)` returns nil on any read failure).
      2. The generic file attachment suggests that even when Notes does
         receive a `data:` URI, it is not decoding it into a *displayed*
         inline image the way the documented technique claims — at least not
         reliably, or not in the current Notes version.

      Needs real debugging next: confirm whether `imgTag(for:base:)` is even
      being reached (add temporary logging, sync one note, inspect), and
      separately test the base64-`<img>`-in-body technique in isolation
      (a trivial AppleScript, one small image) to see what Notes actually
      does with it before trusting that approach further. Deprioritized for
      now per explicit instruction — "should hold for now."
- [ ] **[bug] Swiping with the title bar hidden gives no feedback.** Nothing
      indicates which note you moved to. Worth checking what Antinote does
      here before designing it.

## Behaviour and polish

- [ ] The edge card stack could be presented more cleanly.
- [ ] Notes should be reorderable, in the sidebar and in general.
- [ ] Timer sound is a bare "ting" — needs something better.
- [ ] Pasting multi-line text into a `list` note should split it line by line
      into separate items rather than dropping in one block.
- [ ] Should keep floating above a background app that goes fullscreen.
- [x] Cmd+W closes the Settings window (and now hides the main panel too,
      since the panel already turns a real close into a hide). Also added
      Cmd+N for a new note, and a shortcuts table in the README.
- [ ] Text/letter spacing control, alongside the existing line spacing.
- [ ] Font customisation.
- [ ] Colour tints for the glass appearance.
- [ ] Configurable from macOS's hot-corner settings.
- [x] **Verified the release workflow for real.** Pushed v1.1.0, watched
      .github/workflows/release.yml run on an actual GitHub-hosted macOS
      runner: build, package, and publish all succeeded in 28 seconds. The
      concern going in was real — GitHub's runners ship stable Xcode, not the
      macOS 27 beta this project's local toolchain workaround exists for —
      and it turned out fine, because a standard runner never hits that beta
      SDK mismatch at all. Confirmed both install paths pick up the automated
      release: `curl | bash` and `brew upgrade` (via a cask bump, still
      manual) both landed real 1.1.0 installs.
- [ ] The release workflow still doesn't update the Homebrew cask at
      lsuryatej/homebrew-jot automatically — version and sha256 need a manual
      bump after each release (done by hand for 1.1.0). Worth automating with
      a follow-up job that has push access to that repo.
- [ ] No screenshot in the README yet.

## Lists

- [x] Typing `list` on the first line turns the note into a checklist.
- [ ] More list types, visually distinguishable: checklist, numbered, lettered,
      roman numerals.
- [ ] Decide whether checkboxes should become real radio-style controls or stay
      as styled `[ ]` / `[x]` text. Current approach keeps the file readable in
      `cat` and exportable to Obsidian; a real control would look better but
      needs the text to stop being the source of truth.

## Engineering

- [x] **Automated UI-layer test coverage — first slice.** 18 new checks
      against real ChecklistTextView instances: Cmd+L/Cmd+N/Shift-Cmd-V
      dispatch via performKeyEquivalent, checkbox click precision (including
      that clicking body text does NOT toggle, which an earlier version got
      wrong), caret geometry, and image placement. Verified by mutation —
      reintroducing the caret bug and the click-anywhere-on-the-line bug both
      fail the new tests.

      Getting there required a real fix, not just test code: constructing a
      real NSWindow hangs indefinitely in this project's plain swiftc test
      binary (no window server session), which is what mouseDown's internal
      convert(_:from:) needs to behave correctly. Extracted the actual
      hit-test-and-act logic into handleSpecialClick(at:), which takes an
      already-view-space point and needs no window at all — better factored
      production code, not just a testing workaround.

      Not yet covered: swipe gesture handling, drag-to-resize, and rendering
      itself (draw(_:)) — geometry and dispatch are covered, pixels are not.

## Ideas

- [ ] **Per-app notes.** An app name on the first line (e.g. `WhatsApp`) means
      that note is the one shown when the hot key is pressed while that app is
      frontmost.
- [ ] **Colour swatch previews.** A hex, RGB, or HSL string shows a small
      colour badge beside it, without replacing the text in the buffer.
- [ ] Spotlight-style capabilities in the note itself.

## Done

- [x] Typing `list` on the first line turns the note into a checklist.
- [x] Caret matches the text size rather than filling the line box.
- [x] Notes no longer disappear between launches (they were destroyed by test
      fixtures written into the live file during development; the store now
      keeps ten dated backups and honours `STICKYNOTES_NOTES_FILE`).
- [x] Image paste.
