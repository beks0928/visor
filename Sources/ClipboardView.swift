import SwiftUI

/// Вкладка «Буфер»: история копирований с закрепами, сниппеты и пипетка цвета.
struct ClipboardPage: View {
    let model: IslandModel
    var store: ClipboardStore = .shared

    @State private var adding = false
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            VScroll {
                VStack(alignment: .leading, spacing: 6) {
                    let pinned = store.items.filter(\.pinned)
                    let recent = store.items.filter { !$0.pinned }
                    if !pinned.isEmpty {
                        label("Закреплено")
                        ForEach(pinned) { ClipRow(item: $0, store: store) }
                    }
                    label("Недавние · последние \(ClipboardStore.limit), закреплённые не вытесняются")
                    if recent.isEmpty {
                        Text("Пока пусто: скопируйте что-нибудь, и оно появится здесь.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    } else {
                        ForEach(recent) { ClipRow(item: $0, store: store) }
                    }
                    label("Сниппеты")
                    snippetsArea
                }
            }
        }
        .onAppear { store.reloadSnippets() }
        // Пока пишете сниппет, остров не сворачивается, даже если курсор ушёл.
        .onChange(of: adding) { _, value in
            model.keepOpen = value
            // Окно острова неактивное: без этого ввод с клавиатуры уходил бы в другое приложение.
            if value { IslandController.shared.focusForTyping() }
        }
        .onDisappear { model.keepOpen = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Буфер").font(.system(size: 15, weight: .semibold))
            if let flash = store.flash {
                Text(flash).font(.system(size: 12)).foregroundStyle(AgentState.done.color)
            }
            Spacer()
            Text("Цвет копируется как").font(.system(size: 11)).foregroundStyle(Palette.muted)
            HStack(spacing: 2) {
                ForEach(ColorFormat.allCases) { format in
                    Button { store.setColorFormat(format) } label: {
                        Text(format.title)
                            .font(.system(size: 11.5))
                            .foregroundStyle(store.colorFormat == format ? Palette.text : Palette.muted)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(store.colorFormat == format ? Color.white.opacity(0.16) : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { store.pickColor() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "eyedropper").font(.system(size: 11))
                    Text("Пипетка")
                }
            }
            .buttonStyle(VisorButtonStyle())
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .padding(.top, 6)
    }

    // MARK: Сниппеты

    private var snippetsArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(store.orderedSnippets) { snippet in
                    HStack(spacing: 4) {
                        Button { store.toggleSnippetPin(snippet.id) } label: {
                            Image(systemName: snippet.pinned ? "pin.fill" : "pin")
                                .font(.system(size: 10))
                                .foregroundStyle(snippet.pinned ? Palette.accent : Palette.muted)
                                .frame(width: 20, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(snippet.pinned ? "Открепить сниппет \(snippet.title)" : "Закрепить сниппет \(snippet.title)")
                        Text(snippet.title).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 2)
                        Button { store.removeSnippet(snippet.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Palette.muted)
                                .frame(width: 20, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Удалить сниппет \(snippet.title)")
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                    .background(Capsule().fill(Palette.card))
                    .overlay(Capsule().stroke(snippet.pinned ? Palette.accent.opacity(0.45) : Palette.cardBorder))
                    .contentShape(Capsule())
                    .onTapGesture { store.copy(snippet) }
                }
                Button { adding.toggle() } label: {
                    Text(adding ? "Отмена" : "+ Добавить").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .overlay(Capsule().stroke(Palette.cardBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
                .buttonStyle(.plain)
            }
            if adding {
                VStack(alignment: .leading, spacing: 6) {
                    field("Название, например «Адрес»", text: $title)
                    field("Текст, который вставляется", text: $text)
                    HStack {
                        Button("Сохранить") {
                            store.addSnippet(title: title, text: text)
                            title = ""
                            text = ""
                            adding = false
                        }
                        .buttonStyle(VisorButtonStyle(kind: .primary))
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("Сниппеты лежат в snippets.json: их можно править и руками.")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                }
            } else if store.snippets.isEmpty {
                Text("Сниппет это то, что надоело вводить: адрес, телефон, почта.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.cardBorder))
    }
}

struct ClipRow: View {
    let item: ClipItem
    let store: ClipboardStore

    var body: some View {
        HStack(spacing: 10) {
            leading
            Text(item.text)
                .font(item.kind == .text ? .system(size: 12.5) : .system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            if item.kind == .color, let color = ClipColor.parse(item.text) {
                Text(ClipColor.format(color, as: .rgb))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            Button { store.saveAsSnippet(item) } label: {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Сохранить как сниппет")
            .accessibilityLabel("Сохранить как сниппет")
            Button { store.togglePin(item.id) } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(item.pinned ? Palette.accent : Palette.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.pinned ? "Открепить" : "Закрепить")
            Button { store.remove(item.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Удалить")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .listRow(emphasized: item.pinned)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { store.copy(item) }
    }

    @ViewBuilder
    private var leading: some View {
        if item.kind == .color, let color = ClipColor.parse(item.text) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255))
                .frame(width: 24, height: 24)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.cardBorder))
        } else if item.kind == .link {
            Image(systemName: "link").font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 24)
        }
    }
}
