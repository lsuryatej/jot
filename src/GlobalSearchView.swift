import SwiftUI
import AppKit

/// The Cmd+Shift+F overlay: search every note at once, not just the open one.
///
/// The same view serves the windowed modes and Screen Edge (ContentView
/// overlays it in both), so everything below applies to both.
///
/// Keyboard: focus stays in the search field the whole time, the way
/// Spotlight and Xcode's Open Quickly work, and the field hands Up, Down,
/// Return and Escape to the list (`GlobalSearchKey`). The list's selection
/// is drawn as the system selection and announced to VoiceOver, since the
/// focused element is the field, not the row.
struct GlobalSearchView: View {
    @ObservedObject var notesManager: NotesManager
    @Binding var isPresented: Bool
    var onSelect: (GlobalSearchResult) -> Void

    @State private var query: String = ""
    @State private var selection = GlobalSearchSelection(count: 0)
    @State private var hoveredIndex: Int?

    private var results: [GlobalSearchResult] {
        GlobalSearch.find(query, in: notesManager.notes)
    }

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            searchField(results)
            Divider()
            resultsList(results)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.98))
        .onExitCommand { isPresented = false }
        .onChange(of: query) { _, _ in
            selection.reset(count: self.results.count)
            hoveredIndex = nil
        }
        .onChange(of: results.count) { _, count in
            selection.clamp(count: count)
        }
    }

    private func searchField(_ results: [GlobalSearchResult]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            GlobalSearchField(text: $query, placeholder: "Search all notes") { key in
                handle(key, in: results)
            }
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .accessibilityLabel("Close search")
        }
        .padding(10)
    }

    private func handle(_ key: GlobalSearchKey, in results: [GlobalSearchResult]) {
        switch key {
        case .up:
            selection.moveUp(count: results.count)
            announceSelection(in: results)
        case .down:
            selection.moveDown(count: results.count)
            announceSelection(in: results)
        case .open:
            if let result = selection.selected(in: results) { select(result) }
        case .close:
            isPresented = false
        }
    }

    @ViewBuilder
    private func resultsList(_ results: [GlobalSearchResult]) -> some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            placeholder("Type to search every note")
        } else if results.isEmpty {
            placeholder("No matches")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            row(result, at: index)
                                .id(index)
                            Divider()
                        }
                    }
                }
                // Keep the keyboard's row on screen, scrolling only as far as
                // it takes (a nil anchor), with no animation to wait for.
                .onChange(of: selection.index) { _, index in
                    guard let index else { return }
                    proxy.scrollTo(index, anchor: nil)
                }
                .onChange(of: query) { _, _ in
                    proxy.scrollTo(0, anchor: .top)
                }
            }
        }
    }

    private func row(_ result: GlobalSearchResult, at index: Int) -> some View {
        let isSelected = selection.index == index
        let title = title(for: result)
        return Button {
            select(result)
        } label: {
            resultRow(result, title: title, isSelected: isSelected, isHovered: hoveredIndex == index)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredIndex = index
            } else if hoveredIndex == index {
                hoveredIndex = nil
            }
        }
        .accessibilityLabel("\(title): \(result.snippet)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// One result. Selected rows use the system selection pair, background
    /// and text together, so the row reads like any selected list row on the
    /// Mac whatever the user's accent colour. Hover is a quieter wash: the
    /// pointer shows where a click lands without moving the selection out
    /// from under the keyboard.
    private func resultRow(_ result: GlobalSearchResult, title: String, isSelected: Bool, isHovered: Bool) -> some View {
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
        return VStack(alignment: .leading, spacing: 2) {
            Text(GlobalSearch.highlighted(title, matching: query))
                .font(.caption)
                .foregroundStyle(isSelected ? selectedText : Color.primary)
                .lineLimit(1)
            Text(GlobalSearch.highlighted(GlobalSearch.excerpt(of: result.snippet, around: query), matching: query))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isSelected ? selectedText : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                Color(nsColor: .selectedContentBackgroundColor)
            } else if isHovered {
                Color.primary.opacity(0.06)
            }
        }
        .contentShape(Rectangle())
    }

    private func title(for result: GlobalSearchResult) -> String {
        notesManager.notes.indices.contains(result.noteIndex)
            ? notesManager.notes[result.noteIndex].title
            : "Untitled note"
    }

    /// The focus never leaves the field, so VoiceOver would say nothing as
    /// the selection moves. Say the row instead.
    private func announceSelection(in results: [GlobalSearchResult]) {
        guard let index = selection.index, let result = selection.selected(in: results) else { return }
        let text = GlobalSearch.announcement(
            title: title(for: result), snippet: result.snippet, position: index, count: results.count
        )
        let element: Any = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp as Any
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    private func select(_ result: GlobalSearchResult) {
        onSelect(result)
        isPresented = false
    }
}

/// The keys the search field hands to the results list instead of keeping.
enum GlobalSearchKey: Equatable {
    case up, down, open, close

    /// The field editor's command for a key, mapped to what the list does
    /// with it; nil for every command the field should handle itself.
    init?(command: Selector) {
        switch command {
        case #selector(NSResponder.moveUp(_:)): self = .up
        case #selector(NSResponder.moveDown(_:)): self = .down
        case #selector(NSResponder.insertNewline(_:)): self = .open
        // Escape arrives as cancelOperation:, or as complete: where the key
        // binding asks for completion instead; a search field has nothing to
        // complete, so both close.
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)): self = .close
        default: return nil
        }
    }
}

/// The search field, as an `NSTextField` so the field editor's own commands
/// can be intercepted: a SwiftUI `TextField` keeps Up and Down for its caret
/// (they jump to the start and end of the text) before any list sees them.
struct GlobalSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var onKey: (GlobalSearchKey) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onKey: onKey)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusOnAppearTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        // No typing suggestions. Once a few letters of a word are typed,
        // macOS offers an inline prediction or a completion list, and while
        // one shows it takes Up, Down and Return for itself: the arrow keys
        // worked after one letter and stopped working mid-word. A search
        // query has nothing to predict.
        // The inline-prediction switch is on the field editor; see
        // `FocusOnAppearTextField.becomeFirstResponder`.
        field.isAutomaticTextCompletionEnabled = false
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.delegate = context.coordinator
        field.stringValue = text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onKey = onKey
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onKey: (GlobalSearchKey) -> Void

        init(text: Binding<String>, onKey: @escaping (GlobalSearchKey) -> Void) {
            self.text = text
            self.onKey = onKey
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let key = GlobalSearchKey(command: commandSelector) else { return false }
            onKey(key)
            return true
        }
    }
}

/// Takes the keyboard as soon as it is on screen, so Cmd+Shift+F then typing
/// searches straight away, and hands it back to whatever had it (the note's
/// editor) when the overlay closes, so Escape returns to the caret instead of
/// leaving the window with nothing focused.
private final class FocusOnAppearTextField: NSTextField {
    private weak var previousResponder: NSView?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let editor = currentEditor() as? NSTextView {
            editor.inlinePredictionType = .no
            editor.isAutomaticTextCompletionEnabled = false
        }
        return became
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if let view = window.firstResponder as? NSView, view !== self, !self.isFieldEditor(view) {
                self.previousResponder = view
            }
            window.makeFirstResponder(self)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, let previous = previousResponder, previous.window === window {
            DispatchQueue.main.async { [weak window, weak previous] in
                guard let window, let previous, previous.window === window else { return }
                window.makeFirstResponder(previous)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func isFieldEditor(_ view: NSView) -> Bool {
        (view as? NSTextView)?.isFieldEditor == true && (view as? NSTextView)?.delegate === self
    }
}
