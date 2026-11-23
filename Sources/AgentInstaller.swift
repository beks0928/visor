import Foundation

/// Чтение и запись чужого файла настроек (settings.json, hooks.json). Правила те же, что у Coucou:
/// непонятный файл не считается пустым, перед записью всегда датированная копия,
/// записывается только то, что человеку показали, и только если файл с тех пор не менялся.
enum SafeJSONFile {
    enum Failure: LocalizedError {
        case unreadable(String), invalid(String), changed(String), backupFailed(String), writeFailed(String), unexpected(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let n): "Файл \(n) не читается. Visor его не трогал."
            case .invalid(let n): "Файл \(n) не является корректным JSON. Visor его не трогал."
            case .changed(let n): "Файл \(n) изменился после показа. Ничего не записано: посмотрите изменения ещё раз."
            case .backupFailed(let n): "Не удалось сделать копию \(n). Ничего не записано."
            case .writeFailed(let n): "Не удалось записать \(n). Оригинал не тронут."
            case .unexpected(let n): "В \(n) раздел hooks имеет неожиданный вид. Visor его не трогал."
            }
        }
    }

    /// Объект и байты, из которых он прочитан. Нет файла: пустой объект и nil.
    static func read(at url: URL) throws -> (object: [String: Any], bytes: Data?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([:], nil) }
        let name = url.lastPathComponent
        guard let bytes = try? Data(contentsOf: url) else { throw Failure.unreadable(name) }
        if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) { return ([:], bytes) }
        guard let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { throw Failure.invalid(name) }
        return (object, bytes)
    }

    /// Возвращает адрес копии, либо nil, если файла ещё не было.
    @discardableResult
    static func write(_ data: Data, to url: URL, expecting original: Data?) throws -> URL? {
        let fm = FileManager.default
        let name = url.lastPathComponent
        let exists = fm.fileExists(atPath: url.path)

        var current: Data?
        if exists {
            guard let bytes = try? Data(contentsOf: url) else { throw Failure.unreadable(name) }
            current = bytes
        }
        guard current == original else { throw Failure.changed(name) }

        // Если settings.json это ссылка (dotfiles), пишем в сам файл, чтобы ссылка осталась.
        let target = url.resolvingSymlinksInPath()
        var backup: URL?
        var mode = 0o600 // в settings.json бывают ключи: новый файл только для владельца
        if exists {
            let copy = freeBackupURL(for: url)
            do { try fm.copyItem(at: target, to: copy) } catch { throw Failure.backupFailed(name) }
            backup = copy
            if let found = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber {
                mode = found.intValue & 0o777
            }
        } else {
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        // Пишем рядом и переименовываем: сбой посреди записи не оставит половину файла.
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent("\(target.lastPathComponent).visor-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: temp)
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw Failure.writeFailed(name)
        }
        do { try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: temp.path) } catch {
            try? fm.removeItem(at: temp)
            throw Failure.writeFailed(name)
        }
        guard rename(temp.path, target.path) == 0 else {
            try? fm.removeItem(at: temp)
            throw Failure.writeFailed(name)
        }
        return backup
    }

    private static func freeBackupURL(for url: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(url.lastPathComponent).bak-\(formatter.string(from: Date()))"
        let dir = url.deletingLastPathComponent()
        var candidate = dir.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        return candidate
    }
}

struct HookEvent {
    let name: String
    /// Для событий инструментов у Gemini CLI нужен шаблон: «*» значит любой инструмент.
    var matcher: String? = nil
    /// Тайм-аут хука для агента, секунды.
    let timeout: Int
    /// Сколько секунд ретранслятор ждёт ответа приложения.
    let wait: Int
    let status: String?
}

enum AgentTarget: String, CaseIterable, Identifiable, Hashable, Sendable {
    case claude, codex, gemini, qwen

    var id: String { rawValue }

    var kind: AgentKind {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .gemini: .gemini
        case .qwen: .qwen
        }
    }

    var title: String { kind.name }

    private var relativePath: String {
        switch self {
        case .claude: ".claude/settings.json"
        case .codex: ".codex/hooks.json"
        case .gemini: ".gemini/settings.json"
        case .qwen: ".qwen/settings.json"
        }
    }

    var displayPath: String { "~/" + relativePath }

    var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relativePath) }

    /// Gemini CLI считает тайм-аут хука в миллисекундах, остальные в секундах.
    var timeoutScale: Int { self == .gemini ? 1000 : 1 }

    /// Показываются во вкладке «Агенты», пока вы не выбрали другие в настройках.
    static let defaultPinned: [AgentTarget] = [.claude, .codex, .gemini]

    var events: [HookEvent] {
        switch self {
        case .gemini:
            [HookEvent(name: "SessionStart", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "SessionEnd", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "BeforeAgent", matcher: nil, timeout: 10, wait: 3, status: nil),
             HookEvent(name: "BeforeTool", matcher: "*", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "AfterTool", matcher: "*", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "Notification", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "AfterAgent", matcher: nil, timeout: 10, wait: 3, status: nil)]
        case .qwen:
            [HookEvent(name: "SessionStart", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "SessionEnd", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "UserPromptSubmit", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "PreToolUse", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "PostToolUse", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "Notification", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "Stop", timeout: 10, wait: 3, status: nil)]
        case .claude:
            [HookEvent(name: "SessionStart", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "SessionEnd", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "UserPromptSubmit", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "PreToolUse", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "PostToolUse", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "PermissionRequest", timeout: 120, wait: 118, status: nil),
             HookEvent(name: "Notification", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "Stop", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "StopFailure", timeout: 10, wait: 3, status: nil)]
        case .codex:
            [HookEvent(name: "SessionStart", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "UserPromptSubmit", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "PreToolUse", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "PermissionRequest", timeout: 120, wait: 118, status: "Ждёт ответа в Visor"),
             HookEvent(name: "PostToolUse", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "Stop", timeout: 10, wait: 3, status: nil),
             HookEvent(name: "Interrupt", timeout: 3, wait: 2, status: nil),
             HookEvent(name: "SessionEnd", timeout: 3, wait: 2, status: nil)]
        }
    }
}

struct DiffLine: Identifiable {
    enum Kind { case added, removed }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// Что подключается к агенту: хуки событий или строка состояния для лимитов плана.
enum InstallFeature {
    case hooks, limits
}

struct InstallPlan {
    let target: AgentTarget
    let install: Bool
    let original: Data?
    let after: Data
    let diff: [DiffLine]
    var feature: InstallFeature = .hooks
    /// Прежняя строка состояния пользователя: Visor запоминает её и продолжает печатать её вывод.
    var previousStatusLine: String?
    var restoresPrevious = false
    var isNoop: Bool { diff.isEmpty }
    var hasBackup: Bool { original != nil }
}

enum AgentInstaller {
    /// Признак нашей записи: путь к нашему ретранслятору (visor-hook или visor-statusline).
    private static let marker = "/Visor/bin/visor-"

    private static func isOurs(_ command: Any?) -> Bool {
        (command as? String)?.contains(marker) == true
    }

    static func isInstalled(_ target: AgentTarget, feature: InstallFeature = .hooks) -> Bool {
        guard let object = try? SafeJSONFile.read(at: target.url).object else { return false }
        if feature == .limits {
            return isOurs((object["statusLine"] as? [String: Any])?["command"])
        }
        guard let hooks = object["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]])?.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains { isOurs($0["command"]) } == true
            } == true
        }
    }

    /// Только наши записи: чужие хуки (в том числе Coucou) остаются нетронутыми.
    private static func removingOurs(from groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            guard var inner = group["hooks"] as? [[String: Any]] else { return group }
            let before = inner.count
            inner.removeAll { isOurs($0["command"]) }
            if inner.count == before { return group }
            if inner.isEmpty { return nil }
            var copy = group
            copy["hooks"] = inner
            return copy
        }
    }

    private static func serialize(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Считает, что изменится, ничего не записывая.
    static func plan(_ target: AgentTarget, install: Bool, feature: InstallFeature = .hooks) throws -> InstallPlan {
        let snapshot = try SafeJSONFile.read(at: target.url)
        if feature == .limits { return try limitsPlan(target, install: install, snapshot: snapshot) }
        var root = snapshot.object
        let name = target.url.lastPathComponent

        var hooks: [String: Any] = [:]
        if let raw = root["hooks"] {
            guard let object = raw as? [String: Any] else { throw SafeJSONFile.Failure.unexpected(name) }
            hooks = object
        }

        if install {
            let relay = VisorPaths.relayURL.path.replacingOccurrences(of: "\"", with: "\\\"")
            for event in target.events {
                var groups: [[String: Any]] = []
                if let raw = hooks[event.name] {
                    guard let existing = raw as? [[String: Any]] else { throw SafeJSONFile.Failure.unexpected(name) }
                    groups = removingOurs(from: existing)
                }
                var entry: [String: Any] = [
                    "type": "command",
                    "command": "/bin/sh \"\(relay)\" \(target.kind.rawValue) \(event.wait)",
                    "timeout": event.timeout * target.timeoutScale,
                ]
                if let status = event.status { entry["statusMessage"] = status }
                var group: [String: Any] = ["hooks": [entry]]
                if let matcher = event.matcher { group["matcher"] = matcher }
                groups.append(group)
                hooks[event.name] = groups
            }
        } else {
            for (key, raw) in hooks {
                guard let groups = raw as? [[String: Any]] else { continue }
                let cleaned = removingOurs(from: groups)
                if cleaned.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = cleaned }
            }
        }

        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        let after = try serialize(root)
        // Сравниваем с тем же файлом, прочитанным и записанным тем же способом: видны только настоящие правки.
        let normalizedBefore = try serialize(snapshot.object)
        return InstallPlan(target: target, install: install, original: snapshot.bytes, after: after,
                           diff: diffLines(old: normalizedBefore, new: after))
    }

    /// Строка состояния для лимитов. Если у пользователя уже была своя, она запоминается и продолжает работать.
    private static func limitsPlan(_ target: AgentTarget, install: Bool,
                                   snapshot: (object: [String: Any], bytes: Data?)) throws -> InstallPlan {
        var root = snapshot.object
        let name = target.url.lastPathComponent
        let relay = VisorPaths.statusRelayURL.path.replacingOccurrences(of: "\"", with: "\\\"")
        let ours = "/bin/sh \"\(relay)\""
        var previous: String?
        var restores = false
        let existing = root["statusLine"]

        if install {
            var entry: [String: Any] = ["type": "command", "command": ours]
            if let existing {
                guard let dict = existing as? [String: Any] else { throw SafeJSONFile.Failure.unexpected(name) }
                if isOurs(dict["command"]) {
                    entry = dict
                } else {
                    guard dict["type"] as? String == "command", let command = dict["command"] as? String else {
                        throw SafeJSONFile.Failure.unexpected(name)
                    }
                    previous = command
                    for (key, value) in dict where key != "command" && key != "type" { entry[key] = value }
                }
            }
            root["statusLine"] = entry
        } else if let dict = existing as? [String: Any], isOurs(dict["command"]) {
            if let saved = try? String(contentsOf: VisorPaths.previousStatusLineURL, encoding: .utf8), !saved.isEmpty {
                root["statusLine"] = ["type": "command", "command": saved]
                restores = true
            } else {
                root.removeValue(forKey: "statusLine")
            }
        }

        let after = try serialize(root)
        let before = try serialize(snapshot.object)
        return InstallPlan(target: target, install: install, original: snapshot.bytes, after: after,
                           diff: diffLines(old: before, new: after), feature: .limits,
                           previousStatusLine: previous, restoresPrevious: restores)
    }

    /// Записывает рассчитанные правки. Возвращает адрес резервной копии.
    @discardableResult
    static func apply(_ plan: InstallPlan) throws -> URL? {
        let fm = FileManager.default
        let previousURL = VisorPaths.previousStatusLineURL
        var wrotePrevious = false
        if plan.feature == .limits, plan.install, let previous = plan.previousStatusLine {
            try? fm.createDirectory(at: VisorPaths.supportDir, withIntermediateDirectories: true)
            try previous.write(to: previousURL, atomically: true, encoding: .utf8)
            wrotePrevious = true
        }
        do {
            let backup = try SafeJSONFile.write(plan.after, to: plan.target.url, expecting: plan.original)
            if plan.feature == .limits, !plan.install { try? fm.removeItem(at: previousURL) }
            return backup
        } catch {
            if wrotePrevious { try? fm.removeItem(at: previousURL) }
            throw error
        }
    }

    private static func diffLines(old: Data, new: Data) -> [DiffLine] {
        let a = (String(data: old, encoding: .utf8) ?? "").components(separatedBy: "\n")
        let b = (String(data: new, encoding: .utf8) ?? "").components(separatedBy: "\n")
        var removed: [DiffLine] = []
        var added: [DiffLine] = []
        for change in b.difference(from: a) {
            switch change {
            case .remove(_, let line, _): removed.append(DiffLine(kind: .removed, text: line))
            case .insert(_, let line, _): added.append(DiffLine(kind: .added, text: line))
            }
        }
        return removed + added
    }
}
