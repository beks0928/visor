import AppKit
import EventKit
import Foundation
import Observation

struct CalendarEvent: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendar: String
    /// Ссылка на звонок (Zoom, Meet, Teams…), если она есть в событии.
    var joinURL: URL?
    var calendarID: String = ""
}

/// Календарь одной из учётных записей macOS (iCloud, Google, Exchange…).
struct CalendarInfo: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    /// Название учётной записи: «iCloud», «Gmail» и так далее.
    var account: String
    var writable: Bool
}

enum CalendarAccess: Sendable {
    case notDetermined, denied, granted
}

/// Источник событий. Настоящий это системный календарь, в проверках подставляется заглушка.
@MainActor
protocol CalendarSource: AnyObject {
    var access: CalendarAccess { get }
    func requestAccess() async -> Bool
    func calendars() -> [CalendarInfo]
    func events(in interval: DateInterval) -> [CalendarEvent]
    func defaultCalendarName() -> String?
    func create(title: String, start: Date, end: Date, calendarID: String?) throws -> CalendarEvent
}

/// Ссылки на звонки из места, заметок и адреса события.
enum ConferenceLink {
    private static let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
                                "whereby.com", "telemost.yandex.ru", "telemost.360.yandex.ru", "jazz.sber.ru", "skype.com",
                                "meet.jit.si", "discord.gg"]

    static func find(in texts: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for case let text? in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                if let url = match.url, let host = url.host?.lowercased(),
                   hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }
}

@MainActor
final class EventKitSource: CalendarSource {
    private let store = EKEventStore()

    var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied // writeOnly тоже: читать события с ним нельзя
        }
    }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func calendars() -> [CalendarInfo] {
        store.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title, writable: $0.allowsContentModifications)
        }
        .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    func events(in interval: DateInterval) -> [CalendarEvent] {
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: predicate).map(convert).sorted { $0.start < $1.start }
    }

    func defaultCalendarName() -> String? {
        store.defaultCalendarForNewEvents?.title
    }

    func create(title: String, start: Date, end: Date, calendarID: String?) throws -> CalendarEvent {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        // Выбранный календарь, если он есть и в него можно писать, иначе календарь по умолчанию.
        let chosen = calendarID.flatMap { store.calendar(withIdentifier: $0) }
        event.calendar = (chosen?.allowsContentModifications == true ? chosen : nil) ?? store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
        return convert(event)
    }

    private func convert(_ event: EKEvent) -> CalendarEvent {
        let id = (event.eventIdentifier ?? UUID().uuidString) + "@\(event.startDate.timeIntervalSince1970)"
        return CalendarEvent(
            id: id, title: event.title ?? "Без названия", start: event.startDate, end: event.endDate,
            isAllDay: event.isAllDay, calendar: event.calendar?.title ?? "",
            joinURL: ConferenceLink.find(in: [event.url?.absoluteString, event.location, event.notes]),
            calendarID: event.calendar?.calendarIdentifier ?? ""
        )
    }
}

/// События календаря для острова: ближайшие встречи, вкладка «Планы» и добавление события из строки ввода.
/// Доступ к календарю запрашивается, когда вы нажимаете «Разрешить», а не при запуске.
@MainActor @Observable
final class CalendarService {
    static let shared = CalendarService(source: EventKitSource())

    private(set) var access: CalendarAccess
    /// События от сейчас и на двое суток вперёд.
    private(set) var upcoming: [CalendarEvent] = []
    /// Все календари всех учётных записей.
    private(set) var calendars: [CalendarInfo] = []
    /// Календари, которые вы скрыли в Visor.
    private(set) var hidden: Set<String>
    /// Сколько календарей показывать одновременно; 0 — все включённые. Берутся первые по порядку в настройках.
    private(set) var limit: Int
    /// Календарь для новых событий. Если не выбран, берётся календарь по умолчанию.
    private(set) var targetID: String?
    /// Меняется раз в минуту, чтобы «через 42 мин» и таблетка перечитывались сами.
    private(set) var tick = 0

    @ObservationIgnored private let source: CalendarSource
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?

    private enum Key {
        static let hidden = "calendar.hidden"
        static let target = "calendar.target"
        static let limit = "calendar.limit"
    }

    static let limitOptions = [0, 1, 2, 3, 5]

    init(source: CalendarSource, defaults: UserDefaults = .standard) {
        self.source = source
        self.defaults = defaults
        access = source.access
        hidden = Set(defaults.stringArray(forKey: Key.hidden) ?? [])
        targetID = defaults.string(forKey: Key.target)
        limit = Self.limitOptions.contains(defaults.integer(forKey: Key.limit)) ? defaults.integer(forKey: Key.limit) : 0
    }

    func start() {
        access = source.access
        guard access == .granted else { return }
        refresh()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func requestAccess() async {
        let granted = await source.requestAccess()
        access = granted ? .granted : source.access
        if granted { start() }
    }

    func refresh() {
        tick += 1
        guard access == .granted else { return }
        calendars = source.calendars()
        let now = Date()
        upcoming = visible(source.events(in: DateInterval(start: now, end: now.addingTimeInterval(48 * 3600))))
    }

    func events(in interval: DateInterval) -> [CalendarEvent] {
        access == .granted ? visible(source.events(in: interval)) : []
    }

    private func visible(_ events: [CalendarEvent]) -> [CalendarEvent] {
        let allowed = shownIDs
        return events.filter { !hidden.contains($0.calendarID) && (allowed == nil || allowed?.contains($0.calendarID) == true) }
    }

    /// Номера календарей, которые попадают в Visor при заданном пределе; nil, если предела нет.
    var shownIDs: Set<String>? {
        guard limit > 0 else { return nil }
        return Set(calendars.filter { !hidden.contains($0.id) }.prefix(limit).map(\.id))
    }

    /// Включён ли календарь, но не влезает в предел.
    func isOverLimit(_ id: String) -> Bool {
        guard let shown = shownIDs else { return false }
        return !hidden.contains(id) && !shown.contains(id)
    }

    func setLimit(_ value: Int) {
        limit = Self.limitOptions.contains(value) ? value : 0
        defaults.set(limit, forKey: Key.limit)
        refresh()
    }

    // MARK: Выбор календарей

    func isVisible(_ id: String) -> Bool { !hidden.contains(id) }

    func setVisible(_ id: String, _ visible: Bool) {
        if visible { hidden.remove(id) } else { hidden.insert(id) }
        defaults.set(hidden.sorted(), forKey: Key.hidden)
        refresh()
    }

    func setTarget(_ id: String?) {
        targetID = id
        if let id { defaults.set(id, forKey: Key.target) } else { defaults.removeObject(forKey: Key.target) }
    }

    /// Название календаря, куда попадёт новое событие.
    var destinationName: String? {
        if let id = targetID, let found = calendars.first(where: { $0.id == id && $0.writable }) { return found.title }
        return source.defaultCalendarName()
    }

    /// Календари, сгруппированные по учётным записям.
    var calendarsByAccount: [(account: String, items: [CalendarInfo])] {
        Dictionary(grouping: calendars, by: \.account).map { (account: $0.key, items: $0.value) }.sorted { $0.account < $1.account }
    }

    /// Есть ли Google среди учётных записей.
    var hasGoogle: Bool {
        calendars.contains { $0.account.lowercased().contains("google") || $0.account.lowercased().contains("gmail") }
    }

    // MARK: Ближайшие встречи

    /// Ближайшее событие со временем, которое ещё не кончилось.
    func nextEvent(at now: Date = Date()) -> CalendarEvent? {
        upcoming.first { !$0.isAllDay && $0.end > now }
    }

    /// Ближайшее событие со ссылкой на звонок.
    func nextConference(at now: Date = Date()) -> CalendarEvent? {
        upcoming.first { !$0.isAllDay && $0.end > now && $0.joinURL != nil }
    }

    /// Событие, которое началось или начнётся в течение часа: о нём напоминает правая таблетка.
    func imminentEvent(at now: Date = Date()) -> CalendarEvent? {
        _ = tick
        return upcoming.first { !$0.isAllDay && $0.end > now && $0.start <= now.addingTimeInterval(3600) }
    }

    @discardableResult
    func create(_ entry: ParsedEntry) throws -> CalendarEvent {
        guard let start = entry.start else { throw CalendarError.noTime }
        let created = try source.create(title: entry.title, start: start,
                                        end: start.addingTimeInterval(TimeInterval(entry.durationMinutes * 60)),
                                        calendarID: targetID)
        refresh()
        return created
    }

    enum CalendarError: LocalizedError {
        case noTime

        var errorDescription: String? { "В строке нет времени." }
    }

    /// Ссылка на календарь по подписке: webcal://, https://…ics. Без разбора и без запросов из Visor, подписку оформляет «Календарь».
    nonisolated static func subscriptionURL(from text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("https://") { raw = "webcal://" + raw.dropFirst("https://".count) }
        else if raw.lowercased().hasPrefix("http://") { raw = "webcal://" + raw.dropFirst("http://".count) }
        guard raw.lowercased().hasPrefix("webcal://"), let url = URL(string: raw), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    /// Открывает приложение «Календарь» с подпиской: там нажимается «Подписаться».
    @discardableResult
    static func subscribe(_ text: String) -> Bool {
        guard let url = subscriptionURL(from: text) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    static func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
    }

    /// Открывает «Учётные записи интернета», где добавляется Google. Входить в аккаунт нужно вам самим.
    static func openInternetAccounts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
