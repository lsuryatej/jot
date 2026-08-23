import AppKit
import Foundation

// Coverage for timer celebrations: the style/sound catalogues, the per-style
// physics numbers in `Celebration`, and their settings persistence. The
// window presentation is deliberately untested — building an NSWindow
// headlessly hangs, which is why CelebrationWindow.swift is not compiled here.

func runCelebrationTests() {

    suite("the celebration catalogue") {
        equal(CelebrationStyle.allCases.count, 4, "cannons, rain, burst, and sound only")
        equal(CelebrationSound.allCases.count, 8, "a curated set, not every system ping")
        check(CelebrationSound.allCases.allSatisfy { NSSound(named: $0.systemName) != nil },
              "every offered sound actually exists on this Mac")
    }

    suite("each confetti style has coherent physics") {
        for style in CelebrationStyle.allCases where style != .none {
            let origins = Celebration.origins(for: style)
            check(!origins.isEmpty, "\(style.rawValue) has somewhere to emit from")
            let velocity = Celebration.velocity(for: style)
            check(velocity.base > 0, "\(style.rawValue) particles move")
            let life = Celebration.lifetime(for: style)
            check(life.base > 0, "\(style.rawValue) particles live a while")

            // The window outlasts its longest particle so nothing vanishes
            // mid-air; it never lingers absurdly long either.
            let duration = Celebration.duration(for: style)
            check(duration >= life.base + life.range, "\(style.rawValue) waits out its own tail")
            check(duration < 8, "\(style.rawValue) does not overstay its welcome")
        }

        // Sound-only emits nothing at all: no motion, no lifetime, no window.
        equal(Celebration.origins(for: .none), [], "sound only has nowhere to emit from")
        check(Celebration.velocity(for: .none).base == 0, "sound only has no velocity")
        check(Celebration.lifetime(for: .none).base == 0, "sound only has no lifetime")

        // Cannons fire from two corners; everything else from one place.
        equal(Celebration.origins(for: .cannons).count, 2, "two corners")
        equal(Celebration.origins(for: .rain).count, 1, "one line across the top")
        equal(Celebration.origins(for: .burst).count, 1, "one centre pop")

        // Rain falls gently; cannons fly hard.
        check(Celebration.velocity(for: .rain).base < Celebration.velocity(for: .cannons).base,
              "rain drifts where cannons shoot")
    }

    suite("celebration settings persist") {
        let name = "JotTests.celebration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let fresh = SettingsManager(defaults: defaults)
        equal(fresh.celebrationStyle, .cannons, "confetti by default — the surprise is on")
        equal(fresh.timerSound, .hero, "Hero by default, not the old Glass ping")

        fresh.celebrationStyle = .rain
        fresh.timerSound = .purr
        let reloaded = SettingsManager(defaults: defaults)
        equal(reloaded.celebrationStyle, .rain, "the style survives a reload")
        equal(reloaded.timerSound, .purr, "so does the sound")

        defaults.set("fireworks", forKey: "celebrationStyle")
        defaults.set("foghorn", forKey: "timerSound")
        let garbage = SettingsManager(defaults: defaults)
        equal(garbage.celebrationStyle, .cannons, "unknown styles fall back to the default")
        equal(garbage.timerSound, .hero, "as do unknown sounds")
    }
}
