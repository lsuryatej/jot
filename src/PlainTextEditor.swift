import SwiftUI
import AppKit

enum SwipeDirection {
    case left
    case right
}

/// Scroll view that turns a horizontal two-finger swipe into a note-navigation
/// event instead of a horizontal scroll.
///
/// SwiftUI's `DragGesture` cannot do this: trackpad swipes arrive as
/// scroll-wheel events, which `DragGesture` never receives, and the text view
/// swallows real drags for text selection.
final class SwipeScrollView: NSScrollView {
    var onSwipe: ((SwipeDirection) -> Void)?

    private static let threshold: CGFloat = 55
    private var accumulatedX: CGFloat = 0
    private var didFireForGesture = false

    override func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.began) {
            accumulatedX = 0
            didFireForGesture = false
        }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        // Vertical intent belongs to the text view.
        guard abs(dx) > abs(dy) else {
            super.scrollWheel(with: event)
            return
        }

        accumulatedX += dx
        if !didFireForGesture && abs(accumulatedX) >= Self.threshold {
            didFireForGesture = true
            // Natural scrolling: fingers moving right (positive dx) means
            // "go back", matching the direction pages move under your fingers.
            onSwipe?(accumulatedX > 0 ? .right : .left)
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            accumulatedX = 0
            didFireForGesture = false
        }

        // Consumed: never scroll the text view sideways.
    }
}

/// Text view with checklist behaviour.
///
/// The text stays plain markdown on disk. Everything here is presentation and
/// interaction: the file never holds anything you could not read in `cat`.
final class ChecklistTextView: NSTextView, NSTextStorageDelegate {
    /// Guards the styling pass against re-entering itself through the text
    /// storage delegate.
    private var isStyling = false

    var lineHeightMultiple: Double = 1.0 {
        didSet { defaultParagraphStyle = paragraphStyle }
    }

    /// Renders the first line larger and bolder, so a note reads as a titled
    /// card without the title being a separate field. The text stays plain.
    var stylesFirstLineAsTitle = false

    /// The authoritative body font.
    ///
    /// Never read this back from `NSTextView.font`: that property reports the
    /// font of the *first character*, which the title styling has already made
    /// bold and a point larger. Deriving the base font from it fed the styling
    /// pass its own output, so every restyle promoted the whole note another
    /// point — the text grew a little each time an item was toggled.
    var baseFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet {
            font = baseFont
            applyChecklistStyling()
        }
    }

    private var titleFont: NSFont {
        .monospacedSystemFont(ofSize: baseFont.pointSize + 1, weight: .semibold)
    }

    /// Reports the height the content needs, for cards that size to their note.
    var onHeightChange: ((CGFloat) -> Void)?

    /// Without an enclosing scroll view the text container never learns how
    /// wide it is, so lines run past the card and get clipped instead of
    /// wrapping — and the measured height comes back short to match.
    override func layout() {
        super.layout()
        guard onHeightChange != nil, let textContainer else { return }
        let width = bounds.width - textContainerInset.width * 2
        if abs(textContainer.size.width - width) > 0.5 {
            textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        reportHeight()
    }

    /// Measured through TextKit 1. Touching `layoutManager` opts this view out
    /// of TextKit 2, which is a fair trade for a reliable content height —
    /// nothing here depends on TextKit 2 behaviour.
    func reportHeight() {
        guard let onHeightChange, let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let height = max(18, used + textContainerInset.height * 2)
        if abs(height - lastReportedHeight) > 0.5 {
            lastReportedHeight = height
            DispatchQueue.main.async { onHeightChange(height) }
        }
    }

    private var lastReportedHeight: CGFloat = -1

    private var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = CGFloat(lineHeightMultiple)
        return style
    }

    // MARK: - Editing helpers

    /// Routes every mutation through the undo-aware path, so Cmd+Z still walks
    /// back through checklist edits.
    private func replace(range: NSRange, with replacement: String, selecting selection: NSRange?) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        if let selection {
            setSelectedRange(clamped(selection))
        }
    }

    private func clamped(_ range: NSRange) -> NSRange {
        let length = (string as NSString).length
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    /// The line under `location`, without its trailing newline.
    private func contentRange(forLineAt location: Int) -> NSRange {
        let ns = string as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let full = ns.lineRange(for: NSRange(location: min(location, ns.length - 1), length: 0))
        let hasNewline = full.length > 0 && ns.substring(with: full).hasSuffix("\n")
        return NSRange(location: full.location, length: full.length - (hasNewline ? 1 : 0))
    }

    // MARK: - Toggle

    @objc func toggleChecklist(_ sender: Any?) {
        let ns = string as NSString
        let selection = selectedRange()
        let lineRange = ns.length == 0
            ? NSRange(location: 0, length: 0)
            : ns.lineRange(for: selection)

        let block = ns.substring(with: lineRange)
        let updated = Checklist.toggled(block: block)
        guard updated != block else { return }

        let delta = (updated as NSString).length - (block as NSString).length
        let newSelection = selection.length > 0
            ? NSRange(location: lineRange.location, length: (updated as NSString).length)
            : NSRange(location: selection.location + delta, length: 0)

        replace(range: lineRange, with: updated, selecting: newSelection)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleChecklist(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - Return

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0, (string as NSString).length > 0 else {
            super.insertNewline(sender)
            return
        }

        let lineRange = contentRange(forLineAt: selection.location)
        let line = (string as NSString).substring(with: lineRange)

        guard let outcome = Checklist.newline(inLine: line) else {
            super.insertNewline(sender)
            return
        }

        switch outcome {
        case .exitList(let replacement):
            replace(
                range: lineRange,
                with: replacement,
                selecting: NSRange(location: lineRange.location + (replacement as NSString).length, length: 0)
            )

        case .continueList(let insertion):
            // Splitting mid-item and guessing what the remainder should become
            // is worse than just inserting a plain newline there.
            guard selection.location == lineRange.location + lineRange.length else {
                super.insertNewline(sender)
                return
            }
            replace(
                range: selection,
                with: insertion,
                selecting: NSRange(location: selection.location + (insertion as NSString).length, length: 0)
            )
        }
    }

    // MARK: - Nesting

    override func insertTab(_ sender: Any?) {
        if !indentSelection(by: 1) { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if !indentSelection(by: -1) { super.insertBacktab(sender) }
    }

    private func indentSelection(by levels: Int) -> Bool {
        let ns = string as NSString
        guard ns.length > 0 else { return false }

        let selection = selectedRange()
        let lineRange = ns.lineRange(for: selection)
        let block = ns.substring(with: lineRange)
        guard let updated = Checklist.indented(block: block, by: levels) else { return false }

        let unit = (Checklist.indentUnit as NSString).length
        let newSelection = selection.length > 0
            ? NSRange(location: lineRange.location, length: (updated as NSString).length)
            : NSRange(location: max(lineRange.location, selection.location + (levels > 0 ? unit : -unit)), length: 0)

        replace(range: lineRange, with: updated, selecting: newSelection)
        return true
    }

    // MARK: - Clicking the box

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1, (string as NSString).length > 0 else {
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let lineRange = contentRange(forLineAt: index)
        let line = (string as NSString).substring(with: lineRange)

        guard let item = Checklist.item(in: line) else {
            super.mouseDown(with: event)
            return
        }

        let markerStart = lineRange.location + item.markerRange.location
        let markerEnd = markerStart + item.markerRange.length
        guard index >= markerStart, index <= markerEnd else {
            super.mouseDown(with: event)
            return
        }

        let updated = Checklist.toggled(block: line)
        replace(range: lineRange, with: updated, selecting: selectedRange())
    }

    // MARK: - Styling

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !isStyling, editedMask.contains(.editedCharacters) else { return }
        // Title styling spans the first line, which an edit anywhere can change
        // the extent of, so restyle the whole note when that mode is on.
        applyChecklistStyling(in: stylesFirstLineAsTitle ? nil : editedRange)
    }

    /// Restyles the lines touching `range`, or the whole note when nil.
    ///
    /// Attribute-only changes are safe to make from didProcessEditing, which is
    /// why this never adds or removes characters.
    func applyChecklistStyling(in range: NSRange? = nil) {
        guard let textStorage, !isStyling else { return }
        isStyling = true
        defer { isStyling = false }

        let ns = textStorage.string as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let target = ns.length == 0 ? whole : ns.lineRange(for: clamped(range ?? whole))

        textStorage.setAttributes(
            [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle,
            ],
            range: target
        )

        if stylesFirstLineAsTitle, ns.length > 0 {
            let firstLine = ns.lineRange(for: NSRange(location: 0, length: 0))
            let titleRange = NSIntersectionRange(firstLine, target)
            if titleRange.length > 0 {
                textStorage.addAttribute(
                    .font,
                    value: titleFont,
                    range: titleRange
                )
            }
        }

        ns.enumerateSubstrings(in: target, options: [.byLines]) { line, lineRange, _, _ in
            guard let line, let item = Checklist.item(in: line) else { return }

            let markerRange = NSRange(
                location: lineRange.location + item.markerRange.location,
                length: item.markerRange.length
            )
            textStorage.addAttribute(
                .foregroundColor,
                value: item.isChecked ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor,
                range: markerRange
            )

            guard item.isChecked else { return }
            let bodyStart = markerRange.location + markerRange.length
            let bodyLength = lineRange.location + lineRange.length - bodyStart
            guard bodyLength > 0 else { return }

            textStorage.addAttributes(
                [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor.tertiaryLabelColor,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ],
                range: NSRange(location: bodyStart, length: bodyLength)
            )
        }
    }
}

/// Plain-text editor backed by `NSTextView`.
///
/// SwiftUI's `TextEditor` exposes neither the caret position nor scroll events,
/// which made per-line checklist toggling and swipe navigation impossible.
struct PlainTextEditor: NSViewRepresentable {
    var lineHeightMultiple: Double = 1.0
    /// Extra room at the top when the header bar is hidden, so the first line
    /// clears the traffic lights instead of tucking under them.
    var topInset: CGFloat = 12
    @Binding var text: String
    @Binding var selectedRange: NSRange
    var onSwipe: (SwipeDirection) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> SwipeScrollView {
        let scrollView = SwipeScrollView()
        scrollView.onSwipe = onSwipe
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = ChecklistTextView()
        textView.delegate = context.coordinator

        // Plain text, and nothing that rewrites what you typed.
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false

        textView.baseFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: topInset)

        // Native in-note search. The Find menu items drive this through the
        // responder chain, giving real match highlighting and next/previous
        // rather than a hand-rolled search bar.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        textView.lineHeightMultiple = lineHeightMultiple
        textView.textStorage?.delegate = textView
        textView.string = text
        textView.applyChecklistStyling()

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: SwipeScrollView, context: Context) {
        context.coordinator.parent = self
        scrollView.onSwipe = onSwipe

        guard let textView = scrollView.documentView as? ChecklistTextView else { return }

        if textView.textContainerInset.height != topInset {
            textView.textContainerInset = NSSize(width: 20, height: topInset)
        }

        if textView.lineHeightMultiple != lineHeightMultiple {
            textView.lineHeightMultiple = lineHeightMultiple
            textView.applyChecklistStyling()
        }

        // Only touch the text view when the model genuinely diverged (note
        // switch). Assigning unconditionally would fight the user's typing and
        // reset undo on every keystroke.
        if textView.string != text {
            let caret = textView.selectedRange().location
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(caret, length), length: 0))
            textView.applyChecklistStyling()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor

        init(_ parent: PlainTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.selectedRange = textView.selectedRange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.selectedRange = textView.selectedRange()
        }
    }
}
