import AppKit
import Foundation

// Coverage for the window appearance a paper imposes (so system controls,
// scrollers, and the find bar agree with the paper under them) and for WCAG
// contrast of every ink the papers paint with. Ratios are computed with the
// WCAG 2.x relative-luminance formula in `Contrast`, not eyeballed.

func runAppearanceContrastTests() {

    suite("the WCAG maths itself") {
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        check(abs(Contrast.ratio(white, black) - 21) < 0.01, "white on black is 21:1")
        check(abs(Contrast.ratio(white, white) - 1) < 0.001, "a colour on itself is 1:1")
        // #767676 is the canonical lightest grey that passes 4.5:1 on white.
        let grey = ThemeNote.color(fromHex: "#767676")!
        check(abs(Contrast.ratio(grey, white) - 4.54) < 0.02, "#767676 on white is 4.54:1")
        let half = Contrast.composite(black.withAlphaComponent(0.5), over: white)
        check(abs(half.redComponent - 0.5) < 0.001, "a half-alpha black composites to mid grey")
    }

    suite("the window appearance follows the paper") {
        for translucent in [Appearance.frosted, .glass, .solid] {
            check(SettingsManager.windowAppearanceName(for: translucent, theme: nil) == nil,
                  "\(translucent.rawValue) sits inside the system mode, so the window inherits it")
        }
        equal(SettingsManager.windowAppearanceName(for: .trueDark, theme: nil), .darkAqua,
              "True Dark forces dark controls")
        equal(SettingsManager.windowAppearanceName(for: .cream, theme: nil), .aqua,
              "Cream forces light controls")
        equal(SettingsManager.windowAppearanceName(for: .white, theme: nil), .aqua,
              "White forces light controls")
    }

    suite("theme notes pick the window appearance by luminance") {
        func theme(_ body: String) -> ThemeNote.Theme? { ThemeNote.parse("theme\n" + body) }

        equal(SettingsManager.windowAppearanceName(for: .frosted, theme: theme("paper: #1b2330")), .darkAqua,
              "a dark hex paper gets dark controls")
        equal(SettingsManager.windowAppearanceName(for: .frosted, theme: theme("paper: #f3ead8")), .aqua,
              "a light hex paper gets light controls")
        equal(SettingsManager.windowAppearanceName(for: .white, theme: theme("paper: #101010")), .darkAqua,
              "the theme's paper wins over the picked one")
        equal(SettingsManager.windowAppearanceName(for: .trueDark, theme: theme("paper: #fafafa")), .aqua,
              "in both directions")
        equal(SettingsManager.windowAppearanceName(for: .frosted, theme: theme("ink: #eeeeee")), .darkAqua,
              "light ink on a translucent paper darkens the material under it")
        equal(SettingsManager.windowAppearanceName(for: .glass, theme: theme("ink: #202020")), .aqua,
              "dark ink lightens it")
        check(SettingsManager.windowAppearanceName(for: .frosted, theme: theme("tint: amber")) == nil,
              "a tint alone leaves the system mode alone")
        equal(SettingsManager.windowAppearanceName(for: .trueDark, theme: theme("tint: amber")), .darkAqua,
              "and leaves an opaque picked paper in charge")
    }

    suite("the live setting re-derives on paper and theme changes") {
        let name = "JotTests.appearance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)

        settings.appearance = .frosted
        check(settings.effectiveWindowAppearanceName == nil, "frosted: inherit")
        settings.appearance = .trueDark
        equal(settings.effectiveWindowAppearanceName, .darkAqua, "switching to True Dark flips it")
        settings.appearance = .cream
        equal(settings.effectiveWindowAppearanceName, .aqua, "and Cream flips it back")
        settings.themeOverride = ThemeNote.parse("theme\npaper: #14181f")
        equal(settings.effectiveWindowAppearanceName, .darkAqua, "a theme note takes over live")
        settings.themeOverride = nil
        equal(settings.effectiveWindowAppearanceName, .aqua, "and deleting it hands back to the paper")
    }

    suite("system controls read on every opaque paper, whatever the system mode") {
        // A bare NSView stands in for the panel: both are
        // NSAppearanceCustomization, and a real NSWindow hangs headless.
        for paper in [Appearance.trueDark, .cream, .white] {
            let paperColor = paper.paperColor!
            for system in [NSAppearance.Name.aqua, .darkAqua] {
                let view = NSView()
                view.appearance = NSAppearance(named: system)  // what it would inherit
                view.adoptPaperAppearance(SettingsManager.windowAppearanceName(for: paper, theme: nil))

                let label = Contrast.resolved(.labelColor, in: view.effectiveAppearance)
                let onPaper = Contrast.ratio(Contrast.composite(label, over: paperColor), paperColor)
                let chrome = paper.chromeColor
                let onChrome = Contrast.ratio(Contrast.composite(label, over: chrome), chrome)
                check(onPaper >= 4.5,
                      "\(paper.rawValue) in \(system.rawValue): control label \(String(format: "%.1f", onPaper)):1 on paper")
                check(onChrome >= 4.5,
                      "\(paper.rawValue) in \(system.rawValue): control label \(String(format: "%.1f", onChrome)):1 on chrome")
            }
        }

        // The regression this replaces: without an appearance of its own the
        // header inherits the system label colour, near-black on True Dark.
        let inherited = Contrast.resolved(.labelColor, in: NSAppearance(named: .aqua)!)
        let trueDark = Appearance.trueDark.paperColor!
        check(Contrast.ratio(Contrast.composite(inherited, over: trueDark), trueDark) < 1.5,
              "the old light-mode label on True Dark really was unreadable")
    }

    suite("adopting clears back to inheriting for translucent papers") {
        let view = NSView()
        view.adoptPaperAppearance(.darkAqua)
        equal(view.appearance?.name, .darkAqua, "an opaque paper pins the appearance")
        view.adoptPaperAppearance(nil)
        check(view.appearance == nil, "a translucent paper hands it back to the system")
    }
}
