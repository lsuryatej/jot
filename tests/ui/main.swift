import AppKit
import Foundation

// Entry point for the window harness. Top-level code is only legal in a file
// named main.swift, so the runner lives here and the suites live next door.
//
// Run with ./test-ui.sh. Deliberately not part of ./test.sh: this needs a real
// window server and a real run loop, and takes seconds rather than
// milliseconds.

MainActor.assumeIsolated { startApplication() }

// Nothing here can pass without key status: a locked screen leaves
// loginwindow frontmost, every window stays inactive, and each check then
// waits out its own activation timeout. Say so once and stop, rather than
// grinding into the runner's watchdog.
MainActor.assumeIsolated {
    guard !canBecomeKeyWindow() else { return }
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
    FileHandle.standardError.write(Data(
        "error: no window can become key (\(front) is frontmost). UI tests need an unlocked, interactive session.\n".utf8
    ))
    exit(2)
}

runSettingsWindowTests()
runHeaderDispatchTests()
runUndoAcrossNoteSwitchTests()
runImageResizeTests()
runPanelToggleTests()
runPanelCancelTests()

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    print("failure artifacts (if any): \(artifactDirectory.path)")
    exit(1)
}
try? FileManager.default.removeItem(at: artifactDirectory)
print("all green")
exit(0)
