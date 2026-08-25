import Foundation

/// A recursive-descent parser and evaluator for inline math.
///
/// The document is re-evaluated top to bottom on every keystroke rather than
/// tracked with a dependency graph: notes are at most a few hundred lines, and
/// a full re-evaluation removes an entire class of invalidation bugs for a
/// cost too small to measure.
enum MathExpression {

    // MARK: - Tokens

    enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case op(String)     // + - * / ^ % ( ) =
        case word(String)   // "to", "of", "on", "off", "in", "as" — and anything
                             // else, which is what lets prose coexist with math
    }

    static func tokenize(_ line: String) -> [Token] {
        var tokens: [Token] = []
        let scalars = Array(line.unicodeScalars)
        var i = 0

        func isDigit(_ c: Unicode.Scalar) -> Bool { c.properties.numericType == .decimal }
        func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
            CharacterSet.letters.contains(c) || c == "_"
        }
        func isIdentifierContinuing(_ c: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(c) || c == "_"
        }

        while i < scalars.count {
            let c = scalars[i]

            if CharacterSet.whitespaces.contains(c) {
                i += 1
                continue
            }

            // A leading "$" prices the number that follows: "$50" tokenizes as
            // the number 50 followed by a "usd" unit, the same shape parsePrimary
            // expects for "50 usd" — a unit tag after its number, not before.
            var pricedByDollar = false
            var scanStart = i
            if c == "$", i + 1 < scalars.count, isDigit(scalars[i + 1]) {
                pricedByDollar = true
                scanStart = i + 1
            }

            if isDigit(scalars[scanStart]) || (scalars[scanStart] == "." && scanStart + 1 < scalars.count && isDigit(scalars[scanStart + 1])) {
                var end = scanStart
                while end < scalars.count, isDigit(scalars[end]) { end += 1 }

                // Thousands grouping: consume repeated ",DDD" groups, each
                // exactly three digits, so "1,234,567" reads as one number
                // rather than stopping after the first group.
                while end < scalars.count, scalars[end] == "," {
                    let g2 = end + 3
                    guard g2 < scalars.count,
                          isDigit(scalars[end + 1]), isDigit(scalars[end + 2]), isDigit(scalars[g2]),
                          !(g2 + 1 < scalars.count && isDigit(scalars[g2 + 1]))
                    else { break }
                    end = g2 + 1
                }

                if end < scalars.count, scalars[end] == "." {
                    end += 1
                    while end < scalars.count, isDigit(scalars[end]) { end += 1 }
                }

                let raw = String(String.UnicodeScalarView(scalars[scanStart..<end])).replacingOccurrences(of: ",", with: "")
                if let value = Double(raw) {
                    tokens.append(.number(value))
                    if pricedByDollar { tokens.append(.identifier("usd")) }
                }
                i = end
                continue
            }

            if c == "%" {
                tokens.append(.op("%"))
                i += 1
                continue
            }

            if isIdentifierStart(c) {
                var end = i + 1
                while end < scalars.count, isIdentifierContinuing(scalars[end]) { end += 1 }
                let word = String(String.UnicodeScalarView(scalars[i..<end]))
                if Self.operatorWords.contains(word.lowercased()) {
                    tokens.append(.word(word.lowercased()))
                } else {
                    tokens.append(.identifier(word))
                }
                i = end
                continue
            }

            if "+-*/^()=".unicodeScalars.contains(c) {
                tokens.append(.op(String(c)))
                i += 1
                continue
            }

            // Anything else (punctuation, emoji, other scripts) is prose noise.
            i += 1
        }

        return tokens
    }

    /// Words with grammatical meaning to the parser, lowercase.
    private static let operatorWords: Set<String> = ["to", "of", "on", "off", "in", "as", "plus", "minus"]

    // MARK: - AST

    indirect enum Node {
        case number(Double, unit: String?)
        case variable(String)
        case assignment(name: String, value: Node)
        case binary(String, Node, Node)
        case percentOf(Node, Node)          // "20% of 50"
        case percentAdjust(Node, Node, add: Bool) // "50 + 20%", "50 - 20%", "20% on/off 50"
        case convert(Node, to: String)
        case negate(Node)
    }

    // MARK: - Parsing

    /// A line with no operator, no assignment, and no conversion is prose, even
    /// if it starts with a number — "5 apples" does not evaluate. A bare
    /// variable reference ("x" on its own line, previously assigned) is the one
    /// exception: it is a single token but a deliberate lookup, not incidental
    /// prose, so it is allowed through.
    static func parse(_ line: String) -> Node? {
        let tokens = tokenize(line)
        guard !tokens.isEmpty else { return nil }

        if tokens.count == 1, case .identifier(let name) = tokens[0] {
            return .variable(name)
        }

        var parser = Parser(tokens: tokens)
        guard let node = parser.parseAssignmentOrExpression(), parser.isAtEnd else { return nil }

        // A bare number/identifier with nothing else attached parsed
        // successfully but carries no operator — reject it as prose too.
        guard nodeHasOperator(node) else { return nil }
        return node
    }

    private static func nodeHasOperator(_ node: Node) -> Bool {
        switch node {
        case .number, .variable: return false
        default: return true
        }
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0

        /// How many nested groupings the parser will descend through before
        /// giving up on the line.
        ///
        /// Recursive descent has no stack of its own, so a line like 4000 open
        /// parens (or 4000 leading minus signs) used to recurse until the real
        /// stack ran out and the process died with SIGSEGV. That is reachable
        /// by an ordinary paste, since every line is reparsed on every
        /// keystroke.
        ///
        /// One level of nesting costs eight frames here (expression through
        /// primary), and the observed crash threshold on the main thread's 8MB
        /// stack sits between 2000 and 3000 levels, so a level runs roughly
        /// 3KB. 256 levels is therefore under a megabyte of stack, an order of
        /// magnitude clear of the limit, while being far more nesting than any
        /// expression a person writes by hand. Past it the line just fails to
        /// parse, which is what every other unparseable line already does: no
        /// result is drawn, and the text is left exactly as typed.
        static let maxDepth = 256

        /// Nesting levels currently open. Every production that recurses on
        /// itself counts against it: parenthesised groups, unary minus, the
        /// right-associative "^", and the target of a percent "of" phrase.
        var depth = 0

        var isAtEnd: Bool { index >= tokens.count }
        var current: Token? { index < tokens.count ? tokens[index] : nil }

        mutating func advance() -> Token? {
            guard let token = current else { return nil }
            index += 1
            return token
        }

        mutating func match(_ token: Token) -> Bool {
            guard current == token else { return false }
            index += 1
            return true
        }

        // assignment := identifier "=" expression | expression
        mutating func parseAssignmentOrExpression() -> Node? {
            if case .identifier(let name) = current,
               index + 1 < tokens.count, tokens[index + 1] == .op("=") {
                index += 2
                guard let value = parseConversion() else { return nil }
                return .assignment(name: name, value: value)
            }
            return parseConversion()
        }

        // conversion := additive (("to"|"in"|"as") identifier)?
        mutating func parseConversion() -> Node? {
            guard let left = parseAdditive() else { return nil }
            if case .word(let w) = current, w == "to" || w == "in" || w == "as" {
                index += 1
                guard case .identifier(let unit) = advance() else { return nil }
                return .convert(left, to: unit)
            }
            return left
        }

        /// parsePercent encodes a bare "X%" as `.binary("%", X, X)` — both
        /// operands are the same node, so either can be taken as the value.
        private static func isPercent(_ node: Node) -> Bool {
            if case .binary("%", _, _) = node { return true }
            return false
        }

        private static func percentValue(_ node: Node) -> Node {
            if case .binary("%", let value, _) = node { return value }
            return node
        }

        // additive := multiplicative (("+"|"-"|"plus"|"minus"|percentPhrase) multiplicative)*
        mutating func parseAdditive() -> Node? {
            guard var left = parseMultiplicative() else { return nil }

            while true {
                if case .word(let w) = current, w == "on" || w == "off" {
                    // "20% on 50" / "20% off 50" — `left` is the percentage
                    // that was just parsed, and the operand follows the word.
                    index += 1
                    guard let right = parseMultiplicative() else { return nil }
                    left = .percentAdjust(Self.percentValue(left), right, add: w == "on")
                    continue
                }

                let isAdd = match(.op("+")) || match(.word("plus"))
                let isSub = !isAdd && (match(.op("-")) || match(.word("minus")))
                guard isAdd || isSub else { break }

                guard let right = parseMultiplicative() else { return nil }

                // "50 + 20%" only reduces to base-plus-a-fraction when the left
                // side is a plain amount. "10% + 20%" is two percentages added
                // directly (30%), not 10% grown by another 20% of itself, so
                // that case falls through to an ordinary binary op — apply()
                // already knows how to add two %-tagged values.
                if Self.isPercent(right), !Self.isPercent(left) {
                    left = .percentAdjust(Self.percentValue(right), left, add: isAdd)
                } else {
                    left = .binary(isAdd ? "+" : "-", left, right)
                }
            }
            return left
        }

        // multiplicative := unary (("*"|"/") unary)*
        mutating func parseMultiplicative() -> Node? {
            guard var left = parseUnary() else { return nil }
            while true {
                let isMul = match(.op("*"))
                let isDiv = !isMul && match(.op("/"))
                guard isMul || isDiv else { break }
                guard let right = parseUnary() else { return nil }
                left = .binary(isMul ? "*" : "/", left, right)
            }
            return left
        }

        // unary := "-" unary | power
        mutating func parseUnary() -> Node? {
            if match(.op("-")) {
                guard depth < Self.maxDepth else { return nil }
                depth += 1
                defer { depth -= 1 }
                guard let operand = parseUnary() else { return nil }
                return .negate(operand)
            }
            return parsePower()
        }

        // power := percent ("^" unary)?
        mutating func parsePower() -> Node? {
            guard let left = parsePercent() else { return nil }
            if match(.op("^")) {
                guard depth < Self.maxDepth else { return nil }
                depth += 1
                defer { depth -= 1 }
                guard let right = parseUnary() else { return nil }
                return .binary("^", left, right)
            }
            return left
        }

        // percent := "X% of Y" | primary "%"?
        mutating func parsePercent() -> Node? {
            guard let left = parsePrimary() else { return nil }

            if match(.op("%")) {
                if case .word("of") = current {
                    index += 1
                    guard depth < Self.maxDepth else { return nil }
                    depth += 1
                    defer { depth -= 1 }
                    guard let target = parseMultiplicative() else { return nil }
                    return .percentOf(left, target)
                }
                // A bare "%" with no "of": leave a marker the additive layer
                // recognises, so "50 + 20%" can find it.
                return .binary("%", left, left)
            }
            return left
        }

        // primary := number identifier? | identifier | "(" expression ")"
        mutating func parsePrimary() -> Node? {
            switch advance() {
            case .number(let value):
                if case .identifier(let unit) = current {
                    index += 1
                    return .number(value, unit: unit)
                }
                return .number(value, unit: nil)

            case .identifier(let name):
                return .variable(name)

            case .op("("):
                guard depth < Self.maxDepth else { return nil }
                depth += 1
                defer { depth -= 1 }
                guard let inner = parseAssignmentOrExpression() else { return nil }
                guard match(.op(")")) else { return nil }
                return inner

            default:
                return nil
            }
        }
    }

    // MARK: - Evaluation

    enum EvalError: Error {
        case undefinedVariable(String)
        case unknownUnit(String)
        case incompatibleUnits(String, String)
        case divisionByZero
        /// Two different currencies met under `+` or `-` with no rate that may
        /// be used. Carries which of the two reasons applies, so the editor can
        /// say which one rather than just going blank.
        case currencyRatesUnavailable(CurrencyRates.Availability)
    }

    /// A few failures are worth a word in the margin instead of silence: a
    /// mixed-currency sum looks like it should work, so the reason it did not
    /// goes where the number would have been. Every other failure stays blank.
    static func hint(for error: EvalError) -> String? {
        guard case .currencyRatesUnavailable(let availability) = error else { return nil }
        switch availability {
        case .ratesOff: return "rates off"
        case .noRate: return "no rates"
        case .ok: return nil
        }
    }

    /// A number, optionally tagged with the unit it is expressed in.
    struct Value {
        var amount: Double
        var unit: String?
    }

    static func evaluate(_ node: Node, environment: inout [String: Value]) -> Result<Value, EvalError> {
        switch node {
        case .number(let value, let unit):
            return .success(Value(amount: value, unit: unit))

        case .variable(let name):
            guard let value = environment[name.lowercased()] else {
                return .failure(.undefinedVariable(name))
            }
            return .success(value)

        case .assignment(let name, let valueNode):
            switch evaluate(valueNode, environment: &environment) {
            case .success(let value):
                environment[name.lowercased()] = value
                return .success(value)
            case .failure(let error):
                return .failure(error)
            }

        case .negate(let inner):
            return evaluate(inner, environment: &environment).map { Value(amount: -$0.amount, unit: $0.unit) }

        case .percentOf(let percent, let target):
            return combine(percent, target, environment: &environment) { p, t in
                Value(amount: t.amount * (p.amount / 100), unit: t.unit)
            }

        case .percentAdjust(let percent, let base, let add):
            return combine(percent, base, environment: &environment) { p, b in
                let delta = b.amount * (p.amount / 100)
                return Value(amount: add ? b.amount + delta : b.amount - delta, unit: b.unit)
            }

        case .binary(let op, let lhs, let rhs):
            return evaluateBinary(op, lhs, rhs, environment: &environment)

        case .convert(let inner, let targetUnit):
            switch evaluate(inner, environment: &environment) {
            case .success(let value):
                return Units.convert(value, to: targetUnit)
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    private static func combine<T>(
        _ a: Node, _ b: Node,
        environment: inout [String: Value],
        _ body: (Value, Value) -> T
    ) -> Result<T, EvalError> {
        switch evaluate(a, environment: &environment) {
        case .failure(let error): return .failure(error)
        case .success(let av):
            switch evaluate(b, environment: &environment) {
            case .failure(let error): return .failure(error)
            case .success(let bv): return .success(body(av, bv))
            }
        }
    }

    private static func evaluateBinary(
        _ op: String, _ lhsNode: Node, _ rhsNode: Node,
        environment: inout [String: Value]
    ) -> Result<Value, EvalError> {
        // A bare "%" reaching here (no "of", consumed by neither percent
        // helper) means "X%" stood alone as a pure-percentage value. The
        // parser encodes it as .binary("%", left, left); the right side is a
        // duplicate placeholder and is not evaluated again.
        if op == "%" {
            return evaluate(lhsNode, environment: &environment).map { Value(amount: $0.amount, unit: "%") }
        }

        return combine(lhsNode, rhsNode, environment: &environment) { ($0, $1) }
            .flatMap { apply(op, $0.0, $0.1) }
    }

    private static func apply(_ op: String, _ lhs: Value, _ rhs: Value) -> Result<Value, EvalError> {
        // Percentages behave as pure numbers in arithmetic once they reach
        // here: "10% + 20%" = 30%, but "50% * 30" collapses to a plain number.
        if lhs.unit == "%" && rhs.unit == "%" {
            return applyRaw(op, lhs.amount, rhs.amount).map { Value(amount: $0, unit: op == "*" || op == "/" ? nil : "%") }
        }
        if lhs.unit == "%" || rhs.unit == "%" {
            let percent = lhs.unit == "%" ? lhs : rhs
            let plain = lhs.unit == "%" ? rhs : lhs
            switch op {
            case "*": return .success(Value(amount: plain.amount * (percent.amount / 100), unit: plain.unit))
            case "/":
                guard percent.amount != 0 else { return .failure(.divisionByZero) }
                return .success(Value(amount: plain.amount / (percent.amount / 100), unit: plain.unit))
            default: break
            }
        }

        // Not `try? … .get()`: Swift auto-flattens a throwing call that
        // returns String?, so a reconciled-but-nil unit and an actual thrown
        // error both collapse to plain nil and become indistinguishable.
        // Switching on the Result directly keeps them apart.
        let unit: String?
        switch Units.reconcile(lhs.unit, rhs.unit) {
        case .success(let reconciled): unit = reconciled
        case .failure(let error): return .failure(error)
        }

        switch op {
        case "+", "-":
            // Adding two amounts only means anything once they are expressed in
            // the same unit. `reconcile` above establishes they share a
            // dimension and hands back the label; this converts the right side
            // into that label's unit so the amounts actually line up.
            let right: Value
            switch Units.aligned(lhs, rhs) {
            case .success(let converted): right = converted
            case .failure(let error): return .failure(error)
            }
            let amount = op == "+" ? lhs.amount + right.amount : lhs.amount - right.amount
            return .success(Value(amount: amount, unit: unit))
        case "*": return .success(Value(amount: lhs.amount * rhs.amount, unit: unit ?? rhs.unit ?? lhs.unit))
        case "/":
            guard rhs.amount != 0 else { return .failure(.divisionByZero) }
            return .success(Value(amount: lhs.amount / rhs.amount, unit: lhs.unit))
        case "^": return .success(Value(amount: pow(lhs.amount, rhs.amount), unit: nil))
        default: return .success(Value(amount: 0, unit: nil))
        }
    }

    /// Compact display form: trims trailing zeros, and appends the unit
    /// unless it is the internal "%" marker, which gets a bare "%" instead.
    static func format(_ value: Value) -> String {
        let rounded = (value.amount * 10000).rounded() / 10000
        var text: String
        if rounded == rounded.rounded(), abs(rounded) < 1e15 {
            text = String(Int(rounded))
        } else {
            text = String(format: "%.4f", rounded)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if let unit = value.unit {
            text += unit == "%" ? "%" : " \(unit)"
        }
        return text
    }

    private static func applyRaw(_ op: String, _ a: Double, _ b: Double) -> Result<Double, EvalError> {
        switch op {
        case "+": return .success(a + b)
        case "-": return .success(a - b)
        case "*": return .success(a * b)
        case "/":
            guard b != 0 else { return .failure(.divisionByZero) }
            return .success(a / b)
        default: return .success(0)
        }
    }
}
