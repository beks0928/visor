import Charts
import Foundation
import Observation
import SwiftUI

/// Пара валют из строки: сколько и во что переводится.
struct CurrencyPair: Equatable {
    let from: String
    let to: String
    let amount: Double

    /// Пара без суммы: по ней решается, нужна ли новая история.
    var key: String { from + ">" + to }
}

/// История курса за последние 30 дней из открытого архива (fawazahmed0/currency-api, без ключа).
/// Даты стоят на постоянной сетке (каждый третий день от начала эпохи), поэтому прошлые курсы не меняются,
/// запоминаются на диске и повторно не качаются: график открывается сразу, а в сеть уходит только новая точка.
/// К ним добавляется сегодняшний курс из `RatesStore`.
@MainActor @Observable
final class RateHistory {
    static let shared = RateHistory()

    struct Point: Identifiable, Equatable {
        let date: Date
        let rate: Double
        var id: Date { date }
    }

    private(set) var points: [Point] = []
    private(set) var isLoading = false
    private(set) var failed = false
    private(set) var key = ""

    /// «TRY>KZT|2026-11-03» → курс. Прошлые даты не меняются, поэтому кеш не устаревает.
    @ObservationIgnored private var stored: [String: Double]
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var task: Task<Void, Never>?

    nonisolated static let spanDays = 30
    nonisolated static let stepDays = 3

    init(file: URL = VisorPaths.supportDir.appendingPathComponent("rate-history.json")) {
        self.file = file
        stored = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: file))) ?? [:]
    }

    /// Грузит историю пары. Для той же пары повторно не грузит, пока она на экране. Известные дни берутся с диска сразу.
    func load(_ pair: CurrencyPair, live: Double?) {
        guard pair.key != key || failed else { return }
        key = pair.key
        failed = false
        task?.cancel()
        let now = Date()
        let days = Self.gridDays(now: now)
        points = known(pair, days: days, live: live, now: now)
        let missing = days.filter { stored[pair.key + "|" + $0.text] == nil }
        guard !missing.isEmpty else {
            isLoading = false
            failed = points.count < 2
            return
        }
        isLoading = points.count < 2
        let base = pair.from, target = pair.to.lowercased()
        task = Task { [weak self] in
            var fetched: [String: Double] = [:]
            await withTaskGroup(of: (String, Double?).self) { group in
                for day in missing { group.addTask { (day.text, await Self.fetch(base: base, date: day.text)?[target]) } }
                for await (text, rate) in group { if let rate { fetched[text] = rate } }
            }
            guard let self, !Task.isCancelled, key == pair.key else { return }
            for (text, rate) in fetched { stored[pair.key + "|" + text] = rate }
            persist(now: now)
            points = known(pair, days: days, live: live, now: now)
            failed = points.count < 2
            isLoading = false
        }
    }

    private func known(_ pair: CurrencyPair, days: [(date: Date, text: String)], live: Double?, now: Date) -> [Point] {
        var result = days.compactMap { day in stored[pair.key + "|" + day.text].map { Point(date: day.date, rate: $0) } }
        if let live, !result.isEmpty { result.append(Point(date: now, rate: live)) }
        return result
    }

    /// Пишет кеш на диск, выбросив даты старше 40 дней: файл не растёт.
    private func persist(now: Date) {
        let oldest = Self.dayText(now.addingTimeInterval(-40 * 86400))
        stored = stored.filter { entry in entry.key.split(separator: "|").last.map { String($0) >= oldest } ?? false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: file, options: .atomic) }
    }

    // MARK: Источник

    /// Дни сетки за последние 30 суток, кроме сегодняшнего: он приходит из живого курса.
    nonisolated static func gridDays(now: Date) -> [(date: Date, text: String)] {
        let today = Int(now.timeIntervalSince1970 / 86400)
        return ((today - spanDays)..<today).filter { $0 % stepDays == 0 }.map { day in
            let date = Date(timeIntervalSince1970: Double(day) * 86400 + 43200)
            return (date, dayText(date))
        }
    }

    nonisolated static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Файл на дату: `{"date":"2026-11-04","try":{"kzt":8.95,…}}`. Сначала jsDelivr, при неудаче зеркало.
    nonisolated static func fetch(base: String, date: String) async -> [String: Double]? {
        let code = base.lowercased()
        let urls = [
            "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@\(date)/v1/currencies/\(code).json",
            "https://\(date).currency-api.pages.dev/v1/currencies/\(code).json",
        ]
        for string in urls {
            guard let url = URL(string: string) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue("Visor", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let rates = parse(data, base: base) else { continue }
            return rates
        }
        return nil
    }

    nonisolated static func parse(_ data: Data, base: String) -> [String: Double]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let table = object[base.lowercased()] as? [String: Any] else { return nil }
        var rates: [String: Double] = [:]
        for (code, value) in table {
            if let number = value as? Double, number > 0 { rates[code] = number } else if let number = value as? Int, number > 0 { rates[code] = Double(number) }
        }
        return rates.isEmpty ? nil : rates
    }
}

/// График справа в карточке результата. Сумма из строки умножает курс: чем больше число, тем выше значения на графике.
struct RateChart: View {
    let pair: CurrencyPair
    let history: RateHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if history.points.count >= 2 { chart } else if history.failed {
                Text("История курса недоступна").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 96)
    }

    private var values: [(date: Date, value: Double)] { history.points.map { ($0.date, $0.rate * pair.amount) } }

    private var change: Double {
        guard let first = history.points.first?.rate, let last = history.points.last?.rate, first > 0 else { return 0 }
        return (last / first - 1) * 100
    }

    private var trend: Color { change >= 0 ? AgentState.done.color : Color(red: 1, green: 0.35, blue: 0.35) }

    private var chart: some View {
        let data = values
        let low = data.map(\.value).min() ?? 0, high = data.map(\.value).max() ?? 1
        let pad = max((high - low) * 0.15, high * 0.002)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(pair.from) → \(pair.to), 30 дней").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                Text(String(format: "%@%.1f %%", change >= 0 ? "+" : "−", abs(change)))
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(trend)
            }
            Chart(data, id: \.date) { item in
                AreaMark(x: .value("Дата", item.date), yStart: .value("Низ", low - pad), yEnd: .value("Значение", item.value))
                    .foregroundStyle(LinearGradient(colors: [trend.opacity(0.35), trend.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Дата", item.date), y: .value("Значение", item.value))
                    .foregroundStyle(trend).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: (low - pad)...(high + pad))
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(number.formatted(.number.notation(.compactName).precision(.significantDigits(3...4))))
                                .font(.system(size: 9, design: .rounded)).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: false)
                        .font(.system(size: 9)).foregroundStyle(Palette.muted)
                }
            }
        }
    }
}
