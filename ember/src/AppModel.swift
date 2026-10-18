import AppKit
import Combine
import Network
import ServiceManagement

/// Everything Ember remembers, as one JSON file in Application Support.
///
/// Not the keychain: an ad-hoc signed app gets a new signature every build,
/// and the keychain would ask for your password after each update. The file
/// is readable only by you (0600), which is the same protection your other
/// app data has.
struct Store: Codable {
    var deviceID = UUID()
    var pair: PairSecret?
    var engine = EngineState()
    var lastEventID: String?
}

extension Store {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        deviceID = c.value(.deviceID, or: deviceID)
        pair = try? c.decodeIfPresent(PairSecret.self, forKey: .pair)
        engine = c.value(.engine, or: engine)
        lastEventID = try? c.decodeIfPresent(String.self, forKey: .lastEventID)
    }

    /// `EMBER_STATE=/some/file.json` runs Ember against another state file:
    /// how the smoke test drives the real app, and how you can run two copies
    /// on one Mac to try it alone.
    static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["EMBER_STATE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Ember", isDirectory: true).appendingPathComponent("state.json")
    }

    static func load(from url: URL) -> Store {
        guard let data = try? Data(contentsOf: url) else { return Store() }
        do {
            return try JSONDecoder().decode(Store.self, from: data)
        } catch {
            // Keep the unreadable file rather than overwrite it: losing the
            // pairing silently would be the worst outcome.
            NSLog("Ember: could not read \(url.path) (\(error)); starting fresh and keeping a copy")
            try? FileManager.default.copyItem(at: url, to: url.appendingPathExtension("unreadable"))
            return Store()
        }
    }

    func save(to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Ember: could not save state: \(error)")
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: EngineState
    @Published private(set) var pair: PairSecret?
    @Published private(set) var connection: NtfyTransport.Status = .offline
    /// Messages that couldn't be sent yet; retried when the stream is back.
    @Published private(set) var unsent = 0
    /// Without notifications a ping still plays its sound and lights the
    /// icon, but you'd never see it or its reply buttons, so the menu says so.
    @Published private(set) var notifications: Notifier.Permission = .unknown

    /// The menu bar icon's glow.
    var onSignal: (() -> Void)?
    var onSent: (() -> Void)?
    var onOpenMenu: (() -> Void)?

    private(set) var engine: Engine
    private var store: Store
    private let storeURL: URL
    private var transport: NtfyTransport?
    private var outbox: [String] = []
    private let notifier = Notifier()
    private let hotKey = HotKeyController()
    private var ticker: Timer?
    private var pathMonitor: NWPathMonitor?
    private var networkWasUp = true
    private var presenceWork: DispatchWorkItem?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(storeURL: URL = Store.defaultURL) {
        self.storeURL = storeURL
        let store = Store.load(from: storeURL)
        self.store = store
        self.engine = Engine(state: store.engine, deviceID: store.deviceID)
        self.state = store.engine
        self.pair = store.pair
    }

    // MARK: - Lifecycle

    func start() {
        notifier.onAction = { [weak self] action in
            MainActor.assumeIsolated { self?.handle(action) }
        }
        notifier.onPermission = { [weak self] permission in
            MainActor.assumeIsolated { self?.notifications = permission }
        }
        notifier.setUp()

        hotKey.onFire = { [weak self] in
            MainActor.assumeIsolated { self?.hotKeyPressed() }
        }
        hotKey.register(state.settings.hotKey)

        ticker = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        observePresence()
        observeNetwork()
        connect()
        tick()
    }

    func shutdown() {
        // Best effort: the request may not finish before the process exits,
        // in which case the other Mac shows "at their Mac" a little longer.
        if pair != nil { run(engine.setAway(true, at: Date())) }
        hotKey.unregister()
        store.lastEventID = transport?.lastEventID ?? store.lastEventID
        save()
    }

    // MARK: - Pairing

    @discardableResult
    func createPair() -> PairSecret {
        let secret = PairSecret.generate()
        adopt(secret)
        return secret
    }

    func join(code: String) -> Bool {
        guard let secret = PairSecret(code: code) else { return false }
        if secret == pair { return true }
        adopt(secret)
        return true
    }

    func unpair() {
        transport?.stop()
        transport = nil
        connection = .offline
        store.pair = nil
        store.lastEventID = nil
        pair = nil
        outbox = []
        unsent = 0
        engine = Engine(state: EngineState(settings: engine.state.settings), deviceID: store.deviceID)
        sync()
    }

    private func adopt(_ secret: PairSecret) {
        store.pair = secret
        store.lastEventID = nil
        pair = secret
        outbox = []
        unsent = 0
        engine = Engine(state: EngineState(settings: engine.state.settings), deviceID: store.deviceID)
        sync()
        connect()
    }

    // MARK: - Things you do

    /// Returns why it didn't send, or nil if it did.
    @discardableResult
    func send(_ level: Level) -> String? {
        guard pair != nil else { return "Pair first." }
        do {
            let effects = try engine.send(level, at: Date())
            run(effects)
            onSent?()
            return nil
        } catch SendRefusal.coolingDown(let seconds) {
            return "Easy. \(seconds)s."
        } catch {
            return error.localizedDescription
        }
    }

    func reply(_ reply: Reply, to pingID: UUID) {
        guard pair != nil else { return }
        run(engine.reply(reply, to: pingID, at: Date()))
        onSent?()
    }

    func setBusy(for minutes: Int) {
        run(engine.setBusy(until: Date().addingTimeInterval(TimeInterval(minutes * 60)), at: Date()))
    }

    func setBusyUntilMorning() {
        let calendar = Calendar.current
        let morning = calendar.nextDate(after: Date(), matching: DateComponents(hour: 9), matchingPolicy: .nextTime) ?? Date()
        run(engine.setBusy(until: morning, at: Date()))
    }

    func clearBusy() {
        run(engine.setBusy(until: nil, at: Date()))
    }

    func setVisit(_ plan: VisitPlan?) {
        run(engine.setVisit(plan, at: Date()))
    }

    func updateSettings(_ settings: Settings) {
        let hotKeyChanged = settings.hotKey != engine.state.settings.hotKey
        run(engine.updateSettings(settings, at: Date()))
        if hotKeyChanged { hotKey.register(settings.hotKey) }
    }

    func sendTestNotification() {
        notifier.show(Alert(
            id: "test-" + UUID().uuidString,
            title: engine.partnerName,
            body: Level.spicy.emoji + " This is what a ping looks like",
            category: .pingDistance,
            sound: Level.spicy.sound
        ))
    }

    /// Re-read each time the menu opens: the fix happens in System Settings,
    /// and there's no notification for coming back from there.
    func refreshNotificationPermission() {
        notifier.checkPermission { [weak self] permission in
            MainActor.assumeIsolated {
                if self?.notifications != permission { self?.notifications = permission }
            }
        }
    }

    func startFaceTime() {
        let handle = engine.state.settings.partnerHandle.filter { !$0.isWhitespace }
        if !handle.isEmpty, let url = URL(string: "facetime://" + handle) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/FaceTime.app"))
        }
    }

    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchesAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Ember: launch at login change failed: \(error)")
        }
        objectWillChange.send()
    }

    // MARK: - Plumbing

    private func hotKeyPressed() {
        if send(state.settings.hotKeyLevel) != nil {
            NSSound(named: NSSound.Name("Basso"))?.play()
        }
    }

    private func handle(_ action: Notifier.Action) {
        switch action {
        case .reply(let reply, let pingID): self.reply(reply, to: pingID)
        case .call: startFaceTime()
        case .open: onOpenMenu?()
        }
    }

    private func connect() {
        transport?.stop()
        transport = nil
        guard let pair else {
            connection = .offline
            return
        }
        let transport = NtfyTransport(server: pair.server, topic: pair.topic, lastEventID: store.lastEventID)
        transport.onMessage = { [weak self] eventID, body in
            MainActor.assumeIsolated { self?.received(eventID: eventID, body: body) }
        }
        transport.onStatus = { [weak self] status in
            MainActor.assumeIsolated { self?.connectionChanged(status) }
        }
        self.transport = transport
        transport.start()
        run(engine.hello(at: Date()))
    }

    private func connectionChanged(_ status: NtfyTransport.Status) {
        connection = status
        if status == .online { flushOutbox() }
    }

    private func received(eventID: String, body: String) {
        store.lastEventID = eventID
        guard let pair, let envelope = try? pair.open(body) else { return }
        run(engine.receive(envelope, at: Date()))
    }

    private func tick() {
        guard pair != nil else { return }
        run(engine.tick(at: Date()))
    }

    private func run(_ effects: [Effect]) {
        for effect in effects {
            switch effect {
            case .publish(let envelope): publish(envelope)
            case .notify(let alert): notifier.show(alert)
            case .schedule(let alert, let date): notifier.schedule(alert, at: date)
            case .signal: onSignal?()
            case .startFaceTime: startFaceTime()
            }
        }
        sync()
    }

    private func publish(_ envelope: Envelope) {
        guard let pair, let sealed = try? pair.seal(envelope) else { return }
        guard let transport else {
            enqueue(sealed)
            return
        }
        transport.publish(sealed) { [weak self] delivered in
            MainActor.assumeIsolated {
                if !delivered { self?.enqueue(sealed) }
            }
        }
    }

    private func enqueue(_ sealed: String) {
        outbox.append(sealed)
        if outbox.count > 50 { outbox.removeFirst(outbox.count - 50) }
        unsent = outbox.count
    }

    private func flushOutbox() {
        guard let transport, !outbox.isEmpty else { return }
        let pending = outbox
        outbox = []
        unsent = 0
        for sealed in pending {
            transport.publish(sealed) { [weak self] delivered in
                MainActor.assumeIsolated {
                    if !delivered { self?.enqueue(sealed) }
                }
            }
        }
    }

    private func sync() {
        state = engine.state
        pair = store.pair
        store.engine = engine.state
        if let transport { store.lastEventID = transport.lastEventID ?? store.lastEventID }
        save()
    }

    private func save() {
        store.save(to: storeURL)
    }

    // MARK: - Presence

    /// "At their Mac" follows the screen lock, not mouse movement: unlocking
    /// is a deliberate "I'm here", and it's a handful of messages a day
    /// instead of a heartbeat (ntfy.sh allows 250 a day). Changes settle for
    /// a few seconds first so a quick lock and unlock sends nothing.
    private func observePresence() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter

        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.presenceChanged(away: true, after: 30) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.presenceChanged(away: false, after: 5) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.presenceChanged(away: true, after: 30) }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.presenceChanged(away: true, after: 0) }
        observe(workspace, NSWorkspace.didWakeNotification) { model in
            model.transport?.reconnectNow()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping (AppModel) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self)
            }
        }
        observers.append((center, token))
    }

    private func presenceChanged(away: Bool, after delay: TimeInterval) {
        presenceWork?.cancel()
        guard pair != nil else { return }
        if delay == 0 {
            run(engine.setAway(away, at: Date()))
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.run(self.engine.setAway(away, at: Date()))
            }
        }
        presenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func observeNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            MainActor.assumeIsolated {
                guard let self else { return }
                if up && !self.networkWasUp { self.transport?.reconnectNow() }
                self.networkWasUp = up
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }
}
