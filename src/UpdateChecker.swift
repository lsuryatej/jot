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
    @Published private(set) var isUpdating = false

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

    /// Dotted-integer comparison plus the one semver rule that matters here:
    /// a pre-release ("1.4.0-beta.1") sorts before its release.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func split(_ v: String) -> (core: [Int], pre: [Substring]?) {
            let parts = v.split(separator: "-", maxSplits: 1)
            let core = (parts.first ?? "").split(separator: ".").compactMap { Int($0) }
            return (core, parts.count > 1 ? parts[1].split(separator: ".") : nil)
        }
        let (ac, ap) = split(a)
        let (bc, bp) = split(b)
        for i in 0..<max(ac.count, bc.count) {
            let x = i < ac.count ? ac[i] : 0
            let y = i < bc.count ? bc[i] : 0
            if x != y { return x > y }
        }
        switch (ap, bp) {
        case (nil, nil), (.some, nil): return false
        case (nil, .some): return true
        case let (.some(ap), .some(bp)):
            for i in 0..<max(ap.count, bp.count) {
                guard i < ap.count else { return false }
                guard i < bp.count else { return true }
                if ap[i] == bp[i] { continue }
                if let x = Int(ap[i]), let y = Int(bp[i]) { return x > y }
                return ap[i] > bp[i]
            }
            return false
        }
    }

    enum UpdateOutcome: Equatable { case relaunch, alreadyCurrent, failed }

    /// brew treats "already installed" as success, so only a version that
    /// moved forward on disk counts as an update.
    nonisolated static func outcome(versionBefore: String, installedAfter: String?, exitStatus: Int32) -> UpdateOutcome {
        if let installedAfter, isNewer(installedAfter, than: versionBefore) { return .relaunch }
        return exitStatus == 0 ? .alreadyCurrent : .failed
    }

    func performUpdate() {
        guard !isUpdating, let version = availableVersion else { return }
        guard let brew = Self.brewForCaskInstall() else {
            // An ad-hoc-signed app can't safely replace itself, and remote
            // install scripts are deliberately never run from here.
            let alert = NSAlert()
            alert.messageText = "Jot \(version) is available"
            alert.informativeText = "Download the new version and replace Jot in your Applications folder."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(Self.releasesPage)
            }
            return
        }

        let versionBefore = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let appPath = Bundle.main.bundlePath

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["upgrade", "--cask", "jot"]
        var environment = ProcessInfo.processInfo.environment
        // brew refreshes third-party taps only once a day by default, which
        // would hide a cask bumped minutes ago.
        environment["HOMEBREW_AUTO_UPDATE_SECS"] = "0"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = environment
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            showUpdateFailed(detail: error.localizedDescription)
            return
        }
        isUpdating = true

        DispatchQueue.global(qos: .userInitiated).async {
            // Drained before waiting so a chatty brew can't block on a full pipe.
            let stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let status = process.terminationStatus
            if status != 0 { NSLog("Jot: brew upgrade exited \(status): \(stderr)") }
            Task { @MainActor in
                let checker = UpdateChecker.shared
                checker.isUpdating = false
                let installed = Self.installedVersion(at: appPath)
                switch Self.outcome(versionBefore: versionBefore, installedAfter: installed, exitStatus: status) {
                case .relaunch:
                    checker.relaunch(appPath: appPath)
                case .alreadyCurrent, .failed:
                    checker.showUpdateFailed(detail: Self.briefError(from: stderr))
                }
            }
        }
    }

    private func showUpdateFailed(detail: String?) {
        let alert = NSAlert()
        alert.messageText = "Couldn't update automatically"
        var text = "Homebrew didn't install a newer version. You can download it from GitHub instead."
        if let detail { text += "\n\n\(detail)" }
        alert.informativeText = text
        alert.addButton(withTitle: "Open Releases Page")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.releasesPage)
        }
    }

    /// `NSWorkspace.open` while this instance still runs would only activate
    /// it, so a detached shell waits for this pid to exit before opening the
    /// new bundle. Terminating flushes notes before the new instance reads them.
    private func relaunch(appPath: String) {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = Self.relaunchArguments(pid: ProcessInfo.processInfo.processIdentifier, appPath: appPath)
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            showUpdateFailed(detail: error.localizedDescription)
            return
        }
        NSApp.terminate(nil)
    }

    // pid and path are positional parameters, never spliced into the script.
    nonisolated static func relaunchArguments(pid: Int32, appPath: String) -> [String] {
        ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$2\"",
         "sh", String(pid), appPath]
    }

    /// brew's last `Error:` line, else its last line of any kind.
    nonisolated static func briefError(from stderr: String) -> String? {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let line = lines.last(where: { $0.hasPrefix("Error:") }) ?? lines.last else { return nil }
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }

    /// Read from disk because `Bundle.main` keeps reporting the running
    /// process's version after brew has replaced the files.
    nonisolated static func installedVersion(at path: String) -> String? {
        let plistURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL) else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    nonisolated static let defaultCaskroomPaths = ["/opt/homebrew/Caskroom/jot", "/usr/local/Caskroom/jot"]

    /// The brew that installed this cask, if any. Having brew for other tools
    /// isn't enough: `brew upgrade --cask jot` just fails for an install.sh copy.
    nonisolated static func brewForCaskInstall(caskroomPaths: [String] = defaultCaskroomPaths) -> String? {
        let fm = FileManager.default
        for caskroom in caskroomPaths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: caskroom, isDirectory: &isDir), isDir.boolValue else { continue }
            // <prefix>/Caskroom/jot pairs with <prefix>/bin/brew.
            let prefix = URL(fileURLWithPath: caskroom).deletingLastPathComponent().deletingLastPathComponent()
            let brew = prefix.appendingPathComponent("bin/brew").path
            if fm.isExecutableFile(atPath: brew) { return brew }
        }
        return nil
    }
}
