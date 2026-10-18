import Foundation

// A dependency-free harness, the same shape as Jot's: no XCTest, no Xcode
// project, just an executable that prints and exits non-zero on failure.

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)  (\(file):\(line))")
    }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if actual == expected {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)  (\(file):\(line))")
        print("         expected: \(expected)")
        print("         actual:   \(actual)")
    }
}

func suite(_ name: String, _ body: () -> Void) {
    print("\n\(name)")
    body()
}

// MARK: - Fixtures

/// Both of you are on IST; tests pin it so they pass on a runner in UTC.
let ist: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}()

func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0) -> Date {
    ist.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

/// Two engines that have already said hello, so each knows the other's name.
/// Quiet hours start off so a test at any hour hears its sounds; tests that
/// care turn them on.
func makePair(at now: Date = at(2026, 11, 1)) -> (a: Engine, b: Engine) {
    var stateA = EngineState()
    stateA.settings.myName = "Surya"
    stateA.settings.quietHoursOn = false
    var stateB = EngineState()
    stateB.settings.myName = "Riya"
    stateB.settings.quietHoursOn = false
    let a = Engine(state: stateA, deviceID: UUID(), calendar: ist)
    let b = Engine(state: stateB, deviceID: UUID(), calendar: ist)
    let replies = deliver(a.hello(at: now), to: b, at: now)
    _ = deliver(replies, to: a, at: now)
    return (a, b)
}

func published(_ effects: [Effect]) -> [Envelope] {
    effects.compactMap { if case .publish(let envelope) = $0 { return envelope } else { return nil } }
}

func alerts(_ effects: [Effect]) -> [Alert] {
    effects.compactMap { if case .notify(let alert) = $0 { return alert } else { return nil } }
}

func scheduled(_ effects: [Effect]) -> [(Alert, Date)] {
    effects.compactMap { if case .schedule(let alert, let date) = $0 { return (alert, date) } else { return nil } }
}

func signals(_ effects: [Effect]) -> Int {
    effects.filter { $0 == .signal }.count
}

/// Hands every published envelope to the other engine, as ntfy would.
func deliver(_ effects: [Effect], to engine: Engine, at now: Date) -> [Effect] {
    published(effects).flatMap { engine.receive($0, at: now) }
}

func pings(_ envelopes: [Envelope]) -> [Envelope] {
    envelopes.filter { if case .ping = $0.payload { return true } else { return false } }
}
