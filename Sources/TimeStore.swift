import Foundation
import Observation

enum TimeSub: String, CaseIterable, Identifiable {
    case pomodoro, timer, stopwatch, clocks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pomodoro: "Pomodoro"
        case .timer: "Таймер"
        case .stopwatch: "Секундомер"
        case .clocks: "Часы"
        }
    }
}

/// Обратный отсчёт. Идёт (`endAt`), стоит на паузе (`pausedRemaining`) или закончился (`finishedAt`).
struct Countdown: Codable, Equatable, Sendable {
    var total: TimeInterval
    var label: String
    var endAt: Date?
    var pausedRemaining: TimeInterval?
    var finishedAt: Date?
}

struct ZoneInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

enum TimeFormat {
    /// 18:42 или 1:05:00.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%02d:%02d", minutes, secs)
    }

    /// 01:23.4 для секундомера.
    static func stopwatch(_ seconds: TimeInterval) -> String {
        let tenths = Int(seconds * 10) % 10
        let whole = Int(seconds)
        return String(format: "%02d:%02d.%d", whole / 60, whole % 60, tenths)
    }
}

/// Таймер, Pomodoro, секундомер и мировые часы. Таймер переживает перезапуск приложения.
@MainActor @Observable
final class TimeStore {
    static let shared = TimeStore(defaults: .standard)

    var sub: TimeSub = .pomodoro
    private(set) var countdown: Countdown?
    private(set) var swAccumulated: TimeInterval = 0
    private(set) var swStartedAt: Date?
    private(set) var laps: [TimeInterval] = []
    private(set) var zones: [String]

    /// Через подмену часов тесты проверяют время без ожидания.
    @ObservationIgnored var clock: () -> Date = { Date() }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var endTask: Task<Void, Never>?
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    /// Закончившийся таймер остаётся на виду две минуты, как «готово» у агента.
    static let finishedLifetime: TimeInterval = 120
    /// За столько секунд до конца кольцо становится янтарным.
    static let warnBefore: TimeInterval = 300

    static let catalog: [ZoneInfo] = [
        ZoneInfo(id: "Asia/Almaty", name: "Алматы"), ZoneInfo(id: "Europe/Moscow", name: "Москва"),
        ZoneInfo(id: "Europe/London", name: "Лондон"), ZoneInfo(id: "Europe/Paris", name: "Париж"),
        ZoneInfo(id: "Europe/Istanbul", name: "Стамбул"), ZoneInfo(id: "Asia/Dubai", name: "Дубай"),
        ZoneInfo(id: "Asia/Shanghai", name: "Пекин"), ZoneInfo(id: "Asia/Tokyo", name: "Токио"),
        ZoneInfo(id: "Asia/Seoul", name: "Сеул"), ZoneInfo(id: "Australia/Sydney", name: "Сидней"),
        ZoneInfo(id: "America/New_York", name: "Нью-Йорк"), ZoneInfo(id: "America/Los_Angeles", name: "Лос-Анджелес"),
    ]

    private enum Key {
        static let countdown = "time.countdown"
        static let zones = "time.zones"
    }

    init(defaults: UserDefaults, clock: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.clock = clock
        zones = defaults.stringArray(forKey: Key.zones) ?? ["Asia/Almaty", "Europe/London", "America/New_York", "Asia/Tokyo"]
        restore()
    }

    // MARK: Обратный отсчёт

    var isRunning: Bool { countdown?.endAt != nil }
    var isPaused: Bool { countdown?.pausedRemaining != nil }
    var isFinished: Bool { countdown?.finishedAt != nil }

    func remaining(at date: Date) -> TimeInterval {
        guard let countdown else { return 0 }
        if countdown.finishedAt != nil { return 0 }
        if let end = countdown.endAt { return max(0, end.timeIntervalSince(date)) }
        return countdown.pausedRemaining ?? countdown.total
    }

    func start(seconds: TimeInterval, label: String) {
        guard seconds > 0 else { return }
        clearTask?.cancel()
        countdown = Countdown(total: seconds, label: label, endAt: clock().addingTimeInterval(seconds))
        schedule()
        saveCountdown()
    }

    func pause() {
        guard var current = countdown, current.endAt != nil else { return }
        current.pausedRemaining = remaining(at: clock())
        current.endAt = nil
        countdown = current
        endTask?.cancel()
        saveCountdown()
    }

    func resume() {
        guard var current = countdown, let left = current.pausedRemaining else { return }
        current.endAt = clock().addingTimeInterval(left)
        current.pausedRemaining = nil
        countdown = current
        schedule()
        saveCountdown()
    }

    func reset() {
        endTask?.cancel()
        clearTask?.cancel()
        countdown = nil
        saveCountdown()
    }

    private func schedule() {
        endTask?.cancel()
        guard let end = countdown?.endAt else { return }
        let delay = max(0, end.timeIntervalSince(clock()))
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        guard var current = countdown, current.endAt != nil else { return }
        let moment = clock()
        current.endAt = nil
        current.finishedAt = moment
        countdown = current
        saveCountdown()
        SoundEngine.shared.play(.timer)
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.finishedLifetime))
            guard !Task.isCancelled, self?.countdown?.finishedAt == moment else { return }
            self?.countdown = nil
            self?.saveCountdown()
        }
    }

    // MARK: Секундомер

    func swElapsed(at date: Date) -> TimeInterval {
        swAccumulated + (swStartedAt.map { date.timeIntervalSince($0) } ?? 0)
    }

    var swRunning: Bool { swStartedAt != nil }

    func swToggle() {
        if let started = swStartedAt {
            swAccumulated += clock().timeIntervalSince(started)
            swStartedAt = nil
        } else {
            swStartedAt = clock()
        }
    }

    func swLap() {
        guard swRunning else { return }
        laps.insert(swElapsed(at: clock()), at: 0)
    }

    func swReset() {
        swAccumulated = 0
        swStartedAt = nil
        laps = []
    }

    // MARK: Часы

    func addZone(_ id: String) {
        guard !zones.contains(id), TimeZone(identifier: id) != nil else { return }
        zones.append(id)
        defaults.set(zones, forKey: Key.zones)
    }

    func removeZone(_ id: String) {
        zones.removeAll { $0 == id }
        defaults.set(zones, forKey: Key.zones)
    }

    static func name(of zone: String) -> String {
        catalog.first { $0.id == zone }?.name ?? zone.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone
    }

    // MARK: Хранение

    private func saveCountdown() {
        guard let countdown else {
            defaults.removeObject(forKey: Key.countdown)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(countdown) { defaults.set(data, forKey: Key.countdown) }
    }

    /// После перезапуска идущий таймер продолжается. Тот, что закончился, пока приложение было закрыто, молча убирается.
    private func restore() {
        guard let data = defaults.data(forKey: Key.countdown) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode(Countdown.self, from: data) else { return }
        let now = clock()
        if let end = saved.endAt {
            guard end > now else { defaults.removeObject(forKey: Key.countdown); return }
            countdown = saved
            schedule()
        } else if let finished = saved.finishedAt {
            guard now.timeIntervalSince(finished) < Self.finishedLifetime else { defaults.removeObject(forKey: Key.countdown); return }
            countdown = saved
        } else {
            countdown = saved
        }
    }
}
