import SwiftUI

/// Важное событие, которое занимает правую таблетку и мигает: мало заряда, нужен ответ агенту, задача готова или не получилась.
struct CapsuleAlert: Equatable {
    enum Kind: Equatable { case needsAnswer, charging, batteryCritical, batteryLow, failed, done, lidOff }

    let kind: Kind
    let text: String
    let symbol: String
    let state: AgentState
    let blink: Bool

    /// Чем выше, тем раньше показывается, если событий несколько.
    var priority: Int {
        switch kind {
        case .needsAnswer: 100
        case .charging: 90
        case .failed: 80
        case .batteryCritical: 70
        case .batteryLow: 60
        case .lidOff: 55
        case .done: 50
        }
    }
}

struct BatteryReading: Equatable, Sendable {
    var percent: Int
    var onPower: Bool
}

enum AlertPolicy {
    /// Порог «мало»: на нём таблетка мигает несколько секунд. Ниже критического порога мигает, пока Mac не поставят на зарядку.
    static let lowPercent = 20
    static let criticalPercent = 10

    /// Что происходит между двумя показаниями батареи. nil в `previous`: первое показание.
    static func batteryAlerts(previous: BatteryReading?, current: BatteryReading) -> (transient: [(CapsuleAlert, TimeInterval)], persistent: CapsuleAlert?) {
        var transient: [(CapsuleAlert, TimeInterval)] = []
        if let previous, !previous.onPower, current.onPower {
            transient.append((CapsuleAlert(kind: .charging, text: "\(current.percent)% · заряжается", symbol: "bolt.fill", state: .done, blink: false), 3))
        }
        var persistent: CapsuleAlert?
        if !current.onPower {
            if current.percent <= criticalPercent {
                persistent = CapsuleAlert(kind: .batteryCritical, text: "Заряд \(current.percent)%", symbol: "battery.0percent", state: .error, blink: true)
            } else if current.percent <= lowPercent, previous.map({ $0.onPower || $0.percent > lowPercent }) ?? true {
                transient.append((CapsuleAlert(kind: .batteryLow, text: "Заряд \(current.percent)%", symbol: "battery.25percent", state: .waiting, blink: true), 8))
            }
        }
        return (transient, persistent)
    }

    static func pick(_ candidates: [CapsuleAlert]) -> CapsuleAlert? { candidates.max { $0.priority < $1.priority } }
}

@MainActor @Observable
final class AlertCenter {
    static let shared = AlertCenter()

    private(set) var current: CapsuleAlert?

    @ObservationIgnored private var transient: [(alert: CapsuleAlert, until: Date)] = []
    @ObservationIgnored private var batteryPersistent: CapsuleAlert?
    @ObservationIgnored private var lastBattery: BatteryReading?
    @ObservationIgnored private var lastStates: [String: SessionState] = [:]

    /// Режим «не засыпать» выключился сам: время вышло или упал заряд. Mac теперь засыпает при закрытии крышки.
    func lidModeEnded(because text: String) {
        flash(CapsuleAlert(kind: .lidOff, text: text, symbol: "laptopcomputer", state: .waiting, blink: true), seconds: 10)
    }

    func flash(_ alert: CapsuleAlert, seconds: TimeInterval) {
        transient.removeAll { $0.alert.kind == alert.kind }
        transient.append((alert, Date().addingTimeInterval(seconds)))
    }

    /// Раз в секунду: сверяет батарею и агентов и выбирает, что показывать.
    func evaluate(battery: BatteryReading? = nil, now: Date = Date()) {
        let reading = battery ?? SystemMonitor.battery().map { BatteryReading(percent: $0.percent, onPower: $0.onPower) }
        if let reading, reading != lastBattery {
            let result = AlertPolicy.batteryAlerts(previous: lastBattery, current: reading)
            result.transient.forEach { flash($0.0, seconds: $0.1) }
            batteryPersistent = result.persistent
            lastBattery = reading
        }
        trackAgents()
        transient.removeAll { $0.until <= now }
        var candidates = transient.map(\.alert)
        if let batteryPersistent { candidates.append(batteryPersistent) }
        if let permission = AgentCenter.shared.permissions.first {
            candidates.append(CapsuleAlert(kind: .needsAnswer, text: "Нужен ответ · \(permission.agent.name)", symbol: "hand.raised.fill", state: .waiting, blink: true))
        }
        let picked = AlertPolicy.pick(candidates)
        if picked != current { current = picked }
    }

    /// Агент закончил или упал: короткое сообщение. Первое появление сессии событием не считается.
    private func trackAgents() {
        for (key, session) in AgentCenter.shared.sessions {
            defer { lastStates[key] = session.state }
            guard let before = lastStates[key], before != session.state else { continue }
            let name = session.agent.name
            if session.state == .error {
                flash(CapsuleAlert(kind: .failed, text: "Не вышло · \(name)", symbol: "exclamationmark.triangle.fill", state: .error, blink: true), seconds: 10)
            } else if session.state == .done, before == .working {
                flash(CapsuleAlert(kind: .done, text: "Готово · \(name)", symbol: "checkmark.circle.fill", state: .done, blink: true), seconds: 6)
            }
        }
        lastStates = lastStates.filter { AgentCenter.shared.sessions[$0.key] != nil }
    }
}

/// Мигающая таблетка важного события.
struct AlertCapsule: View {
    let alert: CapsuleAlert

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = !alert.blink || Int(context.date.timeIntervalSinceReferenceDate / 0.5) % 2 == 0
            let tint = alert.state.color
            HStack(spacing: 6) {
                Image(systemName: alert.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                Text(alert.text)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 104, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(tint.opacity(on ? 0.32 : 0.10), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(on ? 0.9 : 0.35)))
            .animation(.easeInOut(duration: 0.35), value: on)
        }
    }
}
