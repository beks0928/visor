import AppKit
import SwiftUI

/// Режим энергосбережения по заряду и действия при закрытой крышке. Работают рядом с режимом «не засыпать» (LidAwake).
enum PowerSaverPolicy {
    enum Action: Equatable { case enable, disable, none }

    static let levelOptions = [0, 20, 30, 40, 50]
    /// Запас, чтобы режим не мигал на границе: выключается, когда заряд выше порога на столько процентов.
    static let hysteresis = 5

    static func arguments(on: Bool) -> [String] { ["-n", LidPmset.pmset, "-b", "lowpowermode", on ? "1" : "0"] }
    static func checkArguments(on: Bool) -> [String] { ["-n", "-l", LidPmset.pmset, "-b", "lowpowermode", on ? "1" : "0"] }

    /// Что делать сейчас. `owned`: режим включил Visor, только его он и выключает.
    static func decide(level: Int, percent: Int, onPower: Bool, lowPowerOn: Bool, owned: Bool, lidClosed: Bool = true) -> Action {
        guard level > 0 else { return owned && lowPowerOn ? .disable : .none }
        if owned {
            if !lowPowerOn { return .none }
            return !lidClosed || onPower || percent > level + hysteresis ? .disable : .none
        }
        return lidClosed && !onPower && percent <= level && !lowPowerOn ? .enable : .none
    }
}

@MainActor @Observable
final class PowerSaver {
    static let shared = PowerSaver()

    /// Заряд, ниже которого включается режим энергосбережения. 0: выключено.
    var level: Int { didSet { defaults.set(level, forKey: "visor.saver.level"); Task { await tick() } } }
    private(set) var owned: Bool
    /// nil: ещё не проверяли. false: правила sudoers для lowpowermode нет.
    private(set) var ruleReady: Bool?
    var message: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var working = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.integer(forKey: "visor.saver.level")
        level = PowerSaverPolicy.levelOptions.contains(saved) ? saved : 0
        owned = defaults.bool(forKey: "visor.saver.owned")
    }

    func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await tick() }
    }

    func checkRule() async {
        let on = await LidAwake.run(LidPmset.sudo, PowerSaverPolicy.checkArguments(on: true))
        let off = await LidAwake.run(LidPmset.sudo, PowerSaverPolicy.checkArguments(on: false))
        ruleReady = on.status == 0 && off.status == 0
    }

    func tick() async {
        guard !working else { return }
        working = true
        defer { working = false }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if owned, !lowPower { setOwned(false) } // выключили сами, например из строки меню
        guard let battery = SystemMonitor.battery() else { return }
        let action = PowerSaverPolicy.decide(level: level, percent: battery.percent, onPower: battery.onPower, lowPowerOn: lowPower, owned: owned, lidClosed: ClosedLidActions.shared.closed)
        guard action != .none else { return }
        await checkRule()
        guard ruleReady == true else {
            message = "Нужно правило, которое разрешает менять режим энергосбережения без пароля."
            return
        }
        let result = await LidAwake.run(LidPmset.sudo, PowerSaverPolicy.arguments(on: action == .enable))
        guard result.status == 0 else {
            message = "Не получилось переключить энергосбережение: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            return
        }
        setOwned(action == .enable)
        message = action == .enable ? "Заряд \(battery.percent) %: включён режим энергосбережения."
            : "Режим энергосбережения выключен: Mac на зарядке или заряд поднялся."
    }

    private func setOwned(_ value: Bool) {
        owned = value
        defaults.set(value, forKey: "visor.saver.owned")
    }
}

/// Что делать, пока крышка закрыта, а Mac не спит: выключить звук и заморозить выбранные программы, чтобы Mac меньше грелся.
@MainActor @Observable
final class ClosedLidActions {
    static let shared = ClosedLidActions()

    var muteOnClose: Bool { didSet { defaults.set(muteOnClose, forKey: "visor.lid.mute") } }
    /// Замораживать при закрытой крышке все программы, кроме отмеченных ниже.
    var freezeOthers: Bool { didSet { defaults.set(freezeOthers, forKey: "visor.lid.freezeOthers") } }
    /// Программы (идентификаторы), которые продолжают работать при закрытой крышке.
    private(set) var keepBundles: Set<String>
    private(set) var closed = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var mutedByUs = false
    @ObservationIgnored private var stopped: [pid_t] = []

    private var frozenFile: URL { VisorPaths.supportDir.appendingPathComponent("lid-frozen") }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        muteOnClose = defaults.object(forKey: "visor.lid.mute") as? Bool ?? true
        freezeOthers = defaults.bool(forKey: "visor.lid.freezeOthers")
        keepBundles = Set(defaults.stringArray(forKey: "visor.lid.keep") ?? [])
    }

    func start() {
        resumeLeftovers()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    func setKept(_ bundle: String, _ on: Bool) {
        if on { keepBundles.insert(bundle) } else { keepBundles.remove(bundle) }
        defaults.set(keepBundles.sorted(), forKey: "visor.lid.keep")
    }

    /// Пары «процесс, родитель» из `ps -axo pid=,ppid=`.
    nonisolated static func parseProcessTable(_ output: String) -> [(pid: pid_t, parent: pid_t)] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, let pid = pid_t(parts[0]), let parent = pid_t(parts[1]) else { return nil }
            return (pid, parent)
        }
    }

    /// Процесс и все его потомки: у браузера и мессенджеров основная работа идёт в дочерних процессах.
    nonisolated static func tree(of root: pid_t, in table: [(pid: pid_t, parent: pid_t)]) -> [pid_t] {
        var result = [root]
        var seen: Set<pid_t> = [root]
        var index = 0
        while index < result.count {
            for entry in table where entry.parent == result[index] && seen.insert(entry.pid).inserted { result.append(entry.pid) }
            index += 1
        }
        return result
    }

    /// Выход из Visor: всё возвращается как было.
    func willQuit() { if closed { restore() } }

    /// `ioreg`: «AppleClamshellState» = Yes, когда крышка закрыта.
    nonisolated static func parseClamshell(_ output: String) -> Bool? {
        for raw in output.split(whereSeparator: \.isNewline) where raw.contains("\"AppleClamshellState\"") {
            if raw.contains("= Yes") { return true }
            if raw.contains("= No") { return false }
        }
        return nil
    }

    /// Программы, которые разрешено замораживать: обычные окна сторонних программ. Программы Apple и сам Visor не замораживаются.
    nonisolated static func freezable(bundle: String?, policy: NSApplication.ActivationPolicy) -> Bool {
        guard let bundle, policy == .regular, !bundle.hasPrefix("com.apple.") else { return false }
        return bundle != (Bundle.main.bundleIdentifier ?? "com.beksultan.visor")
    }

    private func tick() async {
        guard LidAwake.shared.active else {
            if closed { restore() }
            return
        }
        let reading = await LidAwake.run("/usr/sbin/ioreg", ["-r", "-k", "AppleClamshellState", "-d", "1"], timeout: 5)
        guard let nowClosed = Self.parseClamshell(reading.output) else { return }
        if nowClosed, !closed { apply() } else if !nowClosed, closed { restore() }
    }

    private func apply() {
        closed = true
        LidAwake.shared.lidDidClose()
        Task { await PowerSaver.shared.tick() }
        if muteOnClose {
            let muted = NSAppleScript(source: "output muted of (get volume settings)")?.executeAndReturnError(nil).booleanValue ?? true
            if !muted {
                NSAppleScript(source: "set volume with output muted")?.executeAndReturnError(nil)
                mutedByUs = true
            }
        }
        stopped = []
        if freezeOthers {
            let roots = NSWorkspace.shared.runningApplications.filter { app in
                guard Self.freezable(bundle: app.bundleIdentifier, policy: app.activationPolicy), let bundle = app.bundleIdentifier else { return false }
                return !keepBundles.contains(bundle)
            }
            let table = Self.parseProcessTable(Self.processTable())
            for app in roots {
                for pid in Self.tree(of: app.processIdentifier, in: table) where kill(pid, SIGSTOP) == 0 { stopped.append(pid) }
            }
        }
        if !stopped.isEmpty {
            try? FileManager.default.createDirectory(at: VisorPaths.supportDir, withIntermediateDirectories: true)
            try? stopped.map(String.init).joined(separator: "\n").write(to: frozenFile, atomically: true, encoding: .utf8)
        }
    }

    private static func processTable() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func restore() {
        closed = false
        LidAwake.shared.lidDidOpen()
        Task { await PowerSaver.shared.tick() }
        if mutedByUs {
            NSAppleScript(source: "set volume without output muted")?.executeAndReturnError(nil)
            mutedByUs = false
        }
        stopped.forEach { kill($0, SIGCONT) }
        stopped = []
        try? FileManager.default.removeItem(at: frozenFile)
    }

    /// Если Visor завершился в закрытом виде, замороженные программы остаются стоять: при запуске их размораживаем.
    private func resumeLeftovers() {
        guard let text = try? String(contentsOf: frozenFile, encoding: .utf8) else { return }
        text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }.forEach { kill($0, SIGCONT) }
        try? FileManager.default.removeItem(at: frozenFile)
    }
}

// MARK: Настройки

struct PowerExtrasSettings: View {
    var saver: PowerSaver = .shared
    var actions: ClosedLidActions = .shared
    @State private var apps: [(bundle: String, name: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(title: "Энергосбережение ниже") {
                ChoiceChips(options: PowerSaverPolicy.levelOptions.map { ($0, $0 == 0 ? "Выкл" : "\($0) %") }, selection: saver.level) { saver.level = $0 }
            }
            if saver.level > 0, saver.ruleReady == false {
                SettingRow(title: "Разрешение", subtitle: "macOS спросит пароль один раз") {
                    Button("Разрешить без пароля") { Task { await LidAwake.shared.installRule() } }
                        .buttonStyle(VisorButtonStyle()).disabled(LidAwake.shared.busy)
                }
            }
            if let message = saver.message { caption(message, color: Palette.text) }
            caption("Работает только пока крышка закрыта, а режим «не засыпать» включён. Выключается сам, когда крышку открыли, Mac встал на зарядку или заряд поднялся на 5 % выше порога. Включённый вами вручную режим Visor не трогает.")
            SettingRow(title: "Выключать звук при закрытой крышке", subtitle: "вернётся при открытии",
                       toggle: Binding(get: { actions.muteOnClose }, set: { actions.muteOnClose = $0 }))
            SettingRow(title: "Замораживать остальные программы", subtitle: "при закрытой крышке",
                       toggle: Binding(get: { actions.freezeOthers }, set: { actions.freezeOthers = $0 }))
            caption("Замораживаются все программы, кроме отмеченных ниже, вместе с их фоновыми процессами. Они не греют Mac, а при открытии крышки продолжают с того же места. Программы Apple, Visor и Терминал не трогаются. Загрузки и звонки в замороженной программе остановятся: отметьте всё, что должно работать, например Claude.")
            if actions.freezeOthers {
                Text("Продолжают работать").font(.system(size: 12.5, weight: .semibold)).padding(.horizontal, 12).padding(.top, 4)
                ForEach(apps, id: \.bundle) { app in
                    SettingRow(title: app.name,
                               toggle: Binding(get: { actions.keepBundles.contains(app.bundle) }, set: { actions.setKept(app.bundle, $0) }))
                }
            }
            HotspotSettings()
        }
        .task { await saver.checkRule(); loadApps() }
    }

    private func loadApps() {
        var seen = Set<String>()
        apps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard ClosedLidActions.freezable(bundle: app.bundleIdentifier, policy: app.activationPolicy),
                  let bundle = app.bundleIdentifier, let name = app.localizedName, seen.insert(bundle).inserted else { return nil }
            return (bundle, name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func caption(_ text: String, color: Color = Palette.muted) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(color).padding(.horizontal, 12).fixedSize(horizontal: false, vertical: true)
    }
}
