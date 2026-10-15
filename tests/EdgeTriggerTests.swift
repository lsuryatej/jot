import AppKit

// The Screen Edge trigger strip's geometry and the choice of screen, as pure
// functions over screen rectangles: which edges get a strip, how wide it is,
// and which display a reveal belongs on. The windows themselves need a
// window server; the rules don't.

func runEdgeTriggerTests() {
    let laptop = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let laptopVisible = CGRect(x: 0, y: 0, width: 1440, height: 875)

    suite("the edge strip is 2pt wide, flush with the edge, and full visible height") {
        let right = EdgeTriggerGeometry.strips(
            screens: [(frame: laptop, visible: laptopVisible)], edge: .right)
        equal(right, [CGRect(x: 1438, y: 0, width: 2, height: 875)], "one strip against the right edge")
        let left = EdgeTriggerGeometry.strips(
            screens: [(frame: laptop, visible: laptopVisible)], edge: .left)
        equal(left, [CGRect(x: 0, y: 0, width: 2, height: 875)], "one strip against the left edge")
    }

    suite("a pointer pushed against the edge is inside the 2pt strip") {
        // The pointer stops on the screen's last column of pixels; on a 2x
        // display that can be half a point short of the edge.
        let right = EdgeTriggerGeometry.strips(
            screens: [(frame: laptop, visible: laptopVisible)], edge: .right)[0]
        check(right.contains(CGPoint(x: laptop.maxX - 1, y: 400)), "at the last point of the right edge")
        check(right.contains(CGPoint(x: laptop.maxX - 0.5, y: 400)), "at the last half point")
        check(!right.contains(CGPoint(x: laptop.maxX - 3, y: 400)), "but not 3pt in, over a flush window's scroller")
        let left = EdgeTriggerGeometry.strips(
            screens: [(frame: laptop, visible: laptopVisible)], edge: .left)[0]
        check(left.contains(CGPoint(x: 0, y: 400)), "at the first point of the left edge")
    }

    suite("an edge shared with another display gets no strip") {
        let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let screens = [(frame: laptop, visible: laptopVisible), (frame: external, visible: external)]
        equal(EdgeTriggerGeometry.strips(screens: screens, edge: .right),
              [CGRect(x: 3358, y: 0, width: 2, height: 1080)],
              "right edge: only the outer display's, not the seam the pointer crosses")
        equal(EdgeTriggerGeometry.strips(screens: screens, edge: .left),
              [CGRect(x: 0, y: 0, width: 2, height: 875), CGRect(x: 1440, y: 900, width: 2, height: 180)],
              "left edge: the laptop's, and the taller external's stretch above the laptop")
    }

    suite("a partly shared edge keeps a strip along the part that is a real edge") {
        // An external display to the right, set higher than the laptop: the
        // laptop's right edge is open below y = 400.
        let external = CGRect(x: 1440, y: 400, width: 1920, height: 1080)
        let screens = [(frame: laptop, visible: laptopVisible), (frame: external, visible: external)]
        equal(EdgeTriggerGeometry.strips(screens: screens, edge: .right),
              [CGRect(x: 1438, y: 0, width: 2, height: 400), CGRect(x: 3358, y: 400, width: 2, height: 1080)],
              "the laptop's open stretch and the external's whole edge")
    }

    suite("displays stacked vertically each keep their own strip") {
        let above = CGRect(x: 0, y: 900, width: 1440, height: 900)
        let screens = [(frame: laptop, visible: laptopVisible), (frame: above, visible: above)]
        equal(EdgeTriggerGeometry.strips(screens: screens, edge: .right).count, 2, "one per display")
    }

    suite("a sliver of open edge too short to aim at gets no strip") {
        let external = CGRect(x: 1440, y: 20, width: 1920, height: 1080)
        let screens = [(frame: laptop, visible: laptopVisible), (frame: external, visible: external)]
        equal(EdgeTriggerGeometry.strips(screens: screens, edge: .right).count, 1, "only the external's")
    }

    suite("a reveal goes to the display under the pointer") {
        let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let frames = [laptop, external]
        equal(EdgeTriggerGeometry.screenIndex(containing: CGPoint(x: 700, y: 300), frames: frames), 0, "laptop")
        equal(EdgeTriggerGeometry.screenIndex(containing: CGPoint(x: 2000, y: 300), frames: frames), 1, "external")
        equal(EdgeTriggerGeometry.screenIndex(containing: CGPoint(x: 1440, y: 300), frames: frames), 1,
              "on the seam: the display that starts there")
        equal(EdgeTriggerGeometry.screenIndex(containing: CGPoint(x: 3360, y: 1080), frames: frames), 1,
              "on the outer top-right corner, which no half-open rectangle contains")
        equal(EdgeTriggerGeometry.screenIndex(containing: CGPoint(x: 5000, y: 300), frames: frames), 1,
              "somewhere off every display: the nearest")
        equal(EdgeTriggerGeometry.screenIndex(containing: .zero, frames: []), nil, "no displays, no answer")
    }
}
