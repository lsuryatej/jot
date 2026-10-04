import AppKit
import SwiftUI

// The Screen Edge stack, hosted for real: an `NSHostingView` around
// `EdgeStackView`, never put in a window (see `makeTextView` for why), sized
// by hand and laid out by pumping the run loop. SwiftUI lays out a detached
// hosting view the same way it lays out one on screen, which is enough to
// see each card's frame, the stack's scroll geometry, and how many cards
// SwiftUI touches when a note changes.

@MainActor
final class EdgeStackHarness {
    let manager: NotesManager
    let settings: SettingsManager
    let host: NSHostingView<EdgeStackView>

    init(manager: NotesManager, settings: SettingsManager? = nil, width: CGFloat = 340, height: CGFloat = 600) {
        self.manager = manager
        self.settings = settings ?? SettingsManager(defaults: UserDefaults(suiteName: "edge-stack-tests-\(UUID().uuidString)")!)
        var target: Int?
        host = NSHostingView(rootView: EdgeStackView(
            notesManager: manager,
            settings: self.settings,
            scrollToIndex: Binding(get: { target }, set: { target = $0 })
        ))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
    }

    convenience init(notes: [String], width: CGFloat = 340, height: CGFloat = 600) {
        self.init(manager: makeManager(seed: notes), width: width, height: height)
    }

    /// Lets the deferred height reports land and SwiftUI settle.
    func pump(_ turns: Int = 6) {
        for _ in 0..<turns {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
        }
    }

    /// Each card's editor scroll view, keyed by the note it shows.
    func cards() -> [UUID: NSScrollView] {
        var result: [UUID: NSScrollView] = [:]
        for textView in Self.textViews(in: host) {
            guard let scroll = textView.enclosingScrollView,
                  let note = manager.notes.first(where: { $0.text == textView.string })
            else { continue }
            result[note.id] = scroll
        }
        return result
    }

    func card(_ index: Int) -> NSScrollView? { cards()[manager.notes[index].id] }

    /// The stack's own scroll view: the one the cards scroll inside.
    var stackScrollView: NSScrollView? {
        cards().values.first?.superview?.enclosingScrollView
    }

    /// A card's frame in the hosting view's coordinates: where it is on
    /// screen, as opposed to where it is in the scrolled document.
    func onScreenFrame(_ index: Int) -> CGRect? {
        guard let card = card(index) else { return nil }
        return card.convert(card.bounds, to: host)
    }

    /// Top of the first card to the bottom of the last, in the scrolled
    /// document: the height the stack lays its cards out over.
    func contentExtent() -> CGFloat {
        guard let document = stackScrollView?.contentView else { return 0 }
        let frames = cards().values.map { $0.convert($0.bounds, to: document) }
        guard let top = frames.map(\.minY).min(), let bottom = frames.map(\.maxY).max() else { return 0 }
        return bottom - top
    }

    func scroll(toY y: CGFloat) {
        guard let scrollView = stackScrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        pump()
    }

    static func textViews(in view: NSView) -> [ChecklistTextView] {
        ((view as? ChecklistTextView).map { [$0] } ?? []) + view.subviews.flatMap(textViews)
    }
}

/// Notes of visibly different heights, each with distinct text so a card can
/// be matched back to its note.
func edgeStackSeed(_ count: Int) -> [String] {
    (0..<count).map { i in
        (["Note \(i)"] + (0..<(i % 4 + 1)).map { "line \($0) of note \(i)" }).joined(separator: "\n")
    }
}

func runEdgeStackTests() {
    MainActor.assumeIsolated {
        // MARK: - H6: heights never jump

        suite("an edge card is drawn at its measured height from its first frame") {
            EdgeCardHeights.shared.removeAll()
            let manager = makeManager(seed: edgeStackSeed(6))
            let first = EdgeStackHarness(manager: manager)
            first.pump()
            let measured = manager.notes.indices.map { first.card($0)?.frame.height ?? 0 }
            check(Set(measured).count > 1 && measured.allSatisfy { $0 >= 18 },
                  "every card measured its own content (\(measured))")

            // A rebuilt stack (mode switch, the window coming back) over the
            // same notes, inspected before a single deferred report lands.
            let rebuilt = EdgeStackHarness(manager: manager)
            let firstFrame = manager.notes.indices.map { rebuilt.card($0)?.frame.height ?? 0 }
            equal(firstFrame, measured, "the very first layout already uses each note's measured height")
        }

        suite("a never-measured card starts near its real height, not at a fixed 40pt") {
            EdgeCardHeights.shared.removeAll()
            let tall = (["Title"] + (0..<12).map { "line \($0)" }).joined(separator: "\n")
            let harness = EdgeStackHarness(notes: [tall])
            let initial = harness.card(0)?.frame.height ?? 0
            harness.pump()
            let settled = harness.card(0)?.frame.height ?? 0
            check(settled > 150, "a 13-line note measures well over 150pt (\(settled))")
            check(abs(settled - initial) <= settled * 0.15,
                  "the first frame is within 15% of the settled height (\(initial) vs \(settled))")
        }

        suite("every card exists up front, so scrolling never meets an unmeasured one") {
            EdgeCardHeights.shared.removeAll()
            let harness = EdgeStackHarness(notes: edgeStackSeed(30), height: 500)
            harness.pump()
            equal(harness.cards().count, 30, "all 30 cards are built and measured, not just the visible few")

            let document = harness.contentExtent()
            check(document > 500, "the stack is taller than the viewport, so it scrolls (\(document))")
            harness.scroll(toY: document - 500)
            harness.scroll(toY: 0)
            equal(harness.contentExtent(), document, "scrolling to the bottom and back changes no card's height")
        }

        suite("a card above the viewport changing height leaves the visible cards where they are") {
            EdgeCardHeights.shared.removeAll()
            let harness = EdgeStackHarness(notes: edgeStackSeed(30), height: 500)
            harness.pump()
            // Scroll so card 12 sits at the top of the viewport.
            guard let card12 = harness.card(12), let stack = harness.stackScrollView,
                  let document = stack.documentView else {
                check(false, "the stack hosted")
                return
            }
            let card12Y = card12.convert(card12.bounds, to: document).minY - 12
            harness.scroll(toY: card12Y)
            let before = harness.onScreenFrame(15)?.minY ?? -1
            check(before >= 0 && before < 500, "card 15 is in view (\(before))")

            // Card 3 is well above the viewport; give it six more lines.
            harness.manager.setText(harness.manager.text(at: 3) + "\na\nb\nc\nd\ne\nf", at: 3)
            harness.pump()
            let after = harness.onScreenFrame(15)?.minY ?? -1
            check(abs(after - before) < 1, "card 15 stays put on screen (\(before) -> \(after))")
        }

        // MARK: - H6: one keystroke, one card

        suite("typing in one edge card updates only that card") {
            EdgeCardHeights.shared.removeAll()
            let harness = EdgeStackHarness(notes: edgeStackSeed(12), height: 2000)
            harness.pump()
            guard let editor = harness.card(4)?.documentView as? ChecklistTextView else {
                check(false, "card 4 hosted")
                return
            }
            NoteCardEditor.updateCount = 0
            NoteCardEditor.measureCount = 0
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.insertText("x", replacementRange: editor.selectedRange())
            harness.pump()
            print("         per keystroke: \(NoteCardEditor.updateCount) updateNSView, \(NoteCardEditor.measureCount) measured")
            check(harness.manager.text(at: 4).hasSuffix("x"), "the keystroke reached the note")
            check(NoteCardEditor.updateCount <= 1,
                  "at most the edited card's editor is updated (\(NoteCardEditor.updateCount) of 12)")
            equal(NoteCardEditor.measureCount, 0,
                  "and it is not re-measured from the update: the edit itself already did that")
        }

        suite("a note changed elsewhere still reaches its card, and only its card") {
            EdgeCardHeights.shared.removeAll()
            let harness = EdgeStackHarness(notes: edgeStackSeed(12), height: 2000)
            harness.pump()
            NoteCardEditor.updateCount = 0
            NoteCardEditor.measureCount = 0
            harness.manager.setText("Replaced\nfrom elsewhere", at: 7)
            harness.pump()
            let editor = harness.card(7)?.documentView as? ChecklistTextView
            equal(editor?.string, "Replaced\nfrom elsewhere", "the card shows the new text")
            // Once for the text, once more as its own new height lands.
            check(NoteCardEditor.updateCount <= 2,
                  "only that card's editor is updated (\(NoteCardEditor.updateCount) of 12)")
            equal(NoteCardEditor.measureCount, 1, "and measured once, for the new text")
        }

        suite("a setting every card shows still reaches every card") {
            EdgeCardHeights.shared.removeAll()
            let harness = EdgeStackHarness(notes: edgeStackSeed(5), height: 2000)
            harness.pump()
            let spacing = harness.settings.lineSpacing + 0.3
            harness.settings.lineSpacing = spacing
            harness.pump()
            let applied = harness.cards().values.compactMap { ($0.documentView as? ChecklistTextView)?.lineHeightMultiple }
            equal(applied, Array(repeating: spacing, count: 5), "all five cards take the new line spacing")
        }

        // MARK: - Typography: the note's own font

        suite("an edge card is set in its note's own font, not the app default") {
            EdgeCardHeights.shared.removeAll()
            let manager = makeManager(seed: ["Serif note\nbody", "Default note\nbody"])
            manager.notes[0].fontName = "New York"
            let harness = EdgeStackHarness(manager: manager)
            harness.settings.noteFontName = "SF Mono"
            harness.pump()
            let serif = harness.card(0)?.documentView as? ChecklistTextView
            let plain = harness.card(1)?.documentView as? ChecklistTextView
            equal(serif?.baseFont, NoteFont.resolved("New York", size: serif?.baseFont.pointSize ?? 0),
                  "the New York note's card is in New York")
            equal(plain?.baseFont.isFixedPitch, true, "a note with no font of its own follows the default (SF Mono)")
        }

        suite("an edge card keeps its compact size whatever the note's size") {
            EdgeCardHeights.shared.removeAll()
            let manager = makeManager(seed: ["Big\nnote"])
            manager.notes[0].fontSize = 20
            let harness = EdgeStackHarness(manager: manager)
            harness.pump()
            let editor = harness.card(0)?.documentView as? ChecklistTextView
            equal(editor?.baseFont.pointSize, 12, "capped at the 12pt card body")
        }

        suite("an edge card's title is a bold cut of the note's own font") {
            for name in ["SF Pro", "New York", "SF Mono"] {
                let base = NoteFont.resolved(name, size: 12)
                let view = makeTextView("Groceries\nmilk")
                view.baseFont = base
                view.stylesFirstLineAsTitle = true
                view.applyChecklistStyling()
                let title = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                equal(title?.familyName, base.familyName, "\(name): the title stays in the note's family")
                equal(title?.isFixedPitch, base.isFixedPitch, "\(name): monospaced only if the note is")
                check(NSFontManager.shared.weight(of: title ?? base) > NSFontManager.shared.weight(of: base),
                      "\(name): heavier than the body")
                equal(title?.pointSize, 13, "\(name): a point larger than the body")
            }
        }

        // MARK: - Top edge: fade, don't clip

        suite("the edge stack fades content out under its header instead of clipping it") {
            equal(EdgeStackView.topFadeHeight(increasesContrast: false, reduceTransparency: false), 10,
                  "a short fade, as deep as the stack's top padding, so a card at rest is untouched")
            equal(EdgeStackView.topFadeHeight(increasesContrast: true, reduceTransparency: false), 0,
                  "Increase Contrast: a hard edge, never text fading into the paper")
            equal(EdgeStackView.topFadeHeight(increasesContrast: false, reduceTransparency: true), 0,
                  "Reduce Transparency: a hard edge too")
        }

        suite("the fade is a mask over the stack's scroll view, covering the cards' AppKit views") {
            @MainActor func mask(increasesContrast: Bool) -> (CAGradientLayer?, NSScrollView?) {
                let harness = EdgeStackHarness(notes: edgeStackSeed(8), height: 400)
                harness.settings.increasesContrast = increasesContrast
                harness.pump()
                let scroll = harness.stackScrollView
                return (scroll?.layer?.mask as? CAGradientLayer, scroll)
            }
            let (fade, scroll) = mask(increasesContrast: false)
            check(fade != nil, "the stack's scroll view carries a gradient mask")
            equal(fade?.frame, scroll?.layer?.bounds, "covering the whole viewport")
            let stop = (fade?.locations?[1].doubleValue ?? 0) * Double(scroll?.layer?.bounds.height ?? 0)
            check(abs(stop - 10) < 0.01, "opaque from 10pt down (\(stop))")
            let (none, _) = mask(increasesContrast: true)
            check(none == nil, "and none under Increase Contrast")
        }
    }
}
