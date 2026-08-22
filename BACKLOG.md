# Backlog

Working list. Roughly ordered within each section; nothing here is committed to
a schedule. Items marked **[bug]** are defects in shipped behaviour.

## Next up

The three remaining Antinote features, agreed as the priority:

- [ ] **Inline maths with variables** — `x = 40`, `x * 3`, `1200 * 1.18`,
      `10 + 20%`. Results drawn in the right margin so the note stays plain
      text. Recursive-descent parser, no dependency; re-evaluate the document
      top to bottom per keystroke rather than building a dependency graph.
- [ ] **Unit and currency conversion** — `5 km to miles` comes largely free
      from Foundation's `Measurement` once the parser exists. Currency via
      `fawazahmed0/exchange-api`: no API key, CDN-served, includes crypto,
      fetched once and cached so conversions work offline.
- [ ] **Link shrink** — collapse a long URL to its domain, Cmd-click to expand.
      TextKit 2 rendering attributes, so the full URL stays in the file.

## Bugs

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
