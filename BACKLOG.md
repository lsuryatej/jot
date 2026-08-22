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
- [ ] **[bug] Apple Notes sync does not carry images.** The body is sent as
      markdown, so an image line arrives as the literal `![280](…)` text.
      Notes' AppleScript interface has no clean attachment API; the likely
      route is embedding the image as a base64 `<img>` in the HTML body, which
      needs testing to see whether Notes renders it.
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
- [ ] Cmd+W should close the Settings window.
- [ ] Text/letter spacing control, alongside the existing line spacing.
- [ ] Font customisation.
- [ ] Colour tints for the glass appearance.
- [ ] Configurable from macOS's hot-corner settings.
- [ ] The GitHub Actions release workflow (.github/workflows/release.yml)
      publishes a GitHub release automatically on a version tag, but does not
      update the Homebrew cask at lsuryatej/homebrew-jot — its version and
      sha256 still need a manual bump (or a follow-up automation) after each
      release. Also genuinely untested on a real macOS Actions runner;
      scripts/release.sh (run by hand) is the path that has actually been
      exercised end to end.
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

- [ ] **Automated UI-layer test coverage.** Every test today is pure logic. The
      AppKit layer — paste dispatch, caret placement, swipe, rendering — has
      none, and every bug found by hand so far has lived there.

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
