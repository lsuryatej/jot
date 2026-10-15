import AppKit
import Foundation

// A theme note's `accent:` key. It used to be parsed into `accentHex` and then
// ignored. Now it is the accent ink for the whole app while the theme is in
// force (math results, checked checklist markers, links), passed through the
// same `AccentInk` clamp as the system accent: it keeps its hue and moves only
// its lightness until it clears 4.5:1 on the theme's paper, chrome and cards
// (7:1 under Increase Contrast). Without `accent:` nothing changes.

private func srgb(_ color: NSColor) -> NSColor {
    Contrast.resolved(color, in: NSAppearance(named: .aqua)!)
}

private func hexString(_ color: NSColor?) -> String {
    guard let color, let s = color.usingColorSpace(.sRGB) else { return "-" }
    return String(format: "%02x%02x%02x", Int(round(s.redComponent * 255)),
                  Int(round(s.greenComponent * 255)), Int(round(s.blueComponent * 255)))
}

private func ratio(_ r: CGFloat) -> String { String(format: "%.2f", r) }

private func hueDistance(_ a: NSColor, _ b: NSColor) -> CGFloat {
    let ha = AccentInk.hsl(a).h, hb = AccentInk.hsl(b).h
    return min(abs(ha - hb), 1 - abs(ha - hb))
}

private func freshSettings() -> (SettingsManager, () -> Void) {
    let name = "JotTests.themeAccent-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (SettingsManager(defaults: defaults), { defaults.removePersistentDomain(forName: name) })
}

func runThemeAccentTests() {
    suite("theme accent: parsing") {
        equal(hexString(ThemeNote.parse("theme\naccent: #7cc4ff")?.accentHex), "7cc4ff", "with a hash")
        equal(hexString(ThemeNote.parse("theme\nAccent:  C2410C ")?.accentHex), "c2410c",
              "without one, any case, padded")
        equal(hexString(ThemeNote.parse("theme\naccent: #7cc4ff\naccent: #12")?.accentHex), "7cc4ff",
              "a half-typed second line does not throw the first away")
        equal(hexString(ThemeNote.parse("theme\naccent: orange")?.accentHex), "-", "a name is not a hex: ignored")
        equal(hexString(ThemeNote.parse("theme\npaper: #223038")?.accentHex), "-", "absent when not written")
    }

    suite("theme accent: drives the accent ink and links on a theme paper") {
        let (settings, cleanup) = freshSettings()
        defer { cleanup() }
        // A deep orange that already clears 4.5:1 on this light paper: used as is.
        settings.themeOverride = ThemeNote.parse("theme\npaper: #f4f1ea\naccent: #9a3412")
        let ink = settings.effectiveInk
        equal(hexString(srgb(ink.accent)), "9a3412", "an accent that already passes is used exactly")
        check(ink.link === ink.accent, "links take the theme's accent too")
        equal(hexString(ink.text), hexString(ThemeNote.derivedInk(for: ThemeNote.color(fromHex: "#f4f1ea")!).text),
              "the text ink is untouched")
        check(settings.effectiveInk == ink, "re-deriving the theme on the next keystroke gives an equal ink")
        check(settings.effectiveInk.accent === ink.accent, "the very same colour instance, so nothing restyles")
    }

    suite("theme accent: a custom accent is clamped to 4.5:1 on the theme's paper, chrome and cards") {
        let (settings, cleanup) = freshSettings()
        defer { cleanup() }
        let cases: [(paper: String, accent: String)] = [
            ("#f4f1ea", "#7cc4ff"),  // light blue on a light paper: must darken
            ("#ffffff", "#ffd60a"),  // yellow on white: far under, must darken a lot
            ("#223038", "#1d4ed8"),  // deep blue on a dark paper: must lighten
            ("#14181f", "#ff2d55"),  // pink on near-black
            ("#dfe8f2", "#34c759"),  // green on a pale blue paper
        ]
        for (paperHex, accentHex) in cases {
            settings.themeOverride = ThemeNote.parse("theme\npaper: \(paperHex)\naccent: \(accentHex)")
            let paper = ThemeNote.color(fromHex: paperHex)!
            let raw = ThemeNote.color(fromHex: accentHex)!
            let surfaces = [paper, ThemeNote.derivedChromeColor(for: paper), ThemeNote.derivedCardColor(for: paper)]
            let accent = srgb(settings.effectiveInk.accent)
            let worst = surfaces.map { Contrast.ratio(accent, $0) }.min()!
            check(worst >= 4.5, "\(accentHex) on \(paperHex): \(ratio(worst)):1")
            check(hueDistance(accent, raw) < 0.01, "\(accentHex) on \(paperHex): keeps its hue")
            check(abs(AccentInk.hsl(accent).s - AccentInk.hsl(raw).s) < 0.02,
                  "\(accentHex) on \(paperHex): and its saturation")

            let strong = AccentInk.adjusted(raw, on: surfaces, minimum: 7)
            let strongWorst = surfaces.map { Contrast.ratio(strong, $0) }.min()!
            check(strongWorst >= 7, "\(accentHex) on \(paperHex) under Increase Contrast: \(ratio(strongWorst)):1")
            check(strongWorst >= worst - 0.001, "\(accentHex) on \(paperHex): Increase Contrast is never weaker")
        }
    }

    suite("theme accent: an accent-only theme keeps the picked paper and clamps on it") {
        let (settings, cleanup) = freshSettings()
        defer { cleanup() }
        let raw = ThemeNote.color(fromHex: "#ffd60a")!
        for paper in [Appearance.white, .cream, .trueDark] {
            settings.appearance = paper
            settings.themeOverride = ThemeNote.parse("theme\naccent: #ffd60a")
            let ink = settings.effectiveInk
            equal(hexString(ink.text), hexString(paper.ink.text), "\(paper.rawValue): the paper's own text ink stays")
            let accent = srgb(ink.accent)
            for surface in AccentInk.surfaces(for: paper, dark: false) {
                let r = Contrast.ratio(accent, surface)
                check(r >= 4.5, "\(paper.rawValue): the theme's yellow reads at \(ratio(r)):1")
            }
            check(hueDistance(accent, raw) < 0.01, "\(paper.rawValue): and is still yellow")
            check(ink.link === ink.accent, "\(paper.rawValue): links follow it")
        }
        for paper in [Appearance.frosted, .glass, .solid] {
            settings.appearance = paper
            settings.themeOverride = ThemeNote.parse("theme\naccent: #ffd60a")
            for (mode, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
                let accent = Contrast.resolved(settings.effectiveInk.accent, in: NSAppearance(named: mode)!)
                let worst = AccentInk.surfaces(for: paper, dark: dark).map { Contrast.ratio(accent, $0) }.min()!
                check(worst >= 4.5, "\(paper.rawValue)/\(mode.rawValue): follows the system mode live, \(ratio(worst)):1")
                check(hueDistance(accent, raw) < 0.01, "\(paper.rawValue)/\(mode.rawValue): still yellow")
            }
        }
    }

    suite("theme accent: an ink-only theme with an accent clamps on the material it adopts") {
        let (settings, cleanup) = freshSettings()
        defer { cleanup() }
        settings.appearance = .frosted
        settings.themeOverride = ThemeNote.parse("theme\nink: #eeeeee\naccent: #0040dd")
        let mode = NSAppearance(named: settings.effectiveWindowAppearanceName!)!
        let accent = Contrast.resolved(settings.effectiveInk.accent, in: mode)
        for surface in AccentInk.surfaces(for: .frosted, dark: true) {
            let r = Contrast.ratio(accent, surface)
            check(r >= 4.5, "a deep blue lightened for the dark material light ink adopts: \(ratio(r)):1")
        }
        equal(hexString(settings.effectiveInk.text), "eeeeee", "the explicit ink is still verbatim")
    }

    suite("theme accent: absent, nothing changes") {
        let (settings, cleanup) = freshSettings()
        defer { cleanup() }
        settings.themeOverride = ThemeNote.parse("theme\npaper: #223038")
        let paper = ThemeNote.color(fromHex: "#223038")!
        let derived = ThemeNote.derivedInk(for: paper)
        check(settings.effectiveInk.accent === derived.accent, "a paper theme keeps its derived accent")
        equal(hexString(settings.effectiveInk.link), hexString(derived.link), "and its own link blue")

        settings.appearance = .white
        settings.themeOverride = ThemeNote.parse("theme\ntint: amber")
        equal(settings.effectiveInk, Appearance.white.ink, "a tint-only theme leaves the paper's ink alone")

        settings.themeOverride = nil
        equal(settings.effectiveInk, Appearance.white.ink, "no theme: the paper's ink")
    }

    MainActor.assumeIsolated {
        suite("theme accent: checked markers and links in the editor are painted with it") {
            let (settings, cleanup) = freshSettings()
            defer { cleanup() }
            settings.themeOverride = ThemeNote.parse("theme\npaper: #f4f1ea\naccent: #9a3412")
            let view = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            view.isRichText = false
            view.textStorage?.delegate = view
            view.ink = settings.effectiveInk
            view.string = "- [x] posted the letter\nsee https://example.com/a/rather/long/path/to/somewhere"
            view.applyChecklistStyling()
            view.recomputeLinkMatches()
            view.applyLinkFolding()
            let storage = view.textStorage!
            let marker = storage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
            check(marker === settings.effectiveInk.accent, "the checked marker is in the theme's accent")
            let linkStart = (view.string as NSString).range(of: "example").location
            let link = storage.attribute(.foregroundColor, at: linkStart, effectiveRange: nil) as? NSColor
            equal(hexString(link.map(srgb)), "9a3412", "and so is the link")
        }
    }
}
