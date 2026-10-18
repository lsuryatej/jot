import Foundation

// Round-trips real messages through ntfy.sh on a fresh random topic: the one
// part of Ember the offline tests can't reach. Checks the stream parser
// against the real server, that sealed messages survive the trip byte for
// byte, and that a Mac coming back online catches up on exactly what it
// missed and nothing it already had.

var failures = 0

func check(_ condition: Bool, _ label: String) {
    print(condition ? "  ok   \(label)" : "  FAIL \(label)")
    if !condition { failures += 1 }
}

func published(_ effects: [Effect]) -> [Envelope] {
    effects.compactMap { if case .publish(let envelope) = $0 { return envelope } else { return nil } }
}

/// Spins the main run loop (where the transports deliver) until `done` or
/// the timeout.
func spin(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    return done()
}

let secret = PairSecret.generate()
print("topic \(secret.topic) on \(secret.server)")

let surya = Engine(deviceID: UUID())
let riya = Engine(deviceID: UUID())

let sender = NtfyTransport(server: secret.server, topic: secret.topic, lastEventID: nil)
let receiver = NtfyTransport(server: secret.server, topic: secret.topic, lastEventID: nil)
var arrived: [Envelope] = []
receiver.onMessage = { _, body in
    if let envelope = try? secret.open(body) { arrived.append(envelope) }
}

print("\nlive: stream")
receiver.start()
check(spin(20) { receiver.status == .online }, "the receiver connects")

func publish(_ envelope: Envelope) -> Bool {
    var result: Bool?
    sender.publish(try! secret.seal(envelope)) { result = $0 }
    _ = spin(30) { result != nil }
    return result == true
}

let ping = published(try! surya.send(.spicier, at: Date()))
check(ping.count == 1 && publish(ping[0]), "a sealed ping publishes")
check(spin(20) { arrived.count == 1 }, "and arrives on the other Mac")
check(arrived.first == ping.first, "byte for byte")

let effects = arrived.first.map { riya.receive($0, at: Date()) } ?? []
check(effects.contains { if case .notify = $0 { return true } else { return false } }, "and the engine turns it into a notification")

print("\nlive: catching up after being offline")
let resumeFrom = receiver.lastEventID
receiver.stop()
check(resumeFrom != nil, "the receiver knows where it got to")

let missed = Envelope(id: UUID(), from: UUID(), sentAt: Date(), payload: .reply(.giveMe20, to: ping[0].id))
check(publish(missed), "a reply is sent while the receiver is offline")

arrived = []
let resumed = NtfyTransport(server: secret.server, topic: secret.topic, lastEventID: resumeFrom)
resumed.onMessage = { _, body in
    if let envelope = try? secret.open(body) { arrived.append(envelope) }
}
resumed.start()
check(spin(20) { arrived.count >= 1 }, "reconnecting delivers what was missed")
_ = spin(3) { false } // anything extra would show up now
check(arrived == [missed], "and only that, not the ping it already had")
resumed.stop()

print("\nlive: junk on the topic")
var junkResult: Bool?
sender.publish("someone else's message") { junkResult = $0 }
_ = spin(20) { junkResult != nil }
check((try? secret.open("someone else's message")) == nil, "an unsealed message can't be opened, so it's dropped")

print(failures == 0 ? "\nlive: all green" : "\nlive: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
