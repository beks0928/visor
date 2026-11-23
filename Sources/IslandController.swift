import AppKit
import SwiftUI

/// Окно острова: без рамки, поверх строки меню, не забирает фокус у других приложений.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Клавиши, которые не взяло ни одно поле, гасятся здесь: иначе macOS пищит на каждое нажатие.
    /// Esc сворачивает остров.
    override func keyDown(with event: NSEvent) {
        _ = MainActor.assumeIsolated { IslandController.shared.handleKey(event) }
    }
}

/// Окно острова не активно, и по умолчанию первое нажатие по нему тратится на «пробуждение» окна, а действие срабатывает
/// только со второго. Здесь первое нажатие работает сразу.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class IslandController {
    static let shared = IslandController()

    let model = IslandModel()

    private var panel: IslandPanel?
    private var monitors: [Any] = []
    private var idleTimer: Timer?
    private var rotationTimer: Timer?
    private var outsideSince: Date?

    private let normalSize = CGSize(width: 860, height: 380)
    /// Обычный размер, а при развёрнутом тексте песни окно вырастает вниз, но не выходит за экран.
    private var expandedSize: CGSize {
        let wanted: CGFloat = model.lyricsExpanded ? 680 : (model.coverExpanded ? 500 : normalSize.height)
        let room = screen.visibleFrame.height - 16
        return CGSize(width: normalSize.width, height: max(normalSize.height, min(wanted, room)))
    }
    private let prefs = IslandPrefs.shared
    /// Экран, на котором остров стоит сейчас при выборе «Где курсор».
    private var cursorScreen: NSScreen?
    private var rotationTicks = 0

    // MARK: Геометрия выреза

    /// Экран по настройке. «Авто»: с вырезом, иначе основной (тот, где строка меню).
    private var screen: NSScreen {
        let primary = NSScreen.screens.first ?? NSScreen.main
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        switch prefs.screen {
        case .auto: return (notched ?? primary) ?? NSScreen.screens[0]
        case .main: return primary ?? NSScreen.screens[0]
        case .cursor: return cursorScreen ?? (notched ?? primary) ?? NSScreen.screens[0]
        }
    }

    /// Вырез экрана. Если его нет (старые Mac, внешний монитор), остров рисует свой такой же по центру строки меню.
    private var metrics: NotchMetrics.Result {
        let target = screen
        return NotchMetrics.resolve(screenWidth: target.frame.width, left: target.auxiliaryTopLeftArea?.width,
                                    right: target.auxiliaryTopRightArea?.width, safeTop: target.safeAreaInsets.top,
                                    menuBar: NSStatusBar.system.thickness)
    }

    private var notchWidth: CGFloat { metrics.width }
    private var notchHeight: CGFloat { metrics.height }

    /// Левый край выреза в координатах экрана.
    private var notchMinX: CGFloat { screen.frame.minX + metrics.minX }

    /// Экран под курсором.
    private func screenUnderCursor() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    private func frame(open: Bool) -> NSRect {
        let y = screen.frame.maxY
        if open {
            return NSRect(
                x: screen.frame.midX - expandedSize.width / 2,
                y: y - expandedSize.height,
                width: expandedSize.width,
                height: expandedSize.height
            )
        }
        // Свёрнутый остров прилегает к вырезу: узкие крылья по содержимому, а не симметрично по экрану.
        // Спрятанные глазок и таблетка места не занимают: остров сжимается до самого выреза.
        let wings = IslandLayout.wings(for: model)
        let width = wings.left + notchWidth + wings.right
        let height = notchHeight
        return NSRect(x: notchMinX - wings.left, y: y - height, width: width, height: height)
    }

    // MARK: Жизненный цикл

    func start(openAtLaunch: Bool) {
        let panel = IslandPanel(
            contentRect: frame(open: false),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.panel = panel

        rebuildContent()
        panel.orderFrontRegardless()
        installMonitors()

        // Запрос прав: остров раскрывается на «Агентах», решение за вами.
        AgentCenter.shared.onNeedsAnswer = { [weak self] in
            guard let self else { return }
            model.select(.agents)
            if !model.isOpen { open() }
        }
        // Правая таблетка сменяется через заданное число секунд, пока остров свёрнут и курсор не на нём.
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Срок временного скрытия вышел: остров возвращается. Ширина следует за тем, что сейчас показано.
                if let self, let until = self.prefs.hiddenUntil, until <= Date() { self.prefs.hiddenUntil = nil }
                AlertCenter.shared.evaluate()
                self?.syncWings()
                guard let self, !self.model.isOpen, !self.model.isHovering, self.model.capsuleItems.count > 1 else { return }
                self.rotationTicks += 1
                if self.rotationTicks >= self.prefs.rotationSeconds {
                    self.rotationTicks = 0
                    self.model.rotation += 1
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.relayout() }
        }
        NotificationCenter.default.addObserver(forName: .visorWingsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.syncWings() }
        }
        NotificationCenter.default.addObserver(forName: .visorScreenChoiceChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.cursorScreen = self?.screenUnderCursor()
                self?.relayout()
            }
        }

        PlayerController.shared.startBackgroundPolling()
        // Новая вкладка YouTube, TikTok или другого сайта выходит в таблетку сразу, дальше идёт обычная ротация.
        SiteWatcher.shared.onNew = { [weak self] in
            guard let self, let index = model.capsuleItems.firstIndex(of: .site) else { return }
            model.rotation = index
            rotationTicks = 0
        }
        SiteWatcher.shared.start()
        updateBattery()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateBattery() }
        }

        if openAtLaunch { open() }
    }

    /// Таблетка заряда появляется, только когда он ниже 20 % и Mac не на зарядке.
    private func updateBattery() {
        let reading = SystemMonitor.battery()
        model.lowBattery = (reading.map { $0.percent < 20 && !$0.onPower } ?? false) ? reading?.percent : nil
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        idleTimer?.invalidate()
    }

    private func rebuildContent() {
        guard let panel else { return }
        let view = IslandView(
            model: model,
            notchWidth: notchWidth,
            rowHeight: notchHeight,
            onToggle: { [weak self] in self?.toggle() },
            onClose: { [weak self] in self?.close() }
        )
        let host = IslandHostingView(rootView: view)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    /// Ширина свёрнутого острова под то, что сейчас показано (глазок, таблетка). Окно меняется, только если ширина другая.
    private var lastWings: (left: CGFloat, right: CGFloat) = (-1, -1)

    private func syncWings() {
        let wings = IslandLayout.wings(for: model)
        guard wings.left != lastWings.left || wings.right != lastWings.right else { return }
        lastWings = wings
        guard !model.isOpen else { return }
        panel?.setFrame(frame(open: false), display: true)
    }

    private func relayout() {
        panel?.setFrame(frame(open: model.isOpen), display: true)
        rebuildContent()
    }

    // MARK: Открытие и закрытие

    /// Горячая клавиша и клик по острову. Если остров раскрылся сам (запрос агента), первое нажатие отдаёт ему клавиатуру,
    /// второе сворачивает.
    func toggle() {
        if model.isOpen {
            if prefs.keyboardControl, !NSApp.isActive { focusForTyping() } else { close() }
        } else {
            open(userInitiated: true)
        }
    }

    /// `userInitiated`: остров открыт вами (клавиша или клик), и ему можно отдать клавиатуру.
    /// Открытый самим (запрос агента, файл над вырезом) он клавиатуру не забирает: набор текста в другом окне не прерывается.
    func open(userInitiated: Bool = false) {
        model.isOpen = true
        panel?.setFrame(frame(open: true), display: true)
        outsideSince = nil
        startIdleTimer()
        if userInitiated, prefs.keyboardControl { focusForTyping() }
    }

    /// Нажатие на таблетку справа от выреза открывает остров сразу на нужной вкладке.
    /// Нажатие на мигающую таблетку: ответ агенту открывает «Агентов», заряд открывает «Dev» с системой.
    func openFromAlert(_ alert: CapsuleAlert) {
        switch alert.kind {
        case .needsAnswer, .failed, .done: openFromPill(.agent)
        case .charging, .batteryCritical, .batteryLow: openFromPill(.battery)
        case .lidOff:
            open(userInitiated: true)
            model.openSettings(.awake)
        }
    }

    func openFromPill(_ item: CapsuleItem) {
        var tab = model.tab
        switch item {
        case .clock, .site: break
        case .timer:
            tab = .time
            TimeStore.shared.sub = TimeStore.shared.countdown?.label == "Таймер" ? .timer : .pomodoro
        case .stopwatch:
            tab = .time
            TimeStore.shared.sub = .stopwatch
        case .meeting, .tasks:
            tab = .plans
            model.plansHorizon = .day
        case .agent, .limits:
            tab = .agents
        case .music:
            tab = .media
            model.mediaSub = .player
            // Нажатие только открывает плеер. Воспроизведение не запускается: включать музыку нужно отдельной кнопкой.
        case .battery:
            tab = .dev
            model.devSub = .system
        }
        model.select(model.enabledTabs.contains(tab) ? tab : .agents)
        open(userInitiated: true)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard model.isOpen, prefs.keyboardControl else { return false }
        return IslandKeys.handle(event, model: model) { [weak self] in self?.close() }
    }

    /// Приложение, которое было активным до того, как остров забрал фокус для набора текста.
    private var previousApp: NSRunningApplication?

    /// Делает остров активным окном, чтобы в поля ввода можно было печатать.
    func focusForTyping() {
        if !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    /// Возвращает фокус приложению, из которого вы пришли. Без этого Visor оставался активным после сворачивания,
    /// и ваше окно не получало клавиш.
    func releaseFocus() {
        guard NSApp.isActive else {
            previousApp = nil
            return
        }
        if let previousApp, !previousApp.isTerminated {
            previousApp.activate(options: [])
        } else {
            NSApp.deactivate()
        }
        previousApp = nil
    }

    /// `restoreFocus: false` для клика в другом приложении: оно уже стало активным само, фокус отдавать не нужно.
    /// Разворачивает окно под текст песни или возвращает обычный размер.
    func setLyricsExpanded(_ expanded: Bool) {
        guard model.lyricsExpanded != expanded else { return }
        model.lyricsExpanded = expanded
        guard model.isOpen, let panel else { return }
        // Без анимации рамки: она заставляла тяжёлый вид перерисовываться на каждом кадре, и закрытие занимало секунды.
        panel.setFrame(frame(open: true), display: true, animate: false)
    }

    /// Вид с крупной обложкой: окно чуть выше обычного.
    func setCoverExpanded(_ expanded: Bool) {
        guard model.coverExpanded != expanded else { return }
        model.coverExpanded = expanded
        guard model.isOpen, let panel else { return }
        panel.setFrame(frame(open: true), display: true, animate: false)
    }

    func close(restoreFocus: Bool = true) {
        model.isOpen = false
        model.keepOpen = false
        model.lyricsExpanded = false
        model.coverExpanded = false
        panel?.setFrame(frame(open: false), display: true)
        idleTimer?.invalidate()
        idleTimer = nil
        if restoreFocus { releaseFocus() } else { previousApp = nil }
    }

    /// Клик вне острова сворачивает его. Слежение глобальное и только читает событие: клик доходит до окна, на которое нажали.
    private func outsideClick() {
        guard model.isOpen, prefs.closeOnOutsideClick, let panel, !ClipboardStore.shared.isPicking, !lyricsShown else { return }
        guard !panel.frame.contains(NSEvent.mouseLocation) else { return }
        close(restoreFocus: false)
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIdle() }
        }
    }

    /// Текст песни открыт на всю вкладку «Плеер» или открыт список поиска: остров не сворачивается ни по таймеру, ни по клику рядом. Esc и крестик работают.
    private var lyricsShown: Bool {
        model.tab == .media && model.mediaSub == .player && (PlayerController.shared.showLyrics || MusicSearchModel.shared.isOpen)
    }

    /// Сворачивает остров, если курсор не над ним дольше `autoCloseAfter` секунд.
    private func checkIdle() {
        guard model.isOpen, let panel else { return }
        // Пипетка и набор сниппета не должны прерываться сворачиванием.
        if model.keepOpen || ClipboardStore.shared.isPicking || lyricsShown {
            outsideSince = nil
            return
        }
        if panel.frame.contains(NSEvent.mouseLocation) {
            outsideSince = nil
        } else if prefs.autoCloseSeconds == 0 {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) >= TimeInterval(prefs.autoCloseSeconds) { close() }
        } else {
            outsideSince = Date()
        }
    }

    // MARK: Курсор

    private var dragBaseline = NSPasteboard(name: .drag).changeCount

    private func installMonitors() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            let dragging = event.type == .leftMouseDragged
            Task { @MainActor in self?.pointerMoved(dragging: dragging) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.pointerMoved(dragging: false) }
            return event
        }
        let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in
                // Буфер перетаскивания помнит прошлый файл; запоминаем его состояние в момент нажатия.
                self?.dragBaseline = NSPasteboard(name: .drag).changeCount
                self?.outsideClick()
            }
        }
        monitors = [global, local, clicks].compactMap { $0 }
    }

    /// Наведение считается по координатам, а не по событиям окна: окно не активное.
    /// Заодно считаем, куда «смотрит» точка в кольце агента.
    private func pointerMoved(dragging: Bool) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        model.isHovering = panel.frame.contains(mouse)

        // «Где курсор»: свёрнутый остров переезжает на экран, куда ушёл курсор. Раскрытый остров остаётся на месте.
        if prefs.screen == .cursor, !model.isOpen, let target = screenUnderCursor(), target != cursorScreen {
            cursorScreen = target
            relayout()
            return
        }

        // Файл тащат к вырезу: остров раскрывается на полке сам, бросать можно прямо на него.
        // Двигают окно или выделяют текст: буфер перетаскивания не менялся с нажатия, и старый файл в нём не в счёт.
        if dragging, !model.isOpen, model.enabledTabs.contains(.shelf), NSPasteboard(name: .drag).changeCount != dragBaseline,
           ShelfStore.dragHasFiles(),
           panel.frame.insetBy(dx: -40, dy: -40).contains(mouse) {
            model.select(.shelf)
            open()
        }

        guard !model.isOpen else { return }
        let ring = CGPoint(x: panel.frame.minX + IslandLayout.edgePadding + 11, y: panel.frame.maxY - notchHeight / 2)
        let dx = mouse.x - ring.x
        let dy = -(mouse.y - ring.y)
        let distance = max(hypot(dx, dy), 1)
        let reach = min(3.2, distance / 14)
        model.eye = CGSize(width: dx / distance * reach, height: dy / distance * reach)
    }
}
