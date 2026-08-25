import AppKit
import Foundation

// Entry point for the window harness. Top-level code is only legal in a file
// named main.swift, so the runner lives here and the suites live next door.
//
// Run with ./test-ui.sh. Deliberately not part of ./test.sh: this needs a real
// window server and a real run loop, and takes seconds rather than
// milliseconds.

MainActor.assumeIsolated { startApplication() }

runSettingsWindowTests()
runHeaderDispatchTests()
runUndoAcrossNoteSwitchTests()

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    print("failure artifacts (if any): \(artifactDirectory.path)")
    exit(1)
}
try? FileManager.default.removeItem(at: artifactDirectory)
print("all green")
exit(0)
