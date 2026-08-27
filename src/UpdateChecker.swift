import Foundation
import AppKit

/// Checks GitHub's public releases API for a newer version.
///
/// The only facts that ever leave the machine are "what is the latest
/// release tag" and, implicitly, the requesting IP any HTTPS request
/// carries — no note content, no identifiers, no analytics. On by default is
/// a different call than the currency fetch: a stale copy silently missing
/// bug fixes is the harm this exists to prevent, and there is nothing about
/// the user in the request to protect. Settings can still turn it off.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var availableVersion: String?

    /// Update if the project moves to a different owner or repo name.
    private static let repository = "lsuryatej/jot"
    private static let releasesAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!

    private static let refreshInterval: TimeInterval = 86400
    private var lastChecked: Date?

    private init() {}

    static func check(enabled: Bool) {
        shared.checkIfNeeded(enabled: enabled)
    }

    func checkIfNeeded(enabled: Bool) {
        guard enabled else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.refreshInterval { return }
        Task { await run() }
    }

    /// Bypasses the once-a-day interval, for the manual "Check for Updates" menu item.
    func forceCheck() async {
        await run()
    }

    private func run() async {
        lastChecked = Date()
        struct Release: Decodable { let tag_name: String }
        do {
            var request = URLRequest(url: Self.releasesAPI)
            request.setValue("Jot", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            availableVersion = Self.isNewer(latest, than: current) ? latest : nil
        } catch {
            NSLog("Jot: update check failed: \(error.localizedDescription)")
        }
    }

    /// Plain dotted-integer comparison — enough for "1.2.0" vs "1.10.0"
    /// without pulling in a semver library for three numbers.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let av = a.split(separator: ".").compactMap { Int($0) }
        let bv = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// "Restart to update": if Homebrew installed this copy, upgrade through
    /// it and relaunch. An ad-hoc-signed app has no safe way to replace its
    /// own running binary, so without Homebrew the honest fallback is
    /// sending the user to the release page rather than pretending to update.
    ///
    /// Relaunching used to happen unconditionally in the termination handler,
    /// regardless of whether `brew upgrade` actually changed anything —
    /// which it does not always do even on a clean, zero-status exit: brew
    /// treats "already installed" as success, and this project's own
    /// Homebrew cask is bumped by hand after each release (see BACKLOG.md),
    /// so a user could click this the moment a new version is announced but
    /// before the cask itself catches up. The reported bug — click restart,
    /// the app quits, and the same old version comes back — is exactly what
    /// that produces: brew "succeeds" at upgrading nothing, and the old
    /// `/Applications/Jot.app` gets reopened and called done. The same gap
    /// covers a user who has Homebrew for unrelated tools but installed Jot
    /// via `install.sh`: `brew upgrade --cask jot` fails fast for a cask
    /// that was never installed, and the old code ignored that too.
    ///
    /// The fix trusts neither the exit status nor brew's own claims: it
    /// re-reads the actual installed bundle's version from disk after the
    /// process exits, and only relaunches if that genuinely moved forward.
    func performUpdate() {
        guard let brew = Self.brewPath() else {
            NSWorkspace.shared.open(Self.releasesPage)
            return
        }
        let versionBeforeUpgrade = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["upgrade", "--cask", "jot"]
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                let installedVersion = Self.installedVersion(at: Self.installedAppPath) ?? versionBeforeUpgrade
                guard Self.isNewer(installedVersion, than: versionBeforeUpgrade) else {
                    // Nothing on disk actually changed — do not relaunch into
                    // the exact binary that was just running and call it an
                    // update. Send the user to a path that definitely works.
                    NSWorkspace.shared.open(Self.releasesPage)
                    return
                }
                NSWorkspace.shared.open(URL(fileURLWithPath: Self.installedAppPath))
                NSApp.terminate(nil)
            }
        }
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(Self.releasesPage)
        }
    }

    nonisolated static let installedAppPath = "/Applications/Jot.app"

    /// Reads `CFBundleShortVersionString` straight from the installed app's
    /// own `Info.plist` on disk — not `Bundle.main`, which would still
    /// report this (old, currently-running) process's version even after
    /// the file on disk changed underneath it. `path` is overridable so this
    /// is testable against a fixture bundle rather than the real install.
    nonisolated static func installedVersion(at path: String) -> String? {
        let plistURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL) else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    private static func brewPath() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
