import AppKit

/// Клавиатурное управление раскрытым островом. Вызывается только для клавиш, которые не взяло ни одно поле ввода,
/// поэтому набор текста никогда не превращается в команды.
/// Коды клавиш не зависят от раскладки: русская и английская раскладки работают одинаково.
@MainActor
enum IslandKeys {
    private enum Code {
        static let space = 49, left = 123, right = 124, down = 125, up = 126
        static let enter = 36, delete = 51, escape = 53
        static let comma = 43, slash = 44, equal = 24
        static let a = 0, y = 16, n = 45, p = 35, r = 15, l = 37, m = 46
        static let digits: [Int: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
    }

    /// Возвращает true, если клавиша использована.
    static func handle(_ event: NSEvent, model: IslandModel, close: () -> Void) -> Bool {
        let key = Int(event.keyCode)
        let shift = event.modifierFlags.contains(.shift)
        let command = event.modifierFlags.contains(.command)

        // Удерживаемая клавиша повторяется: пробел не должен переключать воспроизведение десять раз подряд.
        if event.isARepeat, ![Code.left, Code.right, Code.up, Code.down].contains(key) { return true }

        if key == Code.escape {
            // Esc идёт на шаг назад: страница, потом список поиска, потом текст песни, и только потом сам остров.
            if model.page != nil {
                model.page = nil
            } else if model.tab == .media, MusicSearchModel.shared.isOpen {
                MusicSearchModel.shared.clear()
            } else if model.tab == .media, PlayerController.shared.showCover {
                PlayerController.shared.showCover = false
            } else if model.tab == .media, PlayerController.shared.showLyrics {
                PlayerController.shared.showLyrics = false
            } else {
                close()
            }
            return true
        }
        // Страница настроек: стрелки листают разделы настроек.
        if model.page == .settings, key == Code.left || key == Code.right {
            model.settingsTab = cycle(SettingsTab.allCases, from: model.settingsTab, by: key == Code.right ? 1 : -1)
            return true
        }
        if model.page != nil, key == Code.comma, !command {
            model.page = nil
            return true
        }

        // Особые клавиши текущей вкладки идут раньше общих.
        if model.page == nil, handleTab(key: key, shift: shift, command: command, model: model) { return true }

        switch key {
        case Code.left, Code.right:
            guard model.page == nil else { return false }
            let tabs = model.visibleTabs
            guard let index = tabs.firstIndex(of: model.tab), tabs.count > 1 else { return true }
            model.select(tabs[(index + (key == Code.right ? 1 : tabs.count - 1)) % tabs.count])
            return true
        case Code.up, Code.down:
            return cycleSub(model: model, by: key == Code.down ? 1 : -1)
        case Code.comma:
            model.togglePage(.settings)
            return true
        case Code.equal:
            model.togglePage(.add)
            return true
        case Code.m:
            model.toggleMute()
            return true
        case Code.slash where shift:
            model.openSettings(.keys)
            return true
        default:
            if let number = Code.digits[key], number <= model.visibleTabs.count {
                model.select(model.visibleTabs[number - 1])
                return true
            }
            return false
        }
    }

    // MARK: Вкладки

    private static func handleTab(key: Int, shift: Bool, command: Bool, model: IslandModel) -> Bool {
        switch model.tab {
        case .agents:
            guard let permission = AgentCenter.shared.permissions.first else { return false }
            switch key {
            case Code.y, Code.enter: AgentCenter.shared.decide(permission.id, .allow)
            case Code.a: AgentCenter.shared.decide(permission.id, .always)
            case Code.n, Code.delete: AgentCenter.shared.decide(permission.id, .deny)
            default: return false
            }
            return true
        case .media:
            switch model.mediaSub {
            case .player: return playerKey(key: key, shift: shift, command: command)
            case .web: return false
            case .teleprompter:
                let store = TeleprompterStore.shared
                switch key {
                case Code.space: store.toggle()
                case Code.r: store.rewind()
                case Code.up where command: store.speed = min(150, store.speed + 10)
                case Code.down where command: store.speed = max(10, store.speed - 10)
                default: return false
                }
                return true
            case .notes: return false
            }
        case .time:
            return timeKey(key: key)
        case .shelf:
            let shelf = ShelfStore.shared
            switch key {
            case Code.a where command: shelf.selectAll()
            case Code.delete: shelf.removeSelected()
            case Code.enter:
                guard let id = shelf.selection.first else { return false }
                shelf.open(id)
            default: return false
            }
            return true
        default:
            return false
        }
    }

    private static func playerKey(key: Int, shift: Bool, command: Bool) -> Bool {
        let player = PlayerController.shared
        switch key {
        case Code.space:
            Task { await player.send(.playPause) }
        case Code.n where !command, Code.right where command:
            Task { await player.send(.next) }
        case Code.p where !command, Code.left where command:
            Task { await player.send(.previous) }
        case Code.right where shift, Code.left where shift:
            // Shift со стрелками перематывает на 10 секунд.
            guard let track = player.nowPlaying, track.canSeek else { return true }
            player.seek(to: track.position(at: Date()) + (key == Code.right ? 10 : -10))
        default:
            return false
        }
        return true
    }

    private static func timeKey(key: Int) -> Bool {
        let store = TimeStore.shared
        switch store.sub {
        case .pomodoro, .timer:
            switch key {
            case Code.space:
                if let current = store.countdown {
                    if current.finishedAt != nil { store.reset() } else if current.endAt != nil { store.pause() } else { store.resume() }
                } else {
                    let focus = store.sub == .pomodoro
                    store.start(seconds: focus ? 25 * 60 : 5 * 60, label: focus ? "Фокус" : "Таймер")
                }
            case Code.r: store.reset()
            default: return false
            }
        case .stopwatch:
            switch key {
            case Code.space: store.swToggle()
            case Code.l: store.swLap()
            case Code.r: store.swReset()
            default: return false
            }
        case .clocks:
            return false
        }
        return true
    }

    // MARK: Разделы внутри вкладки

    private static func cycleSub(model: IslandModel, by step: Int) -> Bool {
        guard model.page == nil else { return false }
        switch model.tab {
        case .time: TimeStore.shared.sub = cycle(TimeSub.allCases, from: TimeStore.shared.sub, by: step)
        case .media: model.mediaSub = cycle(MediaSub.allCases, from: model.mediaSub, by: step)
        case .tools: model.toolsSub = cycle(ToolsSub.allCases, from: model.toolsSub, by: step)
        case .plans: model.plansHorizon = cycle(PlanHorizon.allCases, from: model.plansHorizon, by: step)
        case .dev:
            let subs = [DevSub.system] + IslandModule.allCases.filter { model.enabledModules.contains($0) }.map(DevSub.init)
            model.devSub = cycle(subs, from: model.devSub, by: step)
        default: return false
        }
        return true
    }

    private static func cycle<T: Equatable>(_ all: [T], from current: T, by step: Int) -> T {
        guard let index = all.firstIndex(of: current), !all.isEmpty else { return current }
        return all[(index + step + all.count) % all.count]
    }
}
