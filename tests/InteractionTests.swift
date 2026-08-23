import AppKit
import Foundation

// Coverage for the interaction and rendering rules that previously had no
// automated eyes: swipe recognition, image drag-resize, math-result placement,
// and guide pitch. The state machines were extracted from their views exactly
// so these could be tested without a window server.

func runInteractionTests() {

    // MARK: - Swipe recognition

    suite("a horizontal gesture accumulates to a single fire") {
        var accumulator = SwipeAccumulator()
        accumulator.begin()

        // Deltas short of the threshold absorb silently.
        equal(accumulator.receive(deltaX: 20, deltaY: 0), SwipeAccumulator.Outcome.absorb, "short of the threshold")
        equal(accumulator.receive(deltaX: 20, deltaY: 0), .absorb, "still short")

        // The third delta pushes the total to 60 and crosses 55 exactly once.
        equal(accumulator.receive(deltaX: 20, deltaY: 0),
              SwipeAccumulator.Outcome.fire(.right), "crossing fires once, mid-gesture")
        equal(accumulator.receive(deltaX: 40, deltaY: 0), .absorb, "the rest of the gesture stays quiet")

        accumulator.end()
        check(accumulator.receive(deltaX: 60, deltaY: 0).isFire, "and a new gesture starts from zero")
    }

    suite("direction follows natural scrolling") {
        var accumulator = SwipeAccumulator()
        accumulator.begin()
        // Positive dx (fingers right) navigates back — the pages-under-fingers
        // convention, not the caret one.
        equal(accumulator.receive(deltaX: 80, deltaY: 0),
              SwipeAccumulator.Outcome.fire(.right), "fingers right goes back")

        accumulator = SwipeAccumulator()
        accumulator.begin()
        equal(accumulator.receive(deltaX: -80, deltaY: 0),
              SwipeAccumulator.Outcome.fire(.left), "fingers left goes forward")
    }

    suite("vertical intent passes through") {
        var accumulator = SwipeAccumulator()
        accumulator.begin()
        equal(accumulator.receive(deltaX: 3, deltaY: 40),
              SwipeAccumulator.Outcome.passThrough, "a mostly-vertical delta scrolls the text view")
        equal(accumulator.receive(deltaX: 0, deltaY: -30), .passThrough, "pure vertical as well")
        equal(accumulator.receive(deltaX: 5, deltaY: -5), .passThrough, "ties are vertical too")
        // A vertical event contributes nothing to a later horizontal gesture.
        equal(accumulator.receive(deltaX: 60, deltaY: 1),
              SwipeAccumulator.Outcome.fire(.right), "horizontal still recognised after vertical events")
    }

    suite("cancellation resets cleanly") {
        var accumulator = SwipeAccumulator()
        accumulator.begin()
        _ = accumulator.receive(deltaX: 50, deltaY: 0)
        accumulator.end()
        equal(accumulator.receive(deltaX: 50, deltaY: 0), .absorb, "half a cancelled gesture does not carry over")
    }

    // MARK: - Image resize

    suite("image resize drags wide but never narrow past the floor") {
        equal(ChecklistTextView.resizedWidth(from: 100, to: 160, starting: 200), 260, "growing adds the delta")
        equal(ChecklistTextView.resizedWidth(from: 100, to: 60, starting: 200), 160, "shrinking subtracts it")
        equal(ChecklistTextView.resizedWidth(from: 100, to: -500, starting: 200),
              ChecklistTextView.minimumImageWidth, "an enormous leftward drag floors at the minimum")
        equal(ChecklistTextView.minimumImageWidth, 48, "the floor itself, unchanged from when this lived inline")
    }

    // MARK: - Math result placement

    suite("math results sit in the margin, inside the container") {
        let containerRight: CGFloat = 380
        // A short line: the result right-aligns into the margin, fourteen
        // points in — the wider of the two insets, since the text end is
        // nowhere near the edge.
        let short = ChecklistTextView.mathResultX(textEnd: 100, resultWidth: 60, containerRight: containerRight)
        equal(short, containerRight - 60 - 14, "short-line results right-align with room to spare")

        // A long line: the text end pushes past the right-aligned slot, so
        // the four-point bound is what stops it.
        let long = ChecklistTextView.mathResultX(textEnd: 900, resultWidth: 60, containerRight: containerRight)
        equal(long, containerRight - 60 - 4, "long-line results clamp four points in from the edge")

        // The bounds agree with each other for every input.
        for textEnd in stride(from: CGFloat(0), through: 1200, by: 100) {
            let x = ChecklistTextView.mathResultX(textEnd: textEnd, resultWidth: 60, containerRight: containerRight)
            check(x <= containerRight - 4, "never past the right margin (textEnd \(textEnd))")
            check(x >= containerRight - 60 - 14, "never further in than the wide inset (textEnd \(textEnd))")
        }
    }

    // MARK: - Guide pitch

    suite("guide pitch breathes with the font but has a floor") {
        equal(ChecklistTextView.guideVerticalPitch(lineHeight: 16, spacingMultiple: 1.0), 18,
              "below the floor of 18 it clamps up")
        equal(ChecklistTextView.guideVerticalPitch(lineHeight: 15, spacingMultiple: 2.2), 33,
              "spaced-out fonts space the pattern out")
        equal(ChecklistTextView.guideVerticalPitch(lineHeight: 18, spacingMultiple: 1.5), 27,
              "mid-range values scale linearly")
    }
}

extension SwipeAccumulator.Outcome {
    /// Convenience for asserting "something fired" without caring which way.
    var isFire: Bool {
        if case .fire = self { return true }
        return false
    }
}
