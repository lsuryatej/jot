import AppKit

// Issue #19: symbols the note's font has no glyph for (`⮑` in SF Mono) drew
// as empty boxes once typed or pasted, though the same note opened fine.
// AppKit swaps in a font that has the glyph during its own fix-up pass, but
// Jot's restyle runs after that pass during an edit and put every character
// back on the note's font. These check the glyph the layout actually uses.

@MainActor
private func glyph(of character: String, in view: ChecklistTextView) -> (glyph: CGGlyph, font: String)? {
    let ns = view.string as NSString
    let location = ns.range(of: character).location
    guard location != NSNotFound, let layoutManager = view.layoutManager, let container = view.textContainer else { return nil }
    layoutManager.ensureLayout(for: container)
    let font = view.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    return (layoutManager.cgGlyph(at: layoutManager.glyphIndexForCharacter(at: location)), font?.fontName ?? "nil")
}

@MainActor
private func makeFallbackEditor(code: Bool = false) -> ChecklistTextView {
    let view = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    view.baseFont = NoteFont.resolved("SF Mono", size: 13)
    view.textStorage?.delegate = view
    if code { view.codeKeyword = "code" }
    return view
}

@MainActor
private func type(_ text: String, into view: ChecklistTextView) {
    view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
    view.insertText(text, replacementRange: view.selectedRange())
}

func runFontFallbackTests() {
    MainActor.assumeIsolated {
        suite("a symbol SF Mono lacks still draws when typed (#19)") {
            let view = makeFallbackEditor()
            view.string = "ls "
            view.applyChecklistStyling()
            type("⮑ done", into: view)
            let result = glyph(of: "⮑", in: view)
            check(result.map { $0.glyph != 0 } ?? false, "a real glyph, not the missing-glyph box (font: \(result?.font ?? "nil"))")
        }

        suite("a symbol SF Mono lacks still draws when typed into a code note") {
            let view = makeFallbackEditor(code: true)
            view.string = "code\n$ ls "
            view.applyChecklistStyling()
            type("⮑ out ↳", into: view)
            for symbol in ["⮑", "↳"] {
                let result = glyph(of: symbol, in: view)
                check(result.map { $0.glyph != 0 } ?? false, "\(symbol) draws (font: \(result?.font ?? "nil"))")
            }
        }

        suite("fallback survives a restyle of the line it is on") {
            let view = makeFallbackEditor()
            view.string = "# heading "
            view.applyChecklistStyling()
            type("⮑", into: view)
            view.applyChecklistStyling()
            let result = glyph(of: "⮑", in: view)
            check(result.map { $0.glyph != 0 } ?? false, "on a heading line (font: \(result?.font ?? "nil"))")
        }

        suite("characters the font has keep the note's own font") {
            let view = makeFallbackEditor()
            view.string = ""
            type("plain ⮑", into: view)
            let font = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            equal(font?.fontName, view.baseFont.fontName, "only the missing glyph is swapped")
        }
    }
}
