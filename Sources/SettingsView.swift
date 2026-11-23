import SwiftUI

/// Настройки: пока «Звук» и «Агенты». Остальные разделы придут на шаге 11.
struct SettingsPage: View {
    let model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    Button { model.settingsTab = tab } label: {
                        Text(tab.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(model.settingsTab == tab ? Palette.text : Palette.muted)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(model.settingsTab == tab ? Palette.selected : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            switch model.settingsTab {
            case .general: GeneralSettings()
            case .tabs: TabOrderSettings(model: model)
            case .keys: KeysSettings()
            case .sound: SoundSettings(model: model)
            case .agents: AgentSettings()
            case .calendars: CalendarSettings()
            case .awake: PowerSettings()
            case .chat: ChatSettings()
            }
        }
    }
}

// MARK: Основные

/// Ряд вариантов: выбранный подсвечен, нажимается вся плашка.
struct ChoiceChips<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button { onSelect(option.value) } label: {
                    Text(option.title)
                        .font(.system(size: 12))
                        .foregroundStyle(selection == option.value ? Palette.text : Palette.muted)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(selection == option.value ? Palette.selected : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Palette.hover))
    }
}

/// Основные настройки: автозапуск, экран, сворачивание, смена таблетки и горячая клавиша.
struct GeneralSettings: View {
    var prefs: IslandPrefs = .shared

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Visor \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        VScroll {
            VStack(alignment: .leading, spacing: 0) {
                SettingRow(title: "Запускать при входе в систему", toggle: Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) }))
                if let error = prefs.launchError {
                    caption(error, color: AgentState.waiting.color)
                } else if prefs.launchNeedsApproval {
                    caption("Разрешите Visor в «Системные настройки → Основные → Объекты входа».", color: AgentState.waiting.color)
                } else if !LaunchAtLogin.isInApplications {
                    caption("Visor сейчас лежит не в «Программах». Автозапуск запомнит это место: после переноса включите его заново.")
                }
                SettingRow(title: "Управлять островом с клавиатуры", subtitle: "стрелки, пробел, цифры", toggle: Binding(get: { prefs.keyboardControl }, set: { prefs.keyboardControl = $0 }))
                SettingRow(title: "Сворачивать кликом вне острова", subtitle: "клик проходит в окно, на которое нажали", toggle: Binding(get: { prefs.closeOnOutsideClick }, set: { prefs.closeOnOutsideClick = $0 }))
                SettingRow(title: "Экран") {
                    ChoiceChips(options: ScreenChoice.allCases.map { ($0, $0.title) }, selection: prefs.screen) { prefs.screen = $0 }
                }
                caption(prefs.screen.hint)
                SettingRow(title: "Сворачивать, если курсор ушёл") {
                    ChoiceChips(options: IslandPrefs.autoCloseOptions.map { ($0, $0 == 0 ? "Никогда" : "\($0) с") },
                                selection: prefs.autoCloseSeconds) { prefs.autoCloseSeconds = $0 }
                }
                SettingRow(title: "Глазок", subtitle: "правый клик по острову: быстрые настройки", toggle: Binding(get: { prefs.showEye }, set: { prefs.showEye = $0 }))
                SettingRow(title: "Таблетка", subtitle: "спрячьте, если закрывает значки в строке меню", toggle: Binding(get: { prefs.showCapsule }, set: { prefs.showCapsule = $0 }))
                SettingRow(title: "Стороны", subtitle: "что слева от выреза, а что справа") {
                    ChoiceChips(options: [(false, "Глазок слева"), (true, "Таблетка слева")], selection: prefs.swapSides) { prefs.swapSides = $0 }
                }
                SettingRow(title: "Менять таблетку") {
                    ChoiceChips(options: IslandPrefs.rotationOptions.map { ($0, "\($0) с") },
                                selection: prefs.rotationSeconds) { prefs.rotationSeconds = $0 }
                }
                SettingRow(title: "Открывать остров с клавиатуры") {
                    ChoiceChips(options: HotKeyChoice.allCases.map { ($0, $0.title) }, selection: prefs.hotKey) { prefs.hotKey = $0 }
                }
                if prefs.hotKeyBusy {
                    caption("Это сочетание занято другим приложением. Выберите другое.", color: AgentState.error.color)
                }
                SettingRow(title: "Данные Visor", subtitle: "заметки, буфер, полка") {
                    Button("Показать в Finder") { NSWorkspace.shared.open(VisorPaths.supportDir) }.buttonStyle(VisorButtonStyle())
                }
                if Feedback.repository != nil {
                    SettingRow(title: "Отзыв", subtitle: "форма на GitHub, версия и macOS подставятся сами") {
                        Button("Сообщить об ошибке") { Feedback.open(.bug) }.buttonStyle(VisorButtonStyle())
                        Button("Предложить идею") { Feedback.open(.feature) }.buttonStyle(VisorButtonStyle())
                    }
                }
                caption(version)
            }
        }
        .onAppear { prefs.refreshLaunch() }
    }

    private func caption(_ text: String, color: Color = Palette.muted) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Клавиши

/// Памятка по клавишам. Они работают, когда остров раскрыт горячей клавишей или кликом и фокус не в поле ввода.
struct KeysSettings: View {
    private static let groups: [(title: String, items: [(keys: String, text: String)])] = [
        ("Везде", [
            ("← →", "соседняя вкладка"), ("↑ ↓", "раздел внутри вкладки"), ("1 … 9", "вкладка по номеру"),
            ("Esc", "закрыть страницу или свернуть остров"), (",", "настройки"), ("=", "вкладки и модули"),
            ("M", "звук вкл/выкл"), ("?", "эта памятка"),
        ]),
        ("Агенты, когда ждут ответа", [("Y  или  ↵", "разрешить"), ("A", "всегда разрешать"), ("N  или  ⌫", "запретить")]),
        ("Медиа: плеер", [("Пробел", "пауза и воспроизведение"), ("N  или  ⌘→", "следующий трек"), ("P  или  ⌘←", "предыдущий трек"),
                          ("⇧← ⇧→", "перемотка на 10 секунд")]),
        ("Медиа: телесуфлёр", [("Пробел", "старт и пауза"), ("R", "в начало"), ("⌘↑ ⌘↓", "скорость")]),
        ("Время", [("Пробел", "старт, пауза, продолжить"), ("R", "сброс"), ("L", "круг на секундомере")]),
        ("Полка", [("⌘A", "выбрать всё"), ("⌫", "удалить выбранное"), ("↵", "открыть выбранный файл")]),
    ]

    var body: some View {
        VScroll {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.groups, id: \.title) { group in
                    Text(group.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted).padding(.top, 8)
                    ForEach(group.items, id: \.keys) { item in
                        HStack(spacing: 12) {
                            Text(item.keys)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 9)
                                .frame(minWidth: 84, minHeight: 24)
                                .background(Palette.hover, in: RoundedRectangle(cornerRadius: 7))
                            Text(item.text).font(.system(size: 12.5))
                            Spacer()
                        }
                    }
                }
            }
        }
    }
}

// MARK: Вкладки

/// Порядок и включение вкладок. Тот же порядок меняется перетаскиванием иконок в верхней строке острова.
struct TabOrderSettings: View {
    let model: IslandModel
    @State private var reorder = ReorderDrag()

    var body: some View {
        VScroll {
            VStack(alignment: .leading, spacing: 6) {
                Text("Порядок иконок в верхней строке. Возьмите вкладку за строку и перетащите, или двигайте кнопками справа: две крайние отправляют в начало и в конец. Иконки можно перетаскивать и прямо в верхней строке.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
                ForEach(model.tabOrder) { tab in
                    SwitchRow(
                        title: tab.title,
                        subtitle: tab == .agents ? "всегда включена" : nil,
                        symbol: tab.symbol,
                        isOn: Binding(get: { model.enabledTabs.contains(tab) }, set: { model.setTab(tab, enabled: $0) }),
                        locked: tab == .agents,
                        onMove: { model.moveTab(tab, by: $0) }
                    )
                    .reorderable(tab, model: model, axis: .vertical, space: "tabsList", spacing: 0, order: model.tabOrder, drag: reorder)
                }
                HStack {
                    Button("Сбросить порядок") { model.resetTabOrder() }.buttonStyle(VisorButtonStyle())
                        .disabled(model.tabOrder == IslandTab.allCases)
                    Spacer()
                }
                .padding(.top, 4)
            }
            .coordinateSpace(name: "tabsList")
            .onPreferenceChange(TabFrames.self) { reorder.frames = $0 }
        }
    }
}

// MARK: Звук

private func minutes(from date: Date) -> Int {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
}

private func date(from minutes: Int) -> Date {
    Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
}

struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    /// Если задан, в конце строки зелёный переключатель, а нажатие в любом месте строки его переключает.
    var toggle: Binding<Bool>?
    @ViewBuilder let trailing: Trailing

    init(title: String, subtitle: String? = nil, toggle: Binding<Bool>? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.toggle = toggle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13))
            if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted) }
            Spacer(minLength: 8)
            trailing
            if let toggle {
                Toggle(title, isOn: toggle).toggleStyle(VisorSwitchStyle()).labelsHidden()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .contentShape(Rectangle())
        .onTapGesture { toggle?.wrappedValue.toggle() }
        .listRow()
    }
}

extension SettingRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, toggle: Binding<Bool>) {
        self.init(title: title, subtitle: subtitle, toggle: toggle) { EmptyView() }
    }
}

struct SoundSettings: View {
    let model: IslandModel

    var body: some View {
        let engine = SoundEngine.shared
        VScroll {
            VStack(spacing: 0) {
                SettingRow(title: "Звуки включены", toggle: Binding(get: { !engine.isMuted }, set: { _ in model.toggleMute() }))
                SettingRow(title: "Громкость") {
                    Slider(value: Binding(get: { engine.volume }, set: { engine.setVolume($0) }), in: 0...1)
                        .frame(width: 180)
                        .tint(Palette.accent)
                    Text("\(Int(engine.volume * 100)) %")
                        .font(.system(size: 11, design: .rounded).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                        .frame(width: 36, alignment: .trailing)
                }
                ForEach(SoundEvent.allCases) { event in
                    SettingRow(title: event.title, subtitle: event.kindName) {
                        Button("Проверить") { SoundEngine.shared.play(event, preview: true) }
                            .buttonStyle(VisorButtonStyle())
                    }
                }
                SettingRow(title: "Не играть, если терминал в фокусе", toggle: Binding(
                        get: { engine.skipWhenTerminalFocused }, set: { engine.setSkipWhenTerminalFocused($0) }))
                SettingRow(title: "Тихие часы", toggle: Binding(get: { engine.quietHoursEnabled }, set: { engine.setQuietHours($0) })) {
                    if engine.quietHoursEnabled {
                        DatePicker("С", selection: Binding(get: { date(from: engine.quietStart) },
                                                           set: { engine.setQuietStart(minutes(from: $0)) }),
                                   displayedComponents: .hourAndMinute).labelsHidden()
                        Text("до").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        DatePicker("До", selection: Binding(get: { date(from: engine.quietEnd) },
                                                            set: { engine.setQuietEnd(minutes(from: $0)) }),
                                   displayedComponents: .hourAndMinute).labelsHidden()
                    }
                }
                SettingRow(title: "Свои звуки", subtitle: "finish, approval, error") {
                    Button("Открыть папку") { SoundEngine.shared.revealCustomFolder() }
                        .buttonStyle(VisorButtonStyle())
                }
            }
        }
    }
}

// MARK: Календари

/// Какие календари показывать и куда добавлять новые события. Здесь же подключается Google.
struct CalendarSettings: View {
    var calendar: CalendarService = .shared

    var body: some View {
        VScroll {
            VStack(alignment: .leading, spacing: 6) {
                if calendar.access != .granted {
                    AccessCard(calendar: calendar)
                } else if calendar.calendars.isEmpty {
                    Text("Календарей пока нет. Добавьте учётную запись или подписку ниже, и календари появятся здесь.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                } else {
                    Text("Переключатель показывает или скрывает календарь в Visor. Кружок слева задаёт, куда попадают новые события.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                    SettingRow(title: "Сколько календарей показывать", subtitle: "первые из включённых, остальные скрыты") {
                        ChoiceChips(options: CalendarService.limitOptions.map { ($0, $0 == 0 ? "Все" : "\($0)") },
                                    selection: calendar.limit) { calendar.setLimit($0) }
                    }
                    ForEach(calendar.calendarsByAccount, id: \.account) { group in
                        Text(group.account)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .padding(.top, 6)
                        ForEach(group.items) { item in CalendarRow(item: item, calendar: calendar) }
                    }
                }
                addCard
                googleCard
            }
        }
        .onAppear { calendar.refresh() }
    }

    @State private var feed = ""
    @State private var feedWrong = false

    /// Добавление календарей не только из Google и iCloud: любая учётная запись macOS и календарь по ссылке.
    private var addCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Добавить календарь").font(.system(size: 13, weight: .semibold))
            Text("Visor показывает всё, что есть в приложении «Календарь». Яндекс, Outlook, Exchange, Yahoo и другие CalDAV добавляются как учётная запись, а чужой календарь или расписание по ссылке .ics как подписка.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            HStack(spacing: 8) {
                Button("Учётная запись…") { CalendarService.openInternetAccounts() }.buttonStyle(VisorButtonStyle(kind: .primary))
                Button("Открыть «Календарь»") { CalendarService.openCalendarApp() }.buttonStyle(VisorButtonStyle())
            }
            TextField("Ссылка на календарь: webcal:// или https://…ics", text: $feed)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Palette.hover, in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { addFeed() }
            HStack(spacing: 8) {
                Button("Подписаться по ссылке") { addFeed() }.buttonStyle(VisorButtonStyle()).disabled(feed.isEmpty)
                if feedWrong { Text("Это не ссылка на календарь.").font(.system(size: 11.5)).foregroundStyle(AgentState.waiting.color) }
            }
            Text("Подписка оформляется в «Календаре»: там нажимается «Подписаться». Через минуту-две календарь появится здесь.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.cardBorder))
        .padding(.top, 8)
    }

    private func addFeed() {
        feedWrong = !CalendarService.subscribe(feed)
        if !feedWrong { feed = "" }
    }

    private var googleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(calendar.hasGoogle ? AgentState.done.color : Color(white: 0.35)).frame(width: 8, height: 8)
                Text(calendar.hasGoogle ? "Google Календарь подключён" : "Google Календарь не подключён")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text("macOS получает Google Календарь через «Учётные записи интернета»: «Добавить учётную запись», Google, вход, и оставьте включённым «Календари». Вход делаете вы сами, Visor пароль не видит.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            Button("Открыть «Учётные записи интернета»") { CalendarService.openInternetAccounts() }
                .buttonStyle(VisorButtonStyle(kind: calendar.hasGoogle ? .normal : .primary))
            Text("Если нужного календаря (например, школьного, которым с вами поделились) в списке нет, включите его на calendar.google.com/calendar/syncselect: Google отдаёт macOS только выбранные там календари.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.cardBorder))
        .padding(.top, 8)
    }
}

struct CalendarRow: View {
    let item: CalendarInfo
    let calendar: CalendarService

    var body: some View {
        let isTarget = calendar.targetID == item.id || (calendar.targetID == nil && calendar.destinationName == item.title && item.writable)
        HStack(spacing: 10) {
            Button { if item.writable { calendar.setTarget(item.id) } } label: {
                Image(systemName: isTarget ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isTarget ? Palette.accent : (item.writable ? Palette.muted : Color(white: 0.25)))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!item.writable)
            .help(item.writable ? "Добавлять сюда новые события" : "В этот календарь нельзя писать")
            .accessibilityLabel("Новые события в календарь \(item.title)")
            Text(item.title).font(.system(size: 13)).lineLimit(1)
                .foregroundStyle(calendar.isOverLimit(item.id) ? Palette.muted : Palette.text)
            if calendar.isOverLimit(item.id) { Text("не влезает").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            if !item.writable { Text("только чтение").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            Spacer(minLength: 8)
            Toggle(item.title, isOn: Binding(get: { calendar.isVisible(item.id) }, set: { calendar.setVisible(item.id, $0) }))
                .toggleStyle(VisorSwitchStyle())
                .labelsHidden()
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .contentShape(Rectangle())
        .onTapGesture { calendar.setVisible(item.id, !calendar.isVisible(item.id)) }
        .listRow()
    }
}

// MARK: Агенты

struct AgentSettings: View {
    @State private var plan: InstallPlan?
    @State private var note: String?
    @State private var failure: String?

    var body: some View {
        if let plan {
            PlanConfirm(plan: plan, onCancel: { self.plan = nil }, onApply: { apply(plan) })
        } else {
            VScroll {
                VStack(spacing: 6) {
                    Text("Включите до трёх агентов: только они видны во вкладке «Агенты». Подключать можно любых.")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(AgentTarget.allCases) { target in
                        let on = AgentCenter.shared.installed[target] == true
                        SettingRow(title: target.title, subtitle: on ? "хуки установлены" : "не подключён",
                                   toggle: Binding(get: { AgentPins.shared.pinned.contains(target) }, set: { AgentPins.shared.set(target, $0) })) {
                            Text(target.displayPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                            Button(on ? "Отключить" : "Подключить") { preview(target, install: !on) }
                                .buttonStyle(VisorButtonStyle(kind: on ? .normal : .primary))
                            Text("во вкладке").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }
                    customAgent
                    let limitsOn = AgentCenter.shared.limitsInstalled
                    SettingRow(title: "Лимиты Claude Code", subtitle: limitsOn ? "подключены" : "не подключены") {
                        Text("строка состояния").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Button(limitsOn ? "Отключить" : "Подключить") { preview(.claude, install: !limitsOn, feature: .limits) }
                            .buttonStyle(VisorButtonStyle(kind: limitsOn ? .normal : .primary))
                    }
                    Text("Лимиты Codex Visor спрашивает у самого Codex, если он установлен: настройка не нужна.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let note { MessageBox(text: note, color: AgentState.done.color) }
                    if let failure { MessageBox(text: failure, color: AgentState.error.color) }
                    Text("Visor ничего не меняет без вашего подтверждения: сначала показываются изменения, перед записью рядом создаётся копия файла.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }
        }
    }

    /// Любой другой агент (DeepSeek TUI, OpenCode и другие): хук вписывается в его настройки вручную.
    private var customAgent: some View {
        let command = "/bin/sh \"\(VisorPaths.relayURL.path)\" custom 3"
        return VStack(alignment: .leading, spacing: 6) {
            Text("Другой агент").font(.system(size: 13, weight: .semibold))
            Text("Если у агента есть хуки с командой и JSON на входе, добавьте эту команду на события начала и конца работы, перед и после инструмента. Visor понимает названия событий Claude Code и Gemini CLI.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(command).font(.system(size: 11, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.hover, in: RoundedRectangle(cornerRadius: 8))
                Button("Копировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .buttonStyle(VisorButtonStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.cardBorder))
        .padding(.top, 4)
    }

    private func preview(_ target: AgentTarget, install: Bool, feature: InstallFeature = .hooks) {
        note = nil
        failure = nil
        do {
            let result = try AgentInstaller.plan(target, install: install, feature: feature)
            if result.isNoop {
                note = install ? "Уже подключено, менять нечего." : "Записей Visor в файле нет, убирать нечего."
            } else {
                plan = result
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func apply(_ plan: InstallPlan) {
        do {
            let backup = try AgentInstaller.apply(plan)
            AgentCenter.shared.refreshInstalled()
            let what = plan.feature == .limits ? "Лимиты" : "Хуки"
            note = (plan.install ? "\(what) подключены." : "\(what) отключены.")
                + (backup.map { " Копия: \($0.lastPathComponent)." } ?? "")
                + (plan.previousStatusLine != nil ? " Ваша прежняя строка состояния продолжит работать." : "")
                + " Уже запущенные сессии агента подхватят изменения после перезапуска."
        } catch {
            failure = error.localizedDescription
        }
        self.plan = nil
    }
}

struct MessageBox: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.7)))
    }
}

/// Показ изменений перед записью. Пишется ровно то, что здесь видно.
struct PlanConfirm: View {
    let plan: InstallPlan
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        let added = plan.diff.filter { $0.kind == .added }.count
        let removed = plan.diff.count - added
        VStack(alignment: .leading, spacing: 8) {
            Text("\(plan.install ? "Подключить" : "Отключить") \(plan.feature == .limits ? "лимиты" : "хуки") \(plan.target.title): изменения в \(plan.target.displayPath)")
                .font(.system(size: 13, weight: .semibold))
            Text("Добавится строк: \(added), уберётся: \(removed). "
                 + (plan.hasBackup ? "Перед записью рядом создаётся копия файла." : "Файла ещё нет, он будет создан."))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
            if plan.install, String(data: plan.original ?? Data(), encoding: .utf8)?.contains("nb-hook") == true {
                MessageBox(text: "В файле уже есть хуки Coucou, они остаются. Пока Coucou запущен, его остров и Visor получают одни и те же события. Закройте Coucou, чтобы не было двойных карточек запросов.",
                           color: AgentState.waiting.color)
            }
            VScroll {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(plan.diff.prefix(300)) { line in
                        Text("\(line.kind == .added ? "+" : "−") \(line.text)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(line.kind == .added ? AgentState.done.color : AgentState.error.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
            HStack(spacing: 8) {
                Button("Записать", action: onApply).buttonStyle(VisorButtonStyle(kind: .primary))
                Button("Отмена", action: onCancel).buttonStyle(VisorButtonStyle())
            }
        }
    }
}


