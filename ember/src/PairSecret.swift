import Foundation
import CryptoKit

/// What two Macs share once paired: where to meet and the key to talk with.
///
/// The ntfy topic is random and long enough that nobody stumbles onto it, but
/// that alone isn't privacy: ntfy.sh can read every message on every topic.
/// So each message is sealed with ChaChaPoly under a 256-bit key that only
/// ever travels inside the pair code, and the server relays ciphertext.
struct PairSecret: Codable, Equatable {
    var server: URL
    var topic: String
    var key: Data

    static let defaultServer = URL(string: "https://ntfy.sh")!
    private static let codePrefix = "ember1."
    private static let linkPrefix = "ember://pair?code="

    static func generate(server: URL = defaultServer) -> PairSecret {
        PairSecret(
            server: server,
            topic: "ember-" + Base64URL.encode(randomBytes(18)),
            key: randomBytes(32)
        )
    }

    /// What one of you copies and the other pastes. Self-contained: it
    /// carries the server too, so a self-hosted pair needs no extra setup.
    var code: String {
        // Sorted keys: the same pair always prints the same code.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(Portable(s: server.absoluteString, t: topic, k: Base64URL.encode(key)))) ?? Data()
        return Self.codePrefix + Base64URL.encode(json)
    }

    /// Clicking this in iMessage opens Ember and pairs, no pasting.
    var link: String { Self.linkPrefix + code }

    /// Accepts the bare code or the link, with whatever whitespace or line
    /// breaks a chat app wraps it in.
    init?(code raw: String) {
        var text = raw.components(separatedBy: .whitespacesAndNewlines).joined()
        if text.hasPrefix(Self.linkPrefix) { text.removeFirst(Self.linkPrefix.count) }
        guard text.hasPrefix(Self.codePrefix) else { return nil }
        text.removeFirst(Self.codePrefix.count)
        guard let json = Base64URL.decode(text),
              let portable = try? JSONDecoder().decode(Portable.self, from: json),
              let server = URL(string: portable.s), server.scheme?.hasPrefix("http") == true,
              let key = Base64URL.decode(portable.k), key.count == 32,
              Self.isValidTopic(portable.t)
        else { return nil }
        self.init(server: server, topic: portable.t, key: key)
    }

    init(server: URL, topic: String, key: Data) {
        self.server = server
        self.topic = topic
        self.key = key
    }

    func seal(_ envelope: Envelope) throws -> String {
        let plain = try Wire.encoder().encode(envelope)
        let box = try ChaChaPoly.seal(plain, using: SymmetricKey(data: key), authenticating: Data(topic.utf8))
        return box.combined.base64EncodedString()
    }

    /// Throws for anything not sealed with this pair's key on this topic,
    /// which is how a stray or forged message gets dropped.
    func open(_ text: String) throws -> Envelope {
        guard let combined = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw OpenError.notBase64
        }
        let box = try ChaChaPoly.SealedBox(combined: combined)
        let plain = try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: Data(topic.utf8))
        return try Wire.decoder().decode(Envelope.self, from: plain)
    }

    enum OpenError: Error { case notBase64 }

    /// ntfy's own rule for topic names.
    static func isValidTopic(_ topic: String) -> Bool {
        guard (1...64).contains(topic.count) else { return false }
        return topic.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }
    }

    private struct Portable: Codable {
        var s: String
        var t: String
        var k: String
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}
