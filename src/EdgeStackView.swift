import SwiftUI
import AppKit

/// The edge sidebar: every note as its own card, stacked and scrollable.
///
/// Swipe navigation makes sense when one note fills the window. Docked to an
/// edge there is room to show them all, so the stack replaces the swipe rather
/// than stretching a single note down the whole screen.
struct EdgeStackView: View {
    @ObservedObject var notesManager: NotesManager
    @ObservedObject var settings: SettingsManager
    /// Set by global search to bring a card into view. Every note is already
    /// on screen here, so there's nothing to switch to, just scroll to.
    @Binding var scrollToIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(notesManager.notes.indices), id: \.self) { index in
                            NoteCard(
                                notesManager: notesManager,
                                settings: settings,
                                index: index
                            )
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                .onChange(of: scrollToIndex) { _, target in
                    guard let target else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                    DispatchQueue.main.async { scrollToIndex = nil }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("\(notesManager.notes.count) note\(notesManager.notes.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                notesManager.appendNote()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New note")
        }
        .padding(.horizontal, 16)
        .padding(.top, 30)
        .padding(.bottom, 8)
    }
}

/// One note, in a card sized to its content.
struct NoteCard: View {
    @ObservedObject var notesManager: NotesManager
    @ObservedObject var settings: SettingsManager
    let index: Int

    @State private var height: CGFloat = 40
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NoteCardEditor(
                text: Binding(
                    get: { notesManager.text(at: index) },
                    set: { notesManager.setText($0, at: index) }
                ),
                lineHeightMultiple: settings.lineSpacing,
                listKeyword: settings.effectiveListKeyword,
                onHeightChange: { height = $0 }
            )
            .frame(height: height)
            .padding(12)

            if isHovered {
                Button {
                    notesManager.deleteNote(at: index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Delete this note")
            }
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(settings.appearance.wantsLitEdge ? 0.16 : 0.06), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
    }

    /// Cards sit on the window's own material, so they need their own surface
    /// to read as separate pieces of paper rather than panels of the same glass.
    private var cardBackground: some View {
        Color(nsColor: .controlBackgroundColor)
            .opacity(settings.appearance == .solid ? 1.0 : 0.55)
    }
}

/// A checklist-capable editor that reports the height it needs, so a card can
/// size itself to its note instead of scrolling internally.
struct NoteCardEditor: NSViewRepresentable {
    @Binding var text: String
    var lineHeightMultiple: Double
    var listKeyword: String
    var onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ChecklistTextView {
        let textView = ChecklistTextView()
        textView.delegate = context.coordinator

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false

        textView.baseFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = .zero

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        textView.stylesFirstLineAsTitle = true
        textView.listKeyword = listKeyword
        textView.lineHeightMultiple = lineHeightMultiple
        textView.onHeightChange = onHeightChange
        textView.textStorage?.delegate = textView
        textView.enableImageDrops()
        textView.string = text
        textView.applyChecklistStyling()
        textView.recomputeMathResults()

        return textView
    }

    func updateNSView(_ textView: ChecklistTextView, context: Context) {
        context.coordinator.parent = self
        textView.onHeightChange = onHeightChange

        textView.listKeyword = listKeyword
        if textView.lineHeightMultiple != lineHeightMultiple {
            textView.lineHeightMultiple = lineHeightMultiple
            textView.applyChecklistStyling()
        }
        if textView.string != text {
            textView.string = text
            textView.applyChecklistStyling()
            textView.recomputeMathResults()
            textView.needsDisplay = true
        }
        textView.reportHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteCardEditor
        init(_ parent: NoteCardEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ChecklistTextView else { return }
            parent.text = textView.string
            textView.reportHeight()
        }
    }
}
