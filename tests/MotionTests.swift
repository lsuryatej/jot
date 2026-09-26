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

    suite("Celebrations throw confetti whether or not Reduce Motion is on") {
        // The maintainer's call: a finished timer always gets its confetti.
        // Reduce Motion still calms the toasts and the edge stack, but the
        // celebration is a rare, user-chosen moment and keeps its burst.
        let saved = ReduceMotion.override
        defer { ReduceMotion.override = saved }
        for reduce in [false, true] {
            ReduceMotion.override = reduce
            for style in CelebrationStyle.allCases where style != .none {
                equal(Celebration.presentation(for: style), .particles,
                      "\(style.rawValue) throws confetti with Reduce Motion \(reduce ? "on" : "off")")
            }
            equal(Celebration.presentation(for: .none), .soundOnly,
                  "sound only stays sound only with Reduce Motion \(reduce ? "on" : "off")")
        }
    }
}
