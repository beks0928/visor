import AppKit
import SwiftUI

@MainActor
private enum PlanFormat {
    static let calendar: Calendar = {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // неделя с понедельника
        return calendar
    }()

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = format
        return formatter
    }

    static func hhmm(_ date: Date) -> String { time.string(from: date) }

    /// «сегодня», «завтра», «послезавтра» или «Пт 6 ноября».
    static func dayName(_ date: Date, now: Date = Date()) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "сегодня"
        case 1: return "завтра"
        case 2: return "послезавтра"
        default:
            let text = formatter("EEE d MMMM").string(from: date)
            return text.prefix(1).uppercased() + text.dropFirst()
        }
    }

    static func monthTitle(_ date: Date) -> String { formatter("LLLL yyyy").string(from: date) }
    static func dayNumber(_ date: Date) -> String { formatter("d").string(from: date) }

    static func range(_ event: CalendarEvent) -> String {
        event.isAllDay ? "весь день" : "\(hhmm(event.start))–\(hhmm(event.end))"
    }

    static func overlaps(_ event: CalendarEvent, day: Date) -> Bool {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return event.start < end && event.end > start
    }
}

/// Вкладка «Планы»: события календаря и ваши дела на сегодня, неделю и месяц, строка быстрого ввода.
struct PlansPage: View {
    let model: IslandModel
    let plans: PlansStore
    let calendar: CalendarService

    private var horizon: PlanHorizon { model.plansHorizon }
    @State private var input = ""
    @State private var notice: String?
    @State private var month = Date()
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var events: [CalendarEvent]
    @FocusState private var focused: Bool

    init(model: IslandModel, plans: PlansStore = .shared, calendar: CalendarService = .shared, horizon start: PlanHorizon? = nil) {
        self.model = model
        self.plans = plans
        self.calendar = calendar
        if let start { model.plansHorizon = start }
        _events = State(initialValue: Self.loadEvents(horizon: model.plansHorizon, month: Date(), calendar: calendar))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach(PlanHorizon.allCases) { item in
                    Button { model.plansHorizon = item } label: {
                        Text(item.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(horizon == item ? Palette.text : Palette.muted)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(horizon == item ? Palette.selected : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if let notice { Text(notice).font(.system(size: 12)).foregroundStyle(AgentState.done.color) }
            }
            inputField
            if let line = previewLine {
                Text(line).font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(2)
            }
            VScroll {
                VStack(alignment: .leading, spacing: 6) {
                    if calendar.access != .granted { AccessCard(calendar: calendar) }
                    switch horizon {
                    case .day: dayContent
                    case .week: weekContent
                    case .month: monthContent
                    }
                }
            }
        }
        .task(id: loadKey) { reload() }
        .onAppear { plans.prune() }
        .onChange(of: focused) { _, value in
            model.keepOpen = value
            // Окно острова неактивное: без этого ввод с клавиатуры уходил бы в другое приложение.
            if value { IslandController.shared.focusForTyping() }
        }
        .onDisappear { model.keepOpen = false }
    }

    // MARK: Ввод

    private var inputField: some View {
        TextField("завтра 16:00 репетитор 1ч, и Enter. Без времени это просто дело", text: $input)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .focused($focused)
            .onSubmit(submit)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Palette.accent : Palette.cardBorder))
    }

    private var previewLine: String? {
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let parsed = QuickParser.parse(input) else { return "Добавьте название." }
        if let start = parsed.start {
            let end = start.addingTimeInterval(TimeInterval(parsed.durationMinutes * 60))
            let when = "\(PlanFormat.dayName(start)) \(PlanFormat.hhmm(start))–\(PlanFormat.hhmm(end))"
            if calendar.access == .granted {
                return "Событие «\(parsed.title)», \(when), календарь «\(calendar.destinationName ?? "по умолчанию")». Enter добавит."
            }
            return "Календарь не подключён: «\(parsed.title)» (\(when)) добавится как дело."
        }
        let target = parsed.horizon() ?? horizon
        return "Дело «\(parsed.title)» в списке «\(target.title)». Enter добавит."
    }

    private func submit() {
        guard let parsed = QuickParser.parse(input) else { return }
        notice = nil
        if parsed.isEvent, calendar.access == .granted {
            do {
                try calendar.create(parsed)
                notice = "Добавлено в календарь «\(calendar.destinationName ?? "по умолчанию")»"
            } catch {
                notice = "Не получилось добавить событие: \(error.localizedDescription)"
                return
            }
        } else {
            let title = parsed.isEvent ? "\(parsed.title) · \(PlanFormat.dayName(parsed.start ?? Date())) \(PlanFormat.hhmm(parsed.start ?? Date()))" : parsed.title
            plans.add(title: title, horizon: parsed.horizon() ?? horizon, due: parsed.date)
            notice = "Добавлено в дела"
        }
        input = ""
        reload()
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            notice = nil
        }
    }

    // MARK: Загрузка событий

    private var loadKey: String {
        "\(horizon.rawValue)-\(PlanFormat.calendar.dateInterval(of: .month, for: month)?.start.timeIntervalSince1970 ?? 0)-\(calendar.tick)-\(calendar.access)"
    }

    private func reload() {
        events = Self.loadEvents(horizon: horizon, month: month, calendar: calendar)
    }

    private static func loadEvents(horizon: PlanHorizon, month: Date, calendar: CalendarService) -> [CalendarEvent] {
        let cal = PlanFormat.calendar
        let today = cal.startOfDay(for: Date())
        let interval: DateInterval
        switch horizon {
        case .day:
            interval = DateInterval(start: today, end: cal.date(byAdding: .day, value: 1, to: today) ?? today)
        case .week:
            interval = DateInterval(start: today, end: cal.date(byAdding: .day, value: 7, to: today) ?? today)
        case .month:
            let start = gridStart(for: month)
            interval = DateInterval(start: start, end: cal.date(byAdding: .day, value: 42, to: start) ?? start)
        }
        return calendar.events(in: interval)
    }

    // MARK: Сегодня

    @ViewBuilder
    private var dayContent: some View {
        if let next = calendar.nextEvent() { MeetingCard(event: next) }
        label("События сегодня")
        let today = events.filter { PlanFormat.overlaps($0, day: Date()) }
        if today.isEmpty {
            hint(calendar.access == .granted ? "Событий нет." : "События появятся после подключения календаря.")
        } else {
            ForEach(today) { EventRow(event: $0) }
        }
        tasksSection(.day, title: "Дела на сегодня")
    }

    // MARK: Неделя

    @ViewBuilder
    private var weekContent: some View {
        let cal = PlanFormat.calendar
        let today = cal.startOfDay(for: Date())
        ForEach(0..<7, id: \.self) { offset in
            let day = cal.date(byAdding: .day, value: offset, to: today) ?? today
            let dayEvents = events.filter { PlanFormat.overlaps($0, day: day) }
            label(PlanFormat.dayName(day))
            if dayEvents.isEmpty {
                hint("Свободно")
            } else {
                ForEach(dayEvents) { EventRow(event: $0) }
            }
        }
        tasksSection(.week, title: "Дела на неделю")
    }

    // MARK: Месяц

    private var gridStart: Date { Self.gridStart(for: month) }

    private static func gridStart(for month: Date) -> Date {
        let cal = PlanFormat.calendar
        let first = cal.dateInterval(of: .month, for: month)?.start ?? month
        let offset = (cal.component(.weekday, from: first) + 5) % 7 // понедельник это 0
        return cal.date(byAdding: .day, value: -offset, to: first) ?? first
    }

    @ViewBuilder
    private var monthContent: some View {
        let cal = PlanFormat.calendar
        let start = gridStart
        let today = cal.startOfDay(for: Date())
        HStack {
            monthButton("chevron.left", by: -1)
            Text(PlanFormat.monthTitle(month)).font(.system(size: 13, weight: .medium)).frame(minWidth: 130)
            monthButton("chevron.right", by: 1)
            Spacer()
        }
        HStack(spacing: 4) {
            ForEach(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"], id: \.self) {
                Text($0).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity)
            }
        }
        VStack(spacing: 4) {
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { weekday in
                        let day = cal.date(byAdding: .day, value: week * 7 + weekday, to: start) ?? start
                        dayCell(day, today: today)
                    }
                }
            }
        }
        label(PlanFormat.dayName(selectedDay))
        let dayEvents = events.filter { PlanFormat.overlaps($0, day: selectedDay) }
        if dayEvents.isEmpty { hint("Событий нет.") } else { ForEach(dayEvents) { EventRow(event: $0) } }
        tasksSection(.month, title: "Дела на месяц")
    }

    private func dayCell(_ day: Date, today: Date) -> some View {
        let cal = PlanFormat.calendar
        let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
        let isToday = cal.isDate(day, inSameDayAs: today)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let busy = events.contains { PlanFormat.overlaps($0, day: day) }
        return Button { selectedDay = cal.startOfDay(for: day) } label: {
            VStack(spacing: 2) {
                Text(PlanFormat.dayNumber(day))
                    .font(.system(size: 12, weight: isToday ? .semibold : .regular))
                    .foregroundStyle(isToday ? Color.black : (inMonth ? Color.white : Color(white: 0.35)))
                Circle().fill(busy ? (isToday ? Color.black : Palette.accent) : .clear).frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(isToday ? Palette.accent : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected && !isToday ? Palette.accent : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func monthButton(_ symbol: String, by value: Int) -> some View {
        Button {
            month = PlanFormat.calendar.date(byAdding: .month, value: value, to: month) ?? month
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.card))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value < 0 ? "Прошлый месяц" : "Следующий месяц")
    }

    // MARK: Общее

    @ViewBuilder
    private func tasksSection(_ target: PlanHorizon, title: String) -> some View {
        label(title)
        let list = plans.tasks(in: target)
        if list.isEmpty {
            hint("Пока пусто. Напишите дело в строке выше и нажмите Enter.")
        } else {
            ForEach(list) { TaskRow(task: $0, plans: plans) }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .padding(.top, 6)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Palette.muted)
    }
}

struct EventRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(spacing: 10) {
            Text(PlanFormat.range(event))
                .font(.system(size: 11.5, design: .rounded).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .frame(width: 96, alignment: .leading)
            Text(event.title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            if !event.calendar.isEmpty {
                Text(event.calendar).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            if let url = event.joinURL {
                Button("Подключиться") { NSWorkspace.shared.open(url) }.buttonStyle(VisorButtonStyle(kind: .primary))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .listRow()
    }
}

struct TaskRow: View {
    let task: PlanTask
    let plans: PlansStore

    var body: some View {
        HStack(spacing: 10) {
            Button { plans.toggle(task.id) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(task.done ? AgentState.done.color : .clear)
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(task.done ? AgentState.done.color : Palette.muted, lineWidth: 1.5)
                    if task.done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black) }
                }
                .frame(width: 20, height: 20)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.done ? "Снять отметку" : "Отметить сделанным")
            Text(task.title)
                .font(.system(size: 13))
                .foregroundStyle(task.done ? Palette.muted : Color.white)
                .strikethrough(task.done)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let due = task.due, !task.done {
                Text(PlanFormat.dayName(due)).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Button { plans.remove(task.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Удалить дело")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .listRow()
    }
}

/// Ближайшая встреча: сколько осталось и кнопка «Подключиться», если в событии есть ссылка на звонок.
struct MeetingCard: View {
    let event: CalendarEvent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let started = event.start <= context.date
            let minutes = Int(ceil(event.start.timeIntervalSince(context.date) / 60))
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ближайшая встреча").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Text(event.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(started ? "идёт сейчас · до \(PlanFormat.hhmm(event.end))" : "через \(PlanFormat.humanMinutes(minutes)) · в \(PlanFormat.hhmm(event.start))")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                if let url = event.joinURL {
                    Button("Подключиться") { NSWorkspace.shared.open(url) }.buttonStyle(VisorButtonStyle(kind: .primary))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.accent.opacity(0.2)))
        }
    }
}

extension PlanFormat {
    /// 42 мин, 1 ч 05 мин, 3 ч.
    static func humanMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(max(minutes, 1)) мин" }
        let hours = minutes / 60, rest = minutes % 60
        if hours >= 24 { return "\(hours / 24) д" }
        return rest == 0 ? "\(hours) ч" : "\(hours) ч \(String(format: "%02d", rest)) мин"
    }
}

struct AccessCard: View {
    let calendar: CalendarService

    var body: some View {
        let denied = calendar.access == .denied
        VStack(alignment: .leading, spacing: 8) {
            Text(denied ? "Нет доступа к календарю" : "Календарь не подключён").font(.system(size: 13, weight: .semibold))
            Text(denied
                 ? "Разрешите доступ в настройках macOS: Конфиденциальность и безопасность, Календари."
                 : "Visor покажет ближайшие встречи и добавит события из строки ввода. Дела работают и без календаря.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            HStack(spacing: 8) {
                Button(denied ? "Открыть настройки" : "Разрешить доступ") {
                    if denied {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                            NSWorkspace.shared.open(url)
                        }
                    } else {
                        Task { await calendar.requestAccess() }
                    }
                }
                .buttonStyle(VisorButtonStyle(kind: .primary))
                Button("Добавить Google Календарь") { CalendarService.openInternetAccounts() }
                    .buttonStyle(VisorButtonStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AgentState.waiting.color.opacity(0.6)))
    }
}

/// Правая таблетка острова: событие, которое скоро начнётся или уже идёт.
struct MeetingCapsule: View {
    var calendar: CalendarService = .shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let event = calendar.imminentEvent(at: context.date) {
                let started = event.start <= context.date
                let title = event.title.count > 10 ? String(event.title.prefix(9)) + "…" : event.title
                Text(started ? "идёт · \(title)" : "\(PlanFormat.hhmm(event.start)) \(title)")
                    .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Color.white.opacity(0.10), in: Capsule())
                    .overlay(Capsule().stroke(started ? AgentState.done.color.opacity(0.7) : Palette.cardBorder))
            }
        }
    }
}
