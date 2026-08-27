import Foundation

// Coverage for the update-checker's pure logic: version comparison, and
// reading an installed bundle's real version off disk. The side-effecting
// half — running `brew upgrade`, relaunching, opening the releases page —
// is AppKit/Process plumbing this project's other side-effecting code
// (AppleNotesSync, CelebrationWindow) is equally left untested for the same
// reason: nothing here can run without a real environment to act on.

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

    suite("the restart-to-update decision only trusts a version that actually moved forward") {
        // This is the exact shape of the reported bug: brew exits having
        // upgraded nothing (an already-current cask, or one that was never
        // installed through brew at all), so the version on disk is
        // unchanged from what was already running. The fix in
        // UpdateChecker.performUpdate reads this same signal — isNewer over
        // the freshly re-read on-disk version, not the process's own exit
        // status — before deciding to relaunch and quit.
        let versionBeforeUpgrade = "1.3.0"
        let unchangedOnDisk = "1.3.0"
        check(!UpdateChecker.isNewer(unchangedOnDisk, than: versionBeforeUpgrade),
              "brew reporting success is not, on its own, evidence anything was actually installed")

        let genuinelyUpgraded = "1.4.0"
        check(UpdateChecker.isNewer(genuinelyUpgraded, than: versionBeforeUpgrade),
              "a real version bump on disk is what should actually trigger the relaunch")
    }
}
