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

    /// A bare keyword on the first line puts the note in checklist mode.
    var listKeyword: String = "list"

    /// Whether the note was in list mode at the last edit, so the switch can be
    /// noticed and the existing body converted once.
    private var wasListMode = false

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
    func replace(range: NSRange, with replacement: String, selecting selection: NSRange?) {
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

    /// Handles this app's own shortcuts directly.
    ///
    /// The main menu is not displayed outside Dock mode, and relying on it to
    /// dispatch key equivalents there is a bet not worth making. Handling them
    /// here means Cmd+L and Shift-Cmd-V behave the same in every display mode.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()

        if flags == [.command, .shift], key == "v" {
            extractTextFromClipboardImage(nil)
            return true
        }
        // Cmd+V is routed here too. The main menu is not displayed outside Dock
        // mode, and if it is not consulted for key equivalents then the paste
        // override is never reached at all.
        if flags == [.command], key == "v" {
            paste(nil)
            return true
        }
        if flags == [.command], key == "l" {
            toggleChecklist(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleChecklist(_:)) { return true }
        if item.action == #selector(extractTextFromClipboardImage(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - List mode

    var isListMode: Bool {
        Checklist.isListMode(string, keyword: listKeyword)
    }

    /// Converts the body the moment the keyword appears, and only then.
    ///
    /// Done on the transition rather than continuously: converting on every
    /// keystroke would turn a half-typed word into an item under the cursor.
    private func applyListModeIfNeeded() {
        let nowListMode = isListMode
        defer { wasListMode = nowListMode }
        guard nowListMode, !wasListMode else { return }

        let converted = Checklist.convertedToList(string, keyword: listKeyword)
        guard converted != string else { return }

        let caret = selectedRange()
        let whole = NSRange(location: 0, length: (string as NSString).length)
        // Deferred: the text storage is mid-edit when this is called.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let shift = (converted as NSString).length - whole.length
            self.replace(
                range: NSRange(location: 0, length: (self.string as NSString).length),
                with: converted,
                selecting: NSRange(location: max(0, caret.location + max(0, shift)), length: 0)
            )
        }
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

        // In list mode a plain line becomes an item as soon as you leave it,
        // so the whole note stays a list without any markers being typed.
        if isListMode,
           lineRange.location > 0,
           Checklist.item(in: line) == nil,
           !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let indent = Checklist.leadingWhitespace(of: line)
            let converted = Checklist.render(
                indent: indent,
                isChecked: false,
                body: String(line.dropFirst(indent.count))
            )
            // One edit, so one undo step covers both halves.
            let replacement = converted + "\n" + Checklist.emptyItem(indent: indent)
            replace(
                range: lineRange,
                with: replacement,
                selecting: NSRange(
                    location: lineRange.location + (replacement as NSString).length,
                    length: 0
                )
            )
            return
        }

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

    // MARK: - Images in, text out

    /// Accepts an image dropped anywhere in the note and replaces it with the
    /// text Vision reads out of it.
    func enableImageDrops() {
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        TextRecognition.image(from: sender.draggingPasteboard) != nil
            ? .copy
            : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let image = TextRecognition.image(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }

        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        // Option-drop reads the image as text; a plain drop keeps the image.
        if NSEvent.modifierFlags.contains(.option) {
            recognize(image, insertingAt: index)
        } else {
            insertImage(image, at: index)
        }
        return true
    }

    /// Cmd+V inserts an image on the clipboard as an image.
    ///
    /// Text extraction used to live here, but pasting a screenshot to *keep* it
    /// is the more common intent, so OCR moved to its own command.
    override func paste(_ sender: Any?) {
        if TextRecognition.containsImage(.general),
           let image = TextRecognition.image(from: .general) {
            insertImage(image, at: selectedRange().location)
            return
        }
        super.paste(sender)
    }

    /// Shift-Cmd-V: read the clipboard image as text instead of inserting it.
    @objc func extractTextFromClipboardImage(_ sender: Any?) {
        guard let image = TextRecognition.image(from: .general) else {
            NSSound.beep()
            return
        }
        recognize(image, insertingAt: selectedRange().location)
    }

    /// Saves the image beside the notes and drops a markdown reference to it on
    /// its own line. The note stays plain text.
    func insertImage(_ image: NSImage, at index: Int) {
        do {
            let path = try Attachments.save(image)
            let markdown = Attachments.markdown(path: path, width: Attachments.defaultWidth(for: image))
            let ns = string as NSString
            let location = min(index, ns.length)
            let needsLeadingBreak = location > 0 && ns.substring(with: NSRange(location: location - 1, length: 1)) != "\n"
            let insertion = (needsLeadingBreak ? "\n" : "") + markdown + "\n"
            replace(
                range: NSRange(location: location, length: 0),
                with: insertion,
                selecting: NSRange(location: location + (insertion as NSString).length, length: 0)
            )
        } catch {
            NSSound.beep()
            let alert = NSAlert()
            alert.messageText = "Could not save that image"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func recognize(_ image: NSImage, insertingAt index: Int) {
        Task { @MainActor in
            do {
                let recognised = try await TextRecognition.recognizeText(in: image)
                let insertion = recognised.hasSuffix("\n") ? recognised : recognised + "\n"
                let target = NSRange(location: min(index, (self.string as NSString).length), length: 0)
                self.replace(
                    range: target,
                    with: insertion,
                    selecting: NSRange(location: target.location + (insertion as NSString).length, length: 0)
                )
            } catch {
                NSSound.beep()
                NSLog("StickyNotes: text recognition failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Clicking the box

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1, (string as NSString).length > 0 else {
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)

        if let placed = image(at: point) {
            beginResize(placed, from: point)
            return
        }

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

    // MARK: - Caret

    /// Draws the caret on the text's own baseline, at the text's height.
    ///
    /// The line box is as tall as the line-spacing setting makes it, and on an
    /// image line as tall as the image. Centring the caret in that box was not
    /// enough: extra leading is not distributed evenly, so the caret floated
    /// above the glyphs like a superscript. Anchoring to the real baseline from
    /// the layout manager puts it where the text actually sits.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: caretRect(from: rect), color: color, turnedOn: flag)
    }

    private func caretRect(from rect: NSRect) -> NSRect {
        let ascender = ceil(baseFont.ascender)
        let textHeight = ceil(baseFont.ascender - baseFont.descender)
        guard rect.height > textHeight + 0.5 else { return rect }

        var caret = rect
        caret.size.height = textHeight

        guard let layoutManager,
              let textStorage,
              textStorage.length > 0
        else {
            // Empty note: nothing has been laid out, so sit on the bottom of
            // the box, which is where the first glyph will land.
            caret.origin.y = rect.maxY - textHeight
            return caret
        }

        let characterIndex = min(max(0, selectedRange().location), textStorage.length - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let baseline = fragment.minY
            + layoutManager.location(forGlyphAt: glyphIndex).y
            + textContainerInset.height

        caret.origin.y = baseline - ascender
        return caret
    }

    // MARK: - Inline images

    /// Width being previewed during a resize drag, so the text is rewritten
    /// once on mouse-up rather than on every frame of the drag.
    private var resizingRange: NSRange?
    private var previewWidth: CGFloat?

    private struct PlacedImage {
        let image: NSImage
        let markdownRange: NSRange
        let rect: NSRect
    }

    /// Where each image reference lands on screen, derived fresh from layout.
    private func placedImages() -> [PlacedImage] {
        guard let layoutManager, let textContainer, let textStorage else { return [] }
        let ns = textStorage.string as NSString
        var placed: [PlacedImage] = []

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { line, lineRange, _, _ in
            guard let line else { return }
            for reference in Attachments.references(in: line) {
                guard let image = Attachments.image(at: reference.path) else { continue }

                let markdownRange = NSRange(
                    location: lineRange.location + reference.range.location,
                    length: reference.range.length
                )
                let glyphRange = layoutManager.glyphRange(forCharacterRange: markdownRange, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rect.origin.x += self.textContainerInset.width
                rect.origin.y += self.textContainerInset.height

                let width = self.displayWidth(for: reference, image: image, markdownRange: markdownRange)
                let height = width * (image.size.height / max(1, image.size.width))
                placed.append(
                    PlacedImage(
                        image: image,
                        markdownRange: markdownRange,
                        rect: NSRect(x: rect.minX, y: rect.minY, width: width, height: height)
                    )
                )
            }
        }
        return placed
    }

    private func displayWidth(for reference: ImageReference, image: NSImage, markdownRange: NSRange) -> CGFloat {
        if let previewWidth, resizingRange == markdownRange { return previewWidth }
        return reference.width ?? Attachments.defaultWidth(for: image)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for placed in placedImages() where placed.rect.intersects(dirtyRect) {
            placed.image.draw(
                in: placed.rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
        }
    }

    /// Returns the image under `point`, if any.
    private func image(at point: NSPoint) -> PlacedImage? {
        placedImages().first { $0.rect.contains(point) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for placed in placedImages() {
            addCursorRect(placed.rect, cursor: .resizeLeftRight)
        }
    }

    /// Drag an image left or right to resize it. The width lives in the text,
    /// so the result is still something you could have typed by hand.
    private func beginResize(_ placed: PlacedImage, from startPoint: NSPoint) {
        let startWidth = placed.rect.width
        resizingRange = placed.markdownRange
        previewWidth = startWidth

        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .default) { event, stop in
            guard let event else {
                stop.pointee = true
                return
            }
            let point = self.convert(event.locationInWindow, from: nil)

            if event.type == .leftMouseDragged {
                self.previewWidth = max(48, startWidth + (point.x - startPoint.x))
                self.needsDisplay = true
                return
            }

            stop.pointee = true
            defer {
                self.resizingRange = nil
                self.previewWidth = nil
            }
            guard let finalWidth = self.previewWidth, abs(finalWidth - startWidth) > 1 else { return }

            let ns = self.string as NSString
            let markdown = ns.substring(with: placed.markdownRange)
            guard let rewritten = Attachments.settingWidth(
                finalWidth,
                on: markdown,
                at: NSRange(location: 0, length: (markdown as NSString).length)
            ) else { return }

            self.replace(range: placed.markdownRange, with: rewritten, selecting: nil)
        }
    }

    // MARK: - Styling

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !isStyling, editedMask.contains(.editedCharacters) else { return }
        applyListModeIfNeeded()
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

        if Checklist.isListMode(ns as String, keyword: listKeyword), ns.length > 0 {
            let firstLine = ns.lineRange(for: NSRange(location: 0, length: 0))
            let marker = NSIntersectionRange(firstLine, target)
            if marker.length > 0 {
                textStorage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: marker)
            }
        }

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
            guard let line else { return }

            // An image line is given the height of its image, and the markdown
            // that produced it is painted out. The characters are still there:
            // select the line and you can edit or delete it as text.
            let references = Attachments.references(in: line)
            if !references.isEmpty {
                var tallest: CGFloat = 0
                for reference in references {
                    guard let image = Attachments.image(at: reference.path) else { continue }
                    let width = reference.width ?? Attachments.defaultWidth(for: image)
                    tallest = max(tallest, width * (image.size.height / max(1, image.size.width)))

                    textStorage.addAttribute(
                        .foregroundColor,
                        value: NSColor.clear,
                        range: NSRange(
                            location: lineRange.location + reference.range.location,
                            length: reference.range.length
                        )
                    )
                }
                if tallest > 0 {
                    let style = NSMutableParagraphStyle()
                    style.minimumLineHeight = tallest + 6
                    style.maximumLineHeight = tallest + 6
                    textStorage.addAttribute(.paragraphStyle, value: style, range: lineRange)
                }
            }

            guard let item = Checklist.item(in: line) else { return }

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
    var listKeyword: String = "list"
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
        textView.listKeyword = listKeyword
        textView.textStorage?.delegate = textView
        textView.enableImageDrops()
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

        if textView.listKeyword != listKeyword {
            textView.listKeyword = listKeyword
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
