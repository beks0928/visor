import CoreLocation
import CoreWLAN
import Network
import SwiftUI

/// Запасной выход в сеть, как у Insomnia: если во время режима «не засыпать» пропал Wi-Fi, Visor сам подключается к хотспоту iPhone.
/// Пароль лежит в связке ключей, в аргументы процессов он не попадает: подключение идёт через CoreWLAN.
enum HotspotPolicy {
    /// Сколько сеть должна пробыть недоступной до первой попытки.
    static let initialDelay: TimeInterval = 5
    /// Паузы после попыток: 5, 10, 20, 30, 30…
    static let backoff: [TimeInterval] = [5, 10, 20, 30]

    static func delay(afterAttempt n: Int) -> TimeInterval { backoff[min(max(n - 1, 0), backoff.count - 1)] }

    static func account(for ssid: String) -> String { "hotspot:" + ssid.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Подсказки по тому, что набрано: без учёта регистра, акцентов и вида апострофа (iPhone пишет ’, клавиатура '').
    static func suggestions(for typed: String, among known: [String]) -> [String] {
        let key = fold(typed)
        var seen = Set<String>()
        return known.filter { name in
            !name.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert(name).inserted && (key.isEmpty || fold(name).contains(key))
        }
    }

    /// Качество сигнала по RSSI в дБм.
    static func signalQuality(rssi: Int) -> String {
        rssi == 0 ? "сигнал неизвестен" : rssi >= -60 ? "сигнал хороший" : rssi >= -75 ? "сигнал средний" : "сигнал слабый"
    }

    struct Step: Equatable { let title: String; let ok: Bool; let hint: String }

    /// Что нужно для автоподключения: название, пароль в связке ключей, доступ к названиям сетей.
    static func checklist(ssid: String, hasPassword: Bool, locationAllowed: Bool) -> [Step] {
        let named = !ssid.trimmingCharacters(in: .whitespaces).isEmpty
        return [
            Step(title: named ? "Название: \(ssid.trimmingCharacters(in: .whitespaces))" : "Название хотспота", ok: named, hint: "введите название или выберите из списка"),
            Step(title: "Пароль в связке ключей", ok: hasPassword, hint: "введите пароль и нажмите «Сохранить»"),
            Step(title: "Доступ к названиям сетей", ok: locationAllowed, hint: "нажмите «Разрешить» ниже"),
        ]
    }

    /// Одно и то же название: без учёта регистра и вида апострофа.
    static func sameName(_ a: String, _ b: String) -> Bool { fold(a) == fold(b) }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// Итог проверки: виден ли хотспот сейчас. Пароль так проверить нельзя, он проверяется только настоящим подключением.
enum HotspotCheck: Equatable, Sendable {
    case found(rssi: Int), notFound, noWiFi, error(String)

    var text: String {
        switch self {
        case .found(let rssi): "Хотспот виден, \(HotspotPolicy.signalQuality(rssi: rssi)). Пароль проверится при настоящем подключении."
        case .notFound: "Хотспот не найден: на iPhone включите «Режим модема» и подойдите ближе."
        case .noWiFi: "На этом Mac нет Wi-Fi."
        case .error(let text): "Не получилось проверить: \(text)"
        }
    }

    var ok: Bool { if case .found = self { true } else { false } }
}

@MainActor @Observable
final class HotspotFailover: NSObject, CLLocationManagerDelegate {
    static let shared = HotspotFailover()

    var ssid: String { didSet { defaults.set(ssid, forKey: "visor.hotspot.ssid"); refreshPassword() } }
    private(set) var hasPassword = false
    private(set) var locationAllowed = false
    private(set) var outageSince: Date?
    /// Wi-Fi, к которому Mac подключён сейчас. nil: не подключён или macOS прячет название без доступа.
    private(set) var currentSSID: String?
    private(set) var checking = false
    private(set) var check: HotspotCheck?
    var message: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var location: CLLocationManager?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var attempts = 0
    @ObservationIgnored private var started = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ssid = defaults.string(forKey: "visor.hotspot.ssid") ?? ""
        super.init()
    }

    var configured: Bool { !ssid.trimmingCharacters(in: .whitespaces).isEmpty && hasPassword }

    func start() {
        guard !started else { return }
        started = true
        refreshPassword()
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(satisfied: ok) }
        }
        monitor.start(queue: DispatchQueue(label: "visor.hotspot.path"))
    }

    func refreshCurrent() { currentSSID = CWWiFiClient.shared().interface()?.ssid() }

    /// Ищет хотспот по названию, сеть не меняет.
    func runCheck() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let name = ssid.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { check = .error("введите название хотспота."); return }
        check = await Task.detached { Self.scan(ssid: name) }.value
    }

    nonisolated private static func scan(ssid: String) -> HotspotCheck {
        guard let interface = CWWiFiClient.shared().interface() else { return .noWiFi }
        do {
            guard let network = try interface.scanForNetworks(withSSID: Data(ssid.utf8)).first else { return .notFound }
            return .found(rssi: network.rssiValue)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: Настройка

    func refreshPassword() {
        hasPassword = !ssid.trimmingCharacters(in: .whitespaces).isEmpty && SecretStore.get(HotspotPolicy.account(for: ssid)) != nil
    }

    func savePassword(_ password: String) {
        let clean = ssid.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !password.isEmpty else { return }
        message = SecretStore.set(password, account: HotspotPolicy.account(for: clean)) ? "Пароль сохранён в связке ключей." : "Не удалось сохранить пароль."
        refreshPassword()
    }

    func forget() {
        SecretStore.delete(HotspotPolicy.account(for: ssid))
        refreshPassword()
        message = "Пароль удалён."
    }

    /// Названия сетей, к которым этот Mac уже подключался. macOS скрывает названия без доступа к геопозиции.
    nonisolated static func rememberedNetworks() -> [String] {
        let profiles = CWWiFiClient.shared().interface()?.configuration()?.networkProfiles.array ?? []
        return profiles.compactMap { ($0 as? CWNetworkProfile)?.ssid }
    }

    // MARK: Геопозиция: macOS открывает названия сетей только с ней. Visor координаты не читает.

    func refreshLocation() {
        let status = (location ?? CLLocationManager()).authorizationStatus
        locationAllowed = status == .authorizedAlways
    }

    func requestLocation() {
        if location == nil {
            let manager = CLLocationManager()
            manager.delegate = self
            location = manager
        }
        location?.requestAlwaysAuthorization()
        refreshLocation()
        if !locationAllowed, location?.authorizationStatus == .denied,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refreshLocation() }
    }

    // MARK: Слежение за сетью

    private func pathChanged(satisfied: Bool) {
        if satisfied {
            retry?.cancel()
            if let since = outageSince {
                message = "Сеть вернулась через \(Int(Date().timeIntervalSince(since).rounded())) с."
            }
            outageSince = nil
            attempts = 0
        } else if outageSince == nil, configured, LidAwake.shared.active {
            outageSince = Date()
            attempts = 0
            schedule(after: HotspotPolicy.initialDelay)
        }
    }

    private func schedule(after delay: TimeInterval) {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.attempt()
        }
    }

    private func attempt() async {
        guard outageSince != nil, LidAwake.shared.active, configured,
              let password = SecretStore.get(HotspotPolicy.account(for: ssid)) else { outageSince = nil; return }
        attempts += 1
        let name = ssid.trimmingCharacters(in: .whitespaces)
        let result = await Task.detached { Self.join(ssid: name, password: password) }.value
        message = result ?? "Подключаюсь к «\(name)»…"
        schedule(after: HotspotPolicy.delay(afterAttempt: attempts))
    }

    /// nil: подключение отправлено. Иначе причина неудачи.
    nonisolated private static func join(ssid: String, password: String) -> String? {
        guard let interface = CWWiFiClient.shared().interface() else { return "Не найден адаптер Wi-Fi." }
        do {
            let networks = try interface.scanForNetworks(withSSID: Data(ssid.utf8))
            guard let network = networks.first else { return "Сеть «\(ssid)» не найдена: iPhone далеко или хотспот выключен." }
            try interface.associate(to: network, password: password)
            return nil
        } catch {
            return "Не удалось подключиться: \(error.localizedDescription)"
        }
    }
}

// MARK: Настройки

struct HotspotSettings: View {
    var hotspot: HotspotFailover = .shared
    @State private var password = ""
    @State private var showPassword = false
    @State private var known: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Если Wi-Fi пропал").font(.system(size: 12.5, weight: .semibold)).padding(.horizontal, 12).padding(.top, 4)
            caption("Во время режима «не засыпать» Visor сам подключится к хотспоту iPhone. На Mac включите «Системные настройки → Wi-Fi → Запрашивать подключение к точкам доступа → Автоматически», на iPhone «Режим модема».")
            statusCard
            field("Название хотспота", text: Binding(get: { hotspot.ssid }, set: { hotspot.ssid = $0 }))
            let hints = HotspotPolicy.suggestions(for: hotspot.ssid, among: known).filter { $0 != hotspot.ssid }.prefix(4)
            if !hints.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(hints), id: \.self) { name in
                        Button(name) { hotspot.ssid = name }.buttonStyle(VisorButtonStyle())
                    }
                }
                .padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Group {
                        if showPassword { TextField("Пароль хотспота", text: $password) } else { SecureField("Пароль хотспота", text: $password) }
                    }
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    Button { showPassword.toggle() } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showPassword ? "Скрыть пароль" : "Показать пароль")
                    .accessibilityLabel(showPassword ? "Скрыть пароль" : "Показать пароль")
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(Palette.hover, in: RoundedRectangle(cornerRadius: 8))
                Button("Сохранить") { hotspot.savePassword(password); password = "" }
                    .buttonStyle(VisorButtonStyle(kind: .primary)).disabled(password.isEmpty || hotspot.ssid.isEmpty)
                if hotspot.hasPassword { Button("Забыть") { hotspot.forget() }.buttonStyle(VisorButtonStyle()) }
            }
            .padding(.horizontal, 12)
            SettingRow(title: "Доступ к названиям сетей", subtitle: hotspot.locationAllowed ? "выдан" : "без него macOS прячет названия") {
                if !hotspot.locationAllowed { Button("Разрешить") { hotspot.requestLocation() }.buttonStyle(VisorButtonStyle()) }
            }
            if let message = hotspot.message { caption(message, color: Palette.text) }
            caption("Visor использует доступ только чтобы найти сеть по названию, места не читает. Пароль хранится в связке ключей и никуда не отправляется.")
        }
        .task {
            hotspot.refreshLocation()
            hotspot.refreshPassword()
            known = HotspotFailover.rememberedNetworks()
            while !Task.isCancelled {
                hotspot.refreshCurrent()
                hotspot.refreshLocation()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Готовность, проверка и текущая сеть в одном месте.
    private var statusCard: some View {
        let steps = HotspotPolicy.checklist(ssid: hotspot.ssid, hasPassword: hotspot.hasPassword, locationAllowed: hotspot.locationAllowed)
        let ready = steps.allSatisfy(\.ok)
        let name = hotspot.ssid.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(ready ? AgentState.done.color : AgentState.waiting.color).frame(width: 8, height: 8)
                Text(ready ? "Готов к подключению" : "Не настроено").font(.system(size: 13, weight: .semibold))
            }
            ForEach(steps, id: \.title) { step in
                HStack(spacing: 6) {
                    Image(systemName: step.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(step.ok ? AgentState.done.color : AgentState.waiting.color)
                    Text(step.title).font(.system(size: 12))
                    if !step.ok { Text(step.hint).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                }
            }
            HStack(spacing: 6) {
                let connected = hotspot.currentSSID.map { !name.isEmpty && HotspotPolicy.sameName($0, name) } ?? false
                Image(systemName: connected ? "iphone.radiowaves.left.and.right" : "wifi").font(.system(size: 11))
                    .foregroundStyle(connected ? AgentState.done.color : Palette.muted)
                Text(currentText(connected: connected)).font(.system(size: 12))
            }
            HStack(spacing: 8) {
                Button(hotspot.checking ? "Ищу…" : "Проверить хотспот") { Task { await hotspot.runCheck() } }
                    .buttonStyle(VisorButtonStyle()).disabled(hotspot.checking || name.isEmpty)
                if let check = hotspot.check {
                    Text(check.text).font(.system(size: 11.5)).foregroundStyle(check.ok ? AgentState.done.color : AgentState.waiting.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.cardBorder))
        .padding(.horizontal, 12)
    }

    private func currentText(connected: Bool) -> String {
        if let current = hotspot.currentSSID { return connected ? "Сейчас подключён к хотспоту: \(current)" : "Сейчас в сети: \(current)" }
        return hotspot.locationAllowed ? "Сейчас не подключён к Wi-Fi" : "Название текущей сети скрыто: нужен доступ к названиям сетей"
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain).font(.system(size: 12.5))
            .padding(.horizontal, 10).frame(height: 30)
            .background(Palette.hover, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
    }

    private func caption(_ text: String, color: Color = Palette.muted) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(color).padding(.horizontal, 12).fixedSize(horizontal: false, vertical: true)
    }
}
