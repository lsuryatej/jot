import Foundation

/// Exchange rates for currency conversion.
///
/// Fetched from a free, no-API-key source and cached to disk, refreshed at
/// most once a day. Reads are always synchronous: the math evaluator runs on
/// every keystroke and cannot await a network call, so a background fetch
/// swaps the in-memory table in when it completes and nothing conversion-
/// related ever blocks on the network. Until the first fetch lands — offline,
/// or a fresh install — a fixed snapshot keeps conversions working at all,
/// just not exactly current.
enum CurrencyRates {
    private static var rates: [String: Double] = [
        "usd": 1.0, "eur": 1.17, "gbp": 1.34, "jpy": 0.0067,
        "inr": 0.0114, "cad": 0.72, "aud": 0.65, "chf": 1.24, "cny": 0.14,
    ]
    private static var lastFetched: Date?

    /// Mirrors `SettingsManager.fetchesLiveCurrencyRates`, pushed in from the
    /// app at launch and whenever the toggle changes. The math evaluator runs
    /// on every keystroke and has no view of the settings object, so the
    /// policy lives here, next to the rates it governs. Defaults to off, the
    /// same as the setting.
    static var liveRatesEnabled = false

    /// Whether two currencies can be combined implicitly, and if not, why.
    enum Availability {
        case ok
        case ratesOff
        case noRate
    }

    /// Implicit `+` and `-` hold a higher bar than the explicit `to` operator.
    /// `to` is a deliberate ask, so it falls back to the cached table or the
    /// built-in snapshot. A sum the user never asked to convert should show
    /// nothing rather than a number computed from a rate they opted out of.
    static func availability(from: String, to: String) -> Availability {
        guard liveRatesEnabled else { return .ratesOff }
        guard rates[from.lowercased()] != nil, rates[to.lowercased()] != nil else { return .noRate }
        return .ok
    }

    private static let cacheURL = NoteStore.defaultFileURL()
        .deletingLastPathComponent()
        .appendingPathComponent("currency-rates.json")

    // jsDelivr first; the maintainer's own Cloudflare Pages mirror as a
    // fallback, since both are free and neither guarantees uptime alone.
    private static let sources = [
        URL(string: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.json")!,
        URL(string: "https://latest.currency-api.pages.dev/v1/currencies/usd.json")!,
    ]

    private static let refreshInterval: TimeInterval = 86400

    private struct CachedRates: Codable {
        let date: String
        let usd: [String: Double]
    }

    /// The API reports "units of X per 1 USD" (e.g. inr: 95.7 means
    /// 1 USD = 95.7 INR). `rates` is kept as the reciprocal — USD value of
    /// one unit of X — matching the hand-written fallback table above and
    /// what `convert()` expects. Inverting here once, rather than adjusting
    /// the formula, keeps one convention everywhere in this file.
    private static func invert(_ unitsPerUSD: [String: Double]) -> [String: Double] {
        unitsPerUSD.compactMapValues { $0 > 0 ? 1.0 / $0 : nil }
    }

    /// Loads whatever is already cached on disk — this is never a network
    /// call — then refreshes in the background only if live rates are turned
    /// on. Call once at launch, and again whenever the setting changes.
    static func bootstrap(fetchesLive: Bool) {
        liveRatesEnabled = fetchesLive
        loadFromDisk()
        if fetchesLive { refreshIfNeeded() }
    }

    /// Also checked when the app becomes active, so a copy left running
    /// across midnight picks up the next day's rates without a relaunch.
    /// A no-op unless the setting is on: this is the one function in the app
    /// that can put a byte on the network, so the check happens here, at the
    /// single choke point, rather than being trusted to every call site.
    static func refreshIfNeeded(fetchesLive: Bool = true) {
        liveRatesEnabled = fetchesLive
        guard fetchesLive else { return }
        if let lastFetched, Date().timeIntervalSince(lastFetched) < refreshInterval { return }
        Task.detached(priority: .utility) {
            for source in sources where await fetch(from: source) { break }
        }
    }

    private static func loadFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CachedRates.self, from: data)
        else { return }
        var table = invert(cached.usd)
        table["usd"] = 1.0
        rates = table
        lastFetched = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate]) as? Date
    }

    @discardableResult
    private static func fetch(from url: URL) async -> Bool {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let cached = try JSONDecoder().decode(CachedRates.self, from: data)
            var table = invert(cached.usd)
            table["usd"] = 1.0
            // Rebound as a `let` before crossing the await below: a captured
            // `var` read on the other side of a suspension point is what
            // Swift 6 flags, even though nothing here actually races.
            let fetchedTable = table

            await MainActor.run {
                rates = fetchedTable
                lastFetched = Date()
            }

            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: .atomic)
            return true
        } catch {
            NSLog("Jot: currency rate fetch failed (\(url.host ?? "?")): \(error.localizedDescription)")
            return false
        }
    }

    static func convert(_ amount: Double, from: String, to: String) -> Result<MathExpression.Value, MathExpression.EvalError> {
        guard let fromRate = rates[from.lowercased()], let toRate = rates[to.lowercased()] else {
            return .failure(.unknownUnit(rates[from.lowercased()] == nil ? from : to))
        }
        let usd = amount * fromRate
        return .success(MathExpression.Value(amount: usd / toRate, unit: to.lowercased()))
    }
}
