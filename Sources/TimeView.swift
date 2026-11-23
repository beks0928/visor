import SwiftUI

/// Вкладка «Время»: Pomodoro, таймер, секундомер и мировые часы.
/// Переключатель всегда на одном месте по центру, а содержимое каждой подвкладки стоит в одной и той же сцене
/// (центр, одинаковая ширина), поэтому при переключении ничего не прыгает.
struct TimePage: View {
    let model: IslandModel
    var store: TimeStore = .shared

    /// Ширина сцены: одна для всех подвкладок.
    static let stageWidth: CGFloat = 640

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 2) {
                ForEach(TimeSub.allCases) { sub in
                    Button { store.sub = sub } label: {
                        Text(sub.title)
                            .font(.system(size: 12.5, weight: store.sub == sub ? .semibold : .regular))
                            .foregroundStyle(store.sub == sub ? Palette.text : Palette.muted)
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .background(store.sub == sub ? Palette.selected : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            Group {
                switch store.sub {
                case .pomodoro: CountdownPanel(store: store, kind: .pomodoro)
                case .timer: CountdownPanel(store: store, kind: .timer)
                case .stopwatch: StopwatchPanel(store: store)
                case .clocks: ClocksPanel(store: store)
                }
            }
            .frame(maxWidth: Self.stageWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: Обратный отсчёт

struct CountdownPanel: View {
    enum Kind {
        case pomodoro, timer

        var presets: [(title: String, minutes: Int)] {
            switch self {
            case .pomodoro: [("Фокус 25", 25), ("Перерыв 5", 5), ("Урок 40", 40), ("Длинный 15", 15)]
            case .timer: [("1 мин", 1), ("5 мин", 5), ("10 мин", 10), ("30 мин", 30)]
            }
        }
    }

    let store: TimeStore
    let kind: Kind
    @State private var minutes: Int
    @State private var label: String

    init(store: TimeStore, kind: Kind) {
        self.store = store
        self.kind = kind
        _minutes = State(initialValue: kind.presets[0].minutes)
        _label = State(initialValue: kind == .pomodoro ? "Фокус" : "Таймер")
    }

    var body: some View {
        let active = store.countdown != nil
        HStack(alignment: .center, spacing: 40) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                RingGauge(
                    remaining: active ? store.remaining(at: context.date) : TimeInterval(minutes * 60),
                    total: store.countdown?.total ?? TimeInterval(minutes * 60),
                    warn: active && !store.isFinished && store.remaining(at: context.date) < TimeStore.warnBefore
                )
            }
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.countdown?.label ?? label).font(.system(size: 24, weight: .semibold))
                    Text(statusText).font(.system(size: 13)).foregroundStyle(Palette.muted)
                }
                HStack(spacing: 8) { buttons }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(kind.presets, id: \.title) { preset in
                        Button { choose(preset.title, preset.minutes) } label: {
                            Text(preset.title)
                                .font(.system(size: 12))
                                .foregroundStyle(minutes == preset.minutes && !active ? Palette.text : Palette.muted)
                                .frame(maxWidth: .infinity)
                                .frame(height: 30)
                                .background(Capsule().fill(minutes == preset.minutes && !active ? Color.white.opacity(0.16) : Palette.card))
                                .overlay(Capsule().stroke(Palette.cardBorder))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 8) {
                    Text("Свой").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    stepButton("minus") { choose("Свой", max(1, minutes - 1)) }
                    Text("\(minutes) мин").font(.system(size: 13, design: .rounded).monospacedDigit()).frame(minWidth: 58)
                    stepButton("plus") { choose("Свой", min(180, minutes + 1)) }
                }
            }
            .frame(width: 252, alignment: .leading)
        }
    }

    private var statusText: String {
        guard store.countdown != nil else { return "\(minutes) мин" }
        if store.isFinished { return "Время вышло" }
        if store.isPaused { return "пауза" }
        return "идёт"
    }

    @ViewBuilder
    private var buttons: some View {
        if store.countdown == nil {
            Button("Старт") { store.start(seconds: TimeInterval(minutes * 60), label: label) }
                .buttonStyle(VisorButtonStyle(kind: .primary))
        } else if store.isFinished {
            Button("Заново") { store.reset() }.buttonStyle(VisorButtonStyle(kind: .primary))
        } else {
            if store.isPaused {
                Button("Продолжить") { store.resume() }.buttonStyle(VisorButtonStyle(kind: .primary))
            } else {
                Button("Пауза") { store.pause() }.buttonStyle(VisorButtonStyle(kind: .primary))
            }
            Button("Сброс") { store.reset() }.buttonStyle(VisorButtonStyle())
        }
    }

    private func choose(_ title: String, _ minutes: Int) {
        if store.countdown != nil { store.reset() }
        self.minutes = minutes
        label = title.split(separator: " ").first.map(String.init) ?? title
    }

    /// Круг целиком внутри кнопки: нажимается вся площадь, а не только значок.
    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.card))
                .overlay(Circle().stroke(Palette.cardBorder))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "plus" ? "Больше" : "Меньше")
    }
}

/// Круг таймера: дуга остатка и время в центре. В последние 5 минут дуга становится янтарной.
struct RingGauge: View {
    let remaining: TimeInterval
    let total: TimeInterval
    let warn: Bool

    var body: some View {
        let fraction = total > 0 ? min(1, max(0, remaining / total)) : 0
        ZStack {
            // Обводка ложится половиной толщины наружу, поэтому круг сдвинут внутрь на половину толщины.
            Circle().stroke(Color.white.opacity(0.16), lineWidth: 9).padding(4.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(warn ? AgentState.waiting.color : Palette.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(4.5)
            Text(TimeFormat.clock(remaining)).font(.system(size: 32, weight: .medium, design: .rounded).monospacedDigit())
        }
        .frame(width: 176, height: 176)
    }
}

// MARK: Секундомер

struct StopwatchPanel: View {
    let store: TimeStore

    var body: some View {
        HStack(alignment: .center, spacing: 40) {
            VStack(spacing: 16) {
                TimelineView(.animation(minimumInterval: 0.1, paused: !store.swRunning)) { context in
                    Text(TimeFormat.stopwatch(store.swElapsed(at: context.date)))
                        .font(.system(size: 52, weight: .medium, design: .rounded).monospacedDigit())
                }
                HStack(spacing: 8) {
                    Button(store.swRunning ? "Стоп" : "Старт") { store.swToggle() }
                        .buttonStyle(VisorButtonStyle(kind: .primary))
                    Button("Круг") { store.swLap() }.buttonStyle(VisorButtonStyle()).disabled(!store.swRunning)
                    Button("Сброс") { store.swReset() }.buttonStyle(VisorButtonStyle())
                }
            }
            .frame(maxWidth: .infinity)
            laps
                .frame(width: 252, height: 176)
        }
    }

    @ViewBuilder
    private var laps: some View {
        if store.laps.isEmpty {
            Text("Кругов пока нет")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card.opacity(0.6)))
        } else {
            VScroll {
                VStack(spacing: 6) {
                    ForEach(Array(store.laps.enumerated()), id: \.offset) { index, lap in
                        HStack {
                            Text("Круг \(store.laps.count - index)").font(.system(size: 12)).foregroundStyle(Palette.muted)
                            Spacer()
                            Text(TimeFormat.stopwatch(lap)).font(.system(size: 12.5, design: .rounded).monospacedDigit())
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
                    }
                }
            }
        }
    }
}

// MARK: Мировые часы

/// Левая колонка: ваше время и дата крупно. Справа плитки городов по две в ряд.
/// В плитке время города, разница с вашим, и полоса из 24 клеток по вашим часам: синий рабочее время там (9–18),
/// тёмный ночь, рамка это сейчас.
struct ClocksPanel: View {
    let store: TimeStore

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            LocalClockCard()
                .frame(width: 210)
            VStack(alignment: .leading, spacing: 8) {
                VScroll {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(store.zones.filter { $0 != TimeZone.current.identifier }, id: \.self) { zone in ZoneTile(zone: zone, store: store) }
                        addTile
                    }
                }
                Text("Синий: рабочее время в городе, тёмный: ночь, рамка: сейчас")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
        .frame(height: 216)
    }

    private var addTile: some View {
        Menu {
            ForEach(TimeStore.catalog.filter { !store.zones.contains($0.id) }) { info in
                Button(info.name) { store.addZone(info.id) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                Text("Город").font(.system(size: 12.5))
            }
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.cardBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

/// Ваше время: крупные часы, секунды рядом и дата.
struct LocalClockCard: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 4) {
                Text(ZoneClock.city(of: TimeZone.current))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.muted)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(ZoneClock.time(zone: .current, at: now))
                        .font(.system(size: 54, weight: .medium, design: .rounded).monospacedDigit())
                    Text(ZoneClock.seconds(at: now))
                        .font(.system(size: 18, design: .rounded).monospacedDigit()).foregroundStyle(Palette.muted)
                }
                Text(ZoneClock.dateText(now))
                    .font(.system(size: 13)).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                DayBar(date: now)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.cardBorder))
        }
    }
}

/// Сколько дня прошло: тонкая полоса от полуночи до полуночи.
struct DayBar: View {
    let date: Date

    var body: some View {
        let cal = Calendar.current
        let minutes = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule().fill(Color.white.opacity(0.7)).frame(width: max(4, geometry.size.width * CGFloat(minutes) / 1440))
                }
            }
            .frame(height: 4)
            Text("День прошёл на \(Int((Double(minutes) / 14.4).rounded())) %")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
}

struct ZoneTile: View {
    let zone: String
    let store: TimeStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let tz = TimeZone(identifier: zone) ?? .current
            let minutesShift = (tz.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)) / 60
            let shift = Int((Double(minutesShift) / 60).rounded())
            let localHour = Calendar.current.component(.hour, from: now)
            let hereHour = ((localHour + shift) % 24 + 24) % 24
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: (7..<19).contains(hereHour) ? "sun.max.fill" : "moon.stars.fill")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Text(TimeStore.name(of: zone)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { store.removeZone(zone) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Убрать \(TimeStore.name(of: zone))")
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ZoneClock.time(zone: tz, at: now))
                        .font(.system(size: 28, weight: .medium, design: .rounded).monospacedDigit())
                    Text([dayNote(now: now, tz: tz), ZoneClock.offsetText(minutes: minutesShift)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                HStack(spacing: 1) {
                    ForEach(0..<24, id: \.self) { hour in
                        let there = ((hour + shift) % 24 + 24) % 24
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color(forHour: there))
                            .frame(height: 8)
                            .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(hour == localHour ? Color.white : .clear, lineWidth: 1))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(height: 92)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.cardBorder))
        }
    }

    private func color(forHour hour: Int) -> Color {
        if (9..<18).contains(hour) { return Color(red: 0.23, green: 0.29, blue: 0.54) }
        if hour >= 22 || hour < 7 { return Color(white: 0.03) }
        return Color.white.opacity(0.16)
    }

    /// «завтра» или «вчера», если в городе уже другая дата.
    private func dayNote(now: Date, tz: TimeZone) -> String? {
        var there = Calendar.current
        there.timeZone = tz
        let days = there.ordinality(of: .day, in: .era, for: now) ?? 0
        let here = Calendar.current.ordinality(of: .day, in: .era, for: now) ?? 0
        if days > here { return "завтра" }
        if days < here { return "вчера" }
        return nil
    }
}

@MainActor
enum ZoneClock {
    private static var formatters: [String: DateFormatter] = [:]

    static func time(zone: TimeZone, at date: Date) -> String {
        let formatter = formatters[zone.identifier] ?? {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            f.timeZone = zone
            formatters[zone.identifier] = f
            return f
        }()
        return formatter.string(from: date)
    }

    static func seconds(at date: Date) -> String {
        String(format: "%02d", Calendar.current.component(.second, from: date))
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter.string(from: date).capitalizedFirst
    }

    /// «Алматы» из идентификатора пояса: последняя часть без подчёркиваний.
    static func city(of zone: TimeZone) -> String {
        TimeStore.name(of: zone.identifier)
    }

    /// Разница с вашим временем: «то же время», «+5 ч», «−3 ч 30 м».
    nonisolated static func offsetText(minutes: Int) -> String {
        if minutes == 0 { return "как у вас" }
        let sign = minutes > 0 ? "+" : "−"
        let value = abs(minutes)
        let hours = value / 60, rest = value % 60
        return rest == 0 ? "\(sign)\(hours) ч" : "\(sign)\(hours) ч \(rest) м"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: Таймер в правой таблетке острова

struct TimerCapsule: View {
    var store: TimeStore = .shared

    var body: some View {
        if store.countdown != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = store.remaining(at: context.date)
                let total = store.countdown?.total ?? 1
                let warn = left < TimeStore.warnBefore && !store.isFinished
                HStack(spacing: 6) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.16), lineWidth: 2.2)
                        Circle()
                            .trim(from: 0, to: min(1, max(0, left / total)))
                            .stroke(warn ? AgentState.waiting.color : Palette.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(Int((left / 60).rounded(.up)))")
                            .font(.system(size: 7.5, design: .rounded).monospacedDigit())
                    }
                    .frame(width: 22, height: 22)
                    Text(store.isFinished ? "готово" : TimeFormat.clock(left))
                        .font(.system(size: 11, design: .rounded).monospacedDigit())
                        .foregroundStyle(store.isPaused ? Palette.muted : Color.white)
                        .fixedSize()
                }
                .padding(.leading, 3)
                .padding(.trailing, 10)
                .frame(height: 24)
                .background(Color.white.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(warn ? AgentState.waiting.color.opacity(0.7) : Palette.cardBorder))
            }
        }
    }
}
