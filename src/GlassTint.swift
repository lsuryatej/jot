import AppKit

/// A colour wash laid over the translucent papers.
///
/// Frosted, Glass, and Solid all render a system material behind the text; a
/// tint bends that surface toward a hue without giving up the translucency
/// that makes those papers pleasant to write on. Opaque papers carry their own
/// colour and ignore tints entirely — `applies(to:)` is the single place that
/// rule lives.
enum GlassTint: String, CaseIterable, Identifiable {
    case none
    case graphite
    case amber
    case rose
    case moss
    case indigo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:     return "None"
        case .graphite: return "Graphite"
        case .amber:    return "Amber"
        case .rose:     return "Rose"
        case .moss:     return "Moss"
        case .indigo:   return "Indigo"
        }
    }

    /// The wash itself, or nil for no tint.
    ///
    /// Alphas stay near 0.12 on purpose: these are washes, not papers, so in
    /// either system mode the standard ink keeps its contrast over them.
    var overlayColor: NSColor? {
        switch self {
        case .none:     return nil
        case .graphite: return NSColor(srgbRed: 0.180, green: 0.190, blue: 0.220, alpha: 1)
        case .amber:    return NSColor(srgbRed: 0.870, green: 0.640, blue: 0.310, alpha: 1)
        case .rose:     return NSColor(srgbRed: 0.850, green: 0.420, blue: 0.480, alpha: 1)
        case .moss:     return NSColor(srgbRed: 0.470, green: 0.640, blue: 0.450, alpha: 1)
        case .indigo:   return NSColor(srgbRed: 0.430, green: 0.480, blue: 0.780, alpha: 1)
        }
    }

    /// How strongly the wash sits on the material.
    var overlayOpacity: Double {
        switch self {
        case .none: return 0
        default:    return 0.12
        }
    }

    /// Tints only mean something where the paper itself is translucent.
    static func applies(to appearance: Appearance) -> Bool {
        appearance.paperColor == nil
    }
}
