import AppKit
import Foundation

// Coverage for glass tints: the wash rules in GlassTint itself, which papers
// accept one, and the settings persistence round trip.

func runGlassTintTests() {

    suite("tints are washes, not papers") {
        check(GlassTint.none.overlayColor == nil, "no tint means no wash")
        check(GlassTint.none.overlayOpacity == 0, "and no opacity either")
        for tint in GlassTint.allCases where tint != .none {
            check(tint.overlayColor != nil, "\(tint.rawValue) has a colour")
            check(tint.overlayOpacity > 0 && tint.overlayOpacity <= 0.2,
                  "\(tint.rawValue) stays light enough that system ink keeps its contrast")
        }
        equal(GlassTint.allCases.count, 6, "the curated set, no more")
    }

    suite("tints only apply to translucent papers") {
        for translucent in [Appearance.frosted, .glass, .solid] {
            check(GlassTint.applies(to: translucent), "\(translucent.rawValue) takes a tint")
        }
        for opaque in [Appearance.trueDark, .cream, .white] {
            check(!GlassTint.applies(to: opaque), "\(opaque.rawValue) carries its own colour and ignores tints")
        }
    }

    suite("the tint persists across a settings round trip") {
        let name = "JotTests.tint-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        equal(SettingsManager(defaults: defaults).glassTint, GlassTint.none, "fresh installs start untinted")

        SettingsManager(defaults: defaults).glassTint = .amber
        equal(GlassTint(rawValue: defaults.string(forKey: "appearanceTint") ?? ""), .amber,
              "the raw value lands in defaults")

        equal(SettingsManager(defaults: defaults).glassTint, .amber, "and survives a fresh manager")

        defaults.set("plaid", forKey: "appearanceTint")
        equal(SettingsManager(defaults: defaults).glassTint, .none, "a garbage stored value falls back to none")
    }
}
