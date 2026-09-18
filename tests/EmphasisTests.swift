import Foundation

// Coverage for the inline `**bold**` / `*italic*` / `` `code` `` parser.
// Most of these cases exist because pasted AI chat output is full of prose
// that only looks like a marker: bullet lists, snake_case identifiers,
// multiplication signs, half-typed pairs.

func runEmphasisTests() {

    // MARK: - The three kinds

    suite("finds a single strong span") {
        let matches = Emphasis.matches(in: "some **bold** text" as NSString)
        equal(matches.count, 1, "exactly one span")
        let match = matches[0]
        equal(match.kind, Emphasis.Kind.strong, "two asterisks a side is strong")
        equal(match.range, NSRange(location: 5, length: 8), "whole span, markers included")
        equal(match.contentRange, NSRange(location: 7, length: 4), "content excludes both markers")
        equal(match.markerRanges, [NSRange(location: 5, length: 2), NSRange(location: 11, length: 2)],
              "both `**` pairs are captured, opening then closing")
    }

    suite("finds a single emphasis span") {
        let matches = Emphasis.matches(in: "an *italic* word" as NSString)
        equal(matches.count, 1, "exactly one span")
        equal(matches[0].kind, Emphasis.Kind.emphasis, "one asterisk a side is emphasis")
        equal(matches[0].range, NSRange(location: 3, length: 8), "whole span, markers included")
        equal(matches[0].contentRange, NSRange(location: 4, length: 6), "content excludes both markers")
        equal(matches[0].markerRanges, [NSRange(location: 3, length: 1), NSRange(location: 10, length: 1)],
              "single-character markers")
    }

    suite("finds a single code span") {
        let matches = Emphasis.matches(in: "run `ls -la` now" as NSString)
        equal(matches.count, 1, "exactly one span")
        equal(matches[0].kind, Emphasis.Kind.code, "backticks are code")
        equal(matches[0].range, NSRange(location: 4, length: 8), "whole span, markers included")
        equal(("run `ls -la` now" as NSString).substring(with: matches[0].contentRange), "ls -la",
              "spaces inside code are content, not a disqualifier")
    }

    suite("`**` is tried before `*`") {
        let matches = Emphasis.matches(in: "**bold**" as NSString)
        equal(matches.count, 1, "one span, not an italic wrapping `*bold*` and not two empty ones")
        equal(matches[0].kind, Emphasis.Kind.strong, "read as strong")
        equal(("**bold**" as NSString).substring(with: matches[0].contentRange), "bold", "content has no leftover marker")
    }

    // MARK: - Things that only look like markers

    suite("a bullet line is not an italic") {
        check(Emphasis.matches(in: "* a bullet item" as NSString).isEmpty,
              "the space after the opening `*` rules it out, which is exactly what a bullet has")
    }

    suite("a lone asterisk in prose is not an italic") {
        check(Emphasis.matches(in: "a * b * c" as NSString).isEmpty,
              "multiplication written out longhand stays literal")
    }

    suite("a closing marker needs real content in front of it") {
        check(Emphasis.matches(in: "**bad **" as NSString).isEmpty,
              "a space before the closing `**` means it never closes anything")
    }

    suite("unmatched markers stay literal") {
        check(Emphasis.matches(in: "a ** b" as NSString).isEmpty, "a `**` with no partner folds nothing")
        check(Emphasis.matches(in: "lone ` backtick" as NSString).isEmpty, "nor does a lone backtick")
        check(Emphasis.matches(in: "half *open" as NSString).isEmpty, "nor a single opening asterisk")
    }

    suite("empty content produces no span") {
        check(Emphasis.matches(in: "****" as NSString).isEmpty, "`****` wraps nothing, so it is nothing")
        check(Emphasis.matches(in: "``" as NSString).isEmpty, "an empty backtick pair likewise")
        check(Emphasis.matches(in: "a ** b ** c" as NSString).isEmpty, "spaces on both inner sides, nothing to wrap")
    }

    // Underscore emphasis is deliberately unsupported: these notes are full of
    // snake_case, and `some_var_name` turning italic mid-identifier is worse
    // than an underscore staying an underscore.
    suite("underscores are never emphasis") {
        check(Emphasis.matches(in: "some_var_name" as NSString).isEmpty, "snake_case survives intact")
        check(Emphasis.matches(in: "_foo_ and __bar__" as NSString).isEmpty, "neither single nor double underscores parse")
    }

    // MARK: - Precedence

    suite("code beats emphasis") {
        let matches = Emphasis.matches(in: "`a * b`" as NSString)
        equal(matches.count, 1, "one span")
        equal(matches[0].kind, Emphasis.Kind.code, "the asterisk inside backticks is a character someone typed")
    }

    suite("an emphasis pair reaching across a code span loses to it") {
        let source = "*a `b` c*" as NSString
        let matches = Emphasis.matches(in: source)
        equal(matches.count, 1, "only the code span survives")
        equal(matches[0].kind, Emphasis.Kind.code, "code wins the overlap outright rather than being nested")
        equal(source.substring(with: matches[0].contentRange), "b", "and it is the right code span")
    }

    // Nesting is not attempted: the outer pair wins and the inner asterisks
    // stay on screen as literal characters.
    suite("nesting yields the outer span only") {
        let source = "**bold with *italic* inside**" as NSString
        let matches = Emphasis.matches(in: source)
        equal(matches.count, 1, "one span, not two")
        equal(matches[0].kind, Emphasis.Kind.strong, "the outer pair is the one that parses")
        equal(source.substring(with: matches[0].contentRange), "bold with *italic* inside",
              "the inner markers are part of the content and stay visible")
    }

    suite("a highlight is not emphasis") {
        check(Emphasis.matches(in: "==a==" as NSString).isEmpty,
              "`==` spans are Highlight's business and carry no emphasis markers of their own")
    }

    // MARK: - Several spans, several lines

    suite("finds more than one span per line") {
        let source = "**a** and **b**" as NSString
        let matches = Emphasis.matches(in: source)
        equal(matches.count, 2, "two spans on one line")
        equal(source.substring(with: matches[0].contentRange), "a", "first span's content")
        equal(source.substring(with: matches[1].contentRange), "b", "second span's content")
    }

    suite("mixed kinds on one line come back in reading order") {
        let matches = Emphasis.matches(in: "**a** `b` *c*" as NSString)
        equal(matches.map { $0.kind }, [Emphasis.Kind.strong, Emphasis.Kind.code, Emphasis.Kind.emphasis],
              "sorted by position regardless of which pass found them")
    }

    suite("spans do not cross a line boundary") {
        check(Emphasis.matches(in: "*open\nclose*" as NSString).isEmpty,
              "an asterisk pair split across two lines is not emphasis")
        check(Emphasis.matches(in: "`open\nclose`" as NSString).isEmpty,
              "and neither is a backtick pair")
    }

    suite("spans on a later line carry whole-string offsets") {
        let source = "plain\n**bold**" as NSString
        let matches = Emphasis.matches(in: source)
        equal(matches.count, 1, "one span, on the second line")
        equal(matches[0].range, NSRange(location: 6, length: 8), "offset past the first line and its newline")
        equal(source.substring(with: matches[0].contentRange), "bold", "and the content range points at the right text")
    }

    suite("content may itself contain spaces") {
        let source = "**two words** here" as NSString
        let matches = Emphasis.matches(in: source)
        equal(matches.count, 1, "one span")
        equal(source.substring(with: matches[0].contentRange), "two words",
              "only the characters touching the markers have to be non-whitespace")
    }

    // MARK: - Math lines

    suite("a line with a math result keeps its asterisks") {
        equal(Emphasis.matches(in: "2*3*4" as NSString).count, 0,
              "`2*3*4` is multiplication; folding would show `234` beside a result of 24")
        equal(Emphasis.matches(in: "price = 3\nqty = 4\nprice*qty*2" as NSString).count, 0,
              "variables defined on earlier lines count too")
        equal(Emphasis.matches(in: "2*3*4\nan *italic* word" as NSString).count, 1,
              "only the math line is left alone")
        equal(Emphasis.matches(in: "I *love* it" as NSString).count, 1,
              "prose with no margin result keeps its emphasis")
    }
}
