import Foundation

/// Pushes notes into a folder in Apple Notes.
///
/// One direction only. Apple Notes stores rich text, so round-tripping would
/// mean deciding what a bold run or a table becomes back here, and getting it
/// wrong would corrupt the plain-text original. Pushing is well defined;
/// pulling is a different feature.
///
/// Notes removed here are deliberately left alone over there. Deleting from
/// someone's Notes library on the strength of a mapping file is not a risk
/// worth taking automatically.
actor AppleNotesSync {
    static let folderName = "StickyNotes"

    private let mappingURL: URL
    /// StickyNotes note id -> Apple Notes note id.
    private var mapping: [String: String]

    init(mappingURL: URL = NoteStore.defaultFileURL()
        .deletingLastPathComponent()
        .appendingPathComponent("apple-notes-map.json")) {
        self.mappingURL = mappingURL
        self.mapping = Self.loadMapping(from: mappingURL)
    }

    /// osascript echoes a trailing newline after the value a script returns.
    ///
    /// Storing that unnoticed is what made every sync duplicate the whole
    /// library: the id went into the mapping as "x-coredata://…\n", the next
    /// run asked Notes for `note id "x-coredata://…\n"`, Notes could not find
    /// it, and the code did the reasonable thing for a note that no longer
    /// exists — made a new one. Every time.
    static func normalizeIdentifier(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - HTML

    /// Apple Notes takes HTML for a note body.
    static func htmlBody(for note: Note) -> String {
        note.text
            .components(separatedBy: "\n")
            .map { line in
                let escaped = escape(line)
                return "<div>\(escaped.isEmpty ? "<br>" : escaped)</div>"
            }
            .joined()
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// AppleScript string literals escape only backslash and double quote.
    static func appleScriptLiteral(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Syncing

    struct Result {
        var created = 0
        var updated = 0
        var failed = 0
    }

    @discardableResult
    func sync(_ notes: [Note]) async -> Result {
        var result = Result()

        do {
            try ensureFolder()
        } catch {
            NSLog("StickyNotes: could not reach Apple Notes: \(error.localizedDescription)")
            result.failed = notes.count
            return result
        }

        for note in notes where !note.isBlank {
            do {
                if let existing = mapping[note.id.uuidString] {
                    if try update(note, appleNoteID: existing) {
                        result.updated += 1
                    } else {
                        // The note was deleted over there; make a fresh one.
                        mapping[note.id.uuidString] = try create(note)
                        result.created += 1
                    }
                } else {
                    mapping[note.id.uuidString] = try create(note)
                    result.created += 1
                }
            } catch {
                result.failed += 1
                NSLog("StickyNotes: sync failed for \(note.title): \(error.localizedDescription)")
            }
        }

        saveMapping()
        return result
    }

    private func ensureFolder() throws {
        _ = try runScript("""
        tell application "Notes"
            if not (exists folder "\(Self.folderName)") then
                make new folder with properties {name:"\(Self.folderName)"}
            end if
        end tell
        """)
    }

    private func create(_ note: Note) throws -> String {
        let raw = try runScript("""
        tell application "Notes"
            set theNote to make new note at folder "\(Self.folderName)" ¬
                with properties {name:\(Self.appleScriptLiteral(note.title)), body:\(Self.appleScriptLiteral(Self.htmlBody(for: note)))}
            return id of theNote
        end tell
        """)

        guard let identifier = Self.normalizeIdentifier(raw) else {
            throw NSError(
                domain: "AppleNotesSync",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Notes did not return an identifier for the new note."]
            )
        }
        return identifier
    }

    /// Returns false when the note no longer exists in Apple Notes.
    private func update(_ note: Note, appleNoteID: String) throws -> Bool {
        let output = try runScript("""
        tell application "Notes"
            try
                set theNote to note id \(Self.appleScriptLiteral(appleNoteID))
                set body of theNote to \(Self.appleScriptLiteral(Self.htmlBody(for: note)))
                return "ok"
            on error
                return "missing"
            end try
        end tell
        """)
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    // MARK: - Plumbing

    private func runScript(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "unknown error"
            throw NSError(
                domain: "AppleNotesSync",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func loadMapping(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let mapping = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        // Existing mappings may hold the untrimmed form; repair them on read
        // rather than making the user pay for one more duplicate round.
        return mapping.compactMapValues { normalizeIdentifier($0) }
    }

    private func saveMapping() {
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        try? FileManager.default.createDirectory(
            at: mappingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: mappingURL, options: .atomic)
    }
}
