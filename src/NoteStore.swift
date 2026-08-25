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
        // An override so a test run can never be pointed at real notes. Notes
        // were lost during development by seeding fixtures straight into the
        // live file; a scratch path costs nothing and removes the whole class
        // of mistake.
        if let override = ProcessInfo.processInfo.environment["JOT_NOTES_FILE"] {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Jot", isDirectory: true)
            .appendingPathComponent("notes.json", isDirectory: false)
    }

    /// One-time move of the whole storage directory from the app's previous
    /// name. Renaming the app is not supposed to mean losing your notes — a
    /// bundle ID or display-name change is invisible to the person using it,
    /// so the data on disk moves with it. Notes, backups, attachments, the
    /// Apple Notes sync mapping, and the currency cache all move together in
    /// one atomic directory rename rather than being copied file by file.
    ///
    /// `base` is overridable so this is testable without touching the real
    /// Application Support directory.
    @discardableResult
    static func migrateStorageDirectoryIfNeeded(
        in base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> Bool {
        let newDir = base.appendingPathComponent("Jot", isDirectory: true)
        let oldDir = base.appendingPathComponent("StickyNotes", isDirectory: true)

        guard !FileManager.default.fileExists(atPath: newDir.path),
              FileManager.default.fileExists(atPath: oldDir.path)
        else { return false }

        do {
            try FileManager.default.moveItem(at: oldDir, to: newDir)
            return true
        } catch {
            NSLog("Jot: could not migrate storage directory from StickyNotes to Jot: \(error.localizedDescription)")
            return false
        }
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
            // Neither shape decoded. An empty file is just an empty file, but
            // bytes we cannot read are somebody's notes in a damaged state,
            // and the next debounced save is 0.6s away from writing a single
            // blank note over them. Move them out of the way first.
            if !data.isEmpty {
                quarantineUnreadableFile()
            }
        }

        if allowsLegacyMigration, let migrated = migrateFromUserDefaults() {
            save(migrated)
            return migrated
        }

        return [Note()]
    }

    /// Renames a file that would not decode to `notes.unreadable-<stamp>.json`
    /// beside it, so nothing the app does afterwards can destroy it.
    ///
    /// There is no recovery UI: the point is only that the failure stops being
    /// destructive and leaves something a person can find. The dated `Backups/`
    /// copies are still the first thing to reach for; this is the damaged
    /// original itself, which those backups do not contain.
    private func quarantineUnreadableFile() {
        let directory = fileURL.deletingLastPathComponent()
        let stamp = Self.timestampFormatter.string(from: Date())
        var destination = directory.appendingPathComponent("notes.unreadable-\(stamp).json")

        // Two bad loads inside the same second would otherwise land on the
        // same name, and the second must not overwrite the first.
        if FileManager.default.fileExists(atPath: destination.path) {
            let suffix = UUID().uuidString.prefix(8)
            destination = directory.appendingPathComponent("notes.unreadable-\(stamp)-\(suffix).json")
        }

        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
            NSLog("Jot: \(fileURL.path) did not decode; kept the original at \(destination.path)")
        } catch {
            NSLog("Jot: \(fileURL.path) did not decode and could not be moved aside: \(error)")
        }
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
            NSLog("Jot: failed to save notes to \(fileURL.path): \(error)")
        }
    }

    var backupFileURL: URL {
        backupDirectoryURL.appendingPathComponent("notes.backup.json")
    }

    var backupDirectoryURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }

    /// How many dated copies to keep beside the newest one.
    static let backupsKept = 10

    /// Keeps the last known-good contents beside the live file.
    ///
    /// A scratchpad's whole value is that the text is still there. One note was
    /// lost to a clobbered save during development, which is one more than this
    /// should ever cost — a copy per launch is cheap insurance against the next
    /// bug doing the same thing silently.
    private func writeBackup(_ data: Data, of notes: [Note]) {
        // Never let a backup of nothing overwrite a backup of something.
        guard notes.contains(where: { !$0.isBlank }) else { return }

        try? FileManager.default.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
        try? data.write(to: backupFileURL, options: .atomic)

        // A single backup is only one mistake deep: overwrite the live file
        // twice and the good copy is gone too. Dated copies mean a bad state
        // has to survive ten launches before it costs anything.
        let stamp = Self.timestampFormatter.string(from: Date())
        let dated = backupDirectoryURL.appendingPathComponent("notes-\(stamp).json")
        if !FileManager.default.fileExists(atPath: dated.path) {
            try? data.write(to: dated, options: .atomic)
        }
        pruneBackups()
    }

    private func pruneBackups() {
        let fileManager = FileManager.default
        guard let all = try? fileManager.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: nil
        ) else { return }

        let dated = all
            .filter { $0.lastPathComponent.hasPrefix("notes-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for stale in dated.dropFirst(Self.backupsKept) {
            try? fileManager.removeItem(at: stale)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// One-time import of notes written by the pre-1.0 `UserDefaults` build.
    /// Returns nil when there is nothing to migrate.
    private func migrateFromUserDefaults() -> [Note]? {
        guard let defaults = UserDefaults(suiteName: Self.legacyDomain),
              let legacy = defaults.stringArray(forKey: Self.legacyKey)
        else { return nil }

        let salvaged = legacy.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !salvaged.isEmpty else { return nil }

        NSLog("Jot: migrated \(salvaged.count) note(s) from \(Self.legacyDomain)")
        return salvaged.map { Note(text: $0) }
    }
}
