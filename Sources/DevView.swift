import AppKit
import SwiftUI

enum DevSub: String, CaseIterable, Identifiable {
    case system, ports, github, vercel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Система"
        case .ports: "Порты"
        case .github: "GitHub"
        case .vercel: "Vercel"
        }
    }

    init(_ module: IslandModule) {
        switch module {
        case .ports: self = .ports
        case .github: self = .github
        case .vercel: self = .vercel
        }
    }
}

/// Вкладка Dev: система Mac всегда, порты, GitHub и Vercel только когда включены на странице «+».
struct DevPage: View {
    let model: IslandModel
    var monitor: SystemMonitor = .shared
    var services: DevServices = .shared
    private var sub: DevSub { model.devSub }

    init(model: IslandModel, monitor: SystemMonitor = .shared, services: DevServices = .shared, start: DevSub? = nil) {
        self.model = model
        self.monitor = monitor
        self.services = services
        if let start { model.devSub = start }
    }

    private var subs: [DevSub] {
        [.system] + IslandModule.allCases.filter { model.enabledModules.contains($0) }.map(DevSub.init)
    }

    var body: some View {
        let current = subs.contains(sub) ? sub : .system
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                ForEach(subs) { item in
                    Button { model.devSub = item } label: {
                        Text(item.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(current == item ? Palette.text : Palette.muted)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(current == item ? Palette.selected : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if subs.count == 1 {
                    Text("Порты, GitHub и Vercel включаются на странице «+»")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
            }
            switch current {
            case .system: SystemPanel(monitor: monitor)
            case .ports: PortsPanel(services: services)
            case .github: GitHubPanel(model: model, services: services)
            case .vercel: VercelPanel(model: model, services: services)
            }
        }
    }
}

// MARK: Общие части

struct DevCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
            content
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.cardBorder))
    }
}

struct MeterRow: View {
    let title: String
    let value: String
    let fraction: Double
    var color: Color = Palette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
                Text(value).font(.system(size: 12.5).monospacedDigit())
            }
            Capsule().fill(Color.white.opacity(0.16)).frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(color).frame(width: max(5, proxy.size.width * min(1, max(0, fraction))))
                    }
                }
        }
    }
}

enum DevFormat {
    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824).replacingOccurrences(of: ".", with: ",") + " ГБ"
    }

    static func duration(minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    static func load(_ fraction: Double) -> Color {
        fraction > 0.95 ? AgentState.error.color : fraction > 0.85 ? AgentState.waiting.color : Palette.accent
    }

    static func battery(_ percent: Int) -> Color {
        percent < 20 ? AgentState.error.color : percent < 40 ? AgentState.waiting.color : AgentState.done.color
    }
}

// MARK: Система

struct SystemPanel: View {
    let monitor: SystemMonitor

    var body: some View {
        let stats = monitor.snapshot
        let memory = stats.memoryTotal == 0 ? 0 : Double(stats.memoryUsed) / Double(stats.memoryTotal)
        HStack(alignment: .top, spacing: 12) {
            DevCard(title: "Mac") {
                MeterRow(title: "Процессор", value: "\(Int((stats.cpu * 100).rounded()))%", fraction: stats.cpu, color: DevFormat.load(stats.cpu))
                MeterRow(title: "Память", value: "\(DevFormat.gigabytes(stats.memoryUsed)) из \(DevFormat.gigabytes(stats.memoryTotal))",
                         fraction: memory, color: DevFormat.load(memory))
                if let percent = stats.batteryPercent {
                    MeterRow(title: "Батарея", value: batteryText(stats, percent: percent), fraction: Double(percent) / 100,
                             color: stats.onPower ? AgentState.done.color : DevFormat.battery(percent))
                }
                HStack {
                    Text("Нагрев").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Spacer()
                    Text(stats.thermal.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(thermalColor(stats.thermal))
                    if let temperature = stats.batteryTemperature {
                        Text("· аккумулятор \(Int(temperature.rounded())) °C").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                }
            }
            .frame(maxWidth: 270)
            DevCard(title: "Bluetooth") { bluetoothList }
            DevCard(title: "Что греет Mac") { hotList(stats) }
        }
        .task { await every(2) { monitor.sample() } }
        .task { await every(30) { await monitor.refreshBluetooth() } }
        .task { await every(4) { await monitor.refreshHot() } }
    }

    private func every(_ seconds: Double, _ work: () async -> Void) async {
        while !Task.isCancelled {
            await work()
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    private func batteryText(_ stats: SystemSnapshot, percent: Int) -> String {
        var text = "\(percent)%"
        if stats.isCharging {
            text += " · заряжается"
            if let minutes = stats.minutesRemaining { text += " · \(DevFormat.duration(minutes: minutes))" }
        } else if stats.onPower {
            text += " · от сети"
        } else {
            text += " · от батареи"
            if let minutes = stats.minutesRemaining { text += " · \(DevFormat.duration(minutes: minutes))" }
        }
        return text
    }

    private func thermalColor(_ level: ThermalLevel) -> Color {
        switch level {
        case .nominal: AgentState.done.color
        case .fair: AgentState.waiting.color
        case .serious, .critical: AgentState.error.color
        }
    }

    @ViewBuilder
    private var bluetoothList: some View {
        let connected = monitor.bluetooth.filter(\.connected)
        let remembered = monitor.bluetooth.filter { !$0.connected }
        if monitor.bluetooth.isEmpty {
            Text("Устройств с зарядом нет.").font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
        ForEach(connected.prefix(4)) { device in
            deviceRow(device, dimmed: false)
        }
        if !remembered.isEmpty {
            Text("Не подключены, последний заряд").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 2)
            ForEach(remembered.prefix(max(0, 5 - min(connected.count, 4)))) { device in
                deviceRow(device, dimmed: true)
            }
        }
    }

    private func deviceRow(_ device: BluetoothDevice, dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(device.name).font(.system(size: 12.5)).lineLimit(1).foregroundStyle(dimmed ? Palette.muted : Color.white)
            if device.batteries.isEmpty {
                Text("заряд не сообщается").font(.system(size: 11)).foregroundStyle(Palette.muted)
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(device.batteries.enumerated()), id: \.offset) { _, battery in
                        Text(battery.label == "Заряд" ? "\(battery.percent)%" : "\(battery.label) \(battery.percent)%")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(dimmed ? Palette.muted : DevFormat.battery(battery.percent))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func hotList(_ stats: SystemSnapshot) -> some View {
        if monitor.hot.isEmpty {
            Text("Считаю…").font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
        ForEach(monitor.hot.prefix(5)) { process in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(process.name).font(.system(size: 12.5)).lineLimit(1)
                    Spacer()
                    Text("\(Int(process.cpu.rounded()))%").font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.muted)
                }
                Capsule().fill(Color.white.opacity(0.16)).frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule().fill(DevFormat.load(process.cpu / 100)).frame(width: max(3, proxy.size.width * min(1, process.cpu / 100)))
                        }
                    }
            }
        }
        if stats.thermal != .nominal {
            Text("macOS сообщает: \(stats.thermal.title.lowercased()). Сверху те, кто нагружает процессор.")
                .font(.system(size: 11)).foregroundStyle(AgentState.waiting.color)
        }
    }
}

// MARK: Порты

struct PortsPanel: View {
    let services: DevServices
    @State private var confirming: String?

    var body: some View {
        DevCard(title: services.ports.isEmpty ? "Серверы на этом Mac" : "Слушают порты: \(services.ports.count)") {
            if services.ports.isEmpty {
                Text("Ни один сервер не запущен.").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
            }
            VScroll {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(services.ports) { port in row(port) }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await services.refreshPorts()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func row(_ port: ListeningPort) -> some View {
        HStack(spacing: 10) {
            Text(":\(String(port.port))").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.accent)
                .frame(width: 64, alignment: .leading)
            Text(port.command).font(.system(size: 12.5)).lineLimit(1)
            Text("pid \(String(port.pid))").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
            if port.exposed {
                Text("виден в сети").font(.system(size: 11)).foregroundStyle(AgentState.waiting.color)
            }
            Spacer()
            Button("Открыть") {
                if let url = URL(string: "http://localhost:\(port.port)") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(VisorButtonStyle())
            Button(confirming == port.id ? "Точно остановить?" : "Остановить") {
                if confirming == port.id {
                    confirming = nil
                    services.stop(port)
                } else {
                    confirming = port.id
                }
            }
            .buttonStyle(VisorButtonStyle(kind: confirming == port.id ? .danger : .normal))
        }
    }
}

// MARK: Токен

struct TokenCard: View {
    let model: IslandModel
    let services: DevServices
    let service: String
    let title: String
    let steps: String
    let tokenPage: String
    @State private var token = ""
    @FocusState private var focused: Bool

    var body: some View {
        DevCard(title: title) {
            Text(steps).font(.system(size: 12.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecureField("Вставьте токен", text: $token)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.hover))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Palette.accent : Palette.cardBorder))
                Button("Сохранить") {
                    services.saveToken(token, for: service)
                    token = ""
                }
                .buttonStyle(VisorButtonStyle(kind: .primary))
                Button("Создать токен") {
                    if let url = URL(string: tokenPage) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(VisorButtonStyle())
            }
            Text("Токен хранится в связке ключей macOS и уходит только на сервер \(service == "github" ? "GitHub" : "Vercel").")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        .onChange(of: focused) { _, value in
            model.keepOpen = value
            if value { IslandController.shared.focusForTyping() }
        }
        .onDisappear { model.keepOpen = false }
    }
}

// MARK: GitHub

struct GitHubPanel: View {
    let model: IslandModel
    let services: DevServices

    var body: some View {
        if !services.hasGitHubToken {
            TokenCard(model: model, services: services, service: "github", title: "GitHub: подключение",
                      steps: "Нужен токен, чтобы показывать ваши открытые PR и состояние проверок. Нажмите «Создать токен», подтвердите право repo внизу страницы и вставьте токен сюда.",
                      tokenPage: "https://github.com/settings/tokens/new?scopes=repo&description=Visor")
        } else {
            DevCard(title: "Ваши открытые PR") {
                switch services.pulls {
                case .idle, .loading:
                    Text("Загружаю…").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                case .failed(let message):
                    Text(message).font(.system(size: 12.5)).foregroundStyle(AgentState.error.color)
                case .loaded(let pulls):
                    if pulls.isEmpty { Text("Открытых PR нет.").font(.system(size: 12.5)).foregroundStyle(Palette.muted) }
                    VScroll {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(pulls) { pull in row(pull) }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Убрать токен") { services.removeToken(for: "github") }.buttonStyle(VisorButtonStyle())
                }
            }
            .task {
                while !Task.isCancelled {
                    await services.refreshPulls()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }

    private func row(_ pull: PullRequest) -> some View {
        Button {
            if let url = pull.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                Circle().fill(color(pull.ci)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pull.title).font(.system(size: 12.5)).lineLimit(1)
                    Text("\(pull.repository) #\(String(pull.number))").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if pull.draft { Text("черновик").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                Text("проверки: \(pull.ci.title)").font(.system(size: 11.5)).foregroundStyle(color(pull.ci))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func color(_ state: CIState) -> Color {
        switch state {
        case .passing: AgentState.done.color
        case .running: AgentState.waiting.color
        case .failing: AgentState.error.color
        case .unknown: Palette.muted
        }
    }
}

// MARK: Vercel

struct VercelPanel: View {
    let model: IslandModel
    let services: DevServices

    var body: some View {
        if !services.hasVercelToken {
            TokenCard(model: model, services: services, service: "vercel", title: "Vercel: подключение",
                      steps: "Нужен токен, чтобы показывать последние деплои. Нажмите «Создать токен», создайте токен с любым названием и вставьте его сюда.",
                      tokenPage: "https://vercel.com/account/tokens")
        } else {
            DevCard(title: "Последние деплои") {
                switch services.deployments {
                case .idle, .loading:
                    Text("Загружаю…").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                case .failed(let message):
                    Text(message).font(.system(size: 12.5)).foregroundStyle(AgentState.error.color)
                case .loaded(let items):
                    if items.isEmpty { Text("Деплоев нет.").font(.system(size: 12.5)).foregroundStyle(Palette.muted) }
                    VScroll {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(items) { item in row(item) }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Убрать токен") { services.removeToken(for: "vercel") }.buttonStyle(VisorButtonStyle())
                }
            }
            .task {
                while !Task.isCancelled {
                    await services.refreshDeployments()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }

    private func row(_ item: Deployment) -> some View {
        Button {
            if let url = item.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                Circle().fill(color(item.state)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 12.5)).lineLimit(1)
                    Text(item.created.formatted(.relative(presentation: .named).locale(Locale(identifier: "ru"))))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if item.production { Text("production").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                Text(item.state.title).font(.system(size: 11.5)).foregroundStyle(color(item.state))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func color(_ state: DeployState) -> Color {
        switch state {
        case .ready: AgentState.done.color
        case .building, .queued: AgentState.waiting.color
        case .error: AgentState.error.color
        case .canceled: Palette.muted
        }
    }
}
