import Foundation
import Observation
import SwiftUI

enum AgentKind: String, CaseIterable, Sendable {
    case claude, codex, gemini, qwen, custom

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .qwen: "Qwen Code"
        case .custom: "Другой агент"
        }
    }

    var color: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.56, blue: 0.42)
        case .codex: Color(red: 0.50, green: 0.82, blue: 0.76)
        case .gemini: Color(red: 0.55, green: 0.65, blue: 0.98)
        case .qwen: Color(red: 0.72, green: 0.55, blue: 0.95)
        case .custom: Color(white: 0.7)
        }
    }

    /// Названия событий у разных агентов приводятся к общим: Gemini CLI зовёт их BeforeTool, AfterTool, BeforeAgent, AfterAgent.
    static func canonicalEvent(_ name: String) -> String {
        switch name {
        case "BeforeTool": "PreToolUse"
        case "AfterTool": "PostToolUse"
        case "BeforeAgent": "UserPromptSubmit"
        case "AfterAgent": "Stop"
        default: name
        }
    }
}

enum SessionState {
    case working, waiting, done, error

    var agentState: AgentState {
        switch self {
        case .working: .working
        case .waiting: .waiting
        case .done: .done
        case .error: .error
        }
    }

    var title: String {
        switch self {
        case .working: "работает"
        case .waiting: "ждёт вас"
        case .done: "готово"
        case .error: "ошибка"
        }
    }
}

struct AgentSession: Identifiable {
    let id: String
    let agent: AgentKind
    var cwd: String
    var state: SessionState
    var tool: String?
    var updated: Date
    var workingSince: Date?
    /// Название сессии, которое дал ей Claude Code. Известно только у найденных по файлам.
    var name: String?
    /// Найдена по файлу процесса, а не по событиям хуков. Событие хука делает сессию «своей» и снимает отметку.
    var discovered = false

    var project: String {
        if let name, !name.isEmpty { return name }
        let folder = (cwd as NSString).lastPathComponent
        return folder.isEmpty ? "сессия" : folder
    }
}

struct AgentPermission: Identifiable {
    let id = UUID()
    let sessionKey: String
    let agent: AgentKind
    let tool: String
    let summary: String
    /// Правила, которые агент предлагает запомнить при «Всегда».
    let suggestions: Data?
    let reply: HookReply
}

enum PermissionDecision {
    case allow, always, deny
}

struct AgentSummary {
    var agent: AgentKind
    var state: AgentState
}

/// Всё, что приложение знает об агентах: сессии, их состояния и ждущие запросы прав.
/// Ничего не разрешается само: ответ уходит агенту только после явного нажатия кнопки.
@MainActor @Observable
final class AgentCenter {
    static let shared = AgentCenter()

    private(set) var sessions: [String: AgentSession] = [:]
    private(set) var permissions: [AgentPermission] = []
    private(set) var installed: [AgentTarget: Bool] = [:]
    /// Подключена ли строка состояния Claude Code, из которой берутся лимиты.
    private(set) var limitsInstalled = false
    private(set) var usage: [AgentKind: PlanUsage] = [:]

    /// Остров раскрывается, когда агент ждёт ответа на запрос прав.
    @ObservationIgnored var onNeedsAnswer: (() -> Void)?
    @ObservationIgnored private var pruneTimer: Timer?
    @ObservationIgnored private var scanTimer: Timer?
    @ObservationIgnored private var codexTimer: Timer?

    private static let maxPending = 5
    private static let answerTimeout: Duration = .seconds(110)

    private init() {}

    // MARK: Сводка для острова

    /// «Готово» и «ошибка» горят две минуты и гаснут. «Работает» и «ждёт вас» горят, пока так и есть.
    private static let doneLifetime: TimeInterval = 120

    /// Меняется, когда у какого-то состояния вышел срок. Через него видам сообщается, что пора перечитать сводку.
    private(set) var tick = 0

    private func isLit(_ session: AgentSession) -> Bool {
        switch session.state {
        case .working, .waiting: true
        case .done, .error: Date().timeIntervalSince(session.updated) < Self.doneLifetime
        }
    }

    /// Сессии, которые ещё должны гореть на острове, свежие сверху.
    var litSessions: [AgentSession] {
        _ = tick
        return sessions.values.filter(isLit).sorted { $0.updated > $1.updated }
    }

    private func scheduleExpiry() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.doneLifetime + 1))
            self?.tick += 1
        }
    }

    var summary: AgentSummary {
        if let permission = permissions.first { return AgentSummary(agent: permission.agent, state: .waiting) }
        let all = litSessions
        let pick = all.first { $0.state == .waiting } ?? all.first { $0.state == .working } ?? all.first
        guard let pick else { return AgentSummary(agent: .claude, state: .idle) }
        return AgentSummary(agent: pick.agent, state: pick.state.agentState)
    }

    var orderedSessions: [AgentSession] {
        sessions.values.sorted { $0.updated > $1.updated }
    }

    /// Сессия, о которой говорит правая таблетка острова.
    var focusSession: AgentSession? {
        let lit = litSessions
        return lit.first { $0.state == .waiting }
            ?? lit.first { $0.state == .working }
            ?? lit.first
    }

    // MARK: Запуск

    func start() {
        refreshInstalled()
        // Последние лимиты Claude помнятся между запусками: строка состояния обновляет их, только пока агент работает.
        if let data = UserDefaults.standard.data(forKey: Self.usageKey),
           let saved = try? JSONDecoder().decode(PlanUsage.self, from: data) {
            usage[.claude] = saved
        }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
        rescanSessions()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rescanSessions() }
        }
        refreshCodexLimits()
        codexTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCodexLimits() }
        }
    }

    func refreshInstalled() {
        for target in AgentTarget.allCases { installed[target] = AgentInstaller.isInstalled(target) }
        limitsInstalled = AgentInstaller.isInstalled(.claude, feature: .limits)
    }

    private static let usageKey = "plan.usage.claude"

    /// Лимиты Codex спрашиваются у самого Codex, если он установлен.
    private func refreshCodexLimits() {
        Task {
            guard let fetched = await CodexLimits.fetch() else { return }
            setUsage(.codex, fetched)
        }
    }

    func setUsage(_ agent: AgentKind, _ value: PlanUsage) {
        usage[agent] = value
        if agent == .claude, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.usageKey)
        }
    }

    /// Агенты, по которым есть лимиты, в порядке показа.
    var usageAgents: [AgentKind] {
        AgentKind.allCases.filter { usage[$0]?.dominantPct() != nil }
    }

    /// Сессии без вестей полчаса убираются: терминал могли закрыть без SessionEnd.
    /// Найденные по файлам сюда не входят: их убирает `rescanSessions`, когда процесс исчез.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        for (key, session) in sessions where session.updated < cutoff && session.state != .waiting && !session.discovered {
            sessions.removeValue(forKey: key)
        }
    }

    /// Подхватывает живые сессии Claude Code по файлам процессов: так они видны и после перезапуска Visor,
    /// и когда в сессии давно не было событий. Событий хуков это не заменяет и звуков не играет.
    func rescanSessions(_ entries: [ClaudeSessionEntry]? = nil) {
        let found = entries ?? ClaudeSessionFiles.scan()
        var seen = Set<String>()
        for entry in found {
            let key = "claude:\(entry.sessionID)"
            seen.insert(key)
            if let existing = sessions[key], !existing.discovered {
                if existing.name == nil, !entry.name.isEmpty { sessions[key]?.name = entry.name }
                continue
            }
            var session = sessions[key] ?? AgentSession(id: key, agent: .claude, cwd: entry.cwd, state: .done, tool: nil,
                                                       updated: entry.updated, workingSince: nil)
            session.cwd = entry.cwd
            session.name = entry.name.isEmpty ? nil : entry.name
            session.discovered = true
            let state: SessionState = entry.status == "busy" ? .working : .done
            if session.state != state || sessions[key] == nil {
                session.state = state
                session.updated = entry.updated
                session.workingSince = state == .working ? entry.updated : nil
            }
            sessions[key] = session
        }
        for (key, session) in sessions where session.discovered && !seen.contains(key) {
            sessions.removeValue(forKey: key)
        }
        tick += 1
    }

    // MARK: События

    func handle(_ request: HookRequest) {
        // Строка состояния Claude Code присылает лимиты плана, это не событие сессии.
        if request.agent == "claude-status" {
            if let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
               let parsed = PlanParser.claude(payload: object) {
                setUsage(.claude, parsed)
            }
            request.reply.send(nil)
            return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            request.reply.send(nil)
            return
        }
        let agent = AgentKind(rawValue: request.agent) ?? .claude
        let event = AgentKind.canonicalEvent(object["hook_event_name"] as? String ?? "")
        let sessionID = object["session_id"] as? String ?? "default"
        let key = "\(agent.rawValue):\(sessionID)"
        let tool = object["tool_name"] as? String ?? ""
        let input = object["tool_input"] as? [String: Any] ?? [:]
        let now = Date()

        var session = sessions[key] ?? AgentSession(
            id: key, agent: agent, cwd: object["cwd"] as? String ?? "", state: .done, tool: nil, updated: now, workingSince: nil
        )
        if let cwd = object["cwd"] as? String, !cwd.isEmpty { session.cwd = cwd }
        session.discovered = false // события хуков точнее файлов процесса
        session.updated = now
        let before = session.state

        switch event {
        case "SessionStart":
            session.state = .done
        case "UserPromptSubmit":
            session.state = .working
            session.workingSince = now
            session.tool = nil
            dropPermissions(for: key)
        case "PreToolUse":
            if !hasPermission(for: key) {
                session.state = .working
                if session.workingSince == nil { session.workingSince = now }
            }
            session.tool = Self.describe(tool: tool, input: input)
        case "PostToolUse":
            // Ответили в терминале или разрешили заранее: карточка в острове больше не нужна.
            dropPermissions(for: key, tool: tool)
            if !hasPermission(for: key) { session.state = .working }
        case "PermissionRequest":
            session.state = .waiting
            sessions[key] = session
            handlePermission(object: object, key: key, agent: agent, tool: tool, input: input, request: request)
            if before != .waiting { SoundEngine.shared.play(.approval) }
            return
        case "Notification":
            let type = object["notification_type"] as? String ?? ""
            let message = (object["message"] as? String ?? "").lowercased()
            if type != "idle_prompt", !message.contains("waiting for your input") {
                session.state = .waiting
                if before != .waiting { SoundEngine.shared.play(.approval) }
            }
        case "Stop":
            session.state = .done
            session.workingSince = nil
            session.tool = nil
            dropPermissions(for: key)
            if before == .working || before == .waiting { SoundEngine.shared.play(.finish) }
        case "StopFailure":
            session.state = .error
            session.workingSince = nil
            dropPermissions(for: key)
            SoundEngine.shared.play(.error)
        case "Interrupt":
            session.state = .done
            session.workingSince = nil
            dropPermissions(for: key)
        case "SessionEnd":
            dropPermissions(for: key)
            sessions.removeValue(forKey: key)
            request.reply.send(nil)
            return
        default:
            break
        }
        sessions[key] = session
        if session.state == .done || session.state == .error { scheduleExpiry() }
        request.reply.send(nil)
    }

    /// Для проверок: состаривает сессию, будто с её последнего события прошло `seconds`.
    func backdateForSnapshot(_ key: String, by seconds: TimeInterval) {
        sessions[key]?.updated = Date().addingTimeInterval(-seconds)
        tick += 1
    }

    // MARK: Запросы прав

    private func handlePermission(object: [String: Any], key: String, agent: AgentKind, tool: String,
                                  input: [String: Any], request: HookRequest) {
        // Вопросы агента и план отвечаются только в терминале, остров лишь сообщает, что агент ждёт.
        let terminalOnly = tool == "AskUserQuestion" || tool == "ExitPlanMode"
        guard !terminalOnly, permissions.count < Self.maxPending else {
            request.reply.send(nil)
            return
        }
        var suggestions: Data?
        if let list = object["permission_suggestions"], JSONSerialization.isValidJSONObject(list) {
            suggestions = try? JSONSerialization.data(withJSONObject: list)
        }
        let permission = AgentPermission(
            sessionKey: key, agent: agent, tool: tool, summary: Self.describe(tool: tool, input: input),
            suggestions: suggestions, reply: request.reply
        )
        permissions.append(permission)
        onNeedsAnswer?()

        let id = permission.id
        Task { [weak self] in
            try? await Task.sleep(for: Self.answerTimeout)
            self?.expire(id)
        }
    }

    func decide(_ id: UUID, _ decision: PermissionDecision) {
        guard let index = permissions.firstIndex(where: { $0.id == id }) else { return }
        let permission = permissions.remove(at: index)
        permission.reply.send(Self.hookOutput(for: permission, decision: decision))
        if var session = sessions[permission.sessionKey] {
            session.state = .working
            session.updated = Date()
            sessions[permission.sessionKey] = session
        }
    }

    /// Не дождались ответа: агент сам спросит в терминале.
    private func expire(_ id: UUID) {
        guard let index = permissions.firstIndex(where: { $0.id == id }) else { return }
        permissions.remove(at: index).reply.send(nil)
    }

    private func hasPermission(for key: String) -> Bool {
        permissions.contains { $0.sessionKey == key }
    }

    private func dropPermissions(for key: String, tool: String? = nil) {
        let gone = permissions.filter { $0.sessionKey == key && (tool == nil || $0.tool == tool) }
        guard !gone.isEmpty else { return }
        permissions.removeAll { permission in gone.contains { $0.id == permission.id } }
        gone.forEach { $0.reply.send(nil) }
    }

    /// Ответ в формате хука PermissionRequest: его понимают и Claude Code, и Codex.
    nonisolated static func hookOutput(for permission: AgentPermission, decision: PermissionDecision) -> String? {
        var verdict: [String: Any]
        switch decision {
        case .allow:
            verdict = ["behavior": "allow"]
        case .always:
            verdict = ["behavior": "allow"]
            if permission.agent == .claude, let data = permission.suggestions,
               let rules = try? JSONSerialization.jsonObject(with: data) {
                verdict["updatedPermissions"] = rules
            }
        case .deny:
            verdict = ["behavior": "deny", "message": "Отклонено в Visor"]
        }
        let root: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": verdict]]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Описание инструмента

    nonisolated static func describe(tool: String, input: [String: Any]) -> String {
        if let command = input["command"] as? String { return "\(tool) · \(oneLine(command))" }
        if let path = (input["file_path"] as? String) ?? (input["path"] as? String) {
            return "\(tool) · \((path as NSString).lastPathComponent)"
        }
        if let query = input["query"] as? String { return "\(tool) · \(oneLine(query))" }
        return tool.isEmpty ? "—" : tool
    }

    private nonisolated static func oneLine(_ text: String, limit: Int = 70) -> String {
        let flat = text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    // MARK: Для снимков и проверок

    func clearForSnapshot() {
        sessions = [:]
        permissions = []
        usage = [:]
    }

    /// Заполняет центр примерами. Нужен только режиму `--snapshot`.
    func seedForSnapshot() {
        let now = Date()
        sessions = [
            "claude:a": AgentSession(id: "claude:a", agent: .claude, cwd: "/Users/demo/Visor", state: .working,
                                     tool: "Edit · IslandView.swift", updated: now, workingSince: now.addingTimeInterval(-84)),
            "codex:b": AgentSession(id: "codex:b", agent: .codex, cwd: "/Users/demo/demo-site", state: .done,
                                    tool: nil, updated: now.addingTimeInterval(-300), workingSince: nil),
        ]
        permissions = [
            AgentPermission(sessionKey: "claude:a", agent: .claude, tool: "Bash", summary: "Bash · npm run build",
                            suggestions: nil, reply: HookReply(fd: -1)),
        ]
        usage = [
            .claude: PlanUsage(fiveHour: PlanWindow(usedPct: 42, resetsAt: now.addingTimeInterval(2 * 3600 + 10 * 60)),
                               sevenDay: PlanWindow(usedPct: 18, resetsAt: now.addingTimeInterval(4 * 86400 + 3 * 3600)),
                               updated: now),
            .codex: PlanUsage(fiveHour: PlanWindow(usedPct: 12, resetsAt: now.addingTimeInterval(3600)),
                              sevenDay: PlanWindow(usedPct: 86, resetsAt: now.addingTimeInterval(2 * 86400)),
                              updated: now),
        ]
    }
}
