import AppKit
import SwiftUI

enum MediaSub: String, CaseIterable, Identifiable {
    case player, web, teleprompter, notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .player: "Плеер"
        case .web: "В Visor"
        case .teleprompter: "Телесуфлёр"
        case .notes: "Заметки"
        }
    }
}

/// Вкладка «Медиа»: плеер, телесуфлёр и заметки.
struct MediaPage: View {
    let model: IslandModel
    var player: PlayerController = .shared
    var teleprompter: TeleprompterStore = .shared
    var notes: NotesStore = .shared
    var search: MusicSearchModel = .shared
    private var sub: MediaSub { model.mediaSub }

    init(model: IslandModel, player: PlayerController = .shared, teleprompter: TeleprompterStore = .shared,
         notes: NotesStore = .shared, search: MusicSearchModel = .shared, start: MediaSub? = nil) {
        self.model = model
        self.player = player
        self.teleprompter = teleprompter
        self.notes = notes
        self.search = search
        if let start { model.mediaSub = start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                ForEach(MediaSub.allCases) { item in
                    Button { model.mediaSub = item } label: {
                        Text(item.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(sub == item ? Palette.text : Palette.muted)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(sub == item ? Palette.selected : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if sub == .player {
                    Spacer(minLength: 12)
                    PlayerSearchField(model: search)
                }
            }
            switch sub {
            case .player: PlayerPanel(player: player, model: model)
            case .web: WebPlayerPanel()
            case .teleprompter: TeleprompterPanel(model: model, store: teleprompter)
            case .notes: NotesPanel(model: model, store: notes)
            }
        }
        .overlay(alignment: .topTrailing) {
            if sub == .player, search.isOpen {
                PlayerSearchDropdown(model: search).padding(.top, 34)
            }
        }
    }
}

/// Круглая кнопка с иконкой: нажимается вся окружность, а не только рисунок.
struct RoundIconButton: View {
    let symbol: String
    var size: CGFloat = 34
    var filled = false
    var tint: Color = .white
    /// Цвет круга у главной кнопки и цвет значка на нём.
    var fill: Color = Palette.accent
    var glyph: Color = .black
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(filled ? glyph : tint)
                .frame(width: size, height: size)
                .background(Circle().fill(filled ? fill : Palette.hover))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
    }
}

/// Нажатие чуть уменьшает кнопку: видно, что клик принят.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: Плеер

struct PlayerPanel: View {
    let player: PlayerController
    var model: IslandModel?

    /// Сервис без приложения играет в окне Visor: открывается вкладка «В Visor» и там нужный сайт.
    private func openInVisor(_ service: WebService2) {
        WebPlayer.shared.open(service)
        model?.mediaSub = .web
    }

    private var sources: some View {
        VStack(spacing: 10) {
            Text(player.nowPlaying == nil ? "Ничего не играет" : "Выберите, откуда играть").font(.system(size: 17, weight: .semibold))
            Text("Visor показывает трек из запущенного приложения. Поддерживаются эти сервисы: откройте любой и включите музыку.")
                .font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 10) {
                ForEach(MusicApp.all) { app in MusicAppButton(app: app, onOpenWeb: openInVisor) }
            }
            .padding(.top, 4)
            Text("Нет приложения на Mac: сервис откроется в окне Visor, вкладка «В Visor», войдите там в аккаунт. В Mac App Store этих сервисов нет.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            if !SpotifyConnect.shared.signedIn {
                // Без входа Visor не знает, что играет на телефоне.
                Text("Играете на телефоне? Войдите в Spotify: песня с телефона появится здесь, а кнопка «Играть здесь» перенесёт её на Mac с того же места.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center).frame(maxWidth: 440)
                Button("Подключить Spotify") { player.showDevices = true }.font(.system(size: 12))
            }
            if player.nowPlaying != nil {
                Button("Назад к плееру") { player.showSources = false }.font(.system(size: 12))
            }
            if let failure = player.failure, player.nowPlaying == nil {
                Text(failure).font(.system(size: 11.5)).foregroundStyle(AgentState.waiting.color)
            }
        }
    }

    var body: some View {
        Group {
            if player.showDevices { DevicesScreen(player: player) } else if player.showSources || player.nowPlaying == nil { sources } else if let track = player.nowPlaying { playing(track) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { player.panelVisible = true }
        .onDisappear {
            player.panelVisible = false
            IslandController.shared.setLyricsExpanded(false)
            IslandController.shared.setCoverExpanded(false)
        }
        .task {
            while !Task.isCancelled {
                await player.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Играет

    private func playing(_ track: NowPlaying) -> some View {
        Group {
            if player.showLyrics { lyricsScreen(track) } else if player.showCover { coverScreen(track) } else { layout(track) }
        }
        .animation(.easeOut(duration: 0.2), value: player.showCover)
        .onChange(of: player.showCover) { _, shown in IslandController.shared.setCoverExpanded(shown) }
        .onDisappear { player.showCover = false }
        .onChange(of: player.nowPlaying?.trackKey, initial: true) { _, _ in
            if player.showLyrics { LyricsStore.shared.ensure(for: track) }
        }
        .onChange(of: player.showLyrics) { _, shown in
            if shown { LyricsStore.shared.ensure(for: track) } else { IslandController.shared.setLyricsExpanded(false) }
        }
    }

    /// Текст песни на всю вкладку: крупно по центру, звучащая строка подсвечена.
    private func lyricsScreen(_ track: NowPlaying) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                CoverArt(image: player.cover, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(track.artist).font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer()
                Button { IslandController.shared.setLyricsExpanded(!(model?.lyricsExpanded ?? false)) } label: {
                    Image(systemName: (model?.lyricsExpanded ?? false) ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                        .background(Palette.hover, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .help((model?.lyricsExpanded ?? false) ? "Свернуть окно" : "Развернуть текст на весь экран")
                Button {
                    IslandController.shared.setLyricsExpanded(false)
                    player.showLyrics = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                        .background(Palette.hover, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(PressStyle())
            }
            LyricsView(track: track, size: (model?.lyricsExpanded ?? false) ? 32 : 24, centered: true)
        }
        .padding(.horizontal, 6)
    }

    /// Другой вид песни: сверху название и артист, под ними крупная обложка, окно острова выше обычного.
    /// Нажатие на обложку возвращает обычный вид.
    private func coverScreen(_ track: NowPlaying) -> some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text(track.title).font(.system(size: 22, weight: .semibold)).lineLimit(1)
                    if !track.artist.isEmpty {
                        Text(track.artist).font(.system(size: 14.5)).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
                CoverArt(image: player.cover, size: max(140, min(340, geometry.size.height - 150)))
                    .contentShape(Rectangle())
                    .onTapGesture { player.showCover = false }
                    .help("Вернуться к обычному виду")
                TrackActionBar(track: track)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Явная кнопка выхода: раньше вернуться можно было только нажатием на обложку.
            .overlay(alignment: .topTrailing) {
                Button { player.showCover = false } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                        .background(Palette.hover, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .help("Закрыть (Esc)")
            }
        }
        .padding(.horizontal, 6)
    }

    private func layout(_ track: NowPlaying) -> some View {
        HStack(alignment: .center, spacing: 28) {
            CoverArt(image: player.cover, size: 200)
                .contentShape(Rectangle())
                .onTapGesture { player.showCover = true }
                .help("Открыть обложку")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    sourceLabel(track.source)
                    Spacer(minLength: 8)
                    LikeButton(track: track)
                    PlaylistMenu(track: track, size: 26).padding(.leading, 6)
                }
                Text(track.title)
                    .font(.system(size: 24, weight: .semibold))
                    .lineLimit(2)
                    .padding(.top, 10)
                if !track.artist.isEmpty { artistRow(track) }
                if !track.album.isEmpty {
                    Text(track.album).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1).padding(.top, 6)
                }
                if let device = track.device { deviceRow(device) } else if track.source.id == MediaSource.spotify.id { syncRow }
                // Итог лайка или добавления в плейлист: гаснет сам.
                if let note = TrackActions.shared.message, !TrackActions.shared.needsLogin {
                    Text(note).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).padding(.top, 6)
                }
                Spacer(minLength: 12)
                if track.canSeek {
                    SeekBar(track: track) { seconds in player.seek(to: seconds) }
                }
                controls(track.source, isPlaying: track.isPlaying)
                    .frame(maxWidth: .infinity)
                    .padding(.top, track.canSeek ? 6 : 0)
                if !track.source.canSeek {
                    Text("Название взято из вкладки или приложения. Играть и ставить на паузу нужно там: Visor их не трогает.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 6)
                }
                if let failure = player.failure {
                    Text(failure).font(.system(size: 11)).foregroundStyle(AgentState.waiting.color).padding(.top, 6)
                }
            }
            .frame(width: 360, height: 200, alignment: .leading)
        }
        .animation(.easeOut(duration: 0.25), value: player.cover == nil)
    }

    /// Песня играет на другом устройстве аккаунта (телефон): её можно перенести на этот Mac с того же места.
    private func deviceRow(_ device: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone").font(.system(size: 11)).foregroundStyle(MediaSource.spotify.color)
            Text("Играет на «\(device)»").font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1)
            Button {
                Task {
                    await SpotifyConnect.shared.playHere()
                    await player.refresh()
                }
            } label: {
                Text(SpotifyConnect.shared.busy ? "Переношу…" : "Играть здесь").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(MediaSource.spotify.color, in: Capsule()).foregroundStyle(.black)
            }
            .buttonStyle(PressStyle())
            .disabled(SpotifyConnect.shared.busy)
        }
        .padding(.top, 8)
    }

    /// Песня на Mac, а Spotify не отдаёт плеер аккаунта: пишем, почему телефон не виден, и даём войти заново.
    @ViewBuilder private var syncRow: some View {
        let connect = SpotifyConnect.shared
        if !connect.signedIn || connect.syncStatus != nil {
            HStack(spacing: 8) {
                Image(systemName: "iphone.slash").font(.system(size: 11)).foregroundStyle(AgentState.waiting.color)
                Text(connect.signedIn ? (connect.syncStatus ?? "") : "Телефон не виден: войдите в Spotify.")
                    .font(.system(size: 11)).foregroundStyle(AgentState.waiting.color).lineLimit(2)
                Button { Task { await connect.signIn() } } label: {
                    Text(connect.busy ? "Жду входа…" : "Войти").font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(MediaSource.spotify.color, in: Capsule()).foregroundStyle(.black)
                }
                .buttonStyle(PressStyle())
                .disabled(connect.busy)
            }
            .padding(.top, 8)
        }
    }

    private func sourceLabel(_ source: MediaSource) -> some View {
        HStack(spacing: 7) {
            Group {
                if let icon = player.sourceIcon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Circle().fill(source.color)
                }
            }
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(source.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted)
            Button { player.showSources = true } label: {
                Label("Сменить", systemImage: "arrow.left.arrow.right").font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 7).frame(height: 20).background(Palette.hover, in: Capsule())
            }
            .buttonStyle(PressStyle())
        }
    }

    private func artistRow(_ track: NowPlaying) -> some View {
        HStack(spacing: 9) {
            Group {
                if let avatar = player.avatar {
                    Image(nsImage: avatar).resizable().scaledToFill()
                } else {
                    Text(String(track.artist.prefix(1)).uppercased())
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.card)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.1)))
            Text(track.artist).font(.system(size: 15)).foregroundStyle(Color(white: 0.82)).lineLimit(1)
        }
        .padding(.top, 8)
    }

    private func controls(_ source: MediaSource?, isPlaying: Bool?) -> some View {
        HStack(spacing: 16) {
            // Кнопки управления только у Spotify и Музыки: другим плеерам команд Visor не шлёт.
            if source?.canSeek == true {
                RoundIconButton(symbol: "backward.fill", size: 38) { Task { await player.send(.previous) } }
                RoundIconButton(symbol: isPlaying == true ? "pause.fill" : "play.fill",
                                size: 52, filled: true, fill: source?.color ?? Palette.accent, glyph: source?.glyph ?? .black) {
                    Task { await player.send(.playPause) }
                }
                RoundIconButton(symbol: "forward.fill", size: 38) { Task { await player.send(.next) } }
            }
            if source?.id == MediaSource.spotify.id {
                RoundIconButton(symbol: "iphone.radiowaves.left.and.right", size: 38) { player.showDevices = true }
            }
            if source != nil {
                RoundIconButton(symbol: "quote.bubble", size: 38, filled: player.showLyrics, fill: Palette.selected, glyph: .white) {
                    player.showLyrics.toggle()
                }
            }
        }
    }

    // MARK: Ничего не играет

}

/// Обложка трека: пока её нет или она грузится, стоит тёмная плитка с нотой.
struct CoverArt: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.07).fill(Palette.card)
            Image(systemName: "music.note").font(.system(size: size * 0.28)).foregroundStyle(Color(white: 0.28))
            if let image {
                Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.07))
        .overlay(RoundedRectangle(cornerRadius: size * 0.07).stroke(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.6), radius: 16, y: 8)
    }
}

/// Таймлайн: тянется за любую точку полосы, позиция идёт сама между опросами плеера.
struct SeekBar: View {
    let track: NowPlaying
    let onSeek: (Double) -> Void
    @State private var scrub: Double?

    var body: some View {
        let duration = track.duration ?? 0
        TimelineView(.animation(minimumInterval: 0.25)) { context in
            let value = scrub ?? track.position(at: context.date)
            let fraction = duration > 0 ? min(1, value / duration) : 0
            VStack(spacing: 2) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16)).frame(height: 4)
                        Capsule().fill(track.source.color).frame(width: max(4, proxy.size.width * fraction), height: 4)
                        Circle().fill(Color.white)
                            .frame(width: scrub == nil ? 10 : 14, height: scrub == nil ? 10 : 14)
                            .offset(x: proxy.size.width * fraction - (scrub == nil ? 5 : 7))
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { scrub = Self.seconds(at: $0.location.x, width: proxy.size.width, duration: duration) }
                            .onEnded { drag in
                                let target = Self.seconds(at: drag.location.x, width: proxy.size.width, duration: duration)
                                // Сначала новая позиция уходит плееру, потом ползунок отпускается: без промежуточного кадра со старым временем.
                                onSeek(target)
                                scrub = nil
                            }
                    )
                }
                .frame(height: 22)
                HStack {
                    Text(Self.format(value))
                    Spacer()
                    Text(Self.format(duration))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.muted)
            }
        }
    }

    static func seconds(at x: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard width > 0 else { return 0 }
        return Double(max(0, min(1, x / width))) * duration
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: Телесуфлёр

struct TeleprompterPanel: View {
    let model: IslandModel
    let store: TeleprompterStore
    var dictation: Dictation = .shared
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: Bindable(store).text)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .padding(8)
                    if store.text.isEmpty {
                        Text("Вставьте или продиктуйте текст выступления.")
                            .font(.system(size: 13)).foregroundStyle(Palette.muted)
                            .padding(.horizontal, 13).padding(.top, 8).allowsHitTesting(false)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(focused ? Palette.accent : Palette.cardBorder))
                HStack(spacing: 8) {
                    RoundIconButton(symbol: dictation.isListening ? "mic.fill" : "mic", size: 30,
                                    tint: dictation.isListening ? AgentState.error.color : .white) {
                        dictation.toggle(current: store.text) { store.text = $0 }
                    }
                    if case .failed(let message) = dictation.state {
                        Text(message).font(.system(size: 11)).foregroundStyle(AgentState.waiting.color).lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: 300)
            VStack(alignment: .leading, spacing: 8) {
                viewport
                controls
            }
            .frame(maxWidth: .infinity)
        }
        .onChange(of: focused) { _, value in
            model.keepOpen = value
            if value { IslandController.shared.focusForTyping() }
        }
        .onDisappear {
            model.keepOpen = false
            store.pause()
            dictation.stop()
        }
    }

    private var viewport: some View {
        GeometryReader { proxy in
            Text(store.text.isEmpty ? " " : store.text)
                .font(.system(size: store.fontSize, weight: .medium))
                .multilineTextAlignment(.leading)
                .frame(width: proxy.size.width - 24, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { text in
                    Color.clear
                        .onAppear { store.contentHeight = text.size.height }
                        .onChange(of: text.size.height) { _, height in store.contentHeight = height }
                })
                .offset(x: 12, y: proxy.size.height * 0.3 - store.offset)
                .scaleEffect(x: store.mirrored ? -1 : 1, y: 1)
        }
        .frame(height: 150)
        .clipped()
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
        .overlay(alignment: .topLeading) {
            // Полоска у левого края стоит там, где текст начинает появляться: эту строку и читают.
            Rectangle().fill(Palette.accent).frame(width: 3, height: 26).padding(.top, 150 * 0.3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.cardBorder))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundIconButton(symbol: store.isRunning ? "pause.fill" : "play.fill", size: 38, filled: true) { store.toggle() }
                RoundIconButton(symbol: "backward.end.fill", size: 30) { store.rewind() }
                Toggle("Зеркало", isOn: Bindable(store).mirrored).toggleStyle(.switch).controlSize(.small)
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 8) {
                Text("Скорость").font(.system(size: 11.5)).foregroundStyle(Palette.muted).frame(width: 66, alignment: .leading)
                Slider(value: Bindable(store).speed, in: 10...150)
                Text("\(Int(store.speed))").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Palette.muted).frame(width: 28)
            }
            HStack(spacing: 8) {
                Text("Размер").font(.system(size: 11.5)).foregroundStyle(Palette.muted).frame(width: 66, alignment: .leading)
                Slider(value: Bindable(store).fontSize, in: 16...60)
                Text("\(Int(store.fontSize))").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Palette.muted).frame(width: 28)
            }
        }
    }
}

// MARK: Заметки

struct NotesPanel: View {
    let model: IslandModel
    let store: NotesStore
    var dictation: Dictation = .shared
    @State private var selected: UUID?
    @State private var confirmDelete = false
    @FocusState private var focused: Bool

    var body: some View {
        let current = store.note(selected) ?? store.ordered.first
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Button("Новая заметка") {
                    selected = store.add().id
                    focused = true
                }
                .buttonStyle(VisorButtonStyle(kind: .primary))
                VScroll {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.ordered) { note in row(note, isCurrent: note.id == current?.id) }
                    }
                }
            }
            .frame(width: 230)
            editor(current)
        }
        .onChange(of: focused) { _, value in
            model.keepOpen = value
            if value { IslandController.shared.focusForTyping() }
        }
        .onDisappear {
            model.keepOpen = false
            dictation.stop()
        }
    }

    private func row(_ note: Note, isCurrent: Bool) -> some View {
        Button {
            selected = note.id
            confirmDelete = false
        } label: {
            HStack(spacing: 6) {
                if note.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Palette.accent) }
                Text(note.title).font(.system(size: 12.5)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isCurrent ? Palette.selected : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func editor(_ current: Note?) -> some View {
        if let note = current {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: Binding(get: { store.note(note.id)?.body ?? "" }, set: { store.update(note.id, body: $0) }))
                    .font(.system(size: 13.5))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(focused ? Palette.accent : Palette.cardBorder))
                HStack(spacing: 8) {
                    RoundIconButton(symbol: dictation.isListening ? "mic.fill" : "mic", size: 30,
                                    tint: dictation.isListening ? AgentState.error.color : .white) {
                        dictation.toggle(current: store.note(note.id)?.body ?? "") { store.update(note.id, body: $0) }
                    }
                    Button(note.pinned ? "Открепить" : "Закрепить") { store.togglePin(note.id) }.buttonStyle(VisorButtonStyle())
                    Button(confirmDelete ? "Точно удалить?" : "Удалить") {
                        if confirmDelete {
                            confirmDelete = false
                            selected = nil
                            store.delete(note.id)
                        } else {
                            confirmDelete = true
                        }
                    }
                    .buttonStyle(VisorButtonStyle(kind: confirmDelete ? .danger : .normal))
                    if case .failed(let message) = dictation.state {
                        Text(message).font(.system(size: 11)).foregroundStyle(AgentState.waiting.color).lineLimit(2)
                    }
                }
            }
        } else {
            DevCard(title: "Заметки") {
                Text("Заметок пока нет. Нажмите «Новая заметка».").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
            }
        }
    }
}


/// Текст песни: строка, которая звучит, подсвечена и держится по центру; без отметок времени текст листается пальцем.
struct LyricsView: View {
    let track: NowPlaying
    var size: CGFloat = 14
    var centered = false
    private let store = LyricsStore.shared

    var body: some View {
        Group {
            switch store.state {
            case .idle, .loading:
                note("Ищу текст…")
            case .missing:
                note("Текста этой песни нет в каталоге.")
            case .failed:
                note("Не получилось загрузить текст. Проверьте интернет.")
            case .found:
                if store.isSynced { synced } else { plain }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: centered ? .top : .topLeading)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Palette.muted)
    }

    private var synced: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let active = LRC.activeIndex(store.lines, at: track.position(at: context.date))
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: centered ? .center : .leading, spacing: 7) {
                        ForEach(Array(store.lines.enumerated()), id: \.offset) { index, line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .multilineTextAlignment(centered ? .center : .leading)
                                .font(.system(size: size, weight: index == active ? .semibold : .regular))
                                .foregroundStyle(index == active ? Palette.text : Palette.muted.opacity(0.7))
                                .contentShape(Rectangle())
                                // Нажатие на строку перематывает песню к ней, если плеер умеет перемотку.
                                .onTapGesture {
                                    guard track.canSeek, let time = line.time else { return }
                                    PlayerController.shared.seek(to: time)
                                }
                                .id(index)
                        }
                    }
                    .padding(.vertical, 40)
                }
                .onChange(of: active) { _, index in
                    guard let index else { return }
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(index, anchor: .center) }
                }
                // При открытии текст сразу встаёт на звучащую строку, а не начинается с первой.
                .onAppear {
                    if let active { proxy.scrollTo(active, anchor: .center) }
                }
            }
        }
    }

    private var plain: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: centered ? .center : .leading, spacing: 4) {
                // Без таймингов строки нельзя привязать к песне: объясняем, почему текст стоит на месте.
                Text("У этой песни в каталоге нет разметки по времени: текст показан целиком, строки не подсвечиваются и не перематывают.")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                    .multilineTextAlignment(centered ? .center : .leading)
                    .padding(.bottom, 6)
                ForEach(Array(store.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text.isEmpty ? " " : line.text).font(.system(size: size - 0.5)).foregroundStyle(Palette.text)
                        .multilineTextAlignment(centered ? .center : .leading)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
