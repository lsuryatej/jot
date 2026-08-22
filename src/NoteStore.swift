import Foundation

/// File-backed persistence for notes.
///
/// Replaces the previous `UserDefaults` storage, which rewrote the entire note
/// array on every keystroke, offered no atomicity, and was keyed to a bundle ID
/// that has since changed. For a scratchpad whose whole value proposition is
/// "my text is still there", a non-atomic write on every keypress is the wrong
/// trade.
struct NoteStore {
    private let fileURL: URL

    /// The pre-migration `UserDefaults` domain and key.
    private static let legacyDomain = "com.example.StickyNotes"
    private static let legacyKey = "saved_notes"

    /// `allowsLegacyMigration` exists so tests can point at a temporary file
    /// without silently importing (and then rewriting) the user's real notes.
    private let allowsLegacyMigration: Bool

    init(fileURL: URL = NoteStore.defaultFileURL(), allowsLegacyMigration: Bool = true) {
        self.fileURL = fileURL
        self.allowsLegacyMigration = allowsLegacyMigration
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("StickyNotes", isDirectory: true)
            .appendingPathComponent("notes.json", isDirectory: false)
    }

    /// Loads notes, migrating from the legacy `UserDefaults` domain on first run.
    ///
    /// Always returns at least one (possibly empty) note so `currentIndex` can
    /// never address past the end of the array.
    func load() -> [Note] {
        if let data = try? Data(contentsOf: fileURL) {
            // Current format: objects carrying an id.
            if let notes = try? JSONDecoder().decode([Note].self, from: data), !notes.isEmpty {
                writeBackup(data, of: notes)
                return notes
            }
            // Files written before notes had identities are a bare string array.
            // Read them, and they are rewritten in the new shape on next save.
            if let legacy = try? JSONDecoder().decode([String].self, from: data), !legacy.isEmpty {
                let notes = legacy.map { Note(text: $0) }
                writeBackup(data, of: notes)
                return notes
            }
        }

        if allowsLegacyMigration, let migrated = migrateFromUserDefaults() {
            save(migrated)
            return migrated
        }

        return [Note()]
    }

    /// Writes atomically, so an interrupted save cannot truncate the file.
    func save(_ notes: [Note]) {
        let notes = notes.isEmpty ? [Note()] : notes
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(notes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("StickyNotes: failed to save notes to \(fileURL.path): \(error)")
        }
    }

    var backupFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("notes.backup.json")
    }

    /// Keeps the last known-good contents beside the live file.
    ///
    /// A scratchpad's whole value is that the text is still there. One note was
    /// lost to a clobbered save during development, which is one more than this
    /// should ever cost — a copy per launch is cheap insurance against the next
    /// bug doing the same thing silently.
    private func writeBackup(_ data: Data, of notes: [Note]) {
        // Never let a backup of nothing overwrite a backup of something.
        let meaningful = notes.contains { !$0.isBlank }
        guard meaningful else { return }
        try? data.write(to: backupFileURL, options: .atomic)
    }

    /// One-time import of notes written by the pre-1.0 `UserDefaults` build.
    /// Returns nil when there is nothing to migrate.
    private func migrateFromUserDefaults() -> [Note]? {
        guard let defaults = UserDefaults(suiteName: Self.legacyDomain),
              let legacy = defaults.stringArray(forKey: Self.legacyKey)
        else { return nil }

        let salvaged = legacy.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !salvaged.isEmpty else { return nil }

        NSLog("StickyNotes: migrated \(salvaged.count) note(s) from \(Self.legacyDomain)")
        return salvaged.map { Note(text: $0) }
    }
}
