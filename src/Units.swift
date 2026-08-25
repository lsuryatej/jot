import Foundation

/// Physical-unit conversion for the math engine.
///
/// A flat multiplier table relative to a base unit per dimension, not a type
/// system: this app needs "5 km to miles" and "50 USD to EUR", not arbitrary
/// dimensional analysis like `kg * m / s^2`. A table is the amount of
/// machinery that scope actually calls for.
enum Units {
    /// Every accepted spelling maps to a canonical name, so "kilometers",
    /// "kilometer", and "km" are the same unit.
    private static let aliases: [String: String] = [
        // Length (base: meter)
        "m": "m", "meter": "m", "meters": "m", "metre": "m", "metres": "m",
        "km": "km", "kilometer": "km", "kilometers": "km", "kilometre": "km", "kilometres": "km",
        "cm": "cm", "centimeter": "cm", "centimeters": "cm",
        "mm": "mm", "millimeter": "mm", "millimeters": "mm",
        "mi": "mi", "mile": "mi", "miles": "mi",
        "yd": "yd", "yard": "yd", "yards": "yd",
        "ft": "ft", "foot": "ft", "feet": "ft",
        "in": "in", "inch": "in", "inches": "in",

        // Mass (base: gram)
        "g": "g", "gram": "g", "grams": "g",
        "kg": "kg", "kilogram": "kg", "kilograms": "kg",
        "mg": "mg", "milligram": "mg", "milligrams": "mg",
        "lb": "lb", "lbs": "lb", "pound": "lb", "pounds": "lb",
        "oz": "oz", "ounce": "oz", "ounces": "oz",

        // Time (base: second)
        "s": "s", "sec": "s", "second": "s", "seconds": "s",
        "min": "min", "minute": "min", "minutes": "min",
        "h": "h", "hr": "h", "hour": "h", "hours": "h",
        "day": "day", "days": "day",
        "week": "week", "weeks": "week",

        // Data (base: byte)
        "b": "b", "byte": "b", "bytes": "b",
        "kb": "kb", "kilobyte": "kb", "kilobytes": "kb",
        "mb": "mb", "megabyte": "mb", "megabytes": "mb",
        "gb": "gb", "gigabyte": "gb", "gigabytes": "gb",

        // Temperature — affine, handled separately from the multiplier table.
        "c": "c", "celsius": "c",
        "f": "f", "fahrenheit": "f",
        "k": "k", "kelvin": "k",
    ]

    /// Multiplier to the base unit of its dimension.
    private static let toBase: [String: Double] = [
        "m": 1, "km": 1000, "cm": 0.01, "mm": 0.001,
        "mi": 1609.344, "yd": 0.9144, "ft": 0.3048, "in": 0.0254,

        "g": 1, "kg": 1000, "mg": 0.001, "lb": 453.59237, "oz": 28.349523125,

        "s": 1, "min": 60, "h": 3600, "day": 86400, "week": 604800,

        "b": 1, "kb": 1000, "mb": 1_000_000, "gb": 1_000_000_000,
    ]

    private static let dimension: [String: String] = {
        var map: [String: String] = [:]
        for unit in ["m", "km", "cm", "mm", "mi", "yd", "ft", "in"] { map[unit] = "length" }
        for unit in ["g", "kg", "mg", "lb", "oz"] { map[unit] = "mass" }
        for unit in ["s", "min", "h", "day", "week"] { map[unit] = "time" }
        for unit in ["b", "kb", "mb", "gb"] { map[unit] = "data" }
        for unit in ["c", "f", "k"] { map[unit] = "temperature" }
        return map
    }()

    static func canonical(_ raw: String) -> String? {
        aliases[raw.lowercased()]
    }

    static func isKnownUnit(_ raw: String) -> Bool {
        canonical(raw) != nil
    }

    /// Two operands combine only when their units share a dimension, or when
    /// one side is dimensionless. Returns the unit the result should carry.
    static func reconcile(_ a: String?, _ b: String?) -> Result<String?, MathExpression.EvalError> {
        guard let a, let b else { return .success(a ?? b) }
        guard let da = dimension[a] ?? currencyDimension(a),
              let db = dimension[b] ?? currencyDimension(b)
        else { return .success(a) } // an unrecognised tag is passed through, not fought over

        guard da == db else { return .failure(.incompatibleUnits(a, b)) }
        return .success(a)
    }

    /// Brings `rhs` into `lhs`'s unit so `+` and `-` combine like scales
    /// instead of adding raw amounts under the left operand's label. The left
    /// unit wins: "5 km + 3 m" is 5.003 km, not 5003 m.
    ///
    /// Returns `rhs` untouched whenever no conversion is called for — one side
    /// dimensionless, both sides already the same unit, or a tag this table
    /// does not recognise, which `reconcile` passes through as well.
    static func aligned(
        _ lhs: MathExpression.Value,
        _ rhs: MathExpression.Value
    ) -> Result<MathExpression.Value, MathExpression.EvalError> {
        guard let rawLeft = lhs.unit, let rawRight = rhs.unit else { return .success(rhs) }

        // Canonical names, so "kilometers" and "km" are recognised as one unit
        // and "USD" reaches the currency branch. The result keeps the left
        // operand's original spelling, which is what the note showed.
        let left = canonical(rawLeft) ?? rawLeft.lowercased()
        let right = canonical(rawRight) ?? rawRight.lowercased()
        if left == right { return .success(rhs) }

        guard let leftDim = dimension[left] ?? currencyDimension(left),
              let rightDim = dimension[right] ?? currencyDimension(right)
        else { return .success(rhs) }
        guard leftDim == rightDim else { return .failure(.incompatibleUnits(rawLeft, rawRight)) }

        if leftDim == "temperature" {
            // Two different scales have no meaningful sum. Both are affine and
            // neither reading is a delta, so converting one into the other
            // would be inventing an interpretation. Refuse the line instead.
            return .failure(.incompatibleUnits(rawLeft, rawRight))
        }

        if leftDim == "currency" {
            let availability = CurrencyRates.availability(from: right, to: left)
            guard availability == .ok else {
                return .failure(.currencyRatesUnavailable(availability))
            }
            return CurrencyRates.convert(rhs.amount, from: right, to: left)
                .map { MathExpression.Value(amount: $0.amount, unit: rawLeft) }
        }

        let base = rhs.amount * (toBase[right] ?? 1)
        return .success(MathExpression.Value(amount: base / (toBase[left] ?? 1), unit: rawLeft))
    }

    /// Currency codes are not in the physical table; anything three letters
    /// and all-alphabetic that is not a physical unit is assumed to be one, so
    /// "USD to EUR" reconciles without every currency needing an entry here.
    private static func currencyDimension(_ unit: String) -> String? {
        guard dimension[unit] == nil, unit.count == 3, unit.allSatisfy({ $0.isLetter }) else { return nil }
        return "currency"
    }

    static func convert(_ value: MathExpression.Value, to rawTarget: String) -> Result<MathExpression.Value, MathExpression.EvalError> {
        guard let sourceUnit = value.unit else {
            return .failure(.unknownUnit(rawTarget))
        }
        guard let target = canonical(rawTarget) ?? (currencyDimension(rawTarget.lowercased()) != nil ? rawTarget.lowercased() : nil) else {
            return .failure(.unknownUnit(rawTarget))
        }

        if dimension[sourceUnit] == "temperature" || dimension[target] == "temperature" {
            return convertTemperature(value.amount, from: sourceUnit, to: target)
        }

        guard let sourceDim = dimension[sourceUnit] ?? currencyDimension(sourceUnit),
              let targetDim = dimension[target] ?? currencyDimension(target),
              sourceDim == targetDim
        else {
            return .failure(.incompatibleUnits(sourceUnit, target))
        }

        if sourceDim == "currency" {
            // Currency conversion needs live rates, supplied from outside this
            // pure module. Without one, hand back the amount re-tagged so at
            // least the note does not show a wrong number silently.
            return CurrencyRates.convert(value.amount, from: sourceUnit, to: target)
                .mapError { _ in MathExpression.EvalError.unknownUnit(target) }
        }

        let base = value.amount * (toBase[sourceUnit] ?? 1)
        let converted = base / (toBase[target] ?? 1)
        return .success(MathExpression.Value(amount: converted, unit: target))
    }

    private static func convertTemperature(_ amount: Double, from: String, to: String) -> Result<MathExpression.Value, MathExpression.EvalError> {
        guard dimension[from] == "temperature", dimension[to] == "temperature" else {
            return .failure(.incompatibleUnits(from, to))
        }
        let celsius: Double
        switch from {
        case "f": celsius = (amount - 32) * 5 / 9
        case "k": celsius = amount - 273.15
        default:  celsius = amount
        }
        let result: Double
        switch to {
        case "f": result = celsius * 9 / 5 + 32
        case "k": result = celsius + 273.15
        default:  result = celsius
        }
        return .success(MathExpression.Value(amount: result, unit: to))
    }
}
