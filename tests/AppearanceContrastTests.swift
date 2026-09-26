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

    runInkContrastTests()
}

/// Every surface a paper's ink lands on: the page, the header and footer
/// chrome (pure chrome is the worst case of their 0.8/0.6 wash), and the edge
/// cards. Translucent papers get a spread of what their material resolves to
/// in each mode, including a tint wash.
private func surfaces(for paper: Appearance, in mode: NSAppearance.Name) -> [(String, NSColor)] {
    if let color = paper.paperColor {
        return [("paper", color), ("chrome", paper.chromeColor), ("card", paper.cardColor),
                ("header", Contrast.composite(paper.chromeColor.withAlphaComponent(0.8), over: color))]
    }
    let appearance = NSAppearance(named: mode)!
    let window = Contrast.resolved(.windowBackgroundColor, in: appearance)
    let control = Contrast.resolved(.controlBackgroundColor, in: appearance)
    let amber = GlassTint.amber.overlayColor!.withAlphaComponent(GlassTint.amber.overlayOpacity)
    if mode == .darkAqua {
        let material = ThemeNote.color(fromHex: "#3a3a3c")!
        return [("window", window), ("control", control), ("material", material),
                ("amber wash", Contrast.composite(amber, over: material))]
    }
    let material = ThemeNote.color(fromHex: "#e0e0e0")!
    return [("window", window), ("control", control), ("material", material),
            ("amber wash", Contrast.composite(amber, over: material))]
}

private func ratioText(_ r: CGFloat) -> String { String(format: "%.2f", r) }

func runInkContrastTests() {

    suite("every paper's primary and secondary ink passes 4.5:1 on paper, chrome, and cards") {
        for paper in Appearance.allCases {
            let modes: [NSAppearance.Name] = SettingsManager.windowAppearanceName(for: paper, theme: nil)
                .map { [$0] } ?? [.aqua, .darkAqua]
            for mode in modes {
                let appearance = NSAppearance(named: mode)!
                for (role, ink) in [("primary", paper.ink.text), ("secondary", paper.ink.secondary)] {
                    let resolved = Contrast.resolved(ink, in: appearance)
                    for (surfaceName, surface) in surfaces(for: paper, in: mode) {
                        let r = Contrast.ratio(Contrast.composite(resolved, over: surface), surface)
                        check(r >= 4.5, "\(paper.rawValue)/\(mode.rawValue) \(role) on \(surfaceName): \(ratioText(r)):1")
                    }
                }
            }
        }
    }

    suite("Increase Contrast variants are stronger and reach 7:1") {
        for (name, ink, paper) in AdaptiveInk.catalogue {
            let modes: [NSAppearance.Name] = SettingsManager.windowAppearanceName(for: paper, theme: nil)
                .map { [$0] } ?? [.aqua, .darkAqua]
            for mode in modes {
                let dark = mode == .darkAqua
                let normal = dark ? ink.dark : ink.light
                let strong = dark ? ink.darkHighContrast : ink.lightHighContrast
                for (surfaceName, surface) in surfaces(for: paper, in: mode) {
                    let before = Contrast.ratio(Contrast.composite(normal, over: surface), surface)
                    let after = Contrast.ratio(Contrast.composite(strong, over: surface), surface)
                    check(after > before, "\(name)/\(mode.rawValue) on \(surfaceName): high contrast is stronger (\(ratioText(before)) to \(ratioText(after)))")
                    check(after >= 7, "\(name)/\(mode.rawValue) on \(surfaceName): high contrast reaches 7:1 (\(ratioText(after)))")
                }
            }
        }
    }

    suite("adaptive inks pick their variant from the appearance") {
        let ink = AdaptiveInk.catalogue.first { $0.0 == "system secondary" }!.1
        let increase = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let light = Contrast.resolved(ink.color, in: NSAppearance(named: .aqua)!)
        let dark = Contrast.resolved(ink.color, in: NSAppearance(named: .darkAqua)!)
        func same(_ a: NSColor, _ b: NSColor) -> Bool {
            let a = a.usingColorSpace(.sRGB)!, b = b.usingColorSpace(.sRGB)!
            return abs(a.redComponent - b.redComponent) < 0.002 && abs(a.alphaComponent - b.alphaComponent) < 0.002
        }
        check(same(light, increase ? ink.lightHighContrast : ink.light), "light mode resolves the light variant")
        check(same(dark, increase ? ink.darkHighContrast : ink.dark), "dark mode resolves the dark variant")
        check(Appearance.white.ink.secondary === Appearance.white.ink.secondary,
              "paper inks are shared instances, so InkTheme equality stays cheap and stable")
    }

    suite("theme-note inks are contrast-guaranteed on their paper, chrome, and cards") {
        let papers = ["#223038", "#1b2330", "#f3ead8", "#fdf6e3", "#002b36", "#2e3440",
                      "#282a36", "#e8f0e8", "#ffe4e1", "#3b2f2f", "#d8dee9", "#9aa5b1"]
        for hex in papers {
            let paper = ThemeNote.color(fromHex: hex)!
            let surfaces = [("paper", paper),
                            ("chrome", ThemeNote.derivedChromeColor(for: paper)),
                            ("card", ThemeNote.derivedCardColor(for: paper))]
            let ink = ThemeNote.derivedInk(for: paper)
            for (role, color) in [("primary", ink.text), ("secondary", ink.secondary)] {
                for (surfaceName, surface) in surfaces {
                    let r = Contrast.ratio(color, surface)
                    check(r >= 4.5, "theme \(hex) \(role) on \(surfaceName): \(ratioText(r)):1")
                }
            }
        }

        let name = "JotTests.themeInk-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        settings.themeOverride = ThemeNote.parse("theme\npaper: #223038\nink: #e8e4d8")
        let paper = ThemeNote.color(fromHex: "#223038")!
        for surface in [paper, settings.effectiveChromeColor, settings.effectiveCardColor] {
            let r = Contrast.ratio(settings.effectiveInk.secondary, surface)
            check(r >= 4.5, "an explicit ink's secondary still passes (\(ratioText(r)):1)")
        }

        for inkHex in ["#eeeeee", "#d0d0d0", "#1c1c1e", "#303030"] {
            settings.appearance = .frosted
            settings.themeOverride = ThemeNote.parse("theme\nink: \(inkHex)")
            let mode = NSAppearance(named: settings.effectiveWindowAppearanceName!)!
            for surface in [NSColor.windowBackgroundColor, .controlBackgroundColor] {
                let resolved = Contrast.resolved(surface, in: mode)
                let r = Contrast.ratio(settings.effectiveInk.secondary, resolved)
                check(r >= 4.5, "ink-only theme \(inkHex): secondary on the adopted material \(ratioText(r)):1")
            }
        }
    }
}

