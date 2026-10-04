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

    // MARK: - Mouse wheels (issue #12): Shift+wheel, tilt wheels, thumb wheels

    // A discrete wheel's events carry no phase at all, so nothing ever said
    // "the gesture ended". The first notch fired, `didFire` stuck, and every
    // later Shift+wheel was absorbed in silence until a trackpad swipe happened
    // to reset it.
    suite("each Shift+wheel burst switches exactly one note, every time") {
        var accumulator = SwipeAccumulator(wheelIdleGap: 0.3)
        // Shift+wheel down: macOS turns the vertical notch into a horizontal one.
        equal(accumulator.receive(ScrollSample(deltaX: -1, deltaY: 0, timestamp: 10.00)),
              SwipeAccumulator.Outcome.fire(.left), "the first notch switches straight away")
        equal(accumulator.receive(ScrollSample(deltaX: -1, deltaY: 0, timestamp: 10.05)), .absorb,
              "the rest of the burst is one switch, not one per notch")
        equal(accumulator.receive(ScrollSample(deltaX: -3, deltaY: 0, timestamp: 10.10)), .absorb,
              "an accelerated notch inside the burst too")

        // A pause longer than the idle gap: the next notch is a new burst.
        equal(accumulator.receive(ScrollSample(deltaX: -1, deltaY: 0, timestamp: 10.50)),
              SwipeAccumulator.Outcome.fire(.left), "after a pause, the next burst switches again")
        equal(accumulator.receive(ScrollSample(deltaX: 1, deltaY: 0, timestamp: 11.00)),
              SwipeAccumulator.Outcome.fire(.right), "and the other way, as many times as you like")
        equal(accumulator.receive(ScrollSample(deltaX: 1, deltaY: 0, timestamp: 11.50)),
              SwipeAccumulator.Outcome.fire(.right), "the third burst is not the last one either")
    }

    suite("a continuous wheel spin is still one burst") {
        var accumulator = SwipeAccumulator(wheelIdleGap: 0.3)
        var fires = 0
        // A free-spinning thumb wheel: forty notches, 50ms apart, two seconds
        // in all. Measured from the last notch, not the first, so it never
        // reaches the gap and never switches twice.
        for i in 0..<40 {
            if accumulator.receive(ScrollSample(deltaX: -1, deltaY: 0, timestamp: 20 + Double(i) * 0.05)).isFire {
                fires += 1
            }
        }
        equal(fires, 1, "one switch for one spin")
    }

    suite("the wheel's idle gap is injectable") {
        var short = SwipeAccumulator(wheelIdleGap: 0.1)
        check(short.receive(ScrollSample(deltaX: 1, deltaY: 0, timestamp: 1.0)).isFire, "first notch")
        check(short.receive(ScrollSample(deltaX: 1, deltaY: 0, timestamp: 1.2)).isFire, "0.2s apart clears a 0.1s gap")

        var long = SwipeAccumulator(wheelIdleGap: 0.5)
        check(long.receive(ScrollSample(deltaX: 1, deltaY: 0, timestamp: 1.0)).isFire, "first notch")
        check(!long.receive(ScrollSample(deltaX: 1, deltaY: 0, timestamp: 1.2)).isFire, "0.2s apart is inside a 0.5s gap")

        let standard = SwipeAccumulator()
        check(standard.wheelIdleGap >= 0.25 && standard.wheelIdleGap <= 0.35, "the shipped gap sits between 0.25s and 0.35s")
    }

    suite("a plain vertical wheel still scrolls the note") {
        var accumulator = SwipeAccumulator(wheelIdleGap: 0.3)
        equal(accumulator.receive(ScrollSample(deltaX: 0, deltaY: -1, timestamp: 1.0)),
              SwipeAccumulator.Outcome.passThrough, "a vertical notch is the text view's")
        equal(accumulator.receive(ScrollSample(deltaX: 0, deltaY: 3, timestamp: 1.05)), .passThrough, "every one of them")
        check(accumulator.receive(ScrollSample(deltaX: -1, deltaY: 0, timestamp: 1.1)).isFire,
              "and a horizontal notch straight after still switches")
    }

    suite("wheel bursts and trackpad gestures keep separate books") {
        var accumulator = SwipeAccumulator(wheelIdleGap: 0.3)
        // A trackpad swipe fires and is still in flight...
        _ = accumulator.receive(ScrollSample(deltaX: 0, deltaY: 0, phase: .began, timestamp: 1.0))
        check(accumulator.receive(ScrollSample(deltaX: 60, deltaY: 0, phase: .changed, timestamp: 1.02)).isFire,
              "the trackpad swipe fires")
        // ...which must not swallow a wheel notch, and a wheel burst must not
        // leave a later trackpad gesture deaf.
        check(accumulator.receive(ScrollSample(deltaX: -1, deltaY: 0, timestamp: 1.05)).isFire,
              "a wheel notch is its own burst")
        _ = accumulator.receive(ScrollSample(deltaX: 0, deltaY: 0, phase: .ended, timestamp: 1.1))
        _ = accumulator.receive(ScrollSample(deltaX: 0, deltaY: 0, phase: .began, timestamp: 1.12))
        check(accumulator.receive(ScrollSample(deltaX: -60, deltaY: 0, phase: .changed, timestamp: 1.14)).isFire,
              "the next trackpad swipe fires as normal")
    }

    // MARK: - Trackpad, through the same entry point the scroll view uses

    suite("a trackpad swipe fires once mid-gesture, as it always has") {
        var accumulator = SwipeAccumulator()
        equal(accumulator.receive(ScrollSample(deltaX: 0, deltaY: 0, phase: .mayBegin, timestamp: 0.99)),
              SwipeAccumulator.Outcome.passThrough, "fingers resting is not a swipe")
        equal(accumulator.receive(ScrollSample(deltaX: 20, deltaY: 0, phase: .began, timestamp: 1.00)),
              SwipeAccumulator.Outcome.absorb, "short of the threshold")
        equal(accumulator.receive(ScrollSample(deltaX: 20, deltaY: 0, phase: .changed, timestamp: 1.01)), .absorb, "still short")
        equal(accumulator.receive(ScrollSample(deltaX: 20, deltaY: 0, phase: .changed, timestamp: 1.02)),
              SwipeAccumulator.Outcome.fire(.right), "55pt crossed: fires mid-gesture")
        equal(accumulator.receive(ScrollSample(deltaX: 40, deltaY: 0, phase: .changed, timestamp: 1.03)), .absorb,
              "the rest of the gesture is quiet")
        equal(accumulator.receive(ScrollSample(deltaX: 0, deltaY: 0, phase: .ended, timestamp: 1.04)),
              SwipeAccumulator.Outcome.passThrough, "lift-off carries no delta")
        check(accumulator.receive(ScrollSample(deltaX: 60, deltaY: 0, phase: .began, timestamp: 2.0)).isFire,
              "the next gesture starts from zero")
    }

    // H4. After lift-off the accumulator resets, and the momentum that follows
    // used to accumulate from zero and could cross 55pt again: one swipe, two
    // notes.
    suite("trackpad momentum never switches a second note") {
        var accumulator = SwipeAccumulator()
        _ = accumulator.receive(ScrollSample(deltaX: 0, deltaY: 0, phase: .began, timestamp: 1.0))
        check(accumulator.receive(ScrollSample(deltaX: -70, deltaY: 0, phase: .changed, timestamp: 1.01)).isFire, "the swipe")
        _ = accumulator.receive(ScrollSample(deltaX: 0, deltaY: 0, phase: .ended, timestamp: 1.02))

        var momentumFires = 0
        var outcomes: [SwipeAccumulator.Outcome] = []
        for (i, dx) in [CGFloat(-40), -30, -20, -12, -6, -2].enumerated() {
            let phase: NSEvent.Phase = i == 0 ? .began : .changed
            let outcome = accumulator.receive(ScrollSample(deltaX: dx, deltaY: 0, momentumPhase: phase, timestamp: 1.03 + Double(i) * 0.016))
            if outcome.isFire { momentumFires += 1 }
            outcomes.append(outcome)
        }
        equal(momentumFires, 0, "110pt of horizontal inertia switches nothing")
        check(outcomes.allSatisfy { $0 == .absorb }, "and is absorbed, so the text never scrolls sideways")
        _ = accumulator.receive(ScrollSample(deltaX: 0, deltaY: 0, momentumPhase: .ended, timestamp: 1.2))

        check(accumulator.receive(ScrollSample(deltaX: 0, deltaY: 0, phase: .began, timestamp: 2.0)) == .passThrough
              && accumulator.receive(ScrollSample(deltaX: -60, deltaY: 0, phase: .changed, timestamp: 2.01)).isFire,
              "the next real swipe still fires")
    }

    suite("vertical momentum still belongs to the text view") {
        var accumulator = SwipeAccumulator()
        equal(accumulator.receive(ScrollSample(deltaX: 0, deltaY: -30, momentumPhase: .changed, timestamp: 1.0)),
              SwipeAccumulator.Outcome.passThrough, "inertial scrolling keeps coasting")
        equal(accumulator.receive(ScrollSample(deltaX: 0, deltaY: 0, momentumPhase: .ended, timestamp: 1.1)),
              SwipeAccumulator.Outcome.passThrough, "and ends normally")
    }

    // The wiring, with real NSEvents through the real scroll view: the fix is
    // worthless if `scrollWheel(with:)` never hands the accumulator a phase.
    suite("SwipeScrollView: Shift+wheel switches on every burst, not just the first") {
        let scrollView = SwipeScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        var swipes: [SwipeDirection] = []
        scrollView.onSwipe = { swipes.append($0) }

        func wheel(_ dx: Int32, at time: TimeInterval) -> NSEvent? {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)
            else { return nil }
            cg.timestamp = CGEventTimestamp(time * 1_000_000_000)
            return NSEvent(cgEvent: cg)
        }

        guard let probe = wheel(-1, at: 1) else {
            check(false, "could not synthesise a wheel event")
            return
        }
        check(probe.phase.isEmpty && probe.momentumPhase.isEmpty && !probe.hasPreciseScrollingDeltas,
              "a synthesised wheel notch looks like a real mouse: no phase, no momentum, line deltas")

        for time in [1.0, 1.05, 1.1] { if let e = wheel(-1, at: time) { scrollView.scrollWheel(with: e) } }
        for time in [2.0, 2.05] { if let e = wheel(-1, at: time) { scrollView.scrollWheel(with: e) } }
        for time in [3.0] { if let e = wheel(1, at: time) { scrollView.scrollWheel(with: e) } }
        equal(swipes.count, 3, "three bursts, three switches")
        equal(swipes.first, .left, "a notch toward negative x goes forward, like a swipe")
        equal(swipes.last, .right, "and toward positive x goes back")
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
