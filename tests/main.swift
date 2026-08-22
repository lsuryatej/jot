import Foundation

// Top-level statements are only legal in main.swift, so the runner lives here
// and the suites live next door in NotesManagerTests.swift.

runAllTests()
runUILayerTests()

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("all green")
