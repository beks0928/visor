import AppKit
import SwiftUI

/// Команды режима «не засыпать при закрытой крышке». Устроено так же, как у Insomnia (github.com/krishhgg/Insomnia, MIT):
/// Mac не засыпает при закрытии крышки, пока включён `pmset -a disablesleep 1`. Это делает root, поэтому нужно правило sudoers,
/// которое разрешает ровно две команды без пароля. Правило у Insomnia уже есть: `sudo -n` его находит, и Visor использует его.
enum LidPmset {
    static let sudo = "/usr/bin/sudo"
    static let pmset = "/usr/bin/pmset"
    static let rulePath = "/etc/sudoers.d/visor-lid"

    /// `sudo -n`: без запроса пароля. Если правила нет, команда сразу падает, а не виснет.
    static func arguments(disabled: Bool) -> [String] { ["-n", pmset, "-a", "disablesleep", disabled ? "1" : "0"] }

    /// Проверка правила без запуска команды: `sudo -n -l <команда>` отвечает 0, если её можно без пароля.
    static func checkArguments(disabled: Bool) -> [String] { ["-n", "-l", pmset, "-a", "disablesleep", disabled ? "1" : "0"] }

    /// Строка `SleepDisabled` из `pmset -g`: true для 1, false для 0, nil, если строки нет или значение другое.
    static func readSleepDisabled(_ output: String) -> Bool? {
        for raw in output.split(whereSeparator: \.isNewline) {
            let parts = raw.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "SleepDisabled" else { continue }
            switch parts[1] {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// Имя пользователя попадает в файл sudoers, поэтому пускаем только обычные имена: никаких пробелов, запятых и кавычек.
    static func isSafeUser(_ user: String) -> Bool {
        user.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]{0,31}$"#, options: .regularExpression) != nil
    }

    static func sudoersLine(user: String) -> String? {
        isSafeUser(user) ? "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, "
            + "/usr/bin/pmset -b lowpowermode 1, /usr/bin/pmset -b lowpowermode 0" : nil
    }

    /// Одна строка для `do shell script … with administrator privileges`: проверяет файл через visudo и только потом кладёт его.
    static func installScript(user: String) -> String? {
        guard let line = sudoersLine(user: user) else { return nil }
        return "/bin/mkdir -p /etc/sudoers.d && T=$(/usr/bin/mktemp) && printf '%s\\n' '\(line)' > \"$T\" && /usr/sbin/visudo -cf \"$T\" "
            + "&& /usr/bin/install -m 0440 -o root -g wheel \"$T\" \(rulePath); S=$?; /bin/rm -f \"$T\"; exit $S"
    }

    static let removeScript = "/bin/rm -f \(rulePath)"

    /// Скрипт страховки. Раз в минуту (его запускает агент launchd): если время сессии вышло, возвращает сон.
    /// Работает и когда Visor закрыт, и после перезагрузки.
    static let guardScript = """
    #!/bin/sh
    # Visor: страховка для режима «не засыпать при закрытой крышке». Если время сессии вышло, возвращает сон.
    f="$HOME/Library/Application Support/Visor/lid-session"
    [ -f "$f" ] || exit 0
    ends=$(cat "$f" 2>/dev/null)
    case "$ends" in ''|*[!0-9]*) exit 0 ;; esac
    now=$(date +%s)
    if [ "$now" -ge "$ends" ]; then
        /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 && rm -f "$f"
    fi

    """

    static let agentLabel = "com.beksultan.visor.lidguard"

    static func agentPlist(scriptPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(agentLabel)</string>
        <key>ProgramArguments</key><array><string>/bin/sh</string><string>\(scriptPath)</string></array>
        <key>RunAtLoad</key><true/>
        <key>StartInterval</key><integer>60</integer>
        </dict></plist>
        """
    }

    /// «1:42» или «0:35» для остатка в секундах.
    static func remaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 3600, total % 3600 / 60)
    }

    /// Длительности для выбора: секунды, 0 значит «пока не выключу».
    static let durations: [(seconds: Int, title: String)] = [
        (1800, "30 мин"), (3600, "1 ч"), (7200, "2 ч"), (14400, "4 ч"), (28800, "8 ч"), (0, "Пока не выключу"),
    ]
}

/// Режим «не засыпать при закрытой крышке». Состояние берётся из `pmset -g`, а не из памяти: если режим включили снаружи
/// (Insomnia, Терминал), Visor это видит.
@MainActor @Observable
final class LidAwake {
    static let shared = LidAwake()

    /// Сон отключён сейчас (по `pmset -g`), кем бы ни был включён режим.
    private(set) var active = false
    /// Режим включил Visor: ему принадлежит таймер и страховка.
    private(set) var owned: Bool
    private(set) var endsAt: Date?
    /// nil: ещё не проверяли. false: правила sudoers нет, нужен пароль один раз.
    private(set) var ruleReady: Bool?
    private(set) var busy = false
    var message: String?

    /// Сколько держать: секунды, 0 значит «пока не выключу».
    /// Таймер идёт только при закрытой крышке. Смена срока при уже идущем таймере сразу меняет остаток: отсчёт начинается заново.
    var durationSeconds: Int {
        didSet {
            defaults.set(durationSeconds, forKey: "visor.lid.duration")
            if oldValue != durationSeconds { restartTimerIfClosed() }
        }
    }
    /// Ниже этого заряда на батарее режим выключается. 0: не выключать. Работает, пока запущен Visor.
    var batteryFloor: Int { didSet { defaults.set(batteryFloor, forKey: "visor.lid.floor") } }

    static let floorOptions = [0, 10, 20]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false

    init(defaults: UserDefaults = .standard, directory: URL = VisorPaths.supportDir) {
        self.defaults = defaults
        self.directory = directory
        owned = defaults.bool(forKey: "visor.lid.owned")
        let end = defaults.double(forKey: "visor.lid.endsAt")
        endsAt = end > 0 ? Date(timeIntervalSince1970: end) : nil
        let saved = defaults.object(forKey: "visor.lid.duration") as? Int
        durationSeconds = saved.flatMap { value in LidPmset.durations.contains { $0.seconds == value } ? value : nil } ?? 7200
        let floor = defaults.object(forKey: "visor.lid.floor") as? Int
        batteryFloor = floor.flatMap { Self.floorOptions.contains($0) ? $0 : nil } ?? 10
    }

    private var sessionFile: URL { directory.appendingPathComponent("lid-session") }
    private var guardScriptURL: URL { directory.appendingPathComponent("lid-guard.sh") }
    private var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(LidPmset.agentLabel).plist")
    }

    var remaining: TimeInterval? { endsAt.map { $0.timeIntervalSinceNow } }

    // MARK: Запуск и слежение

    /// Раз в 30 секунд сверяет состояние, время и заряд.
    func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await tick() }
    }

    /// Выход из Visor: режим «пока не выключу» держать некому, поэтому он выключается. Режим с таймером остаётся: его закончит страховка.
    func willQuit() {
        ClosedLidActions.shared.willQuit()
        guard active, owned, endsAt == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: LidPmset.sudo)
        process.arguments = LidPmset.arguments(disabled: false)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        clearOwnership()
    }

    private func tick() async {
        await refresh()
        guard active, owned else { return }
        if let endsAt, endsAt <= Date() {
            await stop(reason: "Время режима вышло: Mac снова засыпает при закрытии крышки.")
            AlertCenter.shared.lidModeEnded(because: "Не спит: время вышло")
        } else if batteryFloor > 0, let battery = SystemMonitor.battery(), !battery.onPower, battery.percent < batteryFloor {
            await stop(reason: "Заряд ниже \(batteryFloor) %: режим выключен, чтобы Mac не сел в ноль в закрытом виде.")
            AlertCenter.shared.lidModeEnded(because: "Не спит: мало заряда")
        }
    }

    // MARK: Состояние

    nonisolated static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 20) async -> (status: Int32, output: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return (-1, "\(error.localizedDescription)") }
            // Зависший процесс останавливается мягко (SIGTERM): жёсткое завершение sudo оставило бы осиротевший pmset.
            let stopper = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stopper)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            stopper.cancel()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }

    func refresh() async {
        let reading = await Self.run(LidPmset.pmset, ["-g"])
        if let disabled = LidPmset.readSleepDisabled(reading.output) { active = disabled }
        if !active, owned { clearOwnership() }
        await checkRule()
    }

    func checkRule() async {
        let on = await Self.run(LidPmset.sudo, LidPmset.checkArguments(disabled: true))
        let off = await Self.run(LidPmset.sudo, LidPmset.checkArguments(disabled: false))
        ruleReady = on.status == 0 && off.status == 0
    }

    private func clearOwnership() {
        owned = false
        endsAt = nil
        defaults.set(false, forKey: "visor.lid.owned")
        defaults.removeObject(forKey: "visor.lid.endsAt")
        try? FileManager.default.removeItem(at: sessionFile)
    }

    // MARK: Включение и выключение

    /// `seconds` 0: пока не выключу.
    func enable(seconds: Int) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        message = nil
        await checkRule()
        guard ruleReady == true else {
            message = "Нужно правило, которое разрешает включать режим без пароля. Нажмите «Разрешить без пароля»."
            return
        }
        let result = await Self.run(LidPmset.sudo, LidPmset.arguments(disabled: true))
        guard result.status == 0 else {
            message = "Не получилось включить режим: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            return
        }
        // Читаем обратно: другая программа могла тут же сбросить значение, и закрытая крышка всё равно усыпила бы Mac.
        try? await Task.sleep(for: .seconds(3))
        let reading = await Self.run(LidPmset.pmset, ["-g"])
        guard LidPmset.readSleepDisabled(reading.output) == true else {
            message = "macOS сразу вернула сон: возможно, другая программа управляет им. Закрытая крышка усыпит Mac."
            return
        }
        active = true
        owned = true
        defaults.set(true, forKey: "visor.lid.owned")
        // Таймер не идёт, пока крышка открыта: он запускается, когда её закроют (`lidDidClose`).
        durationSeconds = seconds
        clearTimer()
        if ClosedLidActions.shared.closed { lidDidClose() }
        message = seconds > 0
            ? "Режим включён. Отсчёт \(LidPmset.durations.first { $0.seconds == seconds }?.title ?? "") начнётся, когда вы закроете крышку."
            : "Режим включён без срока. Выключится при выходе из Visor или кнопкой."
    }

    /// Крышку закрыли: если выбран срок, начинается отсчёт, и страховка launchd будет следить за концом.
    func lidDidClose() {
        guard active, owned, durationSeconds > 0 else { return }
        let end = Date().addingTimeInterval(TimeInterval(durationSeconds))
        endsAt = end
        defaults.set(end.timeIntervalSince1970, forKey: "visor.lid.endsAt")
        writeGuard(endEpoch: Int(end.timeIntervalSince1970))
    }

    /// Крышку открыли: отсчёт останавливается и начнётся заново при следующем закрытии.
    func lidDidOpen() {
        guard owned, endsAt != nil else { return }
        clearTimer()
    }

    private func restartTimerIfClosed() {
        guard active, owned, ClosedLidActions.shared.closed else { return }
        if durationSeconds > 0 { lidDidClose() } else { clearTimer() }
    }

    private func clearTimer() {
        endsAt = nil
        defaults.removeObject(forKey: "visor.lid.endsAt")
        try? FileManager.default.removeItem(at: sessionFile)
    }

    func stop(reason: String? = nil) async {
        if busy, reason == nil { return }
        busy = true
        defer { busy = false }
        let result = await Self.run(LidPmset.sudo, LidPmset.arguments(disabled: false))
        let reading = await Self.run(LidPmset.pmset, ["-g"])
        if let disabled = LidPmset.readSleepDisabled(reading.output) { active = disabled }
        if result.status == 0, !active {
            clearOwnership()
            message = reason ?? "Режим выключен: Mac снова засыпает при закрытии крышки."
        } else {
            message = "Не получилось выключить режим: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines)). Выключите его в Терминале: sudo pmset -a disablesleep 0"
        }
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: Страховка и правило

    /// Записывает время конца и ставит агента launchd, который раз в минуту его проверяет.
    private func writeGuard(endEpoch: Int) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? "\(endEpoch)".write(to: sessionFile, atomically: true, encoding: .utf8)
        try? LidPmset.guardScript.write(to: guardScriptURL, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: guardScriptURL.path)
        let plist = LidPmset.agentPlist(scriptPath: guardScriptURL.path)
        let existing = try? String(contentsOf: agentURL, encoding: .utf8)
        guard existing != plist else { return }
        try? manager.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? plist.write(to: agentURL, atomically: true, encoding: .utf8)
        let agentPath = agentURL.path
        Task.detached {
            let domain = "gui/\(getuid())"
            _ = await Self.run("/bin/launchctl", ["bootout", "\(domain)/\(LidPmset.agentLabel)"])
            _ = await Self.run("/bin/launchctl", ["bootstrap", domain, agentPath])
        }
    }

    /// Правило sudoers: пароль macOS спрашивает один раз, и только по кнопке.
    func installRule() async {
        guard !busy else { return }
        guard let script = LidPmset.installScript(user: NSUserName()) else {
            message = "Имя пользователя не подходит для правила: оно должно состоять из латиницы, цифр, точки, дефиса и подчёркивания."
            return
        }
        busy = true
        defer { busy = false }
        let result = await Self.run("/usr/bin/osascript", ["-e", "do shell script \(MusicSearchModel.quoted(script)) with administrator privileges"], timeout: 120)
        await checkRule()
        await PowerSaver.shared.checkRule()
        message = ruleReady == true ? "Правило установлено: режим включается без пароля."
            : "Правило не установилось. \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    func removeRule() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        _ = await Self.run("/usr/bin/osascript", ["-e", "do shell script \(MusicSearchModel.quoted(LidPmset.removeScript)) with administrator privileges"], timeout: 120)
        await checkRule()
        message = ruleReady == true ? "Правило осталось: его использует и Insomnia. Удалите его оттуда." : "Правило удалено."
    }
}

// MARK: Настройки

/// Вкладка Awake: режим «не засыпать при закрытой крышке».
struct PowerSettings: View {
    var lid: LidAwake = .shared

    var body: some View {
        VScroll { content }
            .task { await lid.refresh() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(title: "Не засыпать при закрытой крышке", subtitle: status) {
                Button(action: toggle) {
                    Text(lid.busy ? "Подождите…" : (lid.active ? "Выключить" : "Включить"))
                }
                .buttonStyle(VisorButtonStyle())
                .disabled(lid.busy)
            }
            SettingRow(title: "На сколько включить") {
                ChoiceChips(options: LidPmset.durations.map { ($0.seconds, $0.title) }, selection: lid.durationSeconds) { lid.durationSeconds = $0 }
            }
            SettingRow(title: "Выключать при заряде ниже", subtitle: "только на батарее, пока запущен Visor") {
                ChoiceChips(options: LidAwake.floorOptions.map { ($0, $0 == 0 ? "Никогда" : "\($0) %") }, selection: lid.batteryFloor) { lid.batteryFloor = $0 }
            }
            if lid.ruleReady == false {
                SettingRow(title: "Разрешение", subtitle: "macOS спросит пароль один раз") {
                    Button("Разрешить без пароля") { Task { await lid.installRule() } }.buttonStyle(VisorButtonStyle()).disabled(lid.busy)
                }
                caption("Правило в /etc/sudoers.d/visor-lid разрешает без пароля четыре команды: pmset -a disablesleep 1 и 0 и pmset -b lowpowermode 1 и 0. Любая программа под вашим пользователем сможет включать и выключать этот режим. У Insomnia то же правило: если оно уже стоит, Visor его использует и это окно не нужно.")
            }
            if let message = lid.message {
                caption(message, color: Palette.text)
            }
            PowerExtrasSettings()
            caption("Ставьте Mac на твёрдую поверхность с вентиляцией, не в сумку: закрытый и работающий Mac греется. Режим с таймером выключит страховка (агент launchd раз в минуту), даже если Visor закрыт. Заряд Visor проверяет только пока запущен.")
        }
    }

    private var status: String {
        if lid.active {
            if let remaining = lid.remaining { return "включён, осталось \(LidPmset.remaining(remaining))" }
            if lid.owned, lid.durationSeconds > 0 { return "включён, отсчёт начнётся, когда закроете крышку" }
            return lid.owned ? "включён, без срока" : "включён (не из Visor, например Insomnia)"
        }
        return "выключен: при закрытии крышки Mac засыпает"
    }

    private func toggle() {
        Task { if lid.active { await lid.stop() } else { await lid.enable(seconds: lid.durationSeconds) } }
    }

    private func caption(_ text: String, color: Color = Palette.muted) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(color).padding(.horizontal, 12).fixedSize(horizontal: false, vertical: true)
    }
}
