import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: Модель

enum AgentState {
    case idle, working, waiting, done, error

    var color: Color {
        switch self {
        case .idle: Color(white: 0.45)
        case .working: Color(red: 0.44, green: 0.69, blue: 1.0)
        case .waiting: Color(red: 1.0, green: 0.71, blue: 0.33)
        case .done: Color(red: 0.37, green: 0.83, blue: 0.60)
        case .error: Color(red: 1.0, green: 0.42, blue: 0.42)
        }
    }
}

enum IslandTab: String, CaseIterable, Identifiable {
    case agents, chat, time, plans, clipboard, tools, shelf, dev, media

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: "Агенты"
        case .chat: "Чат"
        case .time: "Время"
        case .plans: "Планы"
        case .clipboard: "Буфер"
        case .tools: "Инструменты"
        case .shelf: "Полка"
        case .dev: "Dev"
        case .media: "Медиа"
        }
    }

    var symbol: String {
        switch self {
        case .agents: "house"
        case .chat: "bubble.left"
        case .time: "clock"
        case .plans: "checklist"
        case .clipboard: "doc.on.clipboard"
        case .tools: "plus.forwardslash.minus"
        case .shelf: "tray"
        case .dev: "chevron.left.forwardslash.chevron.right"
        case .media: "music.note"
        }
    }
}

/// Страницы поверх вкладок: «+» и настройки.
enum IslandPage: Equatable {
    case add, settings
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, tabs, keys, sound, agents, calendars, awake, chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .awake: "Awake"
        case .chat: "Чат"
        case .general: "Основные"
        case .tabs: "Вкладки"
        case .keys: "Клавиши"
        case .sound: "Звук"
        case .agents: "Агенты"
        case .calendars: "Календари"
        }
    }
}

/// Что показывает правая таблетка свёрнутого острова.
enum CapsuleItem: Hashable {
    case clock, timer, stopwatch, meeting, agent, music, site, tasks, battery, limits(AgentKind)

    /// Ключ вида таблетки для настройки «что показывать». Лимиты всех агентов считаются одним видом.
    var kind: String {
        switch self {
        case .clock: "clock"
        case .timer: "timer"
        case .stopwatch: "stopwatch"
        case .meeting: "meeting"
        case .agent: "agent"
        case .music: "music"
        case .site: "site"
        case .tasks: "tasks"
        case .battery: "battery"
        case .limits: "limits"
        }
    }

    /// Виды таблеток в меню по правому клику.
    static let menuKinds: [(kind: String, title: String)] = [
        ("clock", "Часы"), ("timer", "Таймер"), ("stopwatch", "Секундомер"), ("meeting", "Ближайшая встреча"),
        ("agent", "Агент Claude"), ("music", "Музыка"), ("site", "Сайты: YouTube, TikTok…"),
        ("tasks", "Дела на сегодня"), ("battery", "Низкий заряд"), ("limits", "Лимиты агентов"),
    ]
}

/// Модули и интеграции. По умолчанию все выключены, включаются на странице «+».
enum IslandModule: String, CaseIterable, Identifiable {
    case ports, github, vercel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ports: "Порты"
        case .github: "GitHub"
        case .vercel: "Vercel"
        }
    }

    var subtitle: String {
        switch self {
        case .ports: "локальные серверы"
        case .github: "PR и проверки CI"
        case .vercel: "деплои"
        }
    }
}

@MainActor @Observable
final class IslandModel {
    var isOpen = false
    var isHovering = false
    /// Куда смотрит точка в кольце агента, в pt относительно центра.
    var eye: CGSize = .zero
    var page: IslandPage?
    var settingsTab: SettingsTab = .general
    /// Остров не сворачивается сам, пока вы что-то пишете в нём.
    var keepOpen = false
    /// Выбранные внутри вкладок страницы. Хранятся здесь, чтобы стрелки вверх и вниз на клавиатуре могли их переключать.
    var mediaSub: MediaSub = .player
    /// Заряд, когда он ниже 20 % и Mac не на зарядке: тогда в ротации появляется таблетка заряда.
    var lowBattery: Int?
    var devSub: DevSub = .system
    var toolsSub: ToolsSub = .line
    var plansHorizon: PlanHorizon = .day
    /// Номер таблетки справа, меняется раз в 3 секунды, пока остров свёрнут.
    var rotation = 0
    /// Текст песни развёрнут: окно острова выше обычного.
    var lyricsExpanded = false
    /// Вид с крупной обложкой: окно немного выше обычного, но ниже, чем у текста.
    var coverExpanded = false

    /// Цвет кольца это агент, точка внутри это состояние. Берутся из живых сессий.
    var agentState: AgentState { AgentCenter.shared.summary.state }
    var agentColor: Color { AgentCenter.shared.summary.agent.color }

    var capsuleItems: [CapsuleItem] {
        var items: [CapsuleItem] = [.clock]
        if TimeStore.shared.countdown != nil { items.append(.timer) }
        if TimeStore.shared.swRunning { items.append(.stopwatch) }
        if CalendarService.shared.imminentEvent() != nil { items.append(.meeting) }
        if AgentCenter.shared.focusSession != nil { items.append(.agent) }
        if PlayerController.shared.nowPlaying != nil { items.append(.music) }
        if SiteWatcher.shared.current != nil { items.append(.site) }
        if PlansStore.shared.tasks(in: .day).contains(where: { !$0.done }) { items.append(.tasks) }
        if lowBattery != nil { items.append(.battery) }
        items += AgentCenter.shared.usageAgents.map { CapsuleItem.limits($0) }
        // Виды, выключенные в меню по правому клику, в ротацию не попадают. Если выключено всё, таблетки нет совсем.
        let hidden = IslandPrefs.shared.hiddenCapsules
        return items.filter { !hidden.contains($0.kind) }
    }

    var currentCapsule: CapsuleItem {
        let items = capsuleItems
        return items.isEmpty ? .clock : items[rotation % items.count]
    }

    func openSettings(_ tab: SettingsTab) {
        settingsTab = tab
        page = .settings
    }

    private(set) var tab: IslandTab
    /// Порядок всех вкладок в рейке. Включённые показываются в этом порядке.
    private(set) var tabOrder: [IslandTab]
    private(set) var enabledTabs: Set<IslandTab>
    private(set) var enabledModules: Set<IslandModule>
    private(set) var isMuted: Bool

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let tab = "island.tab"
        static let tabs = "island.enabledTabs"
        static let order = "island.tabOrder"
        static let modules = "island.enabledModules"
        static let muted = "island.muted"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var seen = Set<IslandTab>()
        let savedOrder = (defaults.stringArray(forKey: Key.order) ?? []).compactMap(IslandTab.init(rawValue:)).filter { seen.insert($0).inserted }
        // Новые вкладки, которых нет в сохранённом порядке, встают в конец.
        tabOrder = savedOrder + IslandTab.allCases.filter { !savedOrder.contains($0) }
        let savedTabs = defaults.stringArray(forKey: Key.tabs)?.compactMap(IslandTab.init(rawValue:))
        // «Агенты» остаются всегда, иначе остров может остаться без единой вкладки.
        let tabs = Set(savedTabs ?? IslandTab.allCases).union([.agents])
        enabledTabs = tabs
        let savedTab = defaults.string(forKey: Key.tab).flatMap(IslandTab.init(rawValue:))
        tab = savedTab.flatMap { tabs.contains($0) ? $0 : nil } ?? .agents
        enabledModules = Set(defaults.stringArray(forKey: Key.modules)?.compactMap(IslandModule.init(rawValue:)) ?? [])
        isMuted = defaults.bool(forKey: Key.muted)
        SoundEngine.shared.isMuted = isMuted
    }

    /// Включённые вкладки в порядке рейки.
    var visibleTabs: [IslandTab] {
        tabOrder.filter { enabledTabs.contains($0) }
    }

    /// Перетаскивание в рейке: вкладка встаёт на место той, на которую её бросили.
    func moveTab(_ tab: IslandTab, onto target: IslandTab) {
        guard tab != target, let from = tabOrder.firstIndex(of: tab), let to = tabOrder.firstIndex(of: target) else { return }
        tabOrder.remove(at: from)
        tabOrder.insert(tab, at: to)
        defaults.set(tabOrder.map(\.rawValue), forKey: Key.order)
    }

    func resetTabOrder() {
        tabOrder = IslandTab.allCases
        defaults.set(tabOrder.map(\.rawValue), forKey: Key.order)
    }

    /// Стрелки на странице «+»: на одну позицию влево (-1) или вправо (+1).
    func moveTab(_ tab: IslandTab, by offset: Int) {
        guard let index = tabOrder.firstIndex(of: tab) else { return }
        // Большой сдвиг (в начало или в конец) упирается в край списка.
        let target = max(0, min(tabOrder.count - 1, index + offset))
        moveTab(tab, onto: tabOrder[target])
    }

    func select(_ tab: IslandTab) {
        self.tab = tab
        page = nil
        defaults.set(tab.rawValue, forKey: Key.tab)
    }

    func togglePage(_ target: IslandPage) {
        page = page == target ? nil : target
    }

    func setTab(_ tab: IslandTab, enabled: Bool) {
        guard tab != .agents else { return }
        if enabled {
            enabledTabs.insert(tab)
        } else {
            enabledTabs.remove(tab)
            if self.tab == tab { select(.agents) }
        }
        defaults.set(visibleTabs.map(\.rawValue), forKey: Key.tabs)
    }

    func setModule(_ module: IslandModule, enabled: Bool) {
        if enabled { enabledModules.insert(module) } else { enabledModules.remove(module) }
        defaults.set(enabledModules.map(\.rawValue).sorted(), forKey: Key.modules)
    }

    func toggleMute() {
        isMuted.toggle()
        SoundEngine.shared.isMuted = isMuted
        defaults.set(isMuted, forKey: Key.muted)
    }
}

/// Размеры свёрнутого острова. Крылья узкие: слева кольцо, справа таблетка, всё прижато к вырезу.
enum IslandLayout {
    static let edgePadding: CGFloat = 12
    static let leftWing: CGFloat = 46
    static let rightWing: CGFloat = 158

    /// Ширина крыльев свёрнутого острова. Спрятанный глазок или таблетка места не занимают: остров сжимается до выреза.
    @MainActor static func wings(for model: IslandModel) -> (left: CGFloat, right: CGFloat) {
        let prefs = IslandPrefs.shared
        let showCapsule = prefs.capsuleVisible && !model.capsuleItems.isEmpty
        let eye = prefs.eyeVisible ? leftWing : 0
        let capsule = showCapsule ? rightWing : 0
        return prefs.swapSides ? (capsule, eye) : (eye, capsule)
    }
}

// MARK: Корневой вид

struct IslandView: View {
    let model: IslandModel
    let notchWidth: CGFloat
    let rowHeight: CGFloat
    let onToggle: () -> Void
    let onClose: () -> Void

    var body: some View {
        Group {
            if model.isOpen {
                OpenIsland(model: model, rowHeight: rowHeight, onClose: onClose)
            } else {
                ClosedIsland(model: model, notchWidth: notchWidth, rowHeight: rowHeight)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToggle)
            }
        }
        .preferredColorScheme(.dark)
        // Файлы, брошенные на остров, ложатся на полку.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            ShelfStore.accept(providers)
            return true
        }
    }
}

// MARK: Свёрнутый остров: по бокам выреза

struct ClosedIsland: View {
    let model: IslandModel
    let notchWidth: CGFloat
    let rowHeight: CGFloat

    private enum Wing { case eye, capsule }

    private var swapped: Bool { IslandPrefs.shared.swapSides }

    @ViewBuilder private func wing(_ kind: Wing) -> some View {
        switch kind {
        case .eye: EyeRing(model: model)
        case .capsule: RotatingCapsule(model: model)
        }
    }

    var body: some View {
        let wings = IslandLayout.wings(for: model)
        HStack(spacing: 0) {
            if wings.left > 0 {
                wing(swapped ? .capsule : .eye)
                    .padding(.leading, IslandLayout.edgePadding)
                    .frame(width: wings.left, alignment: .leading)
            }
            Color.clear.frame(width: notchWidth)
            if wings.right > 0 {
                wing(swapped ? .eye : .capsule)
                    .padding(.leading, IslandLayout.edgePadding)
                    .frame(width: wings.right, alignment: .leading)
            }
        }
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(.black))
        // Правый клик или касание двумя пальцами по острову: что показывать и как прятать.
        .contextMenu { IslandContextMenu(model: model) }
    }
}

/// Меню свёрнутого острова: спрятать глазок и таблетку, выбрать виды таблеток, скорость, режим «не засыпать».
struct IslandContextMenu: View {
    let model: IslandModel

    var body: some View {
        let prefs = IslandPrefs.shared
        let lid = LidAwake.shared
        Toggle("Показывать глазок", isOn: Binding(get: { prefs.showEye }, set: { prefs.showEye = $0 }))
        Toggle("Показывать таблетку", isOn: Binding(get: { prefs.showCapsule }, set: { prefs.showCapsule = $0 }))
        Button(prefs.swapSides ? "Глазок слева, таблетка справа" : "Таблетка слева, глазок справа") { prefs.swapSides.toggle() }
        Menu("Скрыть остров на время") {
            Button("На 15 минут") { prefs.hiddenUntil = Date().addingTimeInterval(15 * 60) }
            Button("На час") { prefs.hiddenUntil = Date().addingTimeInterval(3600) }
            Button("До перезапуска Visor") { prefs.hiddenUntil = .distantFuture }
            if prefs.temporarilyHidden {
                Divider()
                Button("Показать сейчас") { prefs.hiddenUntil = nil }
            }
        }
        Menu("Что показывать в таблетке") {
            ForEach(CapsuleItem.menuKinds, id: \.kind) { entry in
                Toggle(entry.title, isOn: Binding(
                    get: { !prefs.hiddenCapsules.contains(entry.kind) },
                    set: { on in if on { prefs.hiddenCapsules.remove(entry.kind) } else { prefs.hiddenCapsules.insert(entry.kind) } }
                ))
            }
        }
        Menu("Менять таблетку каждые") {
            Picker("Менять таблетку каждые", selection: Binding(get: { prefs.rotationSeconds }, set: { prefs.rotationSeconds = $0 })) {
                ForEach(IslandPrefs.rotationOptions, id: \.self) { Text("\($0) с").tag($0) }
            }
            .pickerStyle(.inline)
        }
        Divider()
        Menu("Не засыпать при закрытой крышке") {
            if lid.active {
                Button("Выключить") { Task { await lid.stop() } }
            } else {
                ForEach(LidPmset.durations, id: \.seconds) { option in
                    Button(option.seconds == 0 ? "Пока не выключу" : "На \(option.title)") { Task { await lid.enable(seconds: option.seconds) } }
                }
            }
        }
        Toggle("Без звука", isOn: Binding(get: { model.isMuted }, set: { _ in model.toggleMute() }))
        Divider()
        Button("Настройки Visor…") {
            model.openSettings(.general)
            IslandController.shared.open(userInitiated: true)
        }
    }
}

/// Кольцо агента «Глаз»: цвет кольца это агент, точка внутри это состояние.
/// Точка смотрит на курсор. При наведении возвращается в центр пружиной, от кольца расходится круг.
struct EyeRing: View {
    let model: IslandModel
    @State private var ripple: CGFloat = 1

    var body: some View {
        let offset = model.isHovering ? CGSize.zero : model.eye
        ZStack {
            Circle()
                .stroke(model.agentColor, lineWidth: 2)
                .frame(width: 20, height: 20)
            Circle()
                .stroke(model.agentColor, lineWidth: 1)
                .frame(width: 20, height: 20)
                .scaleEffect(1 + 0.9 * ripple)
                .opacity((1 - ripple) * 0.8)
            Circle()
                .fill(model.agentState.color)
                .frame(width: 8, height: 8)
                .offset(offset)
                .animation(
                    model.isHovering ? .interpolatingSpring(stiffness: 220, damping: 9) : .linear(duration: 0.08),
                    value: offset
                )
        }
        .frame(width: 22, height: 22)
        .onChange(of: model.isHovering) { _, hovering in
            guard hovering else { return }
            ripple = 0
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                withAnimation(.easeOut(duration: 0.7)) { ripple = 1 }
            }
        }
    }
}

/// Правая фишка: таблетки меняют друг друга, справа точки с номером. Сейчас это часы и состояние агента.
/// Таймер, лимит плана и встреча добавятся на шагах 6, 7 и 3e.
struct RotatingCapsule: View {
    let model: IslandModel

    var body: some View {
        let items = model.capsuleItems
        let alert = AlertCenter.shared.current
        HStack(spacing: 6) {
            Group {
                if let alert {
                    AlertCapsule(alert: alert)
                } else {
                switch model.currentCapsule {
                case .clock: ClockCapsule()
                case .timer: TimerCapsule()
                case .stopwatch: StopwatchCapsule()
                case .music: MusicCapsule()
                case .site: SiteCapsule()
                case .tasks: TasksCapsule()
                case .battery: BatteryCapsule(percent: model.lowBattery ?? 0)
                case .meeting: MeetingCapsule()
                case .agent: AgentCapsule()
                case .limits(let agent): LimitsCapsule(agent: agent)
                }
                }
            }
            .id(alert?.kind.hashValue ?? model.currentCapsule.hashValue)
            .transition(.opacity.combined(with: .offset(y: 6)))
            .contentShape(Rectangle())
            // Нажатие на таблетку открывает остров сразу на её вкладке: время на «Время», песня на «Плеер».
            .onTapGesture {
                if let alert { IslandController.shared.openFromAlert(alert) } else { IslandController.shared.openFromPill(model.currentCapsule) }
            }
            if items.count > 1, alert == nil {
                VStack(spacing: 3) {
                    ForEach(0..<items.count, id: \.self) { index in
                        Circle()
                            .fill(index == model.rotation % items.count ? Color.white : Color(white: 0.25))
                            .frame(width: 4, height: 4)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.3), value: model.currentCapsule)
        .animation(.easeOut(duration: 0.3), value: alert?.kind)
    }
}

struct AgentCapsule: View {
    var body: some View {
        if let session = AgentCenter.shared.focusSession {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    Circle().fill(session.state.agentState.color).frame(width: 6, height: 6)
                    Text(label(for: session, at: context.date))
                        .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                        .fixedSize()
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Color.white.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(Palette.cardBorder))
            }
        }
    }

    private func label(for session: AgentSession, at date: Date) -> String {
        guard session.state == .working, let since = session.workingSince else { return session.state.title }
        let seconds = max(0, Int(date.timeIntervalSince(since)))
        if seconds >= 3600 {
            return String(format: "работает %d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
        }
        return String(format: "работает %d:%02d", seconds / 60, seconds % 60)
    }
}

/// Лимиты плана: «5ч 42% · н 18%». Точка слева показывает, чей это лимит.
struct LimitsCapsule: View {
    let agent: AgentKind

    var body: some View {
        if let usage = AgentCenter.shared.usage[agent] {
            let parts = [usage.fiveHour.map { "5ч \(Int($0.effectivePct().rounded()))%" },
                         usage.sevenDay.map { "н \(Int($0.effectivePct().rounded()))%" }].compactMap { $0 }
            HStack(spacing: 5) {
                Circle().fill(agent.color).frame(width: 5, height: 5)
                Text(parts.joined(separator: " · "))
                    .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.white.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(Palette.cardBorder))
        }
    }
}

/// Общий вид таблетки у выреза: значок или точка и короткий текст.
struct PillLabel<Leading: View>: View {
    let text: String
    var maxWidth: CGFloat?
    @ViewBuilder let leading: Leading

    var body: some View {
        HStack(spacing: 6) {
            leading
            Text(text)
                .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .fixedSize(horizontal: maxWidth == nil, vertical: true)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color.white.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(Palette.cardBorder))
    }
}

/// Что играет: значок состояния цвета сервиса и название. Название обрезается многоточием, если не помещается.
struct MusicCapsule: View {
    var body: some View {
        if let track = PlayerController.shared.nowPlaying {
            let playing = track.isPlaying == true
            PillLabel(text: track.title, maxWidth: 86) {
                Image(systemName: playing ? "waveform" : "pause.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(track.source.color)
                    .symbolEffect(.variableColor.iterative, isActive: playing)
            }
        }
    }
}

struct StopwatchCapsule: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let store = TimeStore.shared
            PillLabel(text: TimeFormat.stopwatch(store.swElapsed(at: context.date)).split(separator: ".").first.map(String.init) ?? "",
                      maxWidth: nil) {
                Image(systemName: "stopwatch").font(.system(size: 9, weight: .semibold))
            }
        }
    }
}

/// Сколько дел на сегодня ещё не сделано.
struct TasksCapsule: View {
    var body: some View {
        let left = PlansStore.shared.tasks(in: .day).filter { !$0.done }.count
        if left > 0 {
            PillLabel(text: left == 1 ? "1 дело" : "\(left) \(left < 5 ? "дела" : "дел")", maxWidth: nil) {
                Image(systemName: "checklist").font(.system(size: 9, weight: .semibold))
            }
        }
    }
}

struct BatteryCapsule: View {
    let percent: Int

    var body: some View {
        PillLabel(text: "\(percent)%", maxWidth: nil) {
            Image(systemName: percent < 10 ? "battery.0percent" : "battery.25percent")
                .font(.system(size: 10))
                .foregroundStyle(AgentState.error.color)
        }
    }
}

struct ClockCapsule: View {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.system(size: 10))
                Text(Self.formatter.string(from: context.date))
                    .font(.system(size: 12, design: .rounded).monospacedDigit())
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color.white.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(Palette.cardBorder))
        }
    }
}

// MARK: Развёрнутый остров

enum Palette {
    /// Основной текст на стекле: почти чистый белый.
    static let text = Color.white.opacity(0.96)
    static let muted = Color.white.opacity(0.64)
    /// Слои лежат на стекле прозрачными белыми заливками: сквозь них проступает размытый рабочий стол.
    static let card = Color.white.opacity(0.10)
    static let cardBorder = Color.white.opacity(0.14)
    /// Главное действие и выбор: белый.
    static let accent = Color.white
    static let selected = Color.white.opacity(0.22)
    static let hover = Color.white.opacity(0.13)
    static let hairline = Color.white.opacity(0.12)
    static let good = Color(red: 0.42, green: 0.88, blue: 0.58)
}

struct OpenIsland: View {
    let model: IslandModel
    let rowHeight: CGFloat
    let onClose: () -> Void
    @State private var reorder = ReorderDrag()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(contentKey)
                .transition(.opacity)
        }
        // Единственное движение при смене вкладки: страница проявляется за 0,15 с.
        .animation(.easeOut(duration: 0.15), value: contentKey)
        .padding(.top, rowHeight + 4)
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(GlassBackground(rowHeight: rowHeight))
    }

    /// Меняется, когда открывается другая страница или вкладка.
    private var contentKey: String {
        model.page.map { "page-\($0)" } ?? "tab-\(model.tab.rawValue)"
    }

    @ViewBuilder
    private var content: some View {
        switch model.page {
        case .add: AddPage(model: model)
        case .settings: SettingsPage(model: model)
        case nil:
            switch model.tab {
            case .agents: AgentsPage(model: model)
            case .shelf: ShelfPage(model: model)
            case .clipboard: ClipboardPage(model: model)
            case .time: TimePage(model: model)
            case .plans: PlansPage(model: model)
            case .tools: ToolsPage(model: model)
            case .dev: DevPage(model: model)
            case .chat: ChatPage(model: model)
            case .media: MediaPage(model: model)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            // Иконки переставляются перетаскиванием: взяли иконку, повели вдоль строки, остальные расступаются.
            // Порядок меняется уже в пути, поэтому точно целиться при отпускании не нужно.
            HStack(spacing: 2) {
                ForEach(model.visibleTabs) { tab in
                    HeaderIcon(symbol: tab.symbol, title: tab.title, selected: model.page == nil && model.tab == tab,
                               showsTitle: true, lifted: false) {
                        model.select(tab)
                    }
                    .reorderable(tab, model: model, axis: .horizontal, space: "tabsRow", spacing: 2,
                                 order: model.visibleTabs, drag: reorder)
                }
            }
            .coordinateSpace(name: "tabsRow")
            .onPreferenceChange(TabFrames.self) { reorder.frames = $0 }
            HeaderIcon(symbol: "plus", title: "Вкладки и модули", selected: model.page == .add, showsTitle: false, lifted: false) {
                model.togglePage(.add)
            }
            Spacer()
            HeaderIcon(symbol: "gearshape", title: "Настройки", selected: model.page == .settings, showsTitle: false, lifted: false) {
                model.togglePage(.settings)
            }
            HeaderIcon(symbol: model.isMuted ? "speaker.slash" : "speaker.wave.2", title: model.isMuted ? "Включить звук" : "Выключить звук",
                       selected: false, showsTitle: false, lifted: false) {
                model.toggleMute()
            }
            HeaderIcon(symbol: "xmark", title: "Свернуть", selected: false, showsTitle: false, lifted: false, action: onClose)
        }
    }
}

/// Иконка шапки. Выбранная вкладка показывает ещё и название, остальные только значок.
struct HeaderIcon: View {
    let symbol: String
    let title: String
    let selected: Bool
    let showsTitle: Bool
    let lifted: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                if selected && showsTitle {
                    Text(title).font(.system(size: 12.5, weight: .medium))
                }
            }
            .foregroundStyle(selected ? Palette.text : (hovering ? Palette.text.opacity(0.85) : Palette.muted))
            .padding(.horizontal, selected && showsTitle ? 11 : 0)
            .frame(minWidth: 34, minHeight: 34)
            .background(selected ? Palette.selected : (hovering ? Palette.hover : .clear), in: Capsule())
            .opacity(lifted ? 0.45 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Рамки вкладок в координатах их контейнера: по ним определяется, над какой вкладкой сейчас курсор.
struct TabFrames: PreferenceKey {
    static let defaultValue: [IslandTab: CGRect] = [:]
    static func reduce(value: inout [IslandTab: CGRect], nextValue: () -> [IslandTab: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Состояние одного перетаскивания в списке или строке вкладок.
/// Пока иконку тянут, раскладка не меняется: взятая вкладка едет за курсором, соседи сдвигаются на её ширину, а порядок
/// записывается один раз при отпускании. Так нет петли «поменяли порядок, пересчитали положение, вкладку подбросило».
@MainActor @Observable
final class ReorderDrag {
    @ObservationIgnored var frames: [IslandTab: CGRect] = [:]
    private(set) var dragging: IslandTab?
    private(set) var translation: CGFloat = 0
    private(set) var target = 0
    @ObservationIgnored private var order: [IslandTab] = []
    @ObservationIgnored private var starts: [IslandTab: CGFloat] = [:]
    @ObservationIgnored private var origin = 0
    @ObservationIgnored private var length: CGFloat = 0

    private func mid(_ rect: CGRect, _ axis: Axis) -> CGFloat { axis == .horizontal ? rect.midX : rect.midY }

    func begin(_ tab: IslandTab, order: [IslandTab], axis: Axis, spacing: CGFloat) {
        guard dragging == nil, let frame = frames[tab] else { return }
        self.order = order
        starts = frames.mapValues { mid($0, axis) }
        origin = order.firstIndex(of: tab) ?? 0
        target = origin
        length = (axis == .horizontal ? frame.width : frame.height) + spacing
        translation = 0
        dragging = tab
    }

    func move(translation: CGFloat) {
        guard let dragging, let start = starts[dragging] else { return }
        self.translation = translation
        let pointer = start + translation
        target = order.indices.min { abs((starts[order[$0]] ?? 0) - pointer) < abs((starts[order[$1]] ?? 0) - pointer) } ?? origin
    }

    /// На сколько вкладка сейчас смещена: взятая едет за курсором, соседи расступаются.
    func shift(for tab: IslandTab) -> CGFloat {
        guard let dragging, let index = order.firstIndex(of: tab) else { return 0 }
        if tab == dragging { return translation }
        if origin < target, index > origin, index <= target { return -length }
        if origin > target, index >= target, index < origin { return length }
        return 0
    }

    func finish() -> (tab: IslandTab, onto: IslandTab)? {
        defer {
            dragging = nil
            translation = 0
        }
        guard let dragging, order.indices.contains(target), target != origin else { return nil }
        return (dragging, order[target])
    }
}

extension View {
    /// Вкладку можно взять и перетащить вдоль строки или списка. Свой жест вместо системного перетаскивания:
    /// он работает в окне острова, которое не активно, и даёт видимый отклик.
    func reorderable(_ tab: IslandTab, model: IslandModel, axis: Axis, space: String, spacing: CGFloat,
                     order: [IslandTab], drag: ReorderDrag) -> some View {
        modifier(TabReorder(tab: tab, model: model, axis: axis, space: space, spacing: spacing, order: order, drag: drag))
    }
}

struct TabReorder: ViewModifier {
    let tab: IslandTab
    let model: IslandModel
    let axis: Axis
    let space: String
    let spacing: CGFloat
    let order: [IslandTab]
    let drag: ReorderDrag

    func body(content: Content) -> some View {
        let lifted = drag.dragging == tab
        let others = drag.dragging != nil && !lifted
        let shift = drag.shift(for: tab)
        content
            .background(GeometryReader { proxy in
                Color.clear.preference(key: TabFrames.self, value: [tab: proxy.frame(in: .named(space))])
            })
            .opacity(others ? 0.65 : 1)
            .scaleEffect(lifted ? 1.05 : 1)
            .shadow(color: .black.opacity(lifted ? 0.3 : 0), radius: 5, y: 2)
            .animation(.easeOut(duration: 0.12), value: drag.dragging)
            .offset(x: axis == .horizontal ? shift : 0, y: axis == .vertical ? shift : 0)
            // Соседи сдвигаются плавно, взятая вкладка следует за курсором без задержки.
            .animation(lifted ? nil : .easeOut(duration: 0.14), value: shift)
            .zIndex(lifted ? 1 : 0)
            .simultaneousGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
                    .onChanged { value in
                        if drag.dragging == nil { drag.begin(tab, order: order, axis: axis, spacing: spacing) }
                        guard drag.dragging == tab else { return }
                        drag.move(translation: axis == .horizontal ? value.translation.width : value.translation.height)
                    }
                    .onEnded { _ in
                        guard drag.dragging == tab else { return }
                        // Порядок записывается без анимации: положение всех вкладок при этом не меняется скачком.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            if let move = drag.finish() { model.moveTab(move.tab, onto: move.onto) }
                        }
                    }
            )
    }
}

struct TabPlaceholder: View {
    let tab: IslandTab

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Palette.card)
            Text("\(tab.title): появится на следующих шагах")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Страница «+»: вкладки и модули

private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// В режиме снимка прокрутки нет: ImageRenderer не рисует содержимое ScrollView.
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// Вертикальная прокрутка. В режиме снимка прокрутки нет, иначе содержимое не рисуется.
struct VScroll<Content: View>: View {
    @Environment(\.snapshotMode) private var snapshotMode
    @ViewBuilder let content: Content

    var body: some View {
        if snapshotMode {
            content.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView(showsIndicators: false) { content }
        }
    }
}

struct AddPage: View {
    let model: IslandModel
    @Environment(\.snapshotMode) private var snapshotMode
    @State private var reorder = ReorderDrag()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            column(title: "Вкладки", caption: nil) {
                ForEach(model.tabOrder) { tab in
                    SwitchRow(
                        title: tab.title,
                        subtitle: tab == .agents ? "всегда включена" : nil,
                        symbol: tab.symbol,
                        isOn: Binding(
                            get: { model.enabledTabs.contains(tab) },
                            set: { model.setTab(tab, enabled: $0) }
                        ),
                        locked: tab == .agents,
                        onMove: { model.moveTab(tab, by: $0) }
                    )
                    .reorderable(tab, model: model, axis: .vertical, space: "addList", spacing: 0,
                                 order: model.tabOrder, drag: reorder)
                }
            }
            .coordinateSpace(name: "addList")
            .onPreferenceChange(TabFrames.self) { reorder.frames = $0 }
            column(title: "Модули и интеграции", caption: "По умолчанию выключены") {
                ForEach(IslandModule.allCases) { module in
                    SwitchRow(
                        title: module.title,
                        subtitle: module.subtitle,
                        symbol: nil,
                        isOn: Binding(
                            get: { model.enabledModules.contains(module) },
                            set: { model.setModule(module, enabled: $0) }
                        ),
                        locked: false
                    )
                }
            }
        }
    }

    private func column<Content: View>(title: String, caption: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                if let caption {
                    Text(caption).font(.system(size: 11)).foregroundStyle(Color(white: 0.4))
                }
            }
            let rows = VStack(spacing: 0) { content() }
            if snapshotMode {
                rows.frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView(showsIndicators: false) { rows }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SwitchRow: View {
    let title: String
    let subtitle: String?
    let symbol: String?
    @Binding var isOn: Bool
    let locked: Bool
    /// Стрелки порядка: -1 выше, +1 ниже. Без неё стрелок нет.
    var onMove: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            if onMove != nil {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.muted.opacity(0.7))
                    .frame(width: 12)
                    .help("Потяните, чтобы переставить")
            }
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 18)
            }
            Text(title).font(.system(size: 13))
            if let subtitle {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            if let onMove {
                HStack(spacing: 0) {
                    moveButton("arrow.up.to.line", label: "В начало") { onMove(-99) }
                    moveButton("chevron.up", label: "Выше") { onMove(-1) }
                    moveButton("chevron.down", label: "Ниже") { onMove(1) }
                    moveButton("arrow.down.to.line", label: "В конец") { onMove(99) }
                }
            }
            Toggle(title, isOn: $isOn)
                .toggleStyle(VisorSwitchStyle())
                .labelsHidden()
                .disabled(locked)
                .opacity(locked ? 0.45 : 1)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .contentShape(Rectangle())
        .onTapGesture { if !locked { isOn.toggle() } }
        .listRow()
    }

    private func moveButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.muted)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

struct VisorSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? Palette.good : Color.white.opacity(0.16))
                .frame(width: 34, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? Color.black.opacity(0.85) : Palette.text)
                        .frame(width: 16, height: 16)
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}


extension View {
    /// Строка списка без рамки: волосяная линия снизу и лёгкая подсветка при наведении. Выделенная (закреплённая) подсвечена всегда.
    func listRow(emphasized: Bool = false) -> some View { modifier(ListRowStyle(emphasized: emphasized)) }

    /// Блок страницы без коробки: отделён тонкой линией сверху.
    func flatSection() -> some View {
        overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}

struct ListRowStyle: ViewModifier {
    let emphasized: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(emphasized ? Palette.selected : (hovering ? Palette.hover : Color.white.opacity(0.07)),
                        in: RoundedRectangle(cornerRadius: 14))
            .onHover { hovering = $0 }
            .padding(.vertical, 2)
    }
}

/// Фон раскрытого острова: размытое стекло с затемнением. Полоса у выреза остаётся чёрной и плавно переходит в стекло,
/// поэтому остров продолжает вырез, а не лежит на нём отдельной плиткой.
struct GlassBackground: View {
    let rowHeight: CGFloat
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26)
        ZStack(alignment: .top) {
            if snapshotMode {
                // ImageRenderer не умеет размытие окна: в снимках стекло заменено ровным тёмным тоном.
                shape.fill(Color(red: 0.13, green: 0.15, blue: 0.20))
            } else {
                VisualEffectView(material: .hudWindow).clipShape(shape)
                shape.fill(Color.black.opacity(0.30))
            }
            LinearGradient(colors: [.black, .black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: rowHeight + 26)
                .clipShape(shape)
            shape.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.0), Color.white.opacity(0.22), Color.white.opacity(0.08)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
    }
}

/// Размытие того, что лежит за окном (рабочий стол), как у системных панелей.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
