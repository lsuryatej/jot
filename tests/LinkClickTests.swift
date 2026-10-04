import AppKit
import Foundation

// Issue #12, links: Cmd+click opens (Zed / VS Code), a plain click on a
// shrunk link expands it so it can be edited, and it folds back once the
// caret leaves it. The opener is swapped for a spy so nothing here ever
// reaches NSWorkspace.

private let longURL = "https://www.example.com/some/very/long/path?query=1"

private func linkRect(_ range: NSRange, in view: ChecklistTextView) -> NSRect? {
    guard let lm = view.layoutManager, let tc = view.textContainer else { return nil }
    lm.ensureLayout(for: tc)
    let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    guard glyphs.length > 0 else { return nil }
    var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
    rect.origin.x += view.textContainerInset.width
    rect.origin.y += view.textContainerInset.height
    return rect
}

/// A view holding `text`, links detected and folded, with a spy opener.
private func makeLinkView(_ text: String) -> (ChecklistTextView, () -> [URL]) {
    let view = makeTextView(text)
    view.recomputeLinkMatches()
    view.applyLinkFolding()
    var opened: [URL] = []
    view.linkOpener = { opened.append($0) }
    return (view, { opened })
}

/// Whether every character of the scheme-and-path zone before the domain is
/// folded out of layout.
private func schemeIsHidden(_ match: LinkMatch, in view: ChecklistTextView) -> Bool {
    guard let lm = view.layoutManager, let tc = view.textContainer else { return false }
    lm.ensureLayout(for: tc)
    let scheme = NSRange(location: match.range.location, length: match.displayRange.location - match.range.location)
    let glyphs = lm.glyphRange(forCharacterRange: scheme, actualCharacterRange: nil)
    // The glyph range can reach one glyph past either end of the characters
    // asked for (see the link-shrink test in UILayerTests), so judge only
    // glyphs whose character is really in the scheme zone.
    let inZone = (0..<glyphs.length).map { glyphs.location + $0 }
        .filter { NSLocationInRange(lm.characterIndexForGlyph(at: $0), scheme) }
    return !inZone.isEmpty && inZone.allSatisfy { lm.notShownAttribute(forGlyphAt: $0) }
}

private func everyGlyphShown(_ range: NSRange, in view: ChecklistTextView) -> Bool {
    guard let lm = view.layoutManager, let tc = view.textContainer else { return false }
    lm.ensureLayout(for: tc)
    let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    return glyphs.length > 0 && (0..<glyphs.length).allSatisfy { !lm.notShownAttribute(forGlyphAt: glyphs.location + $0) }
}

func runLinkClickTests() {

    // MARK: - Finding and vetting a link

    suite("the link under an index is found with its URL") {
        let text = "see \(longURL) now"
        let link = LinkShrink.link(containing: 10, in: text)
        equal(link?.range, NSRange(location: 4, length: (longURL as NSString).length), "the whole URL")
        equal(link?.url.absoluteString, longURL, "and the URL itself")
        check(LinkShrink.link(containing: 1, in: text) == nil, "an index outside any link finds nothing")
    }

    suite("a bare domain and an email address come back as openable URLs") {
        equal(LinkShrink.link(containing: 2, in: "example.com")?.url.scheme, "http", "a bare domain gets http")
        equal(LinkShrink.link(containing: 7, in: "mail me@example.com")?.url.scheme, "mailto", "an email address becomes mailto")
    }

    suite("a sentence-ending ? is not part of the link") {
        let text = "did you see https://example.com/x?"
        let link = LinkShrink.link(containing: 15, in: text)
        equal(link?.url.absoluteString, "https://example.com/x", "the trailing ? is punctuation")
        check(LinkShrink.link(containing: (text as NSString).length - 1, in: text) == nil, "the ? itself is not a link")
    }

    suite("a scheme-less link ending in ? keeps its scheme") {
        // The detector keeps the ? on links with a path; trimming it must
        // not drop the http it added.
        let bare = LinkShrink.link(containing: 6, in: "see example.com/page?")
        equal(bare?.url.absoluteString, "http://example.com/page", "a bare domain with a path keeps http, minus the ?")
        check(bare.map { LinkShrink.isSafeToOpen($0.url) } ?? false, "and Cmd+click can open it")
        let www = LinkShrink.link(containing: 8, in: "go to www.example.com/a?")
        equal(www?.url.absoluteString, "http://www.example.com/a", "a www link keeps http too")
    }

    suite("only http, https and mailto are safe to open") {
        check(LinkShrink.isSafeToOpen(URL(string: "https://example.com")!), "https")
        check(LinkShrink.isSafeToOpen(URL(string: "http://example.com")!), "http")
        check(LinkShrink.isSafeToOpen(URL(string: "HTTPS://EXAMPLE.COM")!), "scheme case does not matter")
        check(LinkShrink.isSafeToOpen(URL(string: "mailto:me@example.com")!), "mailto")
        check(!LinkShrink.isSafeToOpen(URL(string: "file:///etc/hosts")!), "never file:")
        check(!LinkShrink.isSafeToOpen(URL(string: "slack://open")!), "never a custom scheme")
        check(!LinkShrink.isSafeToOpen(URL(string: "javascript:alert(1)")!), "never javascript:")
        check(!LinkShrink.isSafeToOpen(URL(string: "ftp://example.com/f")!), "not ftp either")
    }

    // MARK: - Cmd+click opens

    suite("Cmd+click on a shrunk link opens the full URL") {
        let (view, opened) = makeLinkView("read \(longURL) later")
        guard let match = LinkShrink.matches(in: view.string).first,
              let rect = linkRect(match.displayRange, in: view) else {
            check(false, "fixture should contain one shrunk link")
            return
        }
        let claimed = view.handleSpecialClick(at: NSPoint(x: rect.midX, y: rect.midY), modifiers: [.command])
        check(claimed, "the click is claimed")
        equal(opened().map(\.absoluteString), [longURL], "the whole URL, not just the visible domain, is opened")
        check(schemeIsHidden(match, in: view), "and the link stays collapsed")
        equal(view.string, "read \(longURL) later", "the text is untouched")
    }

    suite("Cmd+click on a short, unshrunk link opens it too") {
        let (view, opened) = makeLinkView("see http://a.co ok")
        guard let rect = linkRect(NSRange(location: 4, length: 11), in: view) else {
            check(false, "fixture should lay out")
            return
        }
        let claimed = view.handleSpecialClick(at: NSPoint(x: rect.midX, y: rect.midY), modifiers: [.command])
        check(claimed, "claimed")
        equal(opened().map(\.absoluteString), ["http://a.co"], "short links open as well")
    }

    suite("Cmd+click on an email address opens mailto") {
        let (view, opened) = makeLinkView("mail me@example.com ok")
        guard let rect = linkRect(NSRange(location: 5, length: 14), in: view) else {
            check(false, "fixture should lay out")
            return
        }
        view.handleSpecialClick(at: NSPoint(x: rect.midX, y: rect.midY), modifiers: [.command])
        equal(opened().map(\.absoluteString), ["mailto:me@example.com"], "mail client, not browser")
    }

    suite("Cmd+click on a file: URL never opens it") {
        let text = "file:///Applications/Calculator.app"
        let (view, opened) = makeLinkView(text)
        guard let rect = linkRect(NSRange(location: 0, length: (text as NSString).length), in: view) else {
            check(false, "fixture should lay out")
            return
        }
        view.handleSpecialClick(at: NSPoint(x: rect.midX, y: rect.midY), modifiers: [.command])
        check(opened().isEmpty, "nothing reaches NSWorkspace")
    }

    suite("Cmd+click on plain text is not claimed") {
        let (view, opened) = makeLinkView("just words here")
        guard let rect = linkRect(NSRange(location: 5, length: 5), in: view) else {
            check(false, "fixture should lay out")
            return
        }
        let claimed = view.handleSpecialClick(at: NSPoint(x: rect.midX, y: rect.midY), modifiers: [.command])
        check(!claimed, "falls through to NSTextView's own Cmd+click selection")
        check(opened().isEmpty, "nothing opened")
    }

    suite("Cmd+click past the end of a line ending in a link does not open it") {
        let (view, opened) = makeLinkView("see http://a.co")
        guard let rect = linkRect(NSRange(location: 4, length: 11), in: view) else {
            check(false, "fixture should lay out")
            return
        }
        view.handleSpecialClick(at: NSPoint(x: rect.maxX + 120, y: rect.midY), modifiers: [.command])
        check(opened().isEmpty, "empty margin to the right of a link is not the link")
    }

    suite("Cmd+click in a code note opens nothing") {
        let (view, opened) = makeLinkView("code\nhttp://a.co")
        guard let rect = linkRect(NSRange(location: 5, length: 11), in: view) else {
            check(false, "fixture should lay out")
            return
        }
        view.handleSpecialClick(at: NSPoint(x: rect.midX, y: rect.midY), modifiers: [.command])
        check(opened().isEmpty, "links are not links inside a code block")
    }

    // MARK: - Plain click expands, caret leaving collapses

    suite("a plain click on a collapsed link expands it and puts the caret there") {
        let (view, opened) = makeLinkView(longURL)
        guard let match = LinkShrink.matches(in: view.string).first,
              let rect = linkRect(match.displayRange, in: view) else {
            check(false, "fixture should contain one shrunk link")
            return
        }
        check(schemeIsHidden(match, in: view), "starts collapsed")
        let claimed = view.handleSpecialClick(at: NSPoint(x: rect.midX, y: rect.midY), modifiers: [])
        check(claimed, "the click is claimed, so the caret lands on the clicked character, not where it moved to")
        check(opened().isEmpty, "a plain click never opens")
        check(everyGlyphShown(match.range, in: view), "the whole URL is visible for editing")
        let caret = view.selectedRange()
        check(caret.length == 0 && NSLocationInRange(caret.location, match.displayRange),
              "the caret sits in the domain that was clicked")
        equal(view.string, longURL, "the text is untouched")
    }

    suite("moving the caret out of an expanded link folds it again") {
        let (view, _) = makeLinkView("\(longURL) and more")
        guard let match = LinkShrink.matches(in: view.string).first,
              let rect = linkRect(match.displayRange, in: view) else {
            check(false, "fixture should contain one shrunk link")
            return
        }
        view.handleSpecialClick(at: NSPoint(x: rect.midX, y: rect.midY), modifiers: [])
        check(everyGlyphShown(match.range, in: view), "expanded after the click")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        check(schemeIsHidden(match, in: view), "collapsed once the caret is elsewhere")
    }

    suite("opening and folding a link is instant and moves nothing else") {
        let (view, _) = makeLinkView("above\n\(longURL)\nbelow the link")
        guard let match = LinkShrink.matches(in: view.string).first,
              let rect = linkRect(match.displayRange, in: view),
              let lm = view.layoutManager, let tc = view.textContainer else {
            check(false, "fixture should contain one shrunk link")
            return
        }
        func fragment(at character: Int) -> NSRect {
            lm.ensureLayout(for: tc)
            return lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: character), effectiveRange: nil)
        }
        let aboveBefore = fragment(at: 0)
        let belowIndex = (view.string as NSString).length - 1
        let belowBefore = fragment(at: belowIndex)

        view.handleSpecialClick(at: NSPoint(x: rect.midX, y: rect.midY), modifiers: [])
        check(everyGlyphShown(match.range, in: view), "expanded synchronously, no animation or deferred pass")
        equal(fragment(at: 0), aboveBefore, "the line above is untouched")

        let away = NSRange(location: belowIndex, length: 0)
        view.setSelectedRange(away)
        check(schemeIsHidden(match, in: view), "folded synchronously")
        equal(view.selectedRange(), away, "folding never moves the caret the user just placed")
        equal(fragment(at: belowIndex), belowBefore, "once folded, the line below is back exactly where it was")
        equal(fragment(at: 0), aboveBefore, "and the line above never moved")
    }

    suite("the caret at the very end of the link still counts as inside it") {
        let (view, _) = makeLinkView("\(longURL) and more")
        guard let match = LinkShrink.matches(in: view.string).first,
              let rect = linkRect(match.displayRange, in: view) else {
            check(false, "fixture should contain one shrunk link")
            return
        }
        view.handleSpecialClick(at: NSPoint(x: rect.midX, y: rect.midY), modifiers: [])
        view.setSelectedRange(NSRange(location: NSMaxRange(match.range), length: 0))
        check(everyGlyphShown(match.range, in: view), "End on a link keeps it open, so appending to it works")
    }

    suite("typing inside an expanded link keeps it expanded") {
        let (view, _) = makeLinkView("\(longURL) and more")
        guard let match = LinkShrink.matches(in: view.string).first,
              let rect = linkRect(match.displayRange, in: view) else {
            check(false, "fixture should contain one shrunk link")
            return
        }
        view.handleSpecialClick(at: NSPoint(x: rect.midX, y: rect.midY), modifiers: [])
        let end = NSMaxRange(match.range)
        view.setSelectedRange(NSRange(location: end, length: 0))
        view.insertText("x", replacementRange: NSRange(location: end, length: 0))
        guard let edited = LinkShrink.matches(in: view.string).first else {
            check(false, "the edited URL is still a link")
            return
        }
        equal(edited.range.length, match.range.length + 1, "the new character joined the link")
        check(everyGlyphShown(edited.range, in: view),
              "editing the URL text does not fold it away mid-edit")
    }

    suite("a plain click on an already-expanded link is ordinary caret placement") {
        let (view, opened) = makeLinkView(longURL)
        guard let match = LinkShrink.matches(in: view.string).first,
              let rect = linkRect(match.displayRange, in: view) else {
            check(false, "fixture should contain one shrunk link")
            return
        }
        view.handleSpecialClick(at: NSPoint(x: rect.midX, y: rect.midY), modifiers: [])
        guard let schemeRect = linkRect(NSRange(location: 2, length: 1), in: view) else {
            check(false, "expanded link should lay out")
            return
        }
        let claimed = view.handleSpecialClick(at: NSPoint(x: schemeRect.midX, y: schemeRect.midY), modifiers: [])
        check(!claimed, "left to NSTextView, so click-drag selection inside the URL still works")
        check(opened().isEmpty, "never opens")
    }

    suite("Cmd+click on an expanded link opens it") {
        let (view, opened) = makeLinkView(longURL)
        guard let match = LinkShrink.matches(in: view.string).first,
              let rect = linkRect(match.displayRange, in: view) else {
            check(false, "fixture should contain one shrunk link")
            return
        }
        view.handleSpecialClick(at: NSPoint(x: rect.midX, y: rect.midY), modifiers: [])
        guard let schemeRect = linkRect(NSRange(location: 2, length: 1), in: view) else {
            check(false, "expanded link should lay out")
            return
        }
        view.handleSpecialClick(at: NSPoint(x: schemeRect.midX, y: schemeRect.midY), modifiers: [.command])
        equal(opened().map(\.absoluteString), [longURL], "the expanded URL opens")
    }

    // MARK: - Cursor

    suite("the pointing hand shows only with Cmd held over a link") {
        let (view, _) = makeLinkView("see \(longURL) and words")
        guard let match = LinkShrink.matches(in: view.string).first,
              let linkBox = linkRect(match.displayRange, in: view),
              let wordBox = linkRect(NSRange(location: (view.string as NSString).length - 5, length: 5), in: view) else {
            check(false, "fixture should lay out")
            return
        }
        let overLink = NSPoint(x: linkBox.midX, y: linkBox.midY)
        check(view.wantsLinkCursor(at: overLink, modifiers: [.command]), "Cmd over a link")
        check(!view.wantsLinkCursor(at: overLink, modifiers: []), "no Cmd, no hand: a plain click edits")
        check(!view.wantsLinkCursor(at: NSPoint(x: wordBox.midX, y: wordBox.midY), modifiers: [.command]),
              "Cmd over ordinary words")
    }
}
