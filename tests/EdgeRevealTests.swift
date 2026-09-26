import AppKit

// The Screen Edge sidebar's show/hide (design review H5). The panel itself
// can't be built headlessly, so AppDelegate routes every decision through
// `EdgeRevealState` (which animation completions are still current) and
// `EdgeRevealGeometry` (where it slides and for how long), checked here.

func runEdgeRevealTests() {

    suite("edge reveal: a hide mid-slide makes the slide's completion stale") {
        var state = EdgeRevealState()
        equal(state.phase, .hidden, "starts hidden")

        let reveal = state.beginReveal()
        equal(state.phase, .revealing, "revealing while it slides in")
        check(state.isArrivingOrShown, "counts as coming out")

        // hideInterface() lands before the slide finishes.
        let conceal = state.beginConceal()
        check(conceal != nil, "a hide interrupts a reveal")
        equal(state.phase, .concealing, "concealing while it slides out")
        check(!state.isArrivingOrShown, "no longer counts as coming out")

        // The reveal's completion fires late: it must not focus or re-show.
        check(!state.finish(reveal), "the interrupted reveal's completion is ignored")
        equal(state.phase, .concealing, "and changes nothing")

        check(state.finish(conceal!), "the hide's own completion is current")
        equal(state.phase, .hidden, "hidden once the slide out lands")
    }

    suite("edge reveal: a show during a hide reverses it cleanly") {
        var state = EdgeRevealState()
        let first = state.beginReveal()
        check(state.finish(first), "an uninterrupted reveal completes")
        equal(state.phase, .shown, "shown")

        let conceal = state.beginConceal()!
        let reveal = state.beginReveal()
        equal(state.phase, .revealing, "the show takes over")
        check(!state.finish(conceal), "the hide's completion no longer orders the panel out")
        equal(state.phase, .revealing, "still revealing")
        check(state.finish(reveal), "the reversal completes")
        equal(state.phase, .shown, "shown again")
    }

    suite("edge reveal: hides with nothing to hide, and immediate resets") {
        var state = EdgeRevealState()
        check(state.beginConceal() == nil, "hiding a hidden sidebar starts nothing")

        let reveal = state.beginReveal()
        let conceal = state.beginConceal()!
        check(state.beginConceal() == nil, "a second hide mid-hide starts nothing new")

        // A mode switch hides at once, with no animation.
        state.reset()
        equal(state.phase, .hidden, "a reset is hidden at once")
        check(!state.finish(reveal), "every earlier completion is stale after a reset")
        check(!state.finish(conceal), "including a pending hide's")
        check(!state.finish(state.generation), "finishing while hidden changes nothing")
    }

    suite("edge reveal: in and out travel the same path") {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)

        let right = EdgeRevealGeometry.frames(visible: visible, width: 320, edge: .right)
        equal(right.docked, CGRect(x: 1120, y: 25, width: 320, height: 850), "docked flush right, full height")
        equal(right.hidden, CGRect(x: 1440, y: 25, width: 320, height: 850), "hidden just past the right edge")

        let left = EdgeRevealGeometry.frames(visible: visible, width: 320, edge: .left)
        equal(left.docked, CGRect(x: 0, y: 25, width: 320, height: 850), "docked flush left")
        equal(left.hidden, CGRect(x: -320, y: 25, width: 320, height: 850), "hidden just past the left edge")

        for frames in [right, left] {
            equal(frames.docked.size, frames.hidden.size, "the same size in and out")
            equal(frames.docked.minY, frames.hidden.minY, "only x changes: a straight horizontal path")
        }
    }

    suite("edge reveal: an interrupted slide takes only the time its distance needs") {
        let full = EdgeRevealGeometry.duration
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let f = EdgeRevealGeometry.frames(visible: visible, width: 200, edge: .right)

        equal(EdgeRevealGeometry.slideDuration(fromX: f.hidden.minX, toX: f.docked.minX, frames: f), full,
              "a full slide in takes the full duration")
        equal(EdgeRevealGeometry.slideDuration(fromX: f.docked.minX, toX: f.hidden.minX, frames: f), full,
              "a full slide out takes the same duration: symmetric")

        let halfway = (f.hidden.minX + f.docked.minX) / 2
        check(abs(EdgeRevealGeometry.slideDuration(fromX: halfway, toX: f.hidden.minX, frames: f) - full / 2) < 0.0001,
              "reversing from halfway takes half the time, so the speed doesn't jump")
        equal(EdgeRevealGeometry.slideDuration(fromX: f.docked.minX, toX: f.docked.minX, frames: f), 0,
              "already there costs nothing")
        equal(EdgeRevealGeometry.slideDuration(fromX: 5000, toX: f.docked.minX, frames: f), full,
              "never longer than a full slide")

        equal(EdgeRevealGeometry.fadeDuration(fromAlpha: 0, toAlpha: 1), full, "a full fade in, same duration")
        equal(EdgeRevealGeometry.fadeDuration(fromAlpha: 1, toAlpha: 0), full, "a full fade out, same duration")
        check(abs(EdgeRevealGeometry.fadeDuration(fromAlpha: 0.25, toAlpha: 0) - full / 4) < 0.0001,
              "reversing a fade from a quarter takes a quarter of the time")
    }

    suite("edge reveal: the docked sidebar can't be dragged off its edge") {
        for mode in DisplayMode.allCases {
            equal(mode.allowsWindowDrag, !mode.isEdgeDocked,
                  "\(mode.rawValue): draggable exactly when not docked to an edge")
        }
    }
}
