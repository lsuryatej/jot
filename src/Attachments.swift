import Foundation
import AppKit

/// An inline image reference found in note text.
struct ImageReference: Equatable {
    /// Display width in points. Nil means "use the natural size, capped".
    var width: CGFloat?
    /// Path relative to the attachments directory.
    var path: String
    /// Range of the whole `![320](path)` run within its line.
    var range: NSRange
}

/// Images live as files; notes keep a markdown reference to them.
///
/// The alternative was putting NSTextAttachments into the text storage, which
/// would mean the document is no longer the thing on disk — and this app has
/// already lost notes once to a mismatch between the two. A markdown line is
/// still something you can read in `cat`, and it is the same syntax Obsidian
/// uses, so exported notes keep working.
enum Attachments {
    static let directoryName = "Attachments"

    /// `![320](Attachments/uuid.png)` — a numeric alt text is a display width,
    /// matching Obsidian's convention.
    private static let pattern = try? NSRegularExpression(
        pattern: "!\\[([0-9]*)\\]\\(([^)]+)\\)"
    )

    static func directoryURL(base: URL = NoteStore.defaultFileURL().deletingLastPathComponent()) -> URL {
        base.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func references(in line: String) -> [ImageReference] {
        guard let pattern else { return [] }
        let ns = line as NSString
        return pattern.matches(in: line, range: NSRange(location: 0, length: ns.length)).map { match in
            let widthText = ns.substring(with: match.range(at: 1))
            return ImageReference(
                width: widthText.isEmpty ? nil : CGFloat(Double(widthText) ?? 0),
                path: ns.substring(with: match.range(at: 2)),
                range: match.range
            )
        }
    }

    static func markdown(path: String, width: CGFloat?) -> String {
        let widthText = width.map { String(Int($0.rounded())) } ?? ""
        return "![\(widthText)](\(path))"
    }

    /// Rewrites the width of the reference at `range` without disturbing
    /// anything else on the line.
    static func settingWidth(_ width: CGFloat, on line: String, at range: NSRange) -> String? {
        let ns = line as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return nil }
        let existing = references(in: ns.substring(with: range))
        guard let reference = existing.first else { return nil }
        return ns.replacingCharacters(
            in: range,
            with: markdown(path: reference.path, width: max(48, width))
        )
    }

    // MARK: - Writing

    /// Saves image data and returns the note-relative path.
    @discardableResult
    static func save(_ image: NSImage, in directory: URL = Attachments.directoryURL()) throws -> String {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).png"
        try png.write(to: directory.appendingPathComponent(name), options: .atomic)
        return "\(directoryName)/\(name)"
    }

    static func image(at path: String, in base: URL = NoteStore.defaultFileURL().deletingLastPathComponent()) -> NSImage? {
        NSImage(contentsOf: base.appendingPathComponent(path))
    }

    /// Natural display width for a freshly pasted image, capped so a screenshot
    /// does not arrive three times wider than the note.
    static func defaultWidth(for image: NSImage, maximum: CGFloat = 320) -> CGFloat {
        max(48, min(image.size.width, maximum))
    }
}
