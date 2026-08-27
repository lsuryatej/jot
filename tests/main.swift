import Foundation

// Top-level statements are only legal in main.swift, so the runner lives here
// and the suites live next door in NotesManagerTests.swift.

runAllTests()
runGlassTintTests()
runOrderedListTests()
runThemeNoteTests()
runCelebrationTests()
runInteractionTests()
runUILayerTests()
runHighlightTests()
runPerNoteFontTests()
runDeleteKeepsCurrentNoteTests()
runCodeBlockTests()
runReminderDirectiveTests()
runReminderNotesManagerTests()
runResizableCardTests()
runUpdateCheckerTests()

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("all green")
