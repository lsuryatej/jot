import AppKit

// The accent ink (math results, checked checklist markers) on the papers that
// use the user's system accent: Frosted, Glass and Solid in both system
// modes, and White and Cream, which are always light. The raw accent is only
// about 4:1 on white for the default blue, and purple in dark mode about
// 3.4:1, so `AccentInk` keeps the accent's hue and moves its lightness until
// it clears 4.5:1 (7:1 under Increase Contrast) on every surface the ink
// lands on. The system accent can't be switched headless, so each macOS
// accent is fed in by value, light and dark variants both.

private let systemAccents: [(String, light: UInt32, dark: UInt32)] = [
    ("blue", 0x007AFF, 0x0A84FF),
    ("purple", 0x953D96, 0xA550A7),
    ("pink", 0xF74F9E, 0xF74F9E),
    ("red", 0xE0383E, 0xFF5257),
    ("orange", 0xF7821B, 0xF7821B),
    ("yellow", 0xFFC600, 0xFFC600),
    ("green", 0x62BA46, 0x62BA46),
    ("graphite", 0x989898, 0x8C8C8C),
]

private func rgb(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255, alpha: 1)
}

private func r2(_ r: CGFloat) -> String { String(format: "%.2f", r) }

/// Every surface the accent ink lands on, independent of the source's own
/// list: paper, chrome, header wash, cards; for the translucent papers the
/// window and control backgrounds, a representative material, and every
/// tint wash over it.
private func accentSurfaces(for paper: Appearance, dark: Bool) -> [(String, NSColor)] {
    if let color = paper.paperColor {
        return [("paper", color), ("chrome", paper.chromeColor), ("card", paper.cardColor),
                ("header", Contrast.composite(paper.chromeColor.withAlphaComponent(0.8), over: color))]
    }
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    let material = ThemeNote.color(fromHex: dark ? "#3a3a3c" : "#e0e0e0")!
    var result: [(String, NSColor)] = [
        ("window", Contrast.resolved(.windowBackgroundColor, in: appearance)),
        ("control", Contrast.resolved(.controlBackgroundColor, in: appearance)),
        ("material", material),
    ]
    for tint in GlassTint.allCases {
        guard let overlay = tint.overlayColor else { continue }
        result.append(("\(tint.rawValue) wash",
                       Contrast.composite(overlay.withAlphaComponent(tint.overlayOpacity), over: material)))
    }
    return result
}

private func hsl(_ color: NSColor) -> (h: CGFloat, s: CGFloat, l: CGFloat) {
    AccentInk.hsl(color)
}

func runAccentInkTests() {

    suite("accent ink: every accent clears 4.5:1 on every accent paper, both modes") {
        for paper in AccentInk.papers {
            let modes: [Bool] = paper.paperColor == nil ? [false, true] : [false]
            for dark in modes {
                for (name, light, darkHex) in systemAccents {
                    let raw = rgb(dark ? darkHex : light)
                    let ink = AccentInk.ink(for: paper, accent: raw, dark: dark, highContrast: false)
                    for (surfaceName, surface) in accentSurfaces(for: paper, dark: dark) {
                        let r = Contrast.ratio(ink, surface)
                        check(r >= 4.5, "\(paper.rawValue)/\(dark ? "dark" : "light") \(name) on \(surfaceName): \(r2(r)):1")
                    }
                }
            }
        }
    }

    suite("accent ink: Increase Contrast reaches 7:1 and is never weaker") {
        for paper in AccentInk.papers {
            let modes: [Bool] = paper.paperColor == nil ? [false, true] : [false]
            for dark in modes {
                for (name, light, darkHex) in systemAccents {
                    let raw = rgb(dark ? darkHex : light)
                    let normal = AccentInk.ink(for: paper, accent: raw, dark: dark, highContrast: false)
                    let strong = AccentInk.ink(for: paper, accent: raw, dark: dark, highContrast: true)
                    for (surfaceName, surface) in accentSurfaces(for: paper, dark: dark) {
                        let r = Contrast.ratio(strong, surface)
                        check(r >= 7, "\(paper.rawValue)/\(dark ? "dark" : "light") \(name) high contrast on \(surfaceName): \(r2(r)):1")
                        check(r >= Contrast.ratio(normal, surface) - 0.001,
                              "\(paper.rawValue)/\(dark ? "dark" : "light") \(name): high contrast is at least as strong on \(surfaceName)")
                    }
                }
            }
        }
    }

    suite("accent ink: the user's hue survives, only lightness moves") {
        for paper in AccentInk.papers {
            for dark in [false, true] {
                for (name, light, darkHex) in systemAccents {
                    let raw = rgb(dark ? darkHex : light)
                    for hc in [false, true] {
                        let ink = AccentInk.ink(for: paper, accent: raw, dark: dark, highContrast: hc)
                        let a = hsl(raw), b = hsl(ink)
                        if a.s > 0.02 {
                            let dh = min(abs(a.h - b.h), 1 - abs(a.h - b.h))
                            check(dh < 0.01, "\(paper.rawValue) \(name)\(hc ? " hc" : ""): hue kept (\(r2(a.h)) vs \(r2(b.h)))")
                            check(abs(a.s - b.s) < 0.02, "\(paper.rawValue) \(name)\(hc ? " hc" : ""): saturation kept")
                        } else {
                            check(b.s < 0.03, "\(paper.rawValue) \(name)\(hc ? " hc" : ""): a grey accent stays grey")
                        }
                    }
                }
            }
        }
    }

    suite("accent ink: an accent that already passes is left exactly as picked") {
        let deep = rgb(0x1D4ED8)  // a deep blue, ~6.7:1 on white
        let ink = AccentInk.ink(for: .white, accent: deep, dark: false, highContrast: false)
        check(ink.isEqual(deep) || (abs(hsl(ink).l - hsl(deep).l) < 0.0001), "not darkened when it doesn't need it")
        let lightOnDark = rgb(0x9AD0FF)
        let dark = AccentInk.ink(for: .frosted, accent: lightOnDark, dark: true, highContrast: false)
        check(abs(hsl(dark).l - hsl(lightOnDark).l) < 0.0001, "nor lightened in dark mode")

        let blue = rgb(0x007AFF)
        check(Contrast.ratio(blue, .white) < 4.5, "the raw default blue really does fail on White (\(r2(Contrast.ratio(blue, .white))):1)")
        let fixed = AccentInk.ink(for: .white, accent: blue, dark: false, highContrast: false)
        check(hsl(fixed).l < hsl(blue).l, "so it is darkened on the light papers")
        let purple = rgb(0xA550A7)
        let fixedDark = AccentInk.ink(for: .solid, accent: purple, dark: true, highContrast: false)
        check(hsl(fixedDark).l > hsl(purple).l, "and purple is lightened in dark mode")
    }

    suite("accent ink: the papers wire it up as a live, shared dynamic colour") {
        for paper in [Appearance.frosted, .glass, .solid, .white, .cream] {
            check(paper.ink.accent === paper.ink.accent, "\(paper.rawValue): one shared instance, so InkTheme equality holds")
            check(paper.ink.accent !== NSColor.controlAccentColor, "\(paper.rawValue): no longer the raw system accent")
            let modes: [NSAppearance.Name] = paper.paperColor == nil ? [.aqua, .darkAqua] : [.aqua]
            for mode in modes {
                let resolved = Contrast.resolved(paper.ink.accent, in: NSAppearance(named: mode)!)
                for (surfaceName, surface) in accentSurfaces(for: paper, dark: mode == .darkAqua) {
                    let r = Contrast.ratio(resolved, surface)
                    check(r >= 4.5, "\(paper.rawValue)/\(mode.rawValue) live accent on \(surfaceName): \(r2(r)):1")
                }
            }
        }
        check(Appearance.frosted.ink.accent === Appearance.glass.ink.accent,
              "the translucent papers share one accent ink")
    }

    suite("accent ink: a theme note's custom paper gets the same treatment") {
        for hex in ["#223038", "#f4ecd8", "#1b1b1b", "#dfe8f2"] {
            let paper = ThemeNote.color(fromHex: hex)!
            let surfaces = [paper, ThemeNote.derivedChromeColor(for: paper), ThemeNote.derivedCardColor(for: paper)]
            for (name, light, darkHex) in systemAccents {
                for raw in [rgb(light), rgb(darkHex)] {
                    let ink = AccentInk.adjusted(raw, on: surfaces, minimum: 4.5)
                    let worst = surfaces.map { Contrast.ratio(ink, $0) }.min()!
                    check(worst >= 4.5, "theme paper \(hex) \(name): \(r2(worst)):1")
                }
            }
            let derived = ThemeNote.derivedInk(for: paper).accent
            check(derived === ThemeNote.derivedInk(for: paper).accent,
                  "theme paper \(hex): re-deriving keeps the same accent instance")
            let resolved = Contrast.resolved(derived, in: NSAppearance(named: .aqua)!)
            let worst = surfaces.map { Contrast.ratio(resolved, $0) }.min()!
            check(worst >= 4.5, "theme paper \(hex): live accent \(r2(worst)):1")
        }
    }
}
