import AppKit

// VoiceOver (design review C5): math results are only ever drawn, and image
// references are invisible markdown under a picture. These check what
// VoiceOver actually receives from a real ChecklistTextView, with VoiceOver
// itself and the announcement channel injected.

private func withVoiceOver(_ running: Bool, _ body: () -> Void) {
    let saved = VoiceOver.override
    VoiceOver.override = running
    defer { VoiceOver.override = saved }
    body()
}

/// Types `text` at the caret the way a keystroke does: through the
/// undo-aware replace path, which ends in `didChangeText()`.
private func type(_ text: String, into view: ChecklistTextView) {
    let caret = view.selectedRange()
    view.replace(range: caret, with: text, selecting: NSRange(location: caret.location + (text as NSString).length, length: 0))
}

private func caretAtEnd(of view: ChecklistTextView) {
    view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
}

func runVoiceOverTests() {

    suite("VoiceOver: the caret line's new result is announced once typing pauses") {
        withVoiceOver(true) {
            let view = makeTextView("price = 12\nprice * 4")
            var heard: [String] = []
            view.mathSpeech.post = { heard.append($0) }
            view.recomputeMathResults()
            caretAtEnd(of: view)

            type("0", into: view)  // price * 40 = 480
            check(view.mathSpeech.hasPendingAnnouncement, "an edit schedules an announcement")
            equal(heard, [], "nothing is said mid-typing")
            view.mathSpeech.speakPending(caretLocation: view.selectedRange().location, in: view.string as NSString)
            equal(heard, ["equals 480"], "the new result is announced after the pause")

            // An edit that leaves the result alone says nothing.
            view.mathSpeech.speakPending(caretLocation: view.selectedRange().location, in: view.string as NSString)
            equal(heard, ["equals 480"], "the same result is not repeated")
        }
    }

    suite("VoiceOver: turned on after the note loaded, the first edit is still announced") {
        let view = makeTextView("price = 12\nprice * 4")
        var heard: [String] = []
        view.mathSpeech.post = { heard.append($0) }
        withVoiceOver(false) { view.recomputeMathResults() }
        withVoiceOver(true) {
            caretAtEnd(of: view)
            type("0", into: view)  // price * 40 = 480
            view.mathSpeech.speakPending(caretLocation: view.selectedRange().location, in: view.string as NSString)
            equal(heard, ["equals 480"], "compared with the result before the edit, not after")
        }
    }

    suite("VoiceOver: only the caret line, and only real changes") {
        withVoiceOver(true) {
            let view = makeTextView("a = 2\nb = a * 3\nnotes")
            var heard: [String] = []
            view.mathSpeech.post = { heard.append($0) }
            view.recomputeMathResults()

            // Caret on the plain-text line: editing it changes no result there.
            caretAtEnd(of: view)
            type("!", into: view)
            view.mathSpeech.speakPending(caretLocation: view.selectedRange().location, in: view.string as NSString)
            equal(heard, [], "a line with no result says nothing")

            // Editing line 1 changes line 2's result too, but only line 1 is spoken.
            view.setSelectedRange(NSRange(location: 5, length: 0))  // after "a = 2"
            type("0", into: view)  // a = 20, b = 60
            view.mathSpeech.speakPending(caretLocation: view.selectedRange().location, in: view.string as NSString)
            equal(heard, ["equals 20"], "the caret line is spoken, not every line it affected")
        }
    }

    suite("VoiceOver: silent when VoiceOver is off, and on a note switch") {
        withVoiceOver(false) {
            let view = makeTextView("2 + 2")
            var heard: [String] = []
            view.mathSpeech.post = { heard.append($0) }
            view.recomputeMathResults()
            caretAtEnd(of: view)
            type("0", into: view)
            check(!view.mathSpeech.hasPendingAnnouncement, "no work is even scheduled without VoiceOver")
            view.mathSpeech.speakPending(caretLocation: view.selectedRange().location, in: view.string as NSString)
            equal(heard, [], "nothing is posted without VoiceOver")
        }
        withVoiceOver(true) {
            let view = makeTextView("2 + 2")
            var heard: [String] = []
            view.mathSpeech.post = { heard.append($0) }
            view.recomputeMathResults()
            view.loadNoteText("7 * 6")
            caretAtEnd(of: view)
            view.mathSpeech.speakPending(caretLocation: view.selectedRange().location, in: view.string as NSString)
            equal(heard, [], "a freshly loaded note's results are not announced as changes")
        }
    }

    suite("VoiceOver: the Results rotor steps through every drawn result") {
        let view = makeTextView("Groceries\n3 * 4\nmilk\n10 + 5")
        view.recomputeMathResults()
        let results = view.spokenMathResults
        equal(results.count, 2, "two lines carry results")

        let numbers = MathResultSpeech.lineNumbers(for: results, in: view.string as NSString)
        equal(numbers, [2, 4], "line numbers are 1-based and count every line")
        equal(results[0].rotorLabel(lineNumber: 2), "line 2 equals 12", "the rotor label says line and value")
        equal(results[0].announcement, "equals 12", "the announcement is just the value")

        check(view.accessibilityCustomRotors().contains { $0.label == "Results" }, "a Results rotor is offered")

        let labels = zip(results, numbers).map { $0.rotorLabel(lineNumber: $1) }
        let locations = results.map(\.lineRange.location)
        equal(MathResultSpeech.rotorIndex(labels: labels, locations: locations, from: nil, forward: true, filter: ""), 0,
              "next from nowhere is the first result")
        equal(MathResultSpeech.rotorIndex(labels: labels, locations: locations, from: nil, forward: false, filter: ""), 1,
              "previous from nowhere is the last result")
        equal(MathResultSpeech.rotorIndex(labels: labels, locations: locations, from: locations[0], forward: true, filter: ""), 1,
              "next from the first is the second")
        check(MathResultSpeech.rotorIndex(labels: labels, locations: locations, from: locations[1], forward: true, filter: "") == nil,
              "next from the last is the end")
        equal(MathResultSpeech.rotorIndex(labels: labels, locations: locations, from: nil, forward: true, filter: "15"), 1,
              "typing in the rotor filters by value")

        let rotor = NSAccessibilityCustomRotor(label: "Results", itemSearchDelegate: view)
        let params = NSAccessibilityCustomRotor.SearchParameters()
        params.searchDirection = .next
        let first = view.rotor(rotor, resultFor: params)
        equal(first?.customLabel, "line 2 equals 12", "the delegate hands back the first result's label")
        equal(first?.targetRange, results[0].lineRange, "and moves the VoiceOver cursor to its line")
        params.currentItem = first
        equal(view.rotor(rotor, resultFor: params)?.customLabel, "line 4 equals 15", "then the next one")
    }

    suite("VoiceOver: a drawn image reads as \"Image\", not its markdown") {
        let reference = "![320](Attachments/1234.png)"
        let text = "Look: \(reference) done\n\(reference)"
        let view = makeTextView(text)
        let ns = text as NSString
        let first = ns.range(of: reference)
        let second = NSRange(location: ns.length - (reference as NSString).length, length: (reference as NSString).length)

        // No such file on disk, so styling leaves it visible: it stays text.
        equal(view.loadedImageReferenceRanges(), [], "a reference with no picture drawn is not substituted")
        equal(view.accessibilityString(for: NSRange(location: 0, length: ns.length)), text,
              "and reads exactly as typed")

        // What styling does for a loaded image: paint the markdown out.
        view.textStorage?.addAttribute(.foregroundColor, value: NSColor.clear, range: first)
        view.textStorage?.addAttribute(.foregroundColor, value: NSColor.clear, range: second)
        equal(view.loadedImageReferenceRanges(), [first, second], "painted-out references are the loaded ones")

        equal(view.accessibilityString(for: NSRange(location: 0, length: ns.length)), "Look: Image done\nImage",
              "each image reads as one word")
        let lineTwo = ns.lineRange(for: second)
        equal(view.accessibilityString(for: second), "Image", "an image-only line reads as Image")
        equal(view.accessibilityString(for: lineTwo), "Image", "and so does its line")
        equal(view.accessibilityString(for: NSRange(location: 0, length: 5)), "Look:",
              "text beside an image is untouched")
        equal(view.accessibilityAttributedString(for: NSRange(location: 0, length: ns.length))?.string,
              "Look: Image done\nImage", "the attributed form matches")

        equal(ImageSpeech.substitute("abcdef", range: NSRange(location: 10, length: 6),
                                     imageRanges: [NSRange(location: 12, length: 20)]),
              "abImage", "a range cut through an image still says Image once")
    }
}
