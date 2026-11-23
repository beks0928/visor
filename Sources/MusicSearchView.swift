import AppKit
import SwiftUI

/// Строка поиска справа в ряду вкладок «Медиа».
struct PlayerSearchField: View {
    let model: MusicSearchModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.muted)
            TextField("Найти песню или строчку из текста", text: Binding(get: { model.query }, set: { model.update($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onExitCommand { model.clear() }
                .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                .onSubmit { model.playSelected() }
            if model.status == .searching {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
            }
            if !model.query.isEmpty {
                Button { model.clear() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 380, height: 28)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Palette.selected : Palette.cardBorder))
    }
}

/// Выпадающий список под строкой поиска: варианты Spotify и Apple Music, потом история и тексты.
struct PlayerSearchDropdown: View {
    let model: MusicSearchModel
    @State private var clientID = ""
    @State private var secret = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                        SearchRow(hit: hit, highlighted: model.selected == index) { Task { await model.play(hit) } }
                    }
                    if model.hits.isEmpty { empty }
                    ForEach(model.notes, id: \.self) { note in
                        if !note.isEmpty { Text(note).font(.system(size: 11)).foregroundStyle(AgentState.waiting.color).padding(.horizontal, 8).padding(.top, 4) }
                    }
                    if let message = model.message {
                        Text(message).font(.system(size: 11)).foregroundStyle(AgentState.waiting.color).padding(.horizontal, 8).padding(.top, 4)
                    }
                    if !model.hits.isEmpty {
                        Text("↑ ↓ выбрать   ·   Enter играть   ·   Esc закрыть")
                            .font(.system(size: 10)).foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity).padding(.top, 6)
                    }
                    footer
                }
                .padding(6)
            }
            .frame(maxHeight: 250)
        }
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.cardBorder))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
    }

    private var active: MediaSource { model.activeSource }
    private var isSpotify: Bool { active.id == MediaSource.spotify.id }
    private var isApple: Bool { active.id == MediaSource.appleMusic.id }

    @ViewBuilder private var empty: some View {
        if isSpotify, !model.spotifyConnected {
            EmptyView()
        } else if model.status == .searching {
            Text("Ищу в «\(active.name)»…").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(8)
        } else if model.status == .done, !isSpotify && !isApple {
            Text("Для «\(active.name)» списка нет: у сервиса нет открытого поиска. Кнопка ниже откроет поиск на его сайте.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.muted).padding(8)
        } else if model.status == .done {
            Text("В «\(active.name)» ничего не нашлось.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(8)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isSpotify {
                if model.spotifyConnected {
                    Button("Отключить поиск Spotify") { model.disconnectSpotify() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.horizontal, 8)
                } else {
                    setup
                }
            } else if !isApple {
                webButton(active.name, id: active.id)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
        }
        .padding(.top, 6)
    }

    private func webButton(_ title: String, id: String) -> some View {
        Button { model.openWebSearch(sourceID: id) } label: {
            Label("Искать в «\(title)»", systemImage: "arrow.up.right.square").font(.system(size: 11))
        }
        .buttonStyle(.plain).foregroundStyle(Palette.muted)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Чтобы искать в Spotify, подключите его один раз:").font(.system(size: 12, weight: .semibold))
            Group {
                Text("1. Откройте developer.spotify.com/dashboard и войдите в свой аккаунт Spotify.")
                Text("2. Create app: любое название, а в Redirect URI впишите http://127.0.0.1:8888/callback. (Если приложение уже есть, откройте его.)")
                Text("3. Settings: скопируйте Client ID и нажмите View client secret, скопируйте Secret.")
                Text("4. Вставьте оба значения ниже. Вход в аккаунт в Visor не нужен.")
            }
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
            Button("Открыть developer.spotify.com") {
                if let url = URL(string: "https://developer.spotify.com/dashboard") { NSWorkspace.shared.open(url) }
            }
            .font(.system(size: 11))
            TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder).font(.system(size: 12))
            SecureField("Client Secret", text: $secret).textFieldStyle(.roundedBorder).font(.system(size: 12))
            Button(saving ? "Проверяю…" : "Сохранить и проверить") {
                saving = true
                Task { await model.saveSpotify(id: clientID, secret: secret); saving = false }
            }
            .disabled(saving)
            .font(.system(size: 12))
        }
        .padding(8)
    }
}

private struct SearchRow: View {
    let hit: SearchHit
    var highlighted = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                cover
                VStack(alignment: .leading, spacing: 1) {
                    Text(hit.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(badge).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(hovered || highlighted ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var subtitle: String {
        if let snippet = hit.snippet { return "«\(snippet)» · \(hit.artist)" }
        return hit.artist
    }

    private var badge: String {
        switch hit.origin {
        case .spotify: "Spotify"
        case .apple: "Apple Music"
        case .history: "Слушали"
        case .lyrics: "В тексте"
        }
    }

    @ViewBuilder private var cover: some View {
        Group {
            if let url = hit.coverURL {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Palette.card }
            } else {
                Image(systemName: hit.origin == .lyrics ? "quote.bubble" : "clock.arrow.circlepath")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.card)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
