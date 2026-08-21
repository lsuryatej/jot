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

/// Plain-text editor backed by `NSTextView`.
///
/// SwiftUI's `TextEditor` exposes neither the caret position nor scroll events,
/// which made per-line checklist toggling and swipe navigation impossible.
struct PlainTextEditor: NSViewRepresentable {
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

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text

        // Plain text, and nothing that rewrites what you typed.
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false

        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)

        // Native in-note search. The Find menu items drive this through the
        // responder chain, giving real match highlighting and next/previous
        // rather than a hand-rolled search bar.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: SwipeScrollView, context: Context) {
        context.coordinator.parent = self
        scrollView.onSwipe = onSwipe

        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Only touch the text view when the model genuinely diverged (note
        // switch, checklist toggle). Assigning unconditionally would fight the
        // user's typing and reset undo on every keystroke.
        if textView.string != text {
            let caret = textView.selectedRange().location
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(caret, length), length: 0))
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
