import Foundation

/// Talks to an ntfy server: one long-lived JSON stream to receive, one POST
/// per message to send.
///
/// The stream is plain `GET /<topic>/json`, newline-delimited JSON. ntfy
/// writes a keepalive every 45 seconds, so a request timeout a bit above that
/// doubles as a liveness check: a socket that silently died (sleep, Wi-Fi
/// hop) times out and reconnects instead of hanging forever. Reconnects ask
/// for everything since the last event seen, which ntfy.sh keeps for 12
/// hours, so a Mac that was asleep catches up on what it missed.
final class NtfyTransport: NSObject, URLSessionDataDelegate {
    enum Status: Equatable {
        case offline, connecting, online
    }

    /// Called on the main queue with the ntfy event id and the message body.
    var onMessage: ((_ eventID: String, _ body: String) -> Void)?
    /// Called on the main queue.
    var onStatus: ((Status) -> Void)?

    let server: URL
    let topic: String
    private(set) var lastEventID: String?
    private(set) var status: Status = .offline {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var retryDelay: TimeInterval = 1
    private var retryWork: DispatchWorkItem?
    private var running = false

    init(server: URL, topic: String, lastEventID: String?) {
        self.server = server
        self.topic = topic
        self.lastEventID = lastEventID
    }

    private var topicURL: URL { server.appendingPathComponent(topic) }

    func start() {
        running = true
        connect()
    }

    func stop() {
        running = false
        retryWork?.cancel()
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        status = .offline
    }

    /// After a wake or a network change the old socket is usually dead
    /// without knowing it yet; this skips the wait for it to time out.
    func reconnectNow() {
        guard running else { return }
        retryDelay = 1
        connect()
    }

    private func connect() {
        retryWork?.cancel()
        task?.cancel()
        buffer = Data()

        if session == nil {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 100
            configuration.timeoutIntervalForResource = 24 * 3600
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        }

        var components = URLComponents(url: topicURL.appendingPathComponent("json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "since", value: lastEventID ?? "12h")]
        guard let url = components.url, let session else { return }

        let task = session.dataTask(with: url)
        self.task = task
        status = .connecting
        task.resume()
    }

    /// Sends one message, retrying a few times on failure. `completion`
    /// runs on the main queue once it lands or every attempt has failed.
    func publish(_ body: String, completion: @escaping (Bool) -> Void) {
        publish(body, attempt: 0, completion: completion)
    }

    private func publish(_ body: String, attempt: Int, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: topicURL)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        let delays: [TimeInterval] = [2, 5, 15]
        URLSession.shared.dataTask(with: request) { _, response, error in
            let delivered = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                guard !delivered, attempt < delays.count else {
                    completion(delivered)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
                    guard let self else { return completion(false) }
                    self.publish(body, attempt: attempt + 1, completion: completion)
                }
            }
        }.resume()
    }

    // MARK: - Stream

    private struct Event: Decodable {
        let id: String?
        let event: String
        let message: String?
    }

    /// Splits the stream into lines. Exposed for tests: a chunk can end
    /// mid-line, and that's the case worth checking.
    func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard !line.isEmpty, let event = try? JSONDecoder().decode(Event.self, from: line) else { return }
        switch event.event {
        case "open":
            retryDelay = 1
            status = .online
        case "message":
            guard let id = event.id else { return }
            lastEventID = id
            if let body = event.message { onMessage?(id, body) }
        default:
            break // keepalive, poll_request
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard dataTask === task, (response as? HTTPURLResponse)?.statusCode == 200 else {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task else { return }
        consume(data)
    }

    func urlSession(_ session: URLSession, task finished: URLSessionTask, didCompleteWithError error: Error?) {
        guard finished === task else { return }
        task = nil
        status = .offline
        guard running else { return }

        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
