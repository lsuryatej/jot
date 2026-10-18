import Foundation

// Plays "the other Mac" against a real, running Ember.app. smoke.sh writes a
// paired state file with `prepare`, launches the app on it, then runs
// `exchange`, which checks the app end to end: it loads its pairing,
// connects to ntfy.sh, says hello, receives and decrypts a ping, acknowledges
// it, and saves it to its history.
//
//   EmberProbe prepare <state.json>
//   EmberProbe exchange <state.json>

var failures = 0

func check(_ condition: Bool, _ label: String) {
    print(condition ? "  ok   \(label)" : "  FAIL \(label)")
    if !condition { failures += 1 }
}

func spin(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    return done()
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: EmberProbe prepare|exchange <state.json>")
    exit(2)
}
let stateURL = URL(fileURLWithPath: arguments[2])

switch arguments[1] {
case "prepare":
    var store = Store()
    store.pair = PairSecret.generate()
    store.engine.settings.myName = "CI Mac"
    store.engine.settings.quietHoursOn = false
    store.save(to: stateURL)
    print("prepared \(stateURL.path) on topic \(store.pair!.topic)")
    exit(0)

case "exchange":
    let app = Store.load(from: stateURL)
    guard let secret = app.pair else {
        print("  FAIL no pairing in \(stateURL.path)")
        exit(1)
    }

    let me = Engine(deviceID: UUID())
    let transport = NtfyTransport(server: secret.server, topic: secret.topic, lastEventID: nil)
    var fromApp: [Envelope] = []
    transport.onMessage = { _, body in
        if let envelope = try? secret.open(body), envelope.from == app.deviceID {
            fromApp.append(envelope)
        }
    }
    transport.start()

    func send(_ effects: [Effect]) {
        for case .publish(let envelope) in effects {
            var done = false
            transport.publish(try! secret.seal(envelope)) { _ in done = true }
            _ = spin(30) { done }
        }
    }

    print("\nsmoke: the real app, end to end")
    let helloArrived = spin(45) {
        fromApp.contains { if case .snapshot(_, true) = $0.payload { return true } else { return false } }
    }
    check(helloArrived, "the app loads its pairing, connects, and says hello")
    if let hello = fromApp.first(where: { if case .snapshot = $0.payload { return true } else { return false } }) {
        if case .snapshot(let snapshot, _) = hello.payload {
            check(snapshot.name == "CI Mac", "with its name, decrypted with the shared key")
        }
        send(me.receive(hello, at: Date()))
    }

    let ping = try! me.send(.spicy, at: Date())
    let pingID = ping.compactMap { effect -> UUID? in
        if case .publish(let envelope) = effect { return envelope.id } else { return nil }
    }.first!
    send(ping)

    let acked = spin(30) {
        fromApp.contains { if case .received(pingID) = $0.payload { return true } else { return false } }
    }
    check(acked, "it receives a ping, decrypts it, and acknowledges it")

    _ = spin(2) { false } // let the app write its state
    let after = Store.load(from: stateURL)
    check(after.engine.history.contains { $0.id == pingID && !$0.fromMe }, "and saves it to its history")
    check(after.engine.partner != nil, "it learned about the other Mac from the hello reply")
    check(after.lastEventID != nil, "it remembers where it got to on the stream")

    transport.stop()
    print(failures == 0 ? "\nsmoke: all green" : "\nsmoke: \(failures) FAILED")
    exit(failures == 0 ? 0 : 1)

default:
    print("unknown command \(arguments[1])")
    exit(2)
}
