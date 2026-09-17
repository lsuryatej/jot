import AppKit
import Carbon.HIToolbox
import Foundation

// Pre-release coverage for shipped features an audit found untested: the
// currency snapshot and math formatting, selection-math display, repeated
// search hits, link shrinking edges, theme notes flowing into effective
// settings, backup pruning, attachment saving, and hotkey persistence.

private func formatted(_ line: String) -> String? {
    var env: [String: MathExpression.Value] = [:]
    guard let node = MathExpression.parse(line) else { return nil }
    guard case .success(let value) = MathExpression.evaluate(node, environment: &env) else { return nil }
    return MathExpression.format(value)
}

private func amount(_ line: String) -> Double? {
    var env: [String: MathExpression.Value] = [:]
    guard let node = MathExpression.parse(line) else { return nil }
    guard case .success(let value) = MathExpression.evaluate(node, environment: &env) else { return nil }
    return value.amount
}

/// A throwaway defaults suite that also skips the one-time import from the
/// old StickyNotes bundle: without the sentinel, `SettingsManager.init` copies
/// whatever that real domain holds on this machine into the suite.
private func isolatedDefaults() -> (UserDefaults, String) {
    let name = "JotTests.coverage-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.set(true, forKey: "migratedSettingsFromStickyNotesBundle")
    return (defaults, name)
}

private func hex(_ color: NSColor?) -> String {
    guard let s = color?.usingColorSpace(.sRGB) else { return "-" }
    return String(
        format: "%02x%02x%02x",
        Int(round(s.redComponent * 255)),
        Int(round(s.greenComponent * 255)),
        Int(round(s.blueComponent * 255))
    )
}

private func tempDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jot-coverage-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func bitmapImage(width: Int, height: Int) -> NSImage {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let image = NSImage(size: NSSize(width: width, height: height))
    image.addRepresentation(rep)
    return image
}

func runCoverageGapTests() {

    // MARK: - Math and currency

    suite("explicit currency conversion uses the built-in snapshot when live rates are off") {
        let wasEnabled = CurrencyRates.liveRatesEnabled
        CurrencyRates.liveRatesEnabled = false
        defer { CurrencyRates.liveRatesEnabled = wasEnabled }

        // 50 / 0.0114 = 4385.9649..., which the README rounds to 4385.96.
        equal(formatted("50 usd to inr"), "4385.9649 inr", "the README example, as the margin shows it")
        equal(amount("50 usd to inr").map { ($0 * 100).rounded() / 100 }, 4385.96, "and matches the README to the cent")
        equal(formatted("50 USD to INR"), "4385.9649 inr", "codes are case-insensitive; the result is lowercased")
        equal(formatted("1 eur to usd"), "1.17 usd", "eur snapshot")
        equal(formatted("100 jpy to usd"), "0.67 usd", "jpy snapshot")
        equal(formatted("1 gbp to eur"), "1.1453 eur", "cross rate goes through usd")
        equal(formatted("100 usd to zzz"), nil, "a currency with no rate does not evaluate")
    }

    suite("plus and minus read as operators") {
        equal(formatted("5 plus 3"), "8", "plus")
        equal(formatted("10 minus 4"), "6", "minus")
        equal(formatted("100 plus 10%"), "110", "plus takes a trailing percentage like +")
        equal(formatted("100 MINUS 10%"), "90", "case-insensitive")
    }

    suite("result formatting") {
        equal(formatted("20%"), "20%", "a bare percentage keeps its sign, no space")
        equal(formatted("10% + 20%"), "30%", "summed percentages stay percentages")
        equal(formatted("10 / 3"), "3.3333", "four decimals at most")
        equal(formatted("0.1 + 0.2"), "0.3", "trailing zeros trimmed")
        equal(formatted("1000000 * 1000000000"), "1000000000000000", "1e15 exactly still prints as digits")
        // Past 1e15 the Int path is skipped, so values beyond Int.max must not trap.
        equal(formatted("2 ^ 60"), "1152921504606846976", "large integer")
        equal(formatted("2 ^ 70"), "1180591620717411303424", "beyond Int.max")
        equal(formatted("-(2 ^ 70)"), "-1180591620717411303424", "and its negative")
    }

    suite("an unknown identifier after a number is carried as a unit") {
        equal(formatted("5 apples + 3 apples"), "8 apples", "same unknown unit adds")
        equal(formatted("5 foo * 2"), "10 foo", "and scales")
        equal(formatted("3 abc + 2 abc"), "5 abc", "a three-letter unknown is a currency with itself")
        equal(formatted("5 apples to kg"), nil, "but cannot be converted")
        equal(formatted("5 apples"), nil, "on its own it is still prose")
    }

    // MARK: - Selection math display

    suite("selection math summary") {
        // SelectionMath's formatter follows Locale.current with no injection
        // point, so exact strings are only asserted where every Latin-digit
        // locale agrees: small integers.
        equal(SelectionMath.of("10 20 30")?.summary, "Sum 60 · Avg 20", "summary shape")
        equal(SelectionMath.format(-7), "-7", "negative integer")

        let third = SelectionMath.format(1.0 / 3)
        let separator = Locale.current.decimalSeparator ?? "."
        let fraction = third.components(separatedBy: separator).last ?? ""
        equal(fraction.count, 4, "fractions cap at four digits")

        let mirror = NumberFormatter()
        mirror.numberStyle = .decimal
        mirror.usesGroupingSeparator = true
        mirror.maximumFractionDigits = 4
        equal(SelectionMath.format(1234567.891), mirror.string(from: 1234567.891), "grouping follows the current locale")
    }

    // MARK: - Global search

    suite("two matches on one line are two results") {
        let hits = GlobalSearch.find("cat", in: [Note(text: "cat and cat\ndog")])
        equal(hits.count, 2, "both occurrences")
        equal(hits.map(\.lineNumber), [1, 1], "on the same line")
        equal(hits.map(\.matchRange.location), [0, 8], "at their own offsets")
        equal(hits.map(\.snippet), ["cat and cat", "cat and cat"], "sharing the snippet")
        equal(Set(hits.map(\.id)).count, 2, "with distinct ids, so a list can show both")
    }

    suite("search matches do not overlap") {
        equal(GlobalSearch.find("aa", in: [Note(text: "aaaa")]).count, 2, "aaaa holds two aa")
        equal(GlobalSearch.find("aa", in: [Note(text: "aaa")]).count, 1, "aaa holds one")
    }

    // MARK: - Link shrink

    func shrunk(_ text: String) -> [String] {
        let ns = text as NSString
        return LinkShrink.matches(in: text).map { ns.substring(with: $0.range) + " | " + ns.substring(with: $0.displayRange) }
    }

    suite("link shrink edges") {
        equal(shrunk("see example.com/articles/one/two"), ["example.com/articles/one/two | example.com"],
              "a link without a scheme still shrinks")
        equal(shrunk("see https://example.com/articles/one."), ["https://example.com/articles/one | example.com"],
              "a sentence-ending period stays outside the link")
        equal(shrunk("https://example.com/articles/one, then"), ["https://example.com/articles/one | example.com"],
              "as does a comma")
        equal(shrunk("(https://www.example.com/articles/one)"), ["https://www.example.com/articles/one | example.com"],
              "wrapping parens stay out, and www. is not displayed")
        equal(shrunk("see https://example.com/a."), [], "too short to be worth shrinking")
    }

    // MARK: - Theme notes into effective settings

    suite("an active theme note drives the effective settings") {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        settings.appearance = .glass
        settings.glassTint = .none
        settings.guide = .none
        settings.lineSpacing = 1.0
        settings.letterSpacing = 0

        let notes = [
            Note(text: "shopping\neggs"),
            Note(text: "theme\npaper: #223038\nink: #e8e4d8\nspacing: 1.4\ntracking: 0.5\nguides: grid"),
        ]
        settings.themeOverride = ThemeNote.active(in: notes)

        equal(hex(settings.effectivePaperColor), "223038", "paper comes from the note")
        equal(hex(settings.effectiveInk.text), "e8e4d8", "explicit ink is used verbatim")
        equal(settings.effectiveLineSpacing, 1.4, "line spacing")
        equal(settings.effectiveLetterSpacing, 0.5, "tracking")
        equal(settings.effectiveGuide, .grid, "guides")
        check(!settings.effectiveWantsLitEdge, "an opaque theme paper drops glass's lit edge")
        check(settings.effectiveWantsOpaqueCards, "and makes cards opaque")
        equal(hex(settings.effectiveChromeColor), hex(ThemeNote.derivedChromeColor(for: settings.effectivePaperColor!)),
              "chrome derives from the paper")
        equal(hex(settings.effectiveCardColor), hex(ThemeNote.derivedCardColor(for: settings.effectivePaperColor!)),
              "cards derive from the paper")
        equal(settings.effectiveHairlineColor, NSColor.white, "a dark paper gets a light hairline")

        settings.themeOverride = ThemeNote.active(in: [Note(text: "shopping\neggs")])
        check(settings.themeOverride == nil, "removing the theme note clears the override")
        check(settings.effectivePaperColor == nil, "glass is translucent again")
        equal(settings.effectiveInk, InkTheme.system, "ink falls back to the appearance's")
        equal(settings.effectiveLineSpacing, 1.0, "spacing falls back")
        equal(settings.effectiveLetterSpacing, 0, "tracking falls back")
        equal(settings.effectiveGuide, .none, "guides fall back")
        check(settings.effectiveWantsLitEdge, "and glass gets its lit edge back")
    }

    suite("a theme without ink derives it; a tint-only theme leaves the paper alone") {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        settings.appearance = .cream
        settings.glassTint = .none

        settings.themeOverride = ThemeNote.parse("theme\npaper: #f4f1ea")
        let paper = settings.effectivePaperColor!
        equal(hex(settings.effectiveInk.text), hex(ThemeNote.derivedInk(for: paper).text), "ink derived from the paper")
        check(ThemeNote.luminance(of: settings.effectiveInk.text) < 0.5, "a light paper gets dark ink")
        equal(settings.effectiveHairlineColor, NSColor.black, "and a dark hairline")

        settings.themeOverride = ThemeNote.parse("theme\ntint: amber")
        equal(settings.effectiveTint, .amber, "the note's tint wins")
        equal(hex(settings.effectivePaperColor), hex(Appearance.cream.paperColor), "the picked paper stays")
        equal(settings.effectiveInk, Appearance.cream.ink, "and so does its ink")

        settings.themeOverride = nil
        equal(settings.effectiveTint, GlassTint.none, "tint falls back to the picked one")
    }

    suite("the bottom-most theme note is the one in force") {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        settings.themeOverride = ThemeNote.active(in: [
            Note(text: "theme\npaper: #111111\nguides: dots"),
            Note(text: "theme\npaper: #eeeeee"),
        ])
        equal(hex(settings.effectivePaperColor), "eeeeee", "later note wins")
        equal(settings.effectiveGuide, settings.guide, "keys it omits are not inherited from the earlier theme")
    }

    // MARK: - Backups

    suite("dated backups are pruned to the newest ten") {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NoteStore(fileURL: dir.appendingPathComponent("notes.json"), allowsLegacyMigration: false)
        store.save([Note(text: "keep me")])

        let backups = store.backupDirectoryURL
        try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let seeded = (1...12).map { String(format: "notes-20200101-0000%02d.json", $0) }
        for file in seeded {
            try? Data("[]".utf8).write(to: backups.appendingPathComponent(file))
        }

        _ = store.load()

        let names = ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []).sorted()
        let dated = names.filter { $0.hasPrefix("notes-") }
        equal(dated.count, NoteStore.backupsKept, "exactly ten dated copies remain")
        check(!dated.contains(seeded[0]) && !dated.contains(seeded[2]), "the oldest were removed")
        check(dated.contains(seeded[11]), "the newest seeded copy survives")
        check(dated.contains { !seeded.contains($0) }, "and this launch's copy is among them")
        check(names.contains("notes.backup.json"), "the undated backup is kept and not counted")
    }

    suite("a blank store writes no backup") {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NoteStore(fileURL: dir.appendingPathComponent("notes.json"), allowsLegacyMigration: false)
        store.save([Note(text: "")])
        _ = store.load()
        check(!FileManager.default.fileExists(atPath: store.backupDirectoryURL.path), "no Backups directory at all")
    }

    // MARK: - Attachments

    suite("saving an attachment") {
        let base = tempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = Attachments.directoryURL(base: base)

        let path = try? Attachments.save(bitmapImage(width: 30, height: 20), in: directory)
        check(path?.hasPrefix("Attachments/") == true, "returns a note-relative path")
        check(path?.hasSuffix(".png") == true, "as a png")
        if let path {
            check(FileManager.default.fileExists(atPath: base.appendingPathComponent(path).path), "the file exists")
            let loaded = Attachments.image(at: path, in: base)
            let rep = loaded?.representations.first
            equal(rep?.pixelsWide, 30, "and decodes at its pixel width")
            equal(rep?.pixelsHigh, 20, "and height")
        }
        let second = try? Attachments.save(bitmapImage(width: 4, height: 4), in: directory)
        check(second != nil && second != path, "each save gets its own name")
    }

    suite("default attachment width") {
        equal(Attachments.defaultWidth(for: NSImage(size: NSSize(width: 1000, height: 10))), 320, "capped at 320")
        equal(Attachments.defaultWidth(for: NSImage(size: NSSize(width: 200, height: 10))), 200, "natural width in range")
        equal(Attachments.defaultWidth(for: NSImage(size: NSSize(width: 10, height: 10))), 48, "floored at 48")
        equal(Attachments.defaultWidth(for: NSImage(size: NSSize(width: 1000, height: 10)), maximum: 500), 500,
              "the cap is adjustable")
    }

    // MARK: - Hotkey

    suite("NSEvent modifier flags map to Carbon modifiers") {
        func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
            KeyCombo.carbonModifiers(from: flags.rawValue)
        }
        equal(carbon(.command), UInt32(cmdKey), "command")
        equal(carbon(.option), UInt32(optionKey), "option")
        equal(carbon(.control), UInt32(controlKey), "control")
        equal(carbon(.shift), UInt32(shiftKey), "shift")
        equal(carbon([.command, .shift, .option, .control]),
              UInt32(cmdKey | shiftKey | optionKey | controlKey), "all four combine")
        equal(carbon([.capsLock, .function, .numericPad]), 0, "other flags are ignored")
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: carbon([.command, .shift]))
        equal(combo.displayString, "⇧⌘J", "and render in the standard order")
    }

    suite("the hotkey persists across a relaunch") {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        equal(SettingsManager(defaults: defaults).hotKey, KeyCombo.default, "fresh installs get the default")

        let picked = KeyCombo(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(cmdKey | shiftKey))
        SettingsManager(defaults: defaults).hotKey = picked
        equal(SettingsManager(defaults: defaults).hotKey, picked, "a picked combo round-trips")

        defaults.set(0, forKey: "hotKeyModifiers")
        equal(SettingsManager(defaults: defaults).hotKey, KeyCombo.default,
              "a stored modifier-less combo falls back to the default")
    }
}
