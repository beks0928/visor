import AppKit
import SwiftUI

/// Вкладка «Чат»: Claude и Gemini по вашим ключам, диктовка по-русски.
struct ChatPage: View {
    let model: IslandModel
    var store: ChatStore = .shared
    var dictation: Dictation = .shared
    @Environment(\.snapshotMode) private var snapshotMode
    @State private var draft = ""
    @State private var key = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if store.hasKey {
                conversation
                composer
            } else {
                keyCard
            }
        }
        .onChange(of: focused) { _, value in
            model.keepOpen = value
            // Окно острова неактивное: без этого ввод с клавиатуры уходил бы в другое приложение.
            if value { IslandController.shared.focusForTyping() }
        }
        .onDisappear {
            model.keepOpen = false
            dictation.stop()
        }
    }

    // MARK: Шапка

    private var header: some View {
        HStack(spacing: 2) {
            ForEach(store.pinned) { item in
                Button { store.provider = item } label: {
                    HStack(spacing: 6) {
                        Text(item.title)
                        if !store.keys.contains(item) { Circle().fill(Palette.muted).frame(width: 5, height: 5) }
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(store.provider == item ? Palette.text : Palette.muted)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(store.provider == item ? Palette.selected : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if store.hasKey {
                Text(store.model(for: store.provider)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                if !store.messages.isEmpty {
                    Button("Очистить") { store.clear() }.buttonStyle(VisorButtonStyle())
                }
                Button("Убрать ключ") { store.removeKey() }.buttonStyle(VisorButtonStyle())
            }
        }
    }

    // MARK: Нет ключа

    private var keyCard: some View {
        DevCard(title: "\(store.provider.title): подключение") {
            Text("Нужен ваш ключ \(store.provider.title). Нажмите «Создать ключ», скопируйте его и вставьте сюда. Ключ хранится в связке ключей macOS и уходит только на сервер \(store.provider.title). Запросы оплачиваете вы по своему тарифу.")
                .font(.system(size: 12.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecureField("Вставьте ключ", text: $key)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.hover))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Palette.accent : Palette.cardBorder))
                    .onSubmit(saveKey)
                Button("Сохранить", action: saveKey).buttonStyle(VisorButtonStyle(kind: .primary))
                Button("Создать ключ") {
                    if let url = URL(string: store.provider.keyPage) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(VisorButtonStyle())
            }
        }
    }

    private func saveKey() {
        store.saveKey(key)
        key = ""
    }

    // MARK: Переписка

    private var conversation: some View {
        let list = VStack(alignment: .leading, spacing: 8) {
            if store.messages.isEmpty {
                Text("Напишите вопрос или нажмите микрофон и продиктуйте. Переписка с каждой моделью хранится отдельно.")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.muted)
            }
            ForEach(store.messages) { message in bubble(message) }
            if store.isSending {
                Text("\(store.provider.title) думает…").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Color.clear.frame(height: 1).id("bottom")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        return Group {
            if snapshotMode {
                list.frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) { list }
                        .onChange(of: store.messages.count) { _, _ in proxy.scrollTo("bottom") }
                        .onChange(of: store.isSending) { _, _ in proxy.scrollTo("bottom") }
                }
            }
        }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let mine = message.role == .user
        return HStack {
            if mine { Spacer(minLength: 80) }
            Text(message.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14).fill(mine ? Palette.accent.opacity(0.22) : Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(mine ? Color.clear : Palette.cardBorder))
            if !mine { Spacer(minLength: 80) }
        }
    }

    // MARK: Ввод

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = store.error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(AgentState.error.color)
            }
            if case .failed(let message) = dictation.state {
                Text(message).font(.system(size: 11.5)).foregroundStyle(AgentState.waiting.color)
            }
            HStack(spacing: 8) {
                TextField(dictation.isListening ? "Слушаю…" : "Сообщение", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Palette.accent : Palette.cardBorder))
                    .onSubmit(send)
                Button {
                    dictation.toggle(current: draft) { draft = $0 }
                } label: {
                    Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                        .foregroundStyle(dictation.isListening ? AgentState.error.color : Color.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Palette.hover))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Диктовка по-русски")
                Button("Отправить", action: send)
                    .buttonStyle(VisorButtonStyle(kind: .primary))
                    .disabled(store.isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !store.isSending else { return }
        dictation.stop()
        draft = ""
        Task { await store.send(text) }
    }
}
