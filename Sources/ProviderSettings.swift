import AppKit
import SwiftUI

/// Какие агенты видны во вкладке «Агенты» (до трёх). Остальные подключаются в настройках.
@MainActor @Observable
final class AgentPins {
    static let shared = AgentPins()

    private(set) var pinned: [AgentTarget]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pinned = PinRules.normalize(saved: defaults.stringArray(forKey: "agents.pinned") ?? [], all: AgentTarget.allCases,
                                    defaults: AgentTarget.defaultPinned)
    }

    func set(_ target: AgentTarget, _ on: Bool) {
        pinned = PinRules.toggled(pinned, target, on: on)
        defaults.set(pinned.map(\.rawValue), forKey: "agents.pinned")
    }
}

/// Настройки «Чат»: все модели, ключи и названия моделей. Во вкладке «Чат» видны только выбранные три.
struct ChatSettings: View {
    var store: ChatStore = .shared

    var body: some View {
        VScroll {
            VStack(alignment: .leading, spacing: 6) {
                Text("Включите до трёх моделей: только они видны во вкладке «Чат». Остальные ключи можно держать здесь заранее.")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(ChatProvider.allCases) { provider in ChatProviderRow(provider: provider, store: store) }
                Text("Ключ хранится в связке ключей macOS и уходит только на сервер этой модели. Запросы оплачиваете вы по своему тарифу. Название модели можно заменить, если сервис переименовал её.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }
}

struct ChatProviderRow: View {
    let provider: ChatProvider
    let store: ChatStore
    @State private var open = false
    @State private var key = ""
    @State private var showKey = false
    @State private var model = ""

    var body: some View {
        let pinned = store.pinned.contains(provider)
        VStack(spacing: 0) {
            SettingRow(title: provider.title, subtitle: store.keys.contains(provider) ? "ключ есть" : "нет ключа",
                       toggle: Binding(get: { pinned }, set: { store.setPinned(provider, $0) })) {
                Text("во вкладке").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Button { open.toggle() } label: {
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.muted).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Свернуть" : "Ключ и модель")
            }
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Group {
                            if showKey { TextField("Ключ \(provider.title)", text: $key) } else { SecureField("Ключ \(provider.title)", text: $key) }
                        }
                        .textFieldStyle(.plain).font(.system(size: 12.5))
                        Button { showKey.toggle() } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye").font(.system(size: 12)).foregroundStyle(Palette.muted)
                                .frame(width: 24, height: 24).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showKey ? "Скрыть ключ" : "Показать ключ")
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(Palette.hover, in: RoundedRectangle(cornerRadius: 8))
                    HStack(spacing: 8) {
                        Button("Сохранить ключ") { store.saveKey(key, for: provider); key = "" }
                            .buttonStyle(VisorButtonStyle(kind: .primary)).disabled(key.isEmpty)
                        if store.keys.contains(provider) {
                            Button("Убрать ключ") { store.removeKey(for: provider) }.buttonStyle(VisorButtonStyle())
                        }
                        Button("Создать ключ") {
                            if let url = URL(string: provider.keyPage) { NSWorkspace.shared.open(url) }
                        }
                        .buttonStyle(VisorButtonStyle())
                    }
                    HStack(spacing: 8) {
                        Text("Модель").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        TextField(provider.model, text: $model)
                            .textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced))
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(Palette.hover, in: RoundedRectangle(cornerRadius: 8))
                            .onSubmit { store.setModel(model, for: provider) }
                        Button("Применить") { store.setModel(model, for: provider) }.buttonStyle(VisorButtonStyle())
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .onAppear { model = store.model(for: provider) == provider.model ? "" : store.model(for: provider) }
            }
        }
    }
}
