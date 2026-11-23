import Foundation
import Observation

enum PlanHorizon: String, Codable, CaseIterable, Identifiable, Sendable {
    case day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Сегодня"
        case .week: "Неделя"
        case .month: "Месяц"
        }
    }
}

struct PlanTask: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var horizon: PlanHorizon
    /// Названная дата, если была: «завтра сдать домашку».
    var due: Date?
    var done: Bool
    var created: Date
    var doneAt: Date?
}

/// Ваши дела на сегодня, неделю и месяц. Сделанное убирается, когда период кончился.
@MainActor @Observable
final class PlansStore {
    static let shared = PlansStore(directory: VisorPaths.supportDir)

    private(set) var tasks: [PlanTask] = []

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let directory: URL
    @ObservationIgnored var clock: () -> Date

    init(directory: URL, clock: @escaping () -> Date = { Date() }) {
        self.directory = directory
        self.clock = clock
        url = directory.appendingPathComponent("plans.json")
        load()
        prune()
    }

    /// Сначала несделанные, потом сделанные, внутри групп по порядку добавления.
    func tasks(in horizon: PlanHorizon) -> [PlanTask] {
        let list = tasks.filter { $0.horizon == horizon }
        return list.filter { !$0.done } + list.filter(\.done)
    }

    func add(title: String, horizon: PlanHorizon, due: Date? = nil) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        tasks.append(PlanTask(id: UUID(), title: clean, horizon: horizon, due: due, done: false, created: clock(), doneAt: nil))
        save()
    }

    func toggle(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].done.toggle()
        tasks[index].doneAt = tasks[index].done ? clock() : nil
        save()
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        save()
    }

    /// Сделанное за прошлый день, неделю или месяц убирается. Несделанное остаётся и переходит дальше.
    func prune() {
        let now = clock()
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let startOfDay = calendar.startOfDay(for: now)
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfDay
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? startOfDay
        let before = tasks.count
        tasks.removeAll { task in
            guard task.done, let finished = task.doneAt else { return false }
            switch task.horizon {
            case .day: return finished < startOfDay
            case .week: return finished < startOfWeek
            case .month: return finished < startOfMonth
            }
        }
        if tasks.count != before { save() }
    }

    // MARK: Хранение

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        tasks = (try? decoder.decode([PlanTask].self, from: data)) ?? []
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tasks) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
