import Foundation
@preconcurrency import Vision
import AppKit

/// Screenshot-to-text.
///
/// Apple's Vision framework rather than Tesseract or PaddleOCR: it is already
/// on the machine, so it adds nothing to the binary, runs offline on the Neural
/// Engine, and is more accurate on small UI type than either of them.
enum TextRecognition {
    enum Failure: Error, LocalizedError {
        case notAnImage
        case nothingFound

        var errorDescription: String? {
            switch self {
            case .notAnImage:  return "That file could not be read as an image."
            case .nothingFound: return "No text was found in that image."
            }
        }
    }

    /// Pulls an image out of a drag or a paste, whether it arrived as raw image
    /// data or as a file on disk.
    static func image(from pasteboard: NSPasteboard) -> NSImage? {
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let image = images.first {
            return image
        }

        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return nil
        }
        return urls.lazy.compactMap { NSImage(contentsOf: $0) }.first
    }

    static func recognizeText(in image: NSImage) async throws -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure.notAnImage
        }

        let lines: [String] = try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: observations.compactMap {
                    $0.topCandidates(1).first?.string
                })
            }

            request.recognitionLevel = .accurate
            // On by default, but explicit: it is what makes prose come back
            // clean, and what you would turn off for code or serial numbers.
            request.usesLanguageCorrection = true

            // Vision hands back observations in no particular reading order, so
            // perform off the main thread and sort afterwards.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        let text = lines.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.nothingFound
        }
        return text
    }
}
