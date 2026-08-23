import AppKit
import Foundation

// Coverage for theme-as-note: keyword detection, the key:value grammar, the
// bottom-most-note-wins rule, and the derived palettes that keep a custom
// hex paper looking intentional.

func runThemeNoteTests() {

    suite("only a bare first-line theme activates") {
        check(ThemeNote.isActive("theme"), "the bare word")
        check(ThemeNote.isActive("  THEME \nsize: 12"), "case-insensitive, whitespace tolerated")
        check(!ThemeNote.isActive("# theme"), "a heading named theme is not one")
        check(!ThemeNote.isActive("theme park"), "whole-line exact, like the list keyword")
        check(!ThemeNote.isActive("listen to the podcast"), "ordinary notes stay ordinary")
        check(!ThemeNote.isActive(""), "and so does an empty one")
    }

    suite("parses every key in the grammar") {
        let theme = ThemeNote.parse("""
        theme
        paper: #223038
        tint: amber
        ink: #e8e4d8
        accent: #7cc4ff
        font: Avenir Next
        size: 14
        spacing: 1.3
        tracking: 0.5
        guides: dots
        """)
        check(theme != nil, "a full theme parses")
        equal(theme?.fontName, "Avenir Next", "font values keep their spaces")
        equal(theme?.fontSize, 14, "sizes parse as numbers")
        equal(theme?.lineSpacing, 1.3, "spacing parses too")
        equal(theme?.letterSpacing, 0.5, "as does tracking")
        equal(theme?.guide, .dots, "guides parse by raw name")

        // Colours are compared by round-tripping back to hex components.
        func hex(_ color: NSColor?) -> String {
            guard let s = color?.usingColorSpace(.sRGB) else { return "-" }
            return String(
                format: "%02x%02x%02x",
                Int(round(s.redComponent * 255)),
                Int(round(s.greenComponent * 255)),
                Int(round(s.blueComponent * 255))
            )
        }
        equal(hex(theme?.paperHex), "223038", "paper hex lands exactly")
        equal(hex(theme?.inkHex), "e8e4d8", "as do ink and accent")
        equal(hex(theme?.accentHex), "7cc4ff", "accent too, then")
        equal(theme?.tint, .amber, "and the tint parses by name")
    }

    suite("bad values are skipped, never fatal") {
        let theme = ThemeNote.parse("""
        theme
        paper: plaid
        size: banana
        spacing: 9
        tracking: -40
        guides: paisley
        some commentary line
        font:
        """)
        check(theme != nil, "an unparseable value does not discard the theme")

        // Everything invalid fell through; nothing valid was set.
        check(theme?.paperHex == nil, "a non-hex paper is ignored")
        check(theme?.fontSize == nil, "a non-numeric size is ignored")
        check(theme?.lineSpacing == nil, "spacing outside 0.8...2.5 is ignored")
        check(theme?.letterSpacing == nil, "tracking outside -1...4 is ignored")
        check(theme?.guide == nil, "an unknown guide name is ignored")
        check(theme?.fontName == nil, "an empty font value is ignored")
    }

    suite("clamps match the settings sliders") {
        let theme = ThemeNote.parse("theme\nsize: 200\nspacing: 1.1")
        equal(theme?.fontSize, SettingsManager.fontSizeRange.upperBound, "sizes clamp to the same range as the slider")
        equal(theme?.lineSpacing, 1.1, "in-range spacing passes through untouched")
    }

    suite("hex parsing accepts both spellings") {
        check(ThemeNote.color(fromHex: "#ff8800") != nil, "with the hash")
        check(ThemeNote.color(fromHex: "ff8800") != nil, "without it")
        check(ThemeNote.color(fromHex: "#f80") == nil, "three-digit shorthand is not supported")
        check(ThemeNote.color(fromHex: "#ff88") == nil, "nor four digits")
        check(ThemeNote.color(fromHex: "") == nil, "and neither does nothing at all")
    }

    suite("the bottom-most theme note wins") {
        let top = Note(text: "theme\nsize: 11")
        let middle = Note(text: "groceries")
        let bottom = Note(text: "THEME\nsize: 16")

        let winner = ThemeNote.active(in: [top, middle, bottom])
        equal(winner?.fontSize, 16, "later in the stack beats earlier")

        let onlyProse = ThemeNote.active(in: [middle])
        check(onlyProse == nil, "no theme note means no override")
    }

    suite("derived ink follows the paper's polarity") {
        let lightPaper = NSColor(srgbRed: 0.95, green: 0.93, blue: 0.90, alpha: 1)
        let darkPaper = NSColor(srgbRed: 0.13, green: 0.19, blue: 0.22, alpha: 1)

        for (paper, label) in [(lightPaper, "light paper"), (darkPaper, "dark paper")] {
            let ink = ThemeNote.derivedInk(for: paper)
            let textLuminance = ThemeNote.luminance(of: ink.text)
            let paperLuminance = ThemeNote.luminance(of: paper)
            if paperLuminance > 0.5 {
                check(textLuminance < paperLuminance, "\(label) gets darker-than-paper ink")
            } else {
                check(textLuminance > paperLuminance, "\(label) gets lighter-than-paper ink")
            }
            // Secondary must differ from text or hierarchy collapses.
            check(ThemeNote.luminance(of: ink.secondary) != textLuminance,
                  "\(label) gets a distinct secondary tone")
        }
    }

    suite("derived card and chrome neighbours step off the page") {
        let paper = NSColor(srgbRed: 0.969, green: 0.941, blue: 0.882, alpha: 1)  // cream-ish
        let card = ThemeNote.derivedCardColor(for: paper)
        let chrome = ThemeNote.derivedChromeColor(for: paper)
        let cardBrightness = card.usingColorSpace(.sRGB)!.brightnessComponent
        let chromeBrightness = chrome.usingColorSpace(.sRGB)!.brightnessComponent
        let paperBrightness = paper.usingColorSpace(.sRGB)!.brightnessComponent
        check(cardBrightness > paperBrightness, "the card lifts above the page")
        check(chromeBrightness < paperBrightness, "chrome sinks below it")
    }
}
