import AppKit
import Foundation

// Coverage for plain markdown bullets (`- milk`): the pure parser in
// Checklist.swift, the precedence rules that keep checkboxes and ordered
// markers winning where they overlap, and Return continuation through the real
// text view.

func runBulletListTests() {

    // MARK: - Parsing

    suite("parses a plain bullet") {
        let parsed = Bullet.item(in: "- buy milk")
        check(parsed != nil, "- buy milk is a bullet")
        equal(parsed?.body, "buy milk", "the body is what follows the separator")
        equal(parsed?.indent, "", "an unindented bullet has no indent")
        equal(parsed?.markerRange, NSRange(location: 0, length: 1), "marker range covers the dash alone")
    }

    suite("parses indent and tab separators") {
        let indented = Bullet.item(in: "    - flour")
        equal(indented?.indent, "    ", "leading whitespace is captured")
        equal(indented?.body, "flour", "indentation does not disturb the body")
        equal(indented?.markerRange, NSRange(location: 4, length: 1), "range starts after the indent")

        equal(Bullet.item(in: "\t- eggs")?.indent, "\t", "a tab indents as well as spaces")
        equal(Bullet.item(in: "-\tmilk")?.body, "milk", "a tab separates as well as a space")
        equal(Bullet.item(in: "-   milk")?.body, "milk", "extra separator spaces are not body")
    }

    suite("accepts a bare dash as an empty bullet") {
        let bare = Bullet.item(in: "-")
        check(bare != nil, "a lone dash is an empty bullet, the way a lone 1. is an empty ordered item")
        equal(bare?.body, "", "with nothing after it")
        equal(Bullet.item(in: "  -")?.indent, "  ", "even indented")
        equal(Bullet.item(in: "-   ")?.body.trimmingCharacters(in: .whitespaces), "",
              "a dash and nothing but spaces is still empty")
    }

    suite("rejects prose and rules that merely start with a dash") {
        check(Bullet.item(in: "---") == nil, "a horizontal rule is not a bullet")
        check(Bullet.item(in: "  ---  ") == nil, "an indented rule is not either")
        check(Bullet.item(in: "--") == nil, "two dashes are not a marker")
        check(Bullet.item(in: "-5 degrees") == nil, "no separator means it stays prose")
        check(Bullet.item(in: "-- dashed aside") == nil, "a double-dash aside keeps its ordinary newline")
        check(Bullet.item(in: "hello world") == nil, "plain prose")
        check(Bullet.item(in: "") == nil, "the empty line")
        check(Bullet.item(in: "   ") == nil, "a whitespace-only line")
        check(Bullet.item(in: "1. eggs") == nil, "ordered markers are not bullets")
        check(Bullet.item(in: "# Heading") == nil, "headings are their own structure")
    }

    suite("asterisks and pluses are not bullets here") {
        check(Bullet.item(in: "* buy milk") == nil, "`*` belongs to emphasis and math in this app")
        check(Bullet.item(in: "+ buy milk") == nil, "`+` stays arithmetic for the same reason")
        check(Bullet.item(in: "*italic* opener") == nil, "an emphasis span at line start is never a list")
    }

    suite("checkbox lines are checkboxes, not bullets") {
        check(Bullet.item(in: "- [ ] task") == nil, "an unchecked box outranks the dash it is written with")
        check(Bullet.item(in: "- [x] done") == nil, "a checked box too")
        check(Bullet.item(in: "  - [ ] nested") == nil, "indented boxes as well")
        check(Bullet.item(in: "- [ ]") == nil, "a bare marker with no body is still a box")
        check(Checklist.item(in: "- buy milk") == nil, "and the reverse: a plain bullet is not a checklist item")
    }

    // MARK: - Return behaviour

    suite("newline continues a bullet") {
        equal(Bullet.newline(inLine: "- buy milk"), Bullet.Newline.continueList("\n- "),
              "the next bullet is generated, not typed")
        equal(Bullet.newline(inLine: "    - flour"), Bullet.Newline.continueList("\n    - "),
              "the new line keeps the item's indent")
        equal(Bullet.newline(inLine: "\t- eggs"), Bullet.Newline.continueList("\n\t- "),
              "a tab indent carries forward exactly as typed")
        equal(Bullet.newline(inLine: "-\tmilk"), Bullet.Newline.continueList("\n- "),
              "the generated separator is always one space, like every marker this app writes")
    }

    suite("newline exits on empty bullets and passes prose through") {
        equal(Bullet.newline(inLine: "- "), Bullet.Newline.exitList(""), "an empty bullet exits")
        equal(Bullet.newline(inLine: "-"), Bullet.Newline.exitList(""), "even with the space missing")
        equal(Bullet.newline(inLine: "  -   "), Bullet.Newline.exitList(""), "an indented empty bullet exits too")
        check(Bullet.newline(inLine: "plain text") == nil, "prose keeps its ordinary newline")
        check(Bullet.newline(inLine: "---") == nil, "a rule keeps its ordinary newline")
        check(Bullet.newline(inLine: "- [ ] task") == nil, "checkbox lines are the checklist's business")
    }

    // MARK: - Coexistence

    suite("bullets leave the other markers alone") {
        equal(Checklist.toggled(block: "- buy milk"), "- [ ] - buy milk",
              "toggling a bullet is unchanged by this feature")
        check(OrderedList.item(in: "- buy milk") == nil, "the ordered parser never claimed dashes")
    }

    // MARK: - The view layer

    suite("Return at the end of a bullet continues it through the real editor") {
        let view = makeTextView("note\n- buy milk")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertNewline(nil)

        equal(view.string, "note\n- buy milk\n- ", "the next marker is generated, not typed")
        equal(view.selectedRange(), NSRange(location: (view.string as NSString).length, length: 0),
              "the caret lands ready for the item body")
    }

    suite("Return keeps a bullet's indent through the real editor") {
        let view = makeTextView("note\n    - flour")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertNewline(nil)

        equal(view.string, "note\n    - flour\n    - ", "the generated bullet sits under the one above it")
    }

    suite("Return on an empty bullet leaves the list through the real editor") {
        let view = makeTextView("- ")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.insertNewline(nil)

        equal(view.string, "", "no stacked empty markers; the line empties out")
    }

    suite("Return on an emptied continuation ends the bullet list through the real editor") {
        let view = makeTextView("- buy milk")
        view.setSelectedRange(NSRange(location: 10, length: 0))
        view.insertNewline(nil)
        view.insertNewline(nil)

        equal(view.string, "- buy milk\n", "the second Return clears the generated marker instead of adding another")
    }

    suite("Return mid-bullet inserts an ordinary newline") {
        let view = makeTextView("- buy milk")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.insertNewline(nil)

        equal(view.string, "- buy \nmilk", "splitting an item is not the moment to invent a marker")
    }

    suite("Return on a horizontal rule inserts an ordinary newline") {
        let view = makeTextView("---")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertNewline(nil)

        equal(view.string, "---\n", "a rule is a rule, not a list")
    }

    suite("checkbox lines keep continuing as checkboxes") {
        let view = makeTextView("- [ ] buy milk")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertNewline(nil)

        equal(view.string, "- [ ] buy milk\n- [ ] ", "the checklist branch outranks the bullet branch")
    }

    suite("no bullet continues inside a code block") {
        let view = makeTextView("code\n- buy milk")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertNewline(nil)

        equal(view.string, "code\n- buy milk\n", "a dash in code is a character someone typed")
    }

    suite("list mode still wraps a dashed line as a checkbox") {
        // Pins the precedence, not the prettiness: inside a checklist note the
        // mode's promise is that every line becomes an item, and a typed dash
        // does not opt out of that. The doubled marker it leaves behind is
        // pre-existing and tracked separately.
        let view = makeTextView("list\n- buy milk")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertNewline(nil)

        equal(view.string, "list\n- [ ] - buy milk\n- [ ] ", "list mode outranks the bullet branch")
    }
}
