import SwiftUI

/// The Cmd+Shift+F overlay: search every note at once, not just the open one.
struct GlobalSearchView: View {
    @ObservedObject var notesManager: NotesManager
    @Binding var isPresented: Bool
    var onSelect: (GlobalSearchResult) -> Void

    @State private var query: String = ""
    @FocusState private var fieldFocused: Bool

    private var results: [GlobalSearchResult] {
        GlobalSearch.find(query, in: notesManager.notes)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.98))
        .onAppear { fieldFocused = true }
        .onExitCommand { isPresented = false }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search all notes", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit {
                    if let first = results.first { select(first) }
                }
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(10)
    }

    @ViewBuilder
    private var resultsList: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            placeholder("Type to search every note")
        } else if results.isEmpty {
            placeholder("No matches")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { result in
                        Button {
                            select(result)
                        } label: {
                            resultRow(result)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
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

    private func resultRow(_ result: GlobalSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title(for: result))
                .font(.caption.bold())
                .foregroundStyle(.primary)
            Text(result.snippet)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func title(for result: GlobalSearchResult) -> String {
        notesManager.notes.indices.contains(result.noteIndex)
            ? notesManager.notes[result.noteIndex].title
            : "Untitled note"
    }

    private func select(_ result: GlobalSearchResult) {
        onSelect(result)
        isPresented = false
    }
}
