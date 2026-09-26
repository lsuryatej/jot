import AppKit
import SwiftUI

// Reduce Motion (design review C3). The windows that carry the motion (the
// confetti window, the edge panel's slide, SwiftUI transitions) can't be
// built headlessly, so every decision they make is routed through
// `ReduceMotion`, `MotionPolicy` and `Celebration`, and checked here.

func runMotionTests() {

    suite("Reduce Motion: the setting is injectable") {
        let saved = ReduceMotion.override
        defer { ReduceMotion.override = saved }

        ReduceMotion.override = true
        check(ReduceMotion.isEnabled, "an override of true reads as on")
        ReduceMotion.override = false
        check(!ReduceMotion.isEnabled, "an override of false reads as off")
        ReduceMotion.override = nil
        equal(ReduceMotion.isEnabled, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              "with no override, the system setting decides")
    }

    suite("Reduce Motion: a system change is forwarded live") {
        ReduceMotion.startObserving()
        ReduceMotion.startObserving()  // idempotent: one repost, not two
        var heard = 0
        let token = NotificationCenter.default.addObserver(
            forName: .jotReduceMotionDidChange, object: nil, queue: nil
        ) { _ in heard += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        equal(heard, 1, "the workspace notification is reposted exactly once")
    }

    suite("Reduce Motion: movement becomes a fade or no animation at all") {
        equal(MotionPolicy.toastTransition(reduceMotion: false), .slideAndFade,
              "toasts drop in from the top by default")
        equal(MotionPolicy.toastTransition(reduceMotion: true), .fade,
              "toasts only fade under Reduce Motion")

        check(MotionPolicy.movement(.default, reduceMotion: false) == .default,
              "a scroll or reorder animates by default")
        check(MotionPolicy.movement(.easeOut(duration: 0.15), reduceMotion: true) == nil,
              "a scroll or reorder happens in one step under Reduce Motion")

        check(MotionPolicy.carriedCardScale(reduceMotion: false) < 1,
              "a carried card shrinks a little by default")
        equal(MotionPolicy.carriedCardScale(reduceMotion: true), 1,
              "a carried card keeps its size under Reduce Motion")

        equal(MotionPolicy.edgeReveal(reduceMotion: false), .slide,
              "the edge sidebar slides in by default")
        equal(MotionPolicy.edgeReveal(reduceMotion: true), .fade,
              "the edge sidebar fades in place under Reduce Motion")
    }

    suite("Reduce Motion: celebrations drop the confetti, keep the moment") {
        for style in CelebrationStyle.allCases where style != .none {
            equal(Celebration.presentation(for: style, reduceMotion: false), .particles,
                  "\(style.rawValue) throws confetti by default")
            equal(Celebration.presentation(for: style, reduceMotion: true), .badge,
                  "\(style.rawValue) shows a still badge under Reduce Motion")
        }
        equal(Celebration.presentation(for: .none, reduceMotion: false), .soundOnly,
              "sound only stays sound only")
        equal(Celebration.presentation(for: .none, reduceMotion: true), .soundOnly,
              "sound only does not grow a badge under Reduce Motion")

        equal(Celebration.badgeTitle(endingPhase: nil), "Time's up", "a plain timer")
        equal(Celebration.badgeTitle(endingPhase: .work), "Time for a break", "the end of a work phase")
        equal(Celebration.badgeTitle(endingPhase: .rest), "Back to work", "the end of a break")

        let timing = Celebration.badgeTiming
        check(timing.fadeIn > 0 && timing.fadeIn <= 0.3, "the badge fades in briskly")
        check(timing.fadeIn + timing.hold + timing.fadeOut < 3, "the badge is brief")
    }

    suite("Reduce Motion: the badge sits near the note, always on screen") {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let size = CGSize(width: 180, height: 40)

        let panel = CGRect(x: 600, y: 300, width: 400, height: 420)
        let near = Celebration.badgeFrame(size: size, panelFrame: panel, visibleFrame: visible)
        equal(near.size, size, "the badge keeps its size")
        equal(near.midX, panel.midX, "centred across the panel")
        check(panel.contains(near), "inside the panel's frame, just under its top")
        check(near.maxY < panel.maxY && near.maxY > panel.maxY - 80, "a little below the panel's top edge")

        let offRight = CGRect(x: 1380, y: 300, width: 400, height: 420)
        let clamped = Celebration.badgeFrame(size: size, panelFrame: offRight, visibleFrame: visible)
        check(visible.contains(clamped), "a panel hanging off screen does not take the badge with it")

        let noPanel = Celebration.badgeFrame(size: size, panelFrame: nil, visibleFrame: visible)
        equal(noPanel.midX, visible.midX, "with the note hidden, centred across the screen")
        check(noPanel.maxY <= visible.maxY - 60, "and near the top, clear of the menu bar")
    }
}
