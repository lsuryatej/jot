import Foundation

// Coverage for the update checker's pure logic and the relaunch helper
// script. Running `brew upgrade`, the alerts and NSApp.terminate need a real
// install to act on, so they aren't exercised here.

func runUpdateCheckerTests() {

    // MARK: - isNewer

    suite("isNewer compares dotted version numbers") {
        check(UpdateChecker.isNewer("1.3.0", than: "1.2.0"), "a newer patch")
        check(UpdateChecker.isNewer("2.0.0", than: "1.9.9"), "a newer major over a higher minor/patch")
        check(!UpdateChecker.isNewer("1.2.0", than: "1.2.0"), "identical versions are not newer")
        check(!UpdateChecker.isNewer("1.2.0", than: "1.3.0"), "an older version is not newer")
        check(UpdateChecker.isNewer("1.10.0", than: "1.9.0"), "double-digit component compares numerically, not lexically")
        check(UpdateChecker.isNewer("1.2", than: "1.1.9"), "a missing trailing component reads as zero")
    }

    // MARK: - installedVersion(at:)

    suite("installedVersion(at:) reads CFBundleShortVersionString from a real Info.plist on disk") {
        let appDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jot-update-test-\(UUID().uuidString).app")
        let contentsDir = appDir.appendingPathComponent("Contents")
        try! FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "1.4.2"]
        let plistData = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try! plistData.write(to: contentsDir.appendingPathComponent("Info.plist"))

        equal(UpdateChecker.installedVersion(at: appDir.path), "1.4.2", "reads the version straight off disk")
    }

    suite("installedVersion(at:) returns nil rather than crashing when there is nothing to read") {
        let missingPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jot-update-test-missing-\(UUID().uuidString).app").path
        check(UpdateChecker.installedVersion(at: missingPath) == nil, "no Info.plist at all")
    }

    suite("installedVersion(at:) returns nil for an Info.plist without a version") {
        let appDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jot-update-test-nokey-\(UUID().uuidString).app")
        let contentsDir = appDir.appendingPathComponent("Contents")
        try! FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.suryatejlalam.Jot"]
        let plistData = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try! plistData.write(to: contentsDir.appendingPathComponent("Info.plist"))
        check(UpdateChecker.installedVersion(at: appDir.path) == nil, "missing CFBundleShortVersionString")
        try? FileManager.default.removeItem(at: appDir)
    }

    // MARK: - pre-releases

    suite("isNewer orders a pre-release between the previous release and its own") {
        check(UpdateChecker.isNewer("1.4.0", than: "1.4.0-beta.1"), "a release beats its own beta")
        check(!UpdateChecker.isNewer("1.4.0-beta.1", than: "1.4.0"), "a beta is not newer than its release")
        check(UpdateChecker.isNewer("1.4.0-beta.1", than: "1.3.9"), "a beta beats the previous release")
        check(!UpdateChecker.isNewer("1.3.9", than: "1.4.0-beta.1"), "the previous release is not newer than the beta")
        check(UpdateChecker.isNewer("1.4.0-beta.2", than: "1.4.0-beta.1"), "beta.2 beats beta.1")
        check(UpdateChecker.isNewer("1.4.0-beta.10", than: "1.4.0-beta.9"), "numeric pre-release parts compare numerically")
        check(UpdateChecker.isNewer("1.4.0-rc.1", than: "1.4.0-beta.3"), "rc beats beta")
        check(!UpdateChecker.isNewer("1.4.0-beta.1", than: "1.4.0-beta.1"), "identical pre-releases are not newer")
        check(UpdateChecker.isNewer("1.4.0-beta.1", than: "1.4.0-beta"), "a longer pre-release beats its prefix")
    }

    // MARK: - post-upgrade decision

    suite("outcome relaunches only when the version on disk moved forward") {
        equal(UpdateChecker.outcome(versionBefore: "1.2.0", installedAfter: "1.3.0", exitStatus: 0), .relaunch,
              "a real bump relaunches")
        equal(UpdateChecker.outcome(versionBefore: "1.2.0", installedAfter: "1.3.0", exitStatus: 1), .relaunch,
              "a bump on disk wins over a nonzero exit")
        equal(UpdateChecker.outcome(versionBefore: "1.2.0", installedAfter: "1.2.0", exitStatus: 0), .alreadyCurrent,
              "brew's 'already installed' success is not an update (the stale-cask bug)")
        equal(UpdateChecker.outcome(versionBefore: "1.2.0", installedAfter: "1.2.0", exitStatus: 1), .failed,
              "unchanged version with an error exit is a failure")
        equal(UpdateChecker.outcome(versionBefore: "1.2.0", installedAfter: nil, exitStatus: 1), .failed,
              "an unreadable bundle after a failed run is a failure")
        equal(UpdateChecker.outcome(versionBefore: "1.2.0", installedAfter: nil, exitStatus: 0), .alreadyCurrent,
              "an unreadable bundle never triggers a relaunch")
        equal(UpdateChecker.outcome(versionBefore: "1.3.0", installedAfter: "1.2.0", exitStatus: 0), .alreadyCurrent,
              "a downgrade on disk never triggers a relaunch")
    }

    suite("briefError picks the most useful line of brew's stderr") {
        equal(UpdateChecker.briefError(from: ""), nil, "empty stderr gives nothing")
        equal(UpdateChecker.briefError(from: "\n  \n"), nil, "blank stderr gives nothing")
        equal(UpdateChecker.briefError(from: "Warning: a\nError: Cask 'jot' is not installed.\nWarning: b\n"),
              "Error: Cask 'jot' is not installed.", "prefers the Error: line")
        equal(UpdateChecker.briefError(from: "Warning: x\nWarning: Not upgrading jot, the latest version is already installed\n"),
              "Warning: Not upgrading jot, the latest version is already installed", "falls back to the last line")
        let long = UpdateChecker.briefError(from: "Error: " + String(repeating: "x", count: 400)) ?? ""
        check(long.count == 201 && long.hasSuffix("…"), "truncates a very long line")
    }

    // MARK: - Homebrew detection

    suite("brewForCaskInstall only answers when Jot's own Caskroom exists") {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jot-caskroom-test-\(UUID().uuidString)")
        func makeBrew(in prefix: URL) {
            try! fm.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
            fm.createFile(atPath: prefix.appendingPathComponent("bin/brew").path,
                          contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        let withCask = root.appendingPathComponent("a")
        let brewOnly = root.appendingPathComponent("b")
        makeBrew(in: withCask)
        makeBrew(in: brewOnly)
        let caskA = withCask.appendingPathComponent("Caskroom/jot")
        try! fm.createDirectory(at: caskA, withIntermediateDirectories: true)
        let caskB = brewOnly.appendingPathComponent("Caskroom/jot")

        equal(UpdateChecker.brewForCaskInstall(caskroomPaths: [caskB.path]), nil,
              "brew present but Jot not in its Caskroom (an install.sh copy)")
        equal(UpdateChecker.brewForCaskInstall(caskroomPaths: [caskB.path, caskA.path]),
              withCask.appendingPathComponent("bin/brew").path, "uses the brew whose Caskroom holds Jot")
        equal(UpdateChecker.brewForCaskInstall(caskroomPaths: []), nil, "no candidates")

        let plainFile = root.appendingPathComponent("c/Caskroom/jot")
        makeBrew(in: root.appendingPathComponent("c"))
        try! fm.createDirectory(at: plainFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: plainFile.path, contents: Data())
        equal(UpdateChecker.brewForCaskInstall(caskroomPaths: [plainFile.path]), nil,
              "a plain file named jot is not a Caskroom entry")

        let noBrew = root.appendingPathComponent("d/Caskroom/jot")
        try! fm.createDirectory(at: noBrew, withIntermediateDirectories: true)
        equal(UpdateChecker.brewForCaskInstall(caskroomPaths: [noBrew.path]), nil,
              "a Caskroom entry with no executable brew beside it")
        try? fm.removeItem(at: root)
    }

    // MARK: - relaunch helper

    suite("the relaunch helper takes pid and path as arguments and waits for the pid to exit") {
        let hostile = "/tmp/it's \"$(touch pwned)\" Jot.app"
        let args = UpdateChecker.relaunchArguments(pid: 4242, appPath: hostile)
        equal(args.count, 5, "-c, script, $0, pid, path")
        equal(args[0], "-c", "runs an inline script")
        check(!args[1].contains("4242") && !args[1].contains("Jot.app"), "nothing is interpolated into the script")
        equal(Array(args[2...]), ["sh", "4242", hostile], "pid and path are positional parameters")

        // The watched sleep is orphaned to launchd so it's reaped on exit; a
        // zombie child of this process would keep `kill -0` succeeding forever.
        let spawner = Process()
        spawner.executableURL = URL(fileURLWithPath: "/bin/sh")
        spawner.arguments = ["-c", "sleep 0.6 >/dev/null 2>&1 & echo $!"]
        let out = Pipe()
        spawner.standardOutput = out
        try! spawner.run()
        let pidText = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        spawner.waitUntilExit()
        guard let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            check(false, "could not start the watched process")
            return
        }

        // A path that doesn't exist, so `open` fails harmlessly instead of launching anything.
        let missing = NSTemporaryDirectory() + "jot-relaunch-missing-\(UUID().uuidString).app"
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = UpdateChecker.relaunchArguments(pid: pid, appPath: missing)
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        let started = Date()
        try! helper.run()
        helper.waitUntilExit()
        let elapsed = Date().timeIntervalSince(started)
        check(elapsed >= 0.3, "helper waited for the watched pid to exit (\(String(format: "%.2f", elapsed))s)")
        check(helper.terminationStatus != 0, "then exec'd open, which failed on the missing path")
    }
}
