import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    /// The note a drag is carrying, by identity. Drop events resolve it back
    /// to an index at the moment they fire, because live reordering shifts
    /// every index after the first swap.
    @State private var draggingNoteID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        // Keyed by note identity, not position: a card's
                        // measured height and hover state belong to its note,
                        // so they must travel with it through a reorder
                        // instead of staying with the slot it used to sit in.
                        ForEach(Array(notesManager.notes.enumerated()), id: \.element.id) { index, note in
                            NoteCard(
                                notesManager: notesManager,
                                settings: settings,
                                index: index,
                                noteID: note.id,
                                baseFont: NoteFont.resolved(
                                    settings.effectiveNoteFontName,
                                    // Cards stay compact previews: the chosen
                                    // family, but never larger than the old
                                    // fixed 12pt body no matter the size setting.
                                    size: min(12, settings.effectiveFontSize)
                                ),
                                draggingNoteID: $draggingNoteID
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                .onChange(of: scrollToIndex) { _, target in
                    guard let target, notesManager.notes.indices.contains(target) else { return }
                    // Rows are keyed by note identity, so that is what
                    // scrollTo has to be handed.
                    withAnimation { proxy.scrollTo(notesManager.notes[target].id, anchor: .top) }
                    DispatchQueue.main.async { scrollToIndex = nil }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("\(notesManager.notes.count) note\(notesManager.notes.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color(nsColor: settings.effectiveInk.secondary))

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
    /// This card's note by identity — what drag and drop resolve through,
    /// since `index` shifts underneath a live reorder.
    let noteID: UUID
    let baseFont: NSFont
    @Binding var draggingNoteID: UUID?

    @State private var height: CGFloat = 40
    @State private var isHovered = false

    /// Whether this card is the one a drag is carrying right now.
    private var isCarried: Bool { draggingNoteID == noteID }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NoteCardEditor(
                text: Binding(
                    get: { notesManager.text(at: index) },
                    set: { notesManager.setText($0, at: index) }
                ),
                lineHeightMultiple: settings.effectiveLineSpacing,
                baseFont: settings.effectiveEditorFont,
                listKeyword: settings.effectiveListKeyword,
                codeKeyword: settings.effectiveCodeKeyword,
                ink: settings.effectiveInk,
                onHeightChange: { height = $0 }
            )
            .frame(height: height)
            .padding(12)

            if isHovered {
                Button {
                    notesManager.deleteNote(at: index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: settings.effectiveInk.secondary).opacity(0.9))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(7)
                .help("Delete this note")
                .transition(.opacity)
            }
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color(nsColor: settings.effectiveHairlineColor)
                        .opacity(settings.effectiveWantsLitEdge ? 0.16 : (isHovered ? 0.16 : 0.10)),
                    lineWidth: 1
                )
        )
        .overlay(alignment: .topLeading) { reorderGrip }
        // A hovered card lifts a little off the stack; a carried one dims so
        // the eye keeps track of what is being moved while the others part.
        .shadow(color: .black.opacity(isHovered && !isCarried ? 0.10 : 0), radius: 7, y: 2)
        .scaleEffect(isCarried ? 0.985 : 1)
        .opacity(isCarried ? 0.45 : 1)
        .onDrop(of: [.text], delegate: NoteCardDropDelegate(
            noteID: noteID,
            notesManager: notesManager,
            draggingNoteID: $draggingNoteID
        ))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .animation(.easeOut(duration: 0.15), value: isCarried)
    }

    /// The grip a drag starts from.
    ///
    /// The card's whole body is an NSTextView that claims every mouse event
    /// for caret placement and selection, so a drag needs a corner of its own
    /// to start from — the presentation-side twin of `handleSpecialClick` on
    /// the other side of that view.
    @ViewBuilder
    private var reorderGrip: some View {
        if isHovered {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: settings.effectiveInk.secondary).opacity(0.9))
                .padding(7)
                .contentShape(Rectangle())
                .onDrag {
                    withAnimation(.easeOut(duration: 0.15)) { draggingNoteID = noteID }
                    return NSItemProvider(object: noteID.uuidString as NSString)
                }
                .help("Drag to reorder")
                .transition(.opacity)
        }
    }

    /// Cards sit on the window's own material, so they need their own surface
    /// to read as separate pieces of paper rather than panels of the same glass.
    private var cardBackground: some View {
        Color(nsColor: settings.effectiveCardColor)
            .opacity(settings.effectiveWantsOpaqueCards ? 1.0 : 0.55)
    }
}

/// Live-reorders while a carried card passes over this one: the stack parts
/// around the drag as it goes, and dropping commits whatever position the
/// user already sees.
///
/// Both ends resolve through identity at event time. A fixed index cannot be
/// captured when the delegate is built: the first swap shifts every position,
/// so the second swap would land on the wrong cards.
private struct NoteCardDropDelegate: DropDelegate {
    let noteID: UUID
    let notesManager: NotesManager
    @Binding var draggingNoteID: UUID?

    func dropEntered(info: DropInfo) {
        guard let carriedID = draggingNoteID, carriedID != noteID,
              let from = notesManager.notes.firstIndex(where: { $0.id == carriedID }),
              let to = notesManager.notes.firstIndex(where: { $0.id == noteID })
        else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            notesManager.moveNote(from: from, to: to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: [.text]).isEmpty
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingNoteID = nil
        return true
    }

    // dropExited deliberately does nothing. During a live reorder the drag
    // exits and re-enters cards constantly as they slide out from under it;
    // clearing the carried id there would strand the very next dropEntered.
    // A drag abandoned outside any card leaves a stale value behind, which is
    // harmless — onDrag overwrites it before any delegate can read it again.
}

/// A checklist-capable editor that reports the height it needs, so a card can
/// size itself to its note instead of scrolling internally.
struct NoteCardEditor: NSViewRepresentable {
    @Binding var text: String
    var lineHeightMultiple: Double
    var baseFont: NSFont
    var listKeyword: String
    var codeKeyword: String
    var ink: InkTheme
    var onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ChecklistTextView {
        let textView = ChecklistTextView()
        textView.delegate = context.coordinator

        textView.isRichText = false
        // See the matching comment in PlainTextEditor.swift: `isRichText`
        // alone doesn't hide the contextual menu's "Font ▸ Show Fonts…",
        // and any font it picked would be overwritten by the next restyle
        // pass regardless.
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false

        textView.baseFont = baseFont
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
        textView.codeKeyword = codeKeyword
        // Repaints text and caret itself, superseding the labelColor above.
        textView.ink = ink
        textView.lineHeightMultiple = lineHeightMultiple
        textView.onHeightChange = onHeightChange
        textView.textStorage?.delegate = textView
        textView.enableImageDrops()
        textView.string = text
        textView.applyChecklistStyling()
        textView.recomputeMathResults()
        textView.recomputeLinkMatches()
        textView.applyLinkFolding()

        return textView
    }

    func updateNSView(_ textView: ChecklistTextView, context: Context) {
        context.coordinator.parent = self
        textView.onHeightChange = onHeightChange

        textView.listKeyword = listKeyword
        textView.codeKeyword = codeKeyword
        if textView.lineHeightMultiple != lineHeightMultiple {
            textView.lineHeightMultiple = lineHeightMultiple
            textView.applyChecklistStyling()
        }
        if textView.baseFont != baseFont {
            textView.baseFont = baseFont
        }
        if textView.ink != ink {
            textView.ink = ink
        }
        if textView.string != text {
            textView.string = text
            // Same reason as the matching block in PlainTextEditor.updateNSView:
            // the actions on the stack were recorded against the ranges of the
            // note being swapped out, so leaving them in place lets the next
            // Cmd+Z edit a note that was never edited, or run off the end of a
            // shorter one and throw NSRangeException. The history ends where
            // the note does.
            textView.undoManager?.removeAllActions()
            textView.applyChecklistStyling()
            textView.recomputeMathResults()
            textView.recomputeLinkMatches()
            textView.applyLinkFolding()
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
