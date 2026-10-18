import Foundation
import UserNotifications

func runWireTests() {
    suite("Pair codes") {
        let secret = PairSecret.generate()
        check(secret.code.hasPrefix("ember1."), "codes are versioned")
        equal(PairSecret(code: secret.code), secret, "a code round-trips")
        equal(PairSecret(code: secret.link), secret, "so does the link")
        equal(secret.code, secret.code, "the same pair always prints the same code")
        let code = secret.code
        let mangled = "  " + code.prefix(20) + "\n" + code.dropFirst(20) + " \n"
        equal(PairSecret(code: String(mangled)), secret, "line breaks and spaces from a chat app are ignored")
        equal(PairSecret(code: "hello"), nil, "garbage is rejected")
        equal(PairSecret(code: "ember1.e30"), nil, "an empty payload is rejected")
        check(PairSecret.isValidTopic(secret.topic), "the topic is a legal ntfy topic")
        check(secret.topic.count >= 24, "and long enough not to be guessed")
        equal(secret.key.count, 32, "256-bit key")
        check(PairSecret.generate() != secret, "every pair is different")
        check(!PairSecret.isValidTopic("has space"), "topic validation rejects spaces")
        check(!PairSecret.isValidTopic("ümlaut"), "and non-ASCII")
    }

    suite("Sealing") {
        let secret = PairSecret.generate()
        let envelope = Envelope(id: UUID(), from: UUID(), sentAt: Date(timeIntervalSince1970: 1_800_000_000.123), payload: .ping(.fire, label: "Call me 🔥"))
        let sealed = try! secret.seal(envelope)
        equal(try? secret.open(sealed), envelope, "sealed messages open with the same pair")
        check(!sealed.contains("Call me"), "the server sees no plaintext")
        check(sealed != (try! secret.seal(envelope)), "the same message seals differently each time")

        var otherKey = secret
        otherKey.key = PairSecret.generate().key
        check((try? otherKey.open(sealed)) == nil, "a different key can't open it")
        var otherTopic = secret
        otherTopic.topic = "ember-somewhere-else"
        check((try? otherTopic.open(sealed)) == nil, "a message replayed onto another topic is rejected")
        check((try? secret.open("not base64 at all!")) == nil, "junk on the topic is ignored")
    }

    suite("Every payload survives the wire") {
        let snapshot = Snapshot(
            name: "Riya", busyUntil: Date(timeIntervalSince1970: 1_800_000_000), away: true,
            presenceAt: Date(timeIntervalSince1970: 1_799_999_000), quietHours: .default,
            visit: VisitState(plan: VisitPlan(start: Date(timeIntervalSince1970: 1_801_000_000), end: Date(timeIntervalSince1970: 1_801_300_000)), updatedAt: Date(timeIntervalSince1970: 1_799_000_000))
        )
        let payloads: [Payload] = [
            .ping(.missYou, label: nil),
            .ping(.spicier, label: "Boner alert 🍆"),
            .reply(.giveMe20, to: UUID()),
            .received(UUID()),
            .snapshot(snapshot, wantsReply: true),
            .snapshot(Snapshot(name: "", busyUntil: nil, away: false, presenceAt: .distantPast, quietHours: nil, visit: .empty), wantsReply: false),
        ]
        for payload in payloads {
            let envelope = Envelope(id: UUID(), from: UUID(), sentAt: Date(timeIntervalSince1970: 1_800_000_000.5), payload: payload)
            let data = try! Wire.encoder().encode(envelope)
            equal(try? Wire.decoder().decode(Envelope.self, from: data), envelope, String("\(payload)".prefix(40)) + "…")
        }
    }

    suite("Messages fit ntfy's 4 KB limit") {
        let secret = PairSecret.generate()
        let label = String(repeating: "🍆", count: 80)
        let ping = Envelope(id: UUID(), from: UUID(), sentAt: Date(), payload: .ping(.fire, label: label))
        check(try! secret.seal(ping).utf8.count < 4096, "a ping with the longest label")
        let snapshot = Snapshot(
            name: String(repeating: "N", count: 200), busyUntil: Date(), away: false, presenceAt: Date(),
            quietHours: .default, visit: VisitState(plan: VisitPlan(start: Date(), end: Date()), updatedAt: Date())
        )
        let state = Envelope(id: UUID(), from: UUID(), sentAt: Date(), payload: .snapshot(snapshot, wantsReply: true))
        check(try! secret.seal(state).utf8.count < 4096, "a full snapshot")
    }

    suite("Notification buttons map to actions") {
        let id = UUID()
        if case .reply(let reply, let pingID) = Notifier.action(identifier: "reply.same", category: "ping.distance", pingID: id) {
            equal(reply, .same, "a reply button is that reply")
            equal(pingID, id, "to that ping")
        } else {
            check(false, "a reply button is a reply")
        }
        if case .call = Notifier.action(identifier: "call", category: "call", pingID: nil) {
            check(true, "the call button calls")
        } else {
            check(false, "the call button calls")
        }
        if case .call = Notifier.action(identifier: "com.apple.UNNotificationDefaultActionIdentifier", category: "call", pingID: nil) {
            check(true, "clicking a FaceTime alert calls")
        } else {
            check(false, "clicking a FaceTime alert calls")
        }
        if case .open = Notifier.action(identifier: "com.apple.UNNotificationDefaultActionIdentifier", category: "ping.distance", pingID: id) {
            check(true, "clicking a ping opens the menu")
        } else {
            check(false, "clicking a ping opens the menu")
        }
        if case .open = Notifier.action(identifier: "reply.notARealReply", category: "ping.distance", pingID: id) {
            check(true, "an unknown button does nothing harmful")
        } else {
            check(false, "an unknown button does nothing harmful")
        }
        let categories = Notifier.categories()
        equal(Set(categories.map(\.identifier)), ["ping.distance", "ping.together", "call"], "every alert category is registered")
        equal(categories.first { $0.identifier == "ping.distance" }?.actions.map(\.title), Reply.distance.map(\.text), "distance pings get the FaceTime set")
    }

    suite("The ntfy stream parser") {
        let transport = NtfyTransport(server: PairSecret.defaultServer, topic: "t", lastEventID: nil)
        let newline = Data([0x0A])
        var messages: [String] = []
        var statuses: [NtfyTransport.Status] = []
        transport.onMessage = { id, body in messages.append(id + ":" + body) }
        transport.onStatus = { statuses.append($0) }

        transport.consume(Data(#"{"id":"o1","event":"open"}"#.utf8) + newline)
        transport.consume(Data(#"{"id":"m1","event":"mess"#.utf8))
        equal(messages, [], "half a line waits for the rest")
        transport.consume(Data(#"age","message":"hello"}"#.utf8) + newline + Data(#"{"id":"k1","event":"keepalive"}"#.utf8) + newline)
        equal(messages, ["m1:hello"], "a line split across chunks is one message")
        equal(statuses, [.online], "open means online")
        equal(transport.lastEventID, "m1", "remembers where it got to, for catching up")
        transport.consume(Data("not json\n\n".utf8))
        equal(messages.count, 1, "junk lines are skipped")
    }

    suite("Saved app state") {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        var store = Store()
        store.pair = PairSecret.generate()
        store.engine.settings.myName = "Surya"
        store.lastEventID = "abc"
        store.save(to: url)
        let loaded = Store.load(from: url)
        equal(loaded.pair, store.pair, "the pair survives a restart")
        equal(loaded.deviceID, store.deviceID, "so does the device id")
        equal(loaded.engine, store.engine, "and the engine state")
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        equal(permissions?.intValue, 0o600, "readable only by you")

        try! Data("{ broken".utf8).write(to: url)
        let fresh = Store.load(from: url)
        equal(fresh.pair, nil, "an unreadable file starts fresh")
        check(FileManager.default.fileExists(atPath: url.path + ".unreadable"), "but keeps a copy instead of losing it")
    }
}
