import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct VisorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Окон нет: всё живёт в острове и в строке меню.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var hookServer: HookServer?
    private var hookWatchdog: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), flag + 1 < CommandLine.arguments.count {
            Snapshot.write(to: CommandLine.arguments[flag + 1])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        SecretStore.delete("medkoalu-link") // связь с MedKoalu убрана: забытый ключ больше не нужен
        UserDefaults.standard.removeObject(forKey: "island.medkoaluTabAdded")
        IslandController.shared.start(openAtLaunch: CommandLine.arguments.contains("--open"))
        installStatusItem()
        HotKey.register(IslandPrefs.shared.hotKey)
        NotificationCenter.default.addObserver(forName: .visorHotKeyChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyHotKeyToMenu() }
        }
        applyHotKeyToMenu()
        startAgents()
        ScreenshotWatcher.shared.start()
        SpotifyConnect.shared.startWatching()
        LidAwake.shared.start()
        PowerSaver.shared.start()
        ClosedLidActions.shared.start()
        HotspotFailover.shared.start()
        ClipboardStore.shared.start()
        _ = TimeStore.shared // идущий таймер продолжается после перезапуска
        CalendarService.shared.start() // без запроса доступа: работает, только если он уже выдан
    }

    func applicationWillTerminate(_ notification: Notification) {
        hookServer?.stop()
        LidAwake.shared.willQuit()
        IslandController.shared.stop()
    }

    /// Ретранслятор хуков, сервер на сокете и состояние агентов.
    private func startAgents() {
        HookRelay.install()
        AgentCenter.shared.start()
        startHookServer()
        // Если сокет пропал (его удалила другая копия Visor или очистка), сервер поднимается заново:
        // без него события агентов и звук «готово» молча не доходят.
        hookWatchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hookServer?.isReachable != true else { return }
                NSLog("Visor: сокет хуков пропал, запускаю сервер заново")
                self.hookServer?.stop()
                self.startHookServer()
            }
        }
    }

    private func startHookServer() {
        let server = HookServer()
        do {
            try server.start { request in
                Task { @MainActor in AgentCenter.shared.handle(request) }
            }
            hookServer = server
        } catch {
            hookServer = nil
            NSLog("Visor: сервер хуков не запустился: \(error)")
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "eye.circle", accessibilityDescription: "Visor")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Открыть остров", action: #selector(toggleIsland), keyEquivalent: " ")
        toggle.keyEquivalentModifierMask = [.option]
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        if Feedback.repository != nil {
            let report = NSMenuItem(title: "Сообщить о проблеме…", action: #selector(reportProblem), keyEquivalent: "")
            report.target = self
            menu.addItem(report)
        }
        let quit = NSMenuItem(title: "Выйти из Visor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.delegate = self
        item.menu = menu
        statusItem = item
        toggleItem = toggle
    }

    /// Подпись сочетания в меню строки состояния следует настройке.
    private func applyHotKeyToMenu() {
        toggleItem?.keyEquivalentModifierMask = IslandPrefs.shared.hotKey.menuModifiers
    }

    @objc private func reportProblem() {
        Feedback.open(.bug)
    }

    @objc private func toggleIsland() {
        IslandController.shared.toggle()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        toggleItem?.title = IslandController.shared.model.isOpen ? "Свернуть остров" : "Открыть остров"
    }
}

/// Глобальная горячая клавиша с пробелом, сочетание выбирается в настройках. Carbon не требует системных разрешений.
@MainActor
enum HotKey {
    private static var ref: EventHotKeyRef?
    private static var handlerInstalled = false

    /// Возвращает false, если сочетание уже занято другим приложением.
    @discardableResult
    static func register(_ choice: HotKeyChoice) -> Bool {
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in IslandController.shared.toggle() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        let id = EventHotKeyID(signature: OSType(0x5649_534F), id: 1) // «VISO»
        var fresh: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_Space), choice.carbonModifiers, id, GetApplicationEventTarget(), 0, &fresh)
        ref = status == noErr ? fresh : nil
        return status == noErr
    }
}
