import Foundation
import Observation

/// Курсы валют. Берутся из открытого источника open.er-api.com раз в час, пока открыта вкладка «Инструменты»,
/// и запоминаются на диске. Без сети остаётся последний сохранённый курс, а если и его нет, встроенный снимок.
@MainActor @Observable
final class RatesStore {
    static let shared = RatesStore(directory: VisorPaths.supportDir)

    private(set) var table: RateTable
    private(set) var isRefreshing = false
    /// Сообщение о последней неудаче. Пусто, если всё хорошо.
    private(set) var lastError: String?
    /// Когда мы в последний раз успешно спрашивали источник.
    private(set) var fetchedAt: Date?

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let endpoint: URL
    @ObservationIgnored var clock: () -> Date = { Date() }

    static let maxAge: TimeInterval = 3600

    init(directory: URL, endpoint: URL = URL(string: "https://open.er-api.com/v6/latest/USD")!) {
        self.directory = directory
        self.endpoint = endpoint
        url = directory.appendingPathComponent("rates.json")
        table = .builtIn
        loadCache()
    }

    /// Курс устарел, если с последнего успешного запроса прошёл больше часа.
    var isStale: Bool {
        guard let fetchedAt else { return true }
        return clock().timeIntervalSince(fetchedAt) > Self.maxAge
    }

    func refreshIfNeeded() {
        guard isStale, !isRefreshing else { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.setValue("Visor", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RatesError.badStatus }
            let parsed = try Self.parse(data)
            table = parsed
            fetchedAt = clock()
            lastError = nil
            save()
        } catch {
            lastError = "Нет сети или источник не отвечает. Показан последний курс."
        }
    }

    enum RatesError: Error { case badStatus, invalid }

    /// Ответ open.er-api.com: `{"result":"success","time_last_update_unix":…,"rates":{"USD":1,"KZT":453.3,…}}`.
    nonisolated static func parse(_ data: Data) throws -> RateTable {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["result"] as? String == "success",
              let rates = object["rates"] as? [String: Any] else { throw RatesError.invalid }
        var perUSD: [String: Double] = [:]
        for (code, value) in rates {
            if let number = value as? Double, number > 0 { perUSD[code] = number } else if let number = value as? Int, number > 0 { perUSD[code] = Double(number) }
        }
        guard perUSD["USD"] != nil, perUSD.count > 20 else { throw RatesError.invalid }
        let stamp = (object["time_last_update_unix"] as? Double) ?? (object["time_last_update_unix"] as? Int).map(Double.init)
        return RateTable(perUSD: perUSD, updated: stamp.map(Date.init(timeIntervalSince1970:)) ?? Date())
    }

    // MARK: Хранение

    private func loadCache() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let cached = try? decoder.decode(RateTable.self, from: data), cached.perUSD["USD"] != nil {
            table = cached
            // Кеш считается свежим с момента, когда мы его записали.
            fetchedAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(table) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Валюта по умолчанию: куда переводится сумма, если «в чём» не сказано.
@MainActor @Observable
final class ToolsSettings {
    static let shared = ToolsSettings(defaults: .standard)

    private(set) var defaultCurrency: String
    @ObservationIgnored private let defaults: UserDefaults

    static let popular = ["KZT", "USD", "RUB", "EUR"]
    static let more = ["GBP", "CNY", "TRY", "UAH", "JPY", "KRW", "AED", "PLN", "CHF", "GEL", "UZS", "KGS", "CAD", "AUD", "INR"]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        defaultCurrency = defaults.string(forKey: "tools.defaultCurrency") ?? "KZT"
    }

    func setDefaultCurrency(_ code: String) {
        defaultCurrency = code
        defaults.set(code, forKey: "tools.defaultCurrency")
    }
}
