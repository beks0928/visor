import AppKit
import Carbon.HIToolbox
import Observation
import ServiceManagement

/// На каком экране живёт остров.
enum ScreenChoice: String, CaseIterable, Identifiable {
    case auto, main, cursor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Авто"
        case .main: "Основной"
        case .cursor: "Где курсор"
        }
    }

    var hint: String {
        switch self {
        case .auto: "Экран с вырезом, а если выреза нет, основной"
        case .main: "Экран со строкой меню"
        case .cursor: "Остров переезжает на экран, где сейчас курсор"
        }
    }
}

enum HotKeyChoice: String, CaseIterable, Identifiable {
    case option, optionShift, commandShift

    var id: String { rawValue }

    var title: String {
        switch self {
        case .option: "⌥ Пробел"
        case .optionShift: "⌥⇧ Пробел"
        case .commandShift: "⌘⇧ Пробел"
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .option: UInt32(optionKey)
        case .optionShift: UInt32(optionKey | shiftKey)
        case .commandShift: UInt32(cmdKey | shiftKey)
        }
    }

    var menuModifiers: NSEvent.ModifierFlags {
        switch self {
        case .option: [.option]
        case .optionShift: [.option, .shift]
        case .commandShift: [.command, .shift]
        }
    }
}

extension Notification.Name {
    static let visorHotKeyChanged = Notification.Name("visorHotKeyChanged")
    static let visorScreenChoiceChanged = Notification.Name("visorScreenChoiceChanged")
    /// Глазок или таблетка справа показаны или спрятаны: свёрнутый остров меняет ширину.
    static let visorWingsChanged = Notification.Name("visorWingsChanged")
}

/// Положение и размер выреза. На Mac без выреза остров рисует свой такой же по центру строки меню.
enum NotchMetrics {
    struct Result: Equatable {
        let width: CGFloat
        let height: CGFloat
        /// Левый край выреза от левого края экрана.
        let minX: CGFloat
    }

    static let virtualWidth: CGFloat = 180

    static func resolve(screenWidth: CGFloat, left: CGFloat?, right: CGFloat?, safeTop: CGFloat, menuBar: CGFloat) -> Result {
        if safeTop > 0 {
            if let left, let right { return Result(width: screenWidth - left - right, height: safeTop, minX: left) }
            return Result(width: virtualWidth, height: safeTop, minX: (screenWidth - virtualWidth) / 2)
        }
        // Без выреза остров повторяет высоту строки меню: так он выглядит как её часть.
        let height = min(40, max(22, menuBar))
        return Result(width: virtualWidth, height: height, minX: (screenWidth - virtualWidth) / 2)
    }
}

/// Автозапуск при входе в систему.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Один раз после установки автозапуск включается сам: без него Visor не появляется после перезагрузки.
    /// Только из «Программ» и только если он ещё не включён. Выключенный вручную потом остаётся выключенным.
    nonisolated static func shouldEnableOnFirstRun(offered: Bool, inApplications: Bool, enabled: Bool) -> Bool {
        !offered && inApplications && !enabled
    }

    @MainActor static func enableOnFirstRun(defaults: UserDefaults = .standard) {
        let key = "prefs.launchAtLoginOffered"
        guard shouldEnableOnFirstRun(offered: defaults.bool(forKey: key), inApplications: isInApplications, enabled: isEnabled) else { return }
        defaults.set(true, forKey: key)
        try? set(true)
        IslandPrefs.shared.refreshLaunch()
    }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Основные настройки острова. Хранятся в UserDefaults.
@MainActor @Observable
final class IslandPrefs {
    static let shared = IslandPrefs(defaults: .standard)

    /// Через сколько секунд без курсора остров сворачивается сам. 0 значит никогда.
    var autoCloseSeconds: Int { didSet { defaults.set(autoCloseSeconds, forKey: "prefs.autoClose") } }
    var rotationSeconds: Int { didSet { defaults.set(rotationSeconds, forKey: "prefs.rotation") } }
    var screen: ScreenChoice {
        didSet {
            defaults.set(screen.rawValue, forKey: "prefs.screen")
            NotificationCenter.default.post(name: .visorScreenChoiceChanged, object: nil)
        }
    }
    var hotKey: HotKeyChoice {
        didSet {
            defaults.set(hotKey.rawValue, forKey: "prefs.hotKey")
            hotKeyBusy = !HotKey.register(hotKey)
            NotificationCenter.default.post(name: .visorHotKeyChanged, object: nil)
        }
    }
    /// Раскрытый остров управляется клавишами: стрелки, пробел, цифры.
    /// Клик в любом месте вне острова сворачивает его. Сам клик не перехватывается: окно, на которое нажали, получает его как обычно.
    var closeOnOutsideClick: Bool { didSet { defaults.set(closeOnOutsideClick, forKey: "prefs.outsideClick") } }
    var keyboardControl: Bool { didSet { defaults.set(keyboardControl, forKey: "prefs.keyboard") } }
    /// Глазок слева и таблетка справа свёрнутого острова. Если мешают (закрывают чужие значки в строке меню), прячутся:
    /// остров сжимается до самого выреза. Меню по правому клику на острове.
    var showEye: Bool { didSet { defaults.set(showEye, forKey: "prefs.showEye"); wingsChanged() } }
    var showCapsule: Bool { didSet { defaults.set(showCapsule, forKey: "prefs.showCapsule"); wingsChanged() } }
    /// Поменять стороны: таблетка слева от выреза, глазок справа.
    var swapSides: Bool { didSet { defaults.set(swapSides, forKey: "prefs.swapSides"); wingsChanged() } }
    /// Виды таблеток, которые не участвуют в ротации (`CapsuleItem.kind`).
    var hiddenCapsules: Set<String> {
        didSet { defaults.set(hiddenCapsules.sorted(), forKey: "prefs.hiddenCapsules"); wingsChanged() }
    }
    /// Всё спрятано до этого времени. Не сохраняется: после перезапуска Visor остров возвращается.
    var hiddenUntil: Date? { didSet { wingsChanged() } }
    private(set) var hotKeyBusy = false
    private(set) var launchAtLogin = false
    private(set) var launchNeedsApproval = false
    private(set) var launchError: String?

    static let autoCloseOptions = [5, 8, 15, 30, 0]
    static let rotationOptions = [2, 3, 5, 10]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let close = defaults.object(forKey: "prefs.autoClose") as? Int
        autoCloseSeconds = close.flatMap { Self.autoCloseOptions.contains($0) ? $0 : nil } ?? 8
        let rotation = defaults.object(forKey: "prefs.rotation") as? Int
        rotationSeconds = rotation.flatMap { Self.rotationOptions.contains($0) ? $0 : nil } ?? 3
        closeOnOutsideClick = defaults.object(forKey: "prefs.outsideClick") as? Bool ?? true
        keyboardControl = defaults.object(forKey: "prefs.keyboard") as? Bool ?? true
        showEye = defaults.object(forKey: "prefs.showEye") as? Bool ?? true
        showCapsule = defaults.object(forKey: "prefs.showCapsule") as? Bool ?? true
        swapSides = defaults.bool(forKey: "prefs.swapSides")
        hiddenCapsules = Set(defaults.stringArray(forKey: "prefs.hiddenCapsules") ?? [])
        screen = ScreenChoice(rawValue: defaults.string(forKey: "prefs.screen") ?? "") ?? .auto
        hotKey = HotKeyChoice(rawValue: defaults.string(forKey: "prefs.hotKey") ?? "") ?? .option
    }

    /// Спрятано «на время», и срок ещё не вышел.
    var temporarilyHidden: Bool { hiddenUntil.map { $0 > Date() } ?? false }
    var eyeVisible: Bool { showEye && !temporarilyHidden }
    var capsuleVisible: Bool { showCapsule && !temporarilyHidden }

    private func wingsChanged() {
        NotificationCenter.default.post(name: .visorWingsChanged, object: nil)
    }

    func refreshLaunch() {
        launchAtLogin = LaunchAtLogin.isEnabled
        launchNeedsApproval = LaunchAtLogin.needsApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            launchError = nil
        } catch {
            launchError = "macOS не дала включить автозапуск. Положите Visor в «Программы» и попробуйте снова."
        }
        refreshLaunch()
    }
}
