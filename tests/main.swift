import Foundation

// Top-level statements are only legal in main.swift, so the runner lives here
// and the suites live next door in NotesManagerTests.swift.

runAllTests()
runGlassTintTests()
runOrderedListTests()
runBulletListTests()
runThemeNoteTests()
runCelebrationTests()
runInteractionTests()
runUILayerTests()
runBackgroundRectTests()
runHighlightTests()
runEmphasisTests()
runEmphasisWiringTests()
runPerNoteFontTests()
runDeleteKeepsCurrentNoteTests()
runCodeBlockTests()
runReminderDirectiveTests()
runReminderNotesManagerTests()
runResizableCardTests()
runUpdateCheckerTests()
runImageMarkdownVisibilityTests()
runCoverageGapTests()

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("all green")
