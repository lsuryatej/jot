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
    static func isNewer(_ a: String, than b: String) -> Bool {
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
    func performUpdate() {
        guard let brew = Self.brewPath() else {
            NSWorkspace.shared.open(Self.releasesPage)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["upgrade", "--cask", "jot"]
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Jot.app"))
                NSApp.terminate(nil)
            }
        }
        try? process.run()
    }

    private static func brewPath() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
