import SwiftUI

/// Кнопка в стиле острова.
struct VisorButtonStyle: ButtonStyle {
    enum Kind { case normal, primary, danger }
    var kind: Kind = .normal
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .frame(height: 28)
            .background(background(pressed: configuration.isPressed), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .normal: Palette.text
        case .primary: .black
        case .danger: AgentState.error.color
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: Palette.accent.opacity(pressed ? 0.8 : 1)
        case .normal: Color.white.opacity(pressed ? 0.26 : 0.16)
        case .danger: AgentState.error.color.opacity(pressed ? 0.34 : 0.22)
        }
    }
}

/// Вкладка «Агенты»: запросы прав, сессии и подключение.
struct AgentsPage: View {
    let model: IslandModel

    var body: some View {
        let center = AgentCenter.shared
        HStack(alignment: .top, spacing: 12) {
            VScroll {
                VStack(spacing: 8) {
                    if let permission = center.permissions.first {
                        PermissionCard(permission: permission, more: center.permissions.count - 1)
                    }
                    if center.orderedSessions.isEmpty {
                        EmptyAgents(model: model)
                    } else {
                        ForEach(center.orderedSessions) { SessionRow(session: $0) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            VScroll {
                VStack(spacing: 10) {
                    ConnectionCard(model: model)
                    LimitsCard(model: model)
                }
            }
            .frame(width: 250)
        }
    }
}

struct PermissionCard: View {
    let permission: AgentPermission
    let more: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(AgentState.waiting.color).frame(width: 9, height: 9)
                Text("\(permission.agent.name) просит разрешение").font(.system(size: 13, weight: .semibold))
                Spacer()
                if more > 0 { Text("ещё \(more)").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            }
            Text(permission.summary)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(white: 0.85))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button("Запретить") { AgentCenter.shared.decide(permission.id, .deny) }
                    .buttonStyle(VisorButtonStyle(kind: .danger))
                Button("Разрешить") { AgentCenter.shared.decide(permission.id, .allow) }
                    .buttonStyle(VisorButtonStyle(kind: .primary))
                if permission.agent == .claude {
                    Button("Всегда") { AgentCenter.shared.decide(permission.id, .always) }
                        .buttonStyle(VisorButtonStyle())
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(AgentState.waiting.color.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AgentState.waiting.color.opacity(0.45)))
    }
}

struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(session.state.agentState.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(session.agent.name).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .listRow()
    }

    private var detail: String {
        if session.state == .working, let tool = session.tool { return tool }
        return session.state.title
    }
}

struct EmptyAgents: View {
    let model: IslandModel

    var body: some View {
        let connected = AgentTarget.allCases.contains { AgentCenter.shared.installed[$0] == true }
        VStack(spacing: 8) {
            Text("Нет активных сессий").font(.system(size: 13, weight: .medium))
            Text(connected
                 ? "Запустите агента в терминале: он появится здесь."
                 : "Подключите агента (Claude Code, Codex, Gemini CLI и другие), и его сессии появятся здесь.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
            if !connected {
                Button("Подключить агентов") { model.openSettings(.agents) }
                    .buttonStyle(VisorButtonStyle(kind: .primary))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
    }
}

enum PlanStyle {
    static func color(_ pct: Double) -> Color {
        pct >= 90 ? AgentState.error.color : pct >= 70 ? AgentState.waiting.color : Palette.accent
    }

    static func reset(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "уже сброшено" }
        let days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return "сброс через \(days) д \(hours) ч" }
        if hours > 0 { return "сброс через \(hours) ч \(minutes) мин" }
        return "сброс через \(max(minutes, 1)) мин"
    }
}

/// Лимиты плана: окно 5 часов и неделя, по каждому агенту, у которого они известны.
struct LimitsCard: View {
    let model: IslandModel

    var body: some View {
        let center = AgentCenter.shared
        VStack(alignment: .leading, spacing: 10) {
            Text("Лимиты плана")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.muted)
            if center.usageAgents.isEmpty {
                Text(center.limitsInstalled
                     ? "Появятся после ближайшего ответа Claude Code."
                     : "Подключите лимиты Claude Code в настройках.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                if !center.limitsInstalled {
                    Button("Настроить") { model.openSettings(.agents) }.buttonStyle(VisorButtonStyle())
                }
            } else {
                ForEach(center.usageAgents, id: \.self) { agent in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle().fill(agent.color).frame(width: 7, height: 7)
                            Text(agent.name).font(.system(size: 12, weight: .medium))
                        }
                        if let window = center.usage[agent]?.fiveHour { LimitRow(title: "5 часов", window: window) }
                        if let window = center.usage[agent]?.sevenDay { LimitRow(title: "Неделя", window: window) }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatSection()
    }
}

struct LimitRow: View {
    let title: String
    let window: PlanWindow

    var body: some View {
        let pct = window.effectivePct()
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11.5))
                Spacer()
                Text("\(Int(pct.rounded())) %").font(.system(size: 11.5, design: .rounded).monospacedDigit())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16))
                    Capsule().fill(PlanStyle.color(pct)).frame(width: max(4, proxy.size.width * pct / 100))
                }
            }
            .frame(height: 5)
            Text(PlanStyle.reset(window.resetsAt)).font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
    }
}

struct ConnectionCard: View {
    let model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Подключение")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.muted)
            ForEach(AgentPins.shared.pinned) { target in
                let on = AgentCenter.shared.installed[target] == true
                HStack(spacing: 8) {
                    Circle().fill(on ? AgentState.done.color : Color(white: 0.3)).frame(width: 8, height: 8)
                    Text(target.title).font(.system(size: 13))
                    Spacer()
                    Text(on ? "хуки установлены" : "не подключён")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
            }
            Button("Все агенты") { model.openSettings(.agents) }
                .buttonStyle(VisorButtonStyle())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatSection()
    }
}
