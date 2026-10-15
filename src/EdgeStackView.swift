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
    /// Holds the visible cards still while one above them changes height.
    @State private var scrollAnchor = EdgeScrollAnchor()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    // Eager, not lazy. A lazy stack only learns a card's
                    // height when the card scrolls into view, so every card
                    // met for the first time on the way back up resized under
                    // the pointer and shoved the stack (design review H6).
                    // Built up front, every card is measured before the panel
                    // slides in and nothing is left to resize mid-scroll. A
                    // note stack is tens of cards, not thousands, and each one
                    // only re-renders when its own note changes (see
                    // `NoteCard`), so holding them all costs little.
                    VStack(spacing: 10) {
                        // Keyed by note identity, not position: a card's
                        // measured height and hover state belong to its note,
                        // so they must travel with it through a reorder
                        // instead of staying with the slot it used to sit in.
                        //
                        // Each card is handed only its own note and the
                        // resolved look every card shares, and is compared
                        // by those values (`.equatable()`): a keystroke
                        // republishes `notes`, and only the card whose note
                        // changed then re-renders and touches its editor.
                        let style = EdgeCardStyle(settings: settings)
                        let count = notesManager.notes.count
                        ForEach(Array(notesManager.notes.enumerated()), id: \.element.id) { index, note in
                            NoteCard(
                                notesManager: notesManager,
                                note: note,
                                index: index,
                                count: count,
                                style: style,
                                baseFont: EdgeCardStyle.font(for: note, settings: settings),
                                isCarried: draggingNoteID == note.id,
                                draggingNoteID: $draggingNoteID,
                                scrollAnchor: scrollAnchor
                            )
                            .equatable()
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(EdgeScrollAnchorProbe(
                        anchor: scrollAnchor,
                        // Cards scrolling up under the header fade out over
                        // the stack's top padding rather than being sliced
                        // off at a hard line. A card at rest sits below the
                        // fade, untouched.
                        topFade: Self.topFadeHeight(
                            increasesContrast: settings.increasesContrast,
                            reduceTransparency: reduceTransparency
                        )
                    ))
                }
                .onChange(of: scrollToIndex) { _, target in
                    guard let target, notesManager.notes.indices.contains(target) else { return }
                    // Rows are keyed by note identity, so that is what
                    // scrollTo has to be handed.
                    // Under Reduce Motion the jump happens in one step: a long
                    // animated scroll is motion the user didn't drive.
                    withAnimation(MotionPolicy.movement(.default, reduceMotion: reduceMotion)) {
                        proxy.scrollTo(notesManager.notes[target].id, anchor: .top)
                    }
                    DispatchQueue.main.async { scrollToIndex = nil }
                }
            }
        }
    }

    /// How deep the scroll-edge fade is: the stack's top padding, or none
    /// when the user has asked for contrast or less transparency, where
    /// text dissolving into the paper is the opposite of what they want.
    static func topFadeHeight(increasesContrast: Bool, reduceTransparency: Bool) -> CGFloat {
        increasesContrast || reduceTransparency ? 0 : 10
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
            .accessibilityLabel("New note")
        }
        .padding(.horizontal, 16)
        .padding(.top, 30)
        .padding(.bottom, 8)
    }
}

/// Everything about a card's look that comes from settings rather than from
/// its note, resolved once per stack render instead of read by every card
/// observing `SettingsManager` (which re-rendered all of them on any change).
struct EdgeCardStyle: Equatable {
    var lineHeightMultiple: Double
    var listKeyword: String
    var codeKeyword: String
    var ink: InkTheme
    var cardColor: NSColor
    var opaqueCards: Bool
    var hairlineColor: NSColor
    var restingHairlineOpacity: Double
    var hoveredHairlineOpacity: Double
    var highlightsCurrentLine: Bool

    @MainActor
    init(settings: SettingsManager) {
        lineHeightMultiple = settings.effectiveLineSpacing
        listKeyword = settings.effectiveListKeyword
        codeKeyword = settings.effectiveCodeKeyword
        ink = settings.effectiveInk
        cardColor = settings.effectiveCardColor
        opaqueCards = settings.effectiveWantsOpaqueCards
        hairlineColor = settings.effectiveHairlineColor
        restingHairlineOpacity = settings.hairlineOpacity(settings.effectiveWantsLitEdge ? 0.16 : 0.10)
        hoveredHairlineOpacity = settings.hairlineOpacity(0.16)
        highlightsCurrentLine = settings.highlightsCurrentLine
    }

    /// A card's body font: the note's own family when it has one (a theme
    /// note still wins, as everywhere), at the global text size. Not capped
    /// smaller: cards have always drawn at the size people chose, and
    /// shrinking them would undo a deliberate choice for legibility. Not the
    /// note's own size either: in this mode Bigger and Smaller change the
    /// global size, and every card has to follow them together.
    @MainActor
    static func font(for note: Note, settings: SettingsManager) -> NSFont {
        NoteFont.resolved(
            settings.resolvedFontName(perNote: note.fontName),
            size: CGFloat(settings.resolvedFontSize(perNote: nil))
        )
    }
}

/// One note, in a card sized to its content.
///
/// Deliberately not observing `NotesManager` or `SettingsManager`: it is
/// handed its own note and the shared style as values and compared on them,
/// so editing one note leaves every other card alone. `notesManager` is
/// only here for the actions a card performs.
struct NoteCard: View, Equatable {
    let notesManager: NotesManager
    let note: Note
    let index: Int
    /// How many notes there are, for "Note 3 of 7".
    let count: Int
    let style: EdgeCardStyle
    let baseFont: NSFont
    /// Whether this card is the one a drag is carrying right now.
    let isCarried: Bool
    @Binding var draggingNoteID: UUID?
    let scrollAnchor: EdgeScrollAnchor

    /// This card's note by identity — what drag and drop resolve through,
    /// since `index` shifts underneath a live reorder.
    private var noteID: UUID { note.id }

    nonisolated static func == (lhs: NoteCard, rhs: NoteCard) -> Bool {
        lhs.note == rhs.note && lhs.index == rhs.index && lhs.count == rhs.count
            && lhs.style == rhs.style && lhs.baseFont == rhs.baseFont
            && lhs.isCarried == rhs.isCarried
    }

    /// The height the note's content actually needs — kept current
    /// regardless of whether a fixed height is in effect, so a fresh drag
    /// has a real starting point and double-clicking the handle has a real
    /// value to reset to.
    @State private var contentHeight: CGFloat
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The height a resize drag started from. Nil outside an active drag.
    @State private var dragStartHeight: CGFloat?

    // Main actor explicitly: it reads the main-actor height cache. Newer
    // SDKs make every View main-actor isolated, so this compiled locally;
    // the release machine's older SDK does not, and the build failed there.
    @MainActor
    init(
        notesManager: NotesManager,
        note: Note,
        index: Int,
        count: Int,
        style: EdgeCardStyle,
        baseFont: NSFont,
        isCarried: Bool,
        draggingNoteID: Binding<UUID?>,
        scrollAnchor: EdgeScrollAnchor
    ) {
        self.notesManager = notesManager
        self.note = note
        self.index = index
        self.count = count
        self.style = style
        self.baseFont = baseFont
        self.isCarried = isCarried
        self._draggingNoteID = draggingNoteID
        self.scrollAnchor = scrollAnchor
        // The first frame is drawn at whatever this says, before the editor
        // has measured anything. This session's earlier measurement when
        // there is one, otherwise a line-count estimate: either is far
        // closer than a fixed placeholder, which every card then grew out
        // of in view.
        self._contentHeight = State(initialValue: EdgeCardHeights.shared.height(for: note.id)
            ?? EdgeCardHeights.estimate(
                text: note.text,
                font: baseFont,
                lineHeightMultiple: style.lineHeightMultiple
            ))
    }

    /// Nil means "size to content" — this card's own persisted override, if
    /// the resize handle has ever been dragged.
    private var fixedHeight: Double? { note.cardHeight }

    /// What actually gets asked of the editor's frame: the persisted fixed
    /// height if there is one, otherwise the content's own natural height.
    private var displayedHeight: CGFloat { fixedHeight.map { CGFloat($0) } ?? contentHeight }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NoteCardEditor(
                noteID: noteID,
                text: note.text,
                onTextChange: { [notesManager, index] in notesManager.setText($0, at: index) },
                lineHeightMultiple: style.lineHeightMultiple,
                baseFont: baseFont,
                listKeyword: style.listKeyword,
                codeKeyword: style.codeKeyword,
                ink: style.ink,
                highlightsCurrentLine: style.highlightsCurrentLine,
                onHeightChange: { height, editor in
                    let before = displayedHeight
                    let after = fixedHeight.map { CGFloat($0) } ?? height
                    contentHeight = height
                    EdgeCardHeights.shared.record(height, for: noteID)
                    scrollAnchor.cardWillResize(editor, by: after - before)
                }
            )
            .frame(height: displayedHeight)
            .padding(12)

            if isHovered {
                Button {
                    notesManager.deleteNote(at: index)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: style.ink.secondary).opacity(0.9))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(7)
                .help("Delete this note")
                .accessibilityLabel("Delete note")
                .transition(.opacity)
            }
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color(nsColor: style.hairlineColor)
                        .opacity(isHovered ? style.hoveredHairlineOpacity : style.restingHairlineOpacity),
                    lineWidth: 1
                )
        )
        .overlay(alignment: .topLeading) { reorderGrip }
        .overlay(alignment: .bottom) { resizeHandle }
        // A hovered card lifts a little off the stack; a carried one dims so
        // the eye keeps track of what is being moved while the others part.
        .shadow(color: .black.opacity(isHovered && !isCarried ? 0.10 : 0), radius: 7, y: 2)
        .scaleEffect(isCarried ? MotionPolicy.carriedCardScale(reduceMotion: reduceMotion) : 1)
        .opacity(isCarried ? 0.45 : 1)
        .onDrop(of: [.text], delegate: NoteCardDropDelegate(
            noteID: noteID,
            notesManager: notesManager,
            draggingNoteID: $draggingNoteID,
            reduceMotion: reduceMotion
        ))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        // The delete button, grip and resize handle only exist under the
        // pointer, which VoiceOver never moves. The same actions live on the
        // card itself so they are reachable from the Actions menu (VO-Cmd-Space).
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note \(index + 1) of \(count)")
        .accessibilityAction(named: "Delete note") { notesManager.deleteNote(at: index) }
        .accessibilityAction(named: "Move up") {
            guard index > 0 else { return }
            notesManager.moveNote(from: index, to: index - 1)
        }
        .accessibilityAction(named: "Move down") {
            guard index < count - 1 else { return }
            notesManager.moveNote(from: index, to: index + 2)
        }
        .accessibilityAction(named: "Fit height to content") { notesManager.setCardHeight(nil, at: index) }
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
                .foregroundStyle(Color(nsColor: style.ink.secondary).opacity(0.9))
                .padding(7)
                .contentShape(Rectangle())
                .onDrag {
                    withAnimation(.easeOut(duration: 0.15)) { draggingNoteID = noteID }
                    return NSItemProvider(object: noteID.uuidString as NSString)
                }
                .help("Drag to reorder")
                .accessibilityLabel("Reorder note")
                .accessibilityHint("Drag to move this note in the stack")
                .transition(.opacity)
        }
    }

    /// A thin strip along the bottom edge: drag to give this card a fixed
    /// height shorter than its content instead of growing to fit it, with
    /// the overflow scrolling inside the card. Double-click resets to
    /// sizing to content. Sits in the outer padding below `NoteCardEditor`'s
    /// own frame, not on top of it — the same reason `reorderGrip` needs a
    /// corner of its own: the editor is a real NSTextView claiming every
    /// mouse event over its own bounds.
    @ViewBuilder
    private var resizeHandle: some View {
        // `dragStartHeight != nil` keeps this view (and the gesture attached
        // to it) alive for the whole drag even after the pointer leaves the
        // card's bounds — which a downward resize drag does almost
        // immediately. Gating purely on `isHovered` made `onHover` fire
        // `false` mid-drag, which removed this view from the hierarchy via
        // the `if` above and silently killed the DragGesture along with it:
        // the drag looked like it stopped responding the moment the cursor
        // crossed the card's edge, which is exactly the reported friction.
        if isHovered || dragStartHeight != nil {
            Rectangle()
                .fill(Color(nsColor: style.ink.secondary).opacity(0.35))
                .frame(height: 3)
                .clipShape(Capsule())
                .padding(.horizontal, 44)
                .frame(height: 14)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .help("Drag to resize, double-click to fit content")
                .accessibilityLabel("Resize note")
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            if dragStartHeight == nil {
                                dragStartHeight = fixedHeight.map { CGFloat($0) } ?? contentHeight
                            }
                            let proposed = (dragStartHeight ?? contentHeight) + value.translation.height
                            notesManager.setCardHeight(Double(max(40, proposed)), at: index)
                        }
                        .onEnded { _ in dragStartHeight = nil }
                )
                .onTapGesture(count: 2) {
                    notesManager.setCardHeight(nil, at: index)
                }
                .transition(.opacity)
        }
    }

    /// Cards sit on the window's own material, so they need their own surface
    /// to read as separate pieces of paper rather than panels of the same glass.
    private var cardBackground: some View {
        Color(nsColor: style.cardColor)
            .opacity(style.opaqueCards ? 1.0 : 0.55)
    }
}

/// Every card's last measured content height, by note, for the session.
///
/// A card is a fresh view whenever the stack is rebuilt (a mode switch, a
/// theme change, the window coming back), and a fresh view knows nothing
/// until its editor has laid out. Starting it at the height it last measured
/// means it is drawn at its real size from the first frame instead of
/// growing into it. Kept by note identity, so it follows a note through a
/// reorder; never persisted, since it depends on the panel's width and font.
@MainActor
final class EdgeCardHeights {
    static let shared = EdgeCardHeights()

    private var heights: [UUID: CGFloat] = [:]

    func height(for noteID: UUID) -> CGFloat? { heights[noteID] }

    func record(_ height: CGFloat, for noteID: UUID) { heights[noteID] = height }

    func removeAll() { heights.removeAll() }

    /// A note never measured this session: one line of `font` per line of
    /// text, the first a point larger for the title. Wrapping and images
    /// make the real height larger, never smaller, so this errs short.
    static func estimate(text: String, font: NSFont, lineHeightMultiple: Double) -> CGFloat {
        let layout = NSLayoutManager()
        let multiple = CGFloat(max(lineHeightMultiple, 1))
        let body = layout.defaultLineHeight(for: font) * multiple
        let title = layout.defaultLineHeight(
            for: NSFontManager.shared.convert(font, toSize: font.pointSize + 1)
        ) * multiple
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return max(18, (title + body * CGFloat(max(lines - 1, 0))).rounded(.up))
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
    /// Under Reduce Motion the other cards snap to their new places instead
    /// of sliding; the carried card still follows the pointer, which is
    /// motion the user is driving directly.
    let reduceMotion: Bool

    func dropEntered(info: DropInfo) {
        guard let carriedID = draggingNoteID, carriedID != noteID,
              let from = notesManager.notes.firstIndex(where: { $0.id == carriedID }),
              let to = notesManager.notes.firstIndex(where: { $0.id == noteID })
        else { return }
        withAnimation(MotionPolicy.movement(.easeOut(duration: 0.15), reduceMotion: reduceMotion)) {
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

/// Keeps what the user is looking at still when a card above the viewport
/// changes height.
///
/// A scroll view holds its offset, not its content: a card out of sight above
/// growing by 40pt pushed every visible card down 40pt. A card entirely above
/// the viewport reports its change of height here just before SwiftUI gets
/// it, and the moment SwiftUI lays the new height out (the stack's own frame
/// changing, seen by `EdgeScrollAnchorProbe`) the stack scrolls by the same
/// amount. Both land in the same layout pass, so no frame is ever drawn with
/// the content displaced.
///
/// Only height changes are compensated. A reorder moves cards on purpose,
/// and a card that is even partly in view grows where the user can see it.
@MainActor
final class EdgeScrollAnchor {
    weak var scrollView: NSScrollView?
    /// Height gained above the viewport and not yet scrolled away.
    private(set) var pending: CGFloat = 0

    /// Called just before a card's new height reaches SwiftUI.
    func cardWillResize(_ card: NSView, by delta: CGFloat) {
        guard abs(delta) > 0.5, let scrollView,
              let frame = frame(of: card, in: scrollView),
              frame.maxY <= visibleTop(of: scrollView) + 0.5
        else { return }
        let wasIdle = pending == 0
        pending += delta
        guard wasIdle else { return }
        // Should the stack's frame not change (a card above grew exactly as
        // much as one below shrank), the probe never fires. Settle on the
        // next turn instead, laying out first so the new heights are in
        // place: a stale amount would later undo a scroll the user made.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pending != 0, let scrollView = self.scrollView else { return }
            var root: NSView = scrollView
            while let parent = root.superview { root = parent }
            root.layoutSubtreeIfNeeded()
            self.restore()
        }
    }

    /// Scrolls the pending amount away, so the visible cards are back where
    /// they were.
    func restore() {
        guard pending != 0, let scrollView else { return }
        let delta = pending
        pending = 0
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y += clip.isFlipped ? delta : -delta
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// `view`'s frame in the clip view's document coordinates, flipped so
    /// y grows downwards whichever way the clip view is oriented.
    private func frame(of view: NSView, in scrollView: NSScrollView) -> CGRect? {
        guard view.isDescendant(of: scrollView) else { return nil }
        let clip = scrollView.contentView
        let rect = view.convert(view.bounds, to: clip)
        guard !clip.isFlipped else { return rect }
        return CGRect(x: rect.minX, y: -rect.maxY, width: rect.width, height: rect.height)
    }

    private func visibleTop(of scrollView: NSScrollView) -> CGFloat {
        let clip = scrollView.contentView
        return clip.isFlipped ? clip.bounds.minY : -clip.bounds.maxY
    }
}

/// Sits behind the stack's content to find the scroll view around it: to
/// hear, in the middle of SwiftUI's layout pass, that the content's height
/// has just changed, and to give the scroll view its top-edge fade.
struct EdgeScrollAnchorProbe: NSViewRepresentable {
    let anchor: EdgeScrollAnchor
    /// Depth of the fade at the top of the viewport; 0 for a hard edge.
    var topFade: CGFloat = 0

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.anchor = anchor
        view.topFade = topFade
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.anchor = anchor
        view.topFade = topFade
    }

    final class ProbeView: NSView {
        weak var anchor: EdgeScrollAnchor?
        var topFade: CGFloat = 0 {
            didSet { if topFade != oldValue { fade.update(depth: topFade) } }
        }
        private let fade = EdgeTopFade()

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            adopt(enclosingScrollView)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Layer geometry can flip once the view is in a window; lay
            // the fade out again against the real thing.
            if fade.scrollView != nil { fade.update(depth: topFade) }
        }

        override func setFrameSize(_ newSize: NSSize) {
            let changed = abs(newSize.height - frame.height) > 0.01
            super.setFrameSize(newSize)
            if anchor?.scrollView == nil || fade.scrollView == nil { adopt(enclosingScrollView) }
            if changed { anchor?.restore() }
        }

        private func adopt(_ scrollView: NSScrollView?) {
            guard let scrollView else { return }
            anchor?.scrollView = scrollView
            fade.attach(to: scrollView, depth: topFade)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The scroll-edge fade at the top of the edge stack, as a gradient mask on
/// the stack's own scroll view layer.
///
/// In AppKit rather than a SwiftUI `.mask`: the cards are real NSTextViews
/// hosted inside SwiftUI's scroll view, and a layer mask on that scroll view
/// is guaranteed to cover them, scroller and all. The mask is opaque except
/// for the top `depth` points, so nothing below the fade is touched.
@MainActor
final class EdgeTopFade {
    private(set) weak var scrollView: NSScrollView?
    private var depth: CGFloat = 0
    private var observer: NSObjectProtocol?

    func attach(to scrollView: NSScrollView, depth: CGFloat) {
        guard scrollView !== self.scrollView else { return update(depth: depth) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        self.scrollView = scrollView
        scrollView.postsFrameChangedNotifications = true
        observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        update(depth: depth)
    }

    func update(depth: CGFloat) {
        self.depth = depth
        layout()
        // A layer only knows which way its geometry runs once it is in the
        // layer tree, which for a freshly layer-backed view is a turn later.
        DispatchQueue.main.async { [weak self] in self?.layout() }
    }

    private func layout() {
        guard let scrollView else { return }
        guard depth > 0 else {
            scrollView.layer?.mask = nil
            return
        }
        scrollView.wantsLayer = true
        guard let layer = scrollView.layer else { return }
        let mask = (layer.mask as? CAGradientLayer) ?? CAGradientLayer()
        let bounds = layer.bounds
        let stop = NSNumber(value: Double(min(1, depth / max(bounds.height, 1))))
        // Whichever way the layer's geometry runs, the clear end goes at the
        // top of the viewport, under the header.
        let topIsMinY = layer.contentsAreFlipped()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        mask.locations = [0, stop, 1]
        mask.startPoint = CGPoint(x: 0.5, y: topIsMinY ? 0 : 1)
        mask.endPoint = CGPoint(x: 0.5, y: topIsMinY ? 1 : 0)
        layer.mask = mask
        CATransaction.commit()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// A checklist-capable editor that reports the height it needs, so a card can
/// size itself to its note by default — and, wrapped in a real `NSScrollView`,
/// can just as well be given a fixed height shorter than that and scroll its
/// overflow internally instead, when the card's resize handle has been
/// dragged. The scroll view is transparent to that choice: whatever height
/// SwiftUI's `.frame` on this view ends up giving it, a scroller appears only
/// when the content actually overflows it.
struct NoteCardEditor: NSViewRepresentable {
    /// Which note this card shows; handed to the text view so its commands
    /// act on this card. See `ChecklistTextView.noteID`.
    var noteID: UUID
    /// The note's text as a value, not a binding into the notes array: a
    /// binding's getter is a closure SwiftUI cannot compare, so every card
    /// counted as changed whenever any note did.
    var text: String
    var onTextChange: (String) -> Void
    var lineHeightMultiple: Double
    var baseFont: NSFont
    var listKeyword: String
    var codeKeyword: String
    var ink: InkTheme
    var highlightsCurrentLine: Bool = false
    /// The height the note needs, and the view reporting it: the card's
    /// place on screen decides whether its change of height may move the
    /// cards the user is looking at.
    var onHeightChange: (CGFloat, NSView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        // Same reasoning as `SwipeScrollView`'s matching line: without this,
        // AppKit adds its own top content inset whenever this scroll view's
        // top edge happens to land flush with something it thinks deserves
        // clearance, double-counting space this view never asked it to add.
        scrollView.automaticallyAdjustsContentInsets = false

        let textView = ChecklistTextView()
        textView.delegate = context.coordinator
        textView.noteID = noteID

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
        textView.highlightsCurrentLine = highlightsCurrentLine
        textView.lineHeightMultiple = lineHeightMultiple
        textView.onHeightChange = context.coordinator.reportHeight(in: scrollView)
        textView.textStorage?.delegate = textView
        textView.enableImageDrops()
        textView.string = text
        textView.applyChecklistStyling()
        textView.recomputeMathResults()
        textView.recomputeLinkMatches()
        textView.applyLinkFolding()

        scrollView.documentView = textView
        return scrollView
    }

    /// How many times SwiftUI has pushed new values into a card editor, and
    /// how many of those made it measure its text. Read by the tests, which
    /// hold a keystroke to touching one card, not all of them.
    static var updateCount = 0
    static var measureCount = 0

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        Self.updateCount += 1
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ChecklistTextView else { return }
        textView.noteID = noteID

        // Anything that can change the text's height. The text view
        // re-measures on its own when its width changes (`layout()`) and
        // when the user types (`textDidChange` below), so an update that
        // changes none of these has nothing to measure.
        var needsMeasure = false
        if textView.listKeyword != listKeyword || textView.codeKeyword != codeKeyword {
            textView.listKeyword = listKeyword
            textView.codeKeyword = codeKeyword
            needsMeasure = true
        }
        if textView.lineHeightMultiple != lineHeightMultiple {
            textView.lineHeightMultiple = lineHeightMultiple
            textView.applyChecklistStyling()
            needsMeasure = true
        }
        if textView.baseFont != baseFont {
            textView.baseFont = baseFont
            needsMeasure = true
        }
        if textView.ink != ink {
            textView.ink = ink
        }
        if textView.highlightsCurrentLine != highlightsCurrentLine {
            textView.highlightsCurrentLine = highlightsCurrentLine
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
            needsMeasure = true
        }
        if needsMeasure {
            Self.measureCount += 1
            textView.reportHeight()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteCardEditor
        init(_ parent: NoteCardEditor) { self.parent = parent }

        /// Routed through the coordinator so the text view's callback always
        /// reaches the current `parent`, without being reassigned on every
        /// update.
        func reportHeight(in scrollView: NSScrollView) -> (CGFloat) -> Void {
            { [weak self, weak scrollView] height in
                guard let self, let scrollView else { return }
                self.parent.onHeightChange(height, scrollView)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ChecklistTextView else { return }
            parent.onTextChange(textView.string)
            textView.reportHeight()
        }
    }
}
