import AppKit

/// Whether VoiceOver is running, injectable for tests.
enum VoiceOver {
    /// Set by tests. Nil means ask the system.
    nonisolated(unsafe) static var override: Bool?

    static var isRunning: Bool {
        override ?? NSWorkspace.shared.isVoiceOverEnabled
    }
}

// MARK: - Math results

/// One drawn math result, as VoiceOver hears it.
struct SpokenMathResult: Equatable {
    /// The line the result belongs to, without its terminator.
    var lineRange: NSRange
    var text: String
    /// A reason instead of a number (see `ChecklistTextView.mathResults`).
    var isHint: Bool

    /// What is announced when the caret line's result changes.
    var announcement: String {
        isHint ? text : "equals \(text)"
    }

    /// The Results rotor's entry, with the 1-based line number VoiceOver
    /// users navigate by.
    func rotorLabel(lineNumber: Int) -> String {
        isHint ? "line \(lineNumber), \(text)" : "line \(lineNumber) equals \(text)"
    }
}

/// Speaks math results, which the editor otherwise only draws in the margin
/// (`drawMathResults`), so VoiceOver never saw them at all.
///
/// When the result on the caret's line changes, and the typing has paused
/// long enough to be worth interrupting, it posts an announcement such as
/// "equals 48". Only the caret line: a variable edited on line 2 may change
/// ten results below it, and reading all ten on every keystroke would drown
/// out the typing echo.
///
/// Nothing runs unless VoiceOver does.
final class MathResultSpeech {
    /// Typing pause before the result is announced.
    static let defaultDelay: TimeInterval = 0.6

    var delay = MathResultSpeech.defaultDelay
    /// Where announcements go. Tests replace it with a spy.
    var post: (String) -> Void = MathResultSpeech.postToVoiceOver

    /// The results as of the last recompute.
    private(set) var latest: [SpokenMathResult] = []
    /// What each line's result was when last spoken (or when the note
    /// loaded), keyed by the line's start. Nil means take the next recompute
    /// as the new starting point without announcing anything.
    private var committed: [Int: String]?
    private var pending: DispatchWorkItem?

    /// Called after every recompute, user edit or not.
    func resultsUpdated(_ results: [SpokenMathResult]) {
        latest = results
        guard VoiceOver.isRunning else {
            // Keep the baseline current while VoiceOver is off. Cleared here,
            // the first edit after VoiceOver came on would be snapshotted as
            // its own baseline (the storage delegate recomputes before
            // `didChangeText`) and its new result never announced.
            committed = Self.snapshot(results)
            return
        }
        if committed == nil { committed = Self.snapshot(results) }
    }

    /// A different note is about to be loaded: its results are a starting
    /// point, not a change.
    func rebase() {
        pending?.cancel()
        pending = nil
        committed = nil
    }

    /// Called after a user edit. `caret` is read when the pause ends, so a
    /// caret that moved on meanwhile is where the answer is looked up.
    func userEdited(caret: @escaping () -> (location: Int, text: NSString)?) {
        guard VoiceOver.isRunning else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let caret = caret() else { return }
            self.speakPending(caretLocation: caret.location, in: caret.text)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The end of the pause: announces the caret line's result if it differs
    /// from the last one spoken for that line. Returns what was announced.
    @discardableResult
    func speakPending(caretLocation: Int, in text: NSString) -> String? {
        pending?.cancel()
        pending = nil
        defer { committed = Self.snapshot(latest) }
        guard VoiceOver.isRunning else { return nil }
        let location = min(max(0, caretLocation), text.length)
        let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
        guard let result = latest.first(where: { $0.lineRange.location == lineStart }) else { return nil }
        guard committed?[lineStart] != result.text else { return nil }
        let phrase = result.announcement
        post(phrase)
        return phrase
    }

    var hasPendingAnnouncement: Bool { pending != nil }

    private static func snapshot(_ results: [SpokenMathResult]) -> [Int: String] {
        Dictionary(results.map { ($0.lineRange.location, $0.text) }, uniquingKeysWith: { _, last in last })
    }

    static func postToVoiceOver(_ phrase: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: phrase,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    // MARK: Rotor

    /// 1-based line numbers for each result, in one pass over the text.
    static func lineNumbers(for results: [SpokenMathResult], in text: NSString) -> [Int] {
        var numberByStart: [Int: Int] = [:]
        var number = 0
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: [.byLines, .substringNotRequired]
        ) { _, range, _, _ in
            number += 1
            numberByStart[range.location] = number
        }
        return results.map { numberByStart[$0.lineRange.location] ?? 1 }
    }

    /// The rotor step from `currentLocation` (nil: from the start or end)
    /// in the given direction, among results whose label contains `filter`.
    static func rotorIndex(
        labels: [String], locations: [Int], from currentLocation: Int?, forward: Bool, filter: String
    ) -> Int? {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let candidates = labels.indices.filter {
            needle.isEmpty || labels[$0].localizedCaseInsensitiveContains(needle)
        }
        guard let current = currentLocation else {
            return forward ? candidates.first : candidates.last
        }
        return forward
            ? candidates.first { locations[$0] > current }
            : candidates.last { locations[$0] < current }
    }
}

// MARK: - Images

/// Image references are painted out and the picture drawn over them, so the
/// markdown underneath (`![320](Attachments/…png)`) is invisible text. VoiceOver
/// used to read that path aloud character for character. Here each loaded
/// reference reads as the single word "Image" instead.
enum ImageSpeech {
    static let word = "Image"

    /// The parts of `range` covered by an image reference, relative to
    /// `range.location`, last first so replacing them in order keeps earlier
    /// offsets valid.
    static func replacements(in range: NSRange, imageRanges: [NSRange]) -> [NSRange] {
        imageRanges
            .compactMap { image -> NSRange? in
                let overlap = NSIntersectionRange(image, range)
                guard overlap.length > 0 else { return nil }
                return NSRange(location: overlap.location - range.location, length: overlap.length)
            }
            .sorted { $0.location > $1.location }
    }

    static func substitute(_ spoken: String, range: NSRange, imageRanges: [NSRange]) -> String {
        let mutable = NSMutableString(string: spoken)
        for piece in replacements(in: range, imageRanges: imageRanges)
        where piece.location + piece.length <= mutable.length {
            mutable.replaceCharacters(in: piece, with: word)
        }
        return mutable as String
    }

    static func substitute(_ spoken: NSAttributedString, range: NSRange, imageRanges: [NSRange]) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: spoken)
        for piece in replacements(in: range, imageRanges: imageRanges)
        where piece.location + piece.length <= mutable.length {
            let attributes = mutable.attributes(at: piece.location, effectiveRange: nil)
            mutable.replaceCharacters(in: piece, with: NSAttributedString(string: word, attributes: attributes))
        }
        return mutable
    }
}

// MARK: - The text view's side

extension ChecklistTextView: NSAccessibilityCustomRotorItemSearchDelegate {

    /// A user edit (typing, paste, a checklist toggle through `replace`),
    /// never a programmatic `string =`: the caret line's result is looked at
    /// once the typing pauses.
    override func didChangeText() {
        super.didChangeText()
        mathSpeech.userEdited { [weak self] in
            guard let self else { return nil }
            return (self.selectedRange().location, self.string as NSString)
        }
    }

    /// Ranges of image references whose picture is actually drawn: the ones
    /// styling painted out with a clear foreground. A reference whose file
    /// is missing is left visible as text, so it keeps reading as text too.
    func loadedImageReferenceRanges() -> [NSRange] {
        guard let textStorage else { return [] }
        let ns = textStorage.string as NSString
        guard ns.range(of: "![").location != NSNotFound else { return [] }
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { line, lineRange, _, _ in
            guard let line else { return }
            for reference in Attachments.references(in: line) {
                let range = NSRange(location: lineRange.location + reference.range.location, length: reference.range.length)
                guard range.location < textStorage.length else { continue }
                let color = textStorage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
                if let color, color.alphaComponent == 0 { ranges.append(range) }
            }
        }
        return ranges
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let spoken = super.accessibilityString(for: range)
        let images = loadedImageReferenceRanges()
        guard let spoken, !images.isEmpty else { return spoken }
        return ImageSpeech.substitute(spoken, range: range, imageRanges: images)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        let spoken = super.accessibilityAttributedString(for: range)
        let images = loadedImageReferenceRanges()
        guard let spoken, !images.isEmpty else { return spoken }
        return ImageSpeech.substitute(spoken, range: range, imageRanges: images)
    }

    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        super.accessibilityCustomRotors() + [NSAccessibilityCustomRotor(label: "Results", itemSearchDelegate: self)]
    }

    /// The "Results" rotor: VO-U, then arrow to Results, steps through every
    /// line with a drawn result, reading "line 4 equals 48" and moving the
    /// VoiceOver cursor to that line.
    public func rotor(
        _ rotor: NSAccessibilityCustomRotor,
        resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        let results = spokenMathResults
        guard !results.isEmpty else { return nil }
        let text = string as NSString
        let numbers = MathResultSpeech.lineNumbers(for: results, in: text)
        let labels = zip(results, numbers).map { $0.rotorLabel(lineNumber: $1) }
        let current = searchParameters.currentItem.flatMap { item -> Int? in
            item.targetRange.location == NSNotFound ? nil : item.targetRange.location
        }
        guard let index = MathResultSpeech.rotorIndex(
            labels: labels,
            locations: results.map(\.lineRange.location),
            from: current,
            forward: searchParameters.searchDirection == .next,
            filter: searchParameters.filterString
        ) else { return nil }

        let item = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        item.targetRange = results[index].lineRange
        item.customLabel = labels[index]
        return item
    }
}
