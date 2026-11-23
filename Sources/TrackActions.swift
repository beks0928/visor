import AppKit
import SwiftUI

enum SpotifyID {
    /// «spotify:track:6rqhFgbbKwnb9MLmUQDhG6» → «6rqhFgbbKwnb9MLmUQDhG6». Подкасты и локальные файлы дают nil.
    static func from(_ uri: String) -> String? {
        let parts = uri.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "track", !parts[2].isEmpty else { return nil }
        return String(parts[2])
    }

    /// Адрес песни для запросов библиотеки (с февраля 2026 Spotify принимает только `uris`): двоеточия кодируются.
    static func uri(_ id: String) -> String { "spotify%3Atrack%3A\(id)" }
}

struct PlaylistRef: Identifiable, Equatable {
    let id: String
    let name: String
    /// Версия плейлиста у Spotify: пока она та же, состав не перечитывается.
    var snapshot: String?
}

/// Лайк, плейлист, перемешивание и ссылка для играющей песни. Spotify работает через его сайт-API (нужен вход в Visor),
/// Музыка через AppleScript. У остальных сервисов (сайты, Яндекс Музыка) такого управления снаружи нет.
@MainActor @Observable
final class TrackActions {
    static let shared = TrackActions()

    var liked = false
    var shuffling = false
    var playlists: [PlaylistRef] = []
    /// В каких плейлистах уже есть песни: номер плейлиста → номера песен. Заполняется в фоне после списка плейлистов.
    private(set) var membership: [String: Set<String>] = [:]
    @ObservationIgnored private var membershipSnapshots: [String: String] = [:]

    /// Песня уже лежит в этом плейлисте.
    func contains(_ track: NowPlaying, in playlist: PlaylistRef) -> Bool {
        guard let id = track.trackID else { return false }
        return membership[playlist.id]?.contains(id) == true
    }

    /// Песня есть хотя бы в одном плейлисте.
    func isInAnyPlaylist(_ track: NowPlaying) -> Bool { playlists.contains { contains(track, in: $0) } }

    /// Номера песен и признак «есть следующая страница» из ответа `GET /playlists/{id}/items`.
    nonisolated static func parsePlaylistItems(_ data: Data) -> (ids: [String], hasNext: Bool)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else { return nil }
        let ids = items.compactMap { entry -> String? in
            ((entry["item"] ?? entry["track"]) as? [String: Any])?["id"] as? String
        }
        return (ids, object["next"] is String)
    }

    /// Читает состав плейлистов (до 10 страниц по 50 песен). Плейлист, у которого не менялась версия, не перечитывается.
    private func loadMembership(force: Bool) async {
        for list in playlists {
            if !force, let snapshot = list.snapshot, membershipSnapshots[list.id] == snapshot, membership[list.id] != nil { continue }
            var ids = Set<String>()
            var offset = 0
            var complete = false
            for _ in 0..<10 {
                guard let (code, data) = await spotify("GET", "/playlists/\(list.id)/items?limit=50&offset=\(offset)", quiet: true), code == 200,
                      let page = Self.parsePlaylistItems(data) else { break }
                ids.formUnion(page.ids)
                offset += 50
                if !page.hasNext { complete = true; break }
            }
            membership[list.id] = ids
            if complete, let snapshot = list.snapshot { membershipSnapshots[list.id] = snapshot }
        }
    }
    /// Итог последнего действия. Сообщение «готово» гаснет через секунду, ошибка через несколько секунд, а просьба войти остаётся.
    var message: String? {
        didSet {
            clearTask?.cancel()
            guard message != nil else { return }
            let seconds = TrackActions.lifetime(of: message)
            clearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, !Task.isCancelled, !needsLogin else { return }
                message = nil
            }
        }
    }
    /// Сколько секунд висит сообщение: итог удачного действия коротко, ошибка дольше, чтобы её успели прочитать.
    nonisolated static func lifetime(of message: String?) -> Double {
        let done = ["Добавлено", "Убрано", "Ссылка на песню", "Вход выполнен", "Играет на"]
        return done.contains { message?.hasPrefix($0) == true } ? 1 : 6
    }

    /// Нужен вход в Spotify (или новый вход, чтобы выдать права на лайки и плейлисты).
    var needsLogin = false
    var busy = false

    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var stateKey = ""
    @ObservationIgnored private var meID: String?
    @ObservationIgnored private var playlistsLoaded: (service: String, at: Date)?

    /// Права Spotify, без которых лайки и плейлисты не работают.
    static let neededScopes = ["user-library-read", "user-library-modify", "playlist-read-private",
                               "playlist-modify-private", "playlist-modify-public"]

    private func isSpotify(_ track: NowPlaying) -> Bool { track.source.id == MediaSource.spotify.id }
    private func isApple(_ track: NowPlaying) -> Bool { track.source.id == MediaSource.appleMusic.id }

    /// Действия доступны для Spotify (песня с номером) и Музыки.
    func supports(_ track: NowPlaying) -> Bool { (isSpotify(track) && track.trackID != nil) || isApple(track) }
    func canLink(_ track: NowPlaying) -> Bool { isSpotify(track) && track.trackID != nil }

    // MARK: Помощники

    private func osascript(_ app: String, _ expression: String) async -> String? {
        let output = await Shell.run("/usr/bin/osascript", ["-e", "tell application \"\(app)\" to \(expression)"])
        return output?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Запрос в Spotify. nil: ответа нет, причина уже в `message`.
    private func spotify(_ method: String, _ path: String, body: Data? = nil, quiet: Bool = false) async -> (Int, Data)? {
        guard SpotifyConnect.shared.signedIn else {
            if !quiet { message = "Войдите в Spotify, чтобы лайкать песни и добавлять их в плейлисты."; needsLogin = true }
            return nil
        }
        do {
            let result = try await SpotifyConnect.shared.call(method, path, body: body)
            if result.0 == 401 || result.0 == 403 {
                if !quiet {
                    let missing = SpotifyConnect.shared.missingScopes(Self.neededScopes)
                    if !missing.isEmpty {
                        message = "Spotify не выдал права на лайки и плейлисты. Нажмите «Войти в Spotify» и в окне согласия подтвердите все пункты."
                        needsLogin = true
                    } else if result.0 == 401 {
                        message = "Вход в Spotify устарел: войдите заново."
                        needsLogin = true
                    } else {
                        // Права выданы, а Spotify отказывает: новый вход не поможет, поэтому «Войти» не предлагается.
                        message = "Spotify отказал (\(result.0)): \(SpotifyConnect.errorMessage(result.1) ?? "без пояснения"). Подробности в spotify.log."
                    }
                }
                return nil
            }
            return result
        } catch {
            if !quiet { message = "Нет ответа от Spotify: проверьте интернет." }
            return nil
        }
    }

    private func local(_ track: NowPlaying) -> String? {
        isSpotify(track) ? (track.device == nil ? "Spotify" : nil) : (isApple(track) ? "Music" : nil)
    }

    // MARK: Состояние песни

    /// Читает, лайкнута ли песня и включено ли перемешивание. Один раз на песню, если не просили заново.
    func refresh(for track: NowPlaying, force: Bool = false) async {
        guard supports(track) else { return }
        let key = track.trackKey
        guard force || key != stateKey else { return }
        stateKey = key
        message = nil
        needsLogin = false
        liked = false
        shuffling = false
        if isSpotify(track), let id = track.trackID {
            if let (code, data) = await spotify("GET", "/me/library/contains?uris=\(SpotifyID.uri(id))", quiet: true), code == 200 {
                liked = ((try? JSONSerialization.jsonObject(with: data) as? [Bool])?.first) ?? false
            }
            if local(track) != nil { shuffling = await osascript("Spotify", "return shuffling") == "true" }
        } else if isApple(track) {
            liked = await osascript("Music", "return favorited of current track") == "true"
            shuffling = await osascript("Music", "return shuffle enabled") == "true"
        }
    }

    // MARK: Действия

    func toggleLike(_ track: NowPlaying) async {
        guard supports(track), !busy else { return }
        busy = true
        defer { busy = false }
        message = nil
        let want = !liked
        if isSpotify(track), let id = track.trackID {
            guard let (code, _) = await spotify(want ? "PUT" : "DELETE", "/me/library?uris=\(SpotifyID.uri(id))") else { return }
            if (200...204).contains(code) {
                liked = want
                message = want ? "Добавлено в «Любимые треки»." : "Убрано из любимых."
            } else {
                message = "Spotify ответил кодом \(code)."
            }
        } else if isApple(track) {
            _ = await osascript("Music", "set favorited of current track to \(want)")
            let now = await osascript("Music", "return favorited of current track") == "true"
            if now == want {
                liked = want
                message = want ? "Добавлено в «Любимые»." : "Убрано из любимых."
            } else {
                message = "Музыка не приняла лайк. Для песен вне вашей медиатеки сначала добавьте песню в медиатеку."
            }
        }
    }

    /// Список плейлистов запоминается на две минуты: меню на главном экране и в виде обложки не дёргают сеть при каждой песне.
    func loadPlaylists(for track: NowPlaying, force: Bool = false) async {
        guard supports(track) else { playlists = []; return }
        if !force, let loaded = playlistsLoaded, loaded.service == track.source.id,
           Date().timeIntervalSince(loaded.at) < 120, !playlists.isEmpty { return }
        playlists = []
        defer { playlistsLoaded = (track.source.id, Date()) }
        if isSpotify(track) {
            guard SpotifyConnect.shared.signedIn else { needsLogin = true; return }
            if meID == nil, let (code, data) = await spotify("GET", "/me", quiet: true), code == 200 {
                meID = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
            }
            guard let (code, data) = await spotify("GET", "/me/playlists?limit=50", quiet: true), code == 200,
                  let list = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"] as? [[String: Any]] else { return }
            // Добавлять песни можно только в свои плейлисты и в общие.
            playlists = list.compactMap { item in
                guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                let owner = (item["owner"] as? [String: Any])?["id"] as? String
                guard owner == meID || item["collaborative"] as? Bool == true else { return nil }
                return PlaylistRef(id: id, name: name, snapshot: item["snapshot_id"] as? String)
            }
            Task { await loadMembership(force: force) }
        } else if isApple(track) {
            let script = """
            tell application "Music" to set names to name of user playlists
            set AppleScript's text item delimiters to linefeed
            return names as text
            """
            let output = await Shell.run("/usr/bin/osascript", ["-e", script]) ?? ""
            playlists = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.map { PlaylistRef(id: $0, name: $0) }
        }
    }

    func add(_ track: NowPlaying, to playlist: PlaylistRef) async {
        guard supports(track), !busy else { return }
        busy = true
        defer { busy = false }
        message = nil
        if isSpotify(track), let id = track.trackID {
            let body = try? JSONSerialization.data(withJSONObject: ["uris": ["spotify:track:\(id)"]])
            guard let (code, _) = await spotify("POST", "/playlists/\(playlist.id)/items", body: body) else { return }
            if (200...201).contains(code) {
                membership[playlist.id, default: []].insert(id)
                membershipSnapshots[playlist.id] = nil
                message = "Добавлено в «\(playlist.name)»."
            } else {
                message = "Spotify ответил кодом \(code)."
            }
        } else if isApple(track) {
            let script = "tell application \"Music\" to duplicate current track to playlist \(MusicSearchModel.quoted(playlist.name))\nreturn \"ok\""
            let output = await Shell.run("/usr/bin/osascript", ["-e", script])
            message = output?.contains("ok") == true ? "Добавлено в «\(playlist.name)»."
                : "Не получилось добавить: песня должна быть в вашей медиатеке Музыки."
        }
    }

    /// Убирает песню из плейлиста (Spotify). Остальные песни и сам плейлист не меняются.
    func remove(_ track: NowPlaying, from playlist: PlaylistRef) async {
        guard isSpotify(track), let id = track.trackID, !busy else { return }
        busy = true
        defer { busy = false }
        message = nil
        let body = try? JSONSerialization.data(withJSONObject: ["items": [["uri": "spotify:track:\(id)"]]])
        guard let (code, _) = await spotify("DELETE", "/playlists/\(playlist.id)/items", body: body) else { return }
        if (200...204).contains(code) {
            membership[playlist.id]?.remove(id)
            membershipSnapshots[playlist.id] = nil
            message = "Убрано из «\(playlist.name)»."
        } else {
            message = "Spotify ответил кодом \(code)."
        }
    }

    func toggleShuffle(_ track: NowPlaying) async {
        guard supports(track), !busy else { return }
        busy = true
        defer { busy = false }
        message = nil
        let want = !shuffling
        if isApple(track) {
            _ = await osascript("Music", "set shuffle enabled to \(want)")
            shuffling = await osascript("Music", "return shuffle enabled") == "true"
        } else if local(track) != nil {
            _ = await osascript("Spotify", "set shuffling to \(want)")
            shuffling = await osascript("Spotify", "return shuffling") == "true"
        } else if let (code, _) = await spotify("PUT", "/me/player/shuffle?state=\(want)") {
            if (200...204).contains(code) { shuffling = want } else { message = "Spotify ответил кодом \(code)." }
        }
    }

    func copyLink(_ track: NowPlaying) {
        guard let id = track.trackID else { return }
        ClipboardStore.shared.copyPlain("https://open.spotify.com/track/\(id)")
        message = "Ссылка на песню скопирована."
    }

    /// Вход в Spotify с новыми правами. Причина неудачи (порт, Redirect URI, отказ) показывается как есть, а не прячется.
    func login(for track: NowPlaying? = nil) async {
        await SpotifyConnect.shared.signIn()
        meID = nil
        stateKey = ""
        playlistsLoaded = nil
        guard SpotifyConnect.shared.signedIn else {
            message = SpotifyConnect.shared.message ?? "Вход не завершён."
            needsLogin = true
            return
        }
        let missing = SpotifyConnect.shared.missingScopes(Self.neededScopes)
        if missing.isEmpty {
            needsLogin = false
            message = "Вход выполнен: лайки и плейлисты доступны."
        } else {
            needsLogin = true
            message = "Spotify выдал не все права (нет: \(missing.joined(separator: ", "))). Войдите ещё раз и подтвердите все пункты."
        }
        if let track {
            // refresh сбрасывает сообщение, а итог входа должен остаться на экране.
            let (result, needs) = (message, needsLogin)
            await refresh(for: track, force: true)
            await loadPlaylists(for: track, force: true)
            message = result
            needsLogin = needs
        }
    }
}

/// Маленькое сердечко для обычного вида плеера.
struct LikeButton: View {
    let track: NowPlaying
    var actions: TrackActions = .shared

    var body: some View {
        Group {
            if actions.supports(track) {
                Button {
                    Task {
                        await actions.toggleLike(track)
                        // Нужен вход: открываем вид обложки, там сообщение и кнопка «Войти в Spotify».
                        if actions.needsLogin { PlayerController.shared.showCover = true }
                    }
                } label: {
                    Image(systemName: actions.liked ? "heart.fill" : "heart")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(actions.liked ? TrackActionBar.heart : Palette.muted)
                        .frame(width: 26, height: 26)
                        .background(Palette.hover, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .help(actions.liked ? "Убрать из любимых" : "Добавить в любимые")
            }
        }
        .task(id: track.trackKey) { await actions.refresh(for: track) }
    }
}

/// Ряд действий для вида с обложкой: лайк, плейлист, перемешивание, ссылка.
struct TrackActionBar: View {
    static let heart = Color(red: 1, green: 0.36, blue: 0.5)

    let track: NowPlaying
    var actions: TrackActions = .shared

    var body: some View {
        VStack(spacing: 8) {
            if actions.supports(track) {
                HStack(spacing: 14) {
                    RoundIconButton(symbol: actions.liked ? "heart.fill" : "heart", size: 38, filled: actions.liked,
                                    fill: Self.heart, glyph: .white) { Task { await actions.toggleLike(track) } }
                        .help(actions.liked ? "Убрать из любимых" : "Добавить в любимые")
                    PlaylistMenu(track: track, size: 38)
                    RoundIconButton(symbol: "shuffle", size: 38, filled: actions.shuffling, fill: Palette.selected, glyph: .white) {
                        Task { await actions.toggleShuffle(track) }
                    }
                    .help("Перемешивание")
                    if actions.canLink(track) {
                        RoundIconButton(symbol: "link", size: 38) { actions.copyLink(track) }.help("Скопировать ссылку на песню")
                    }
                }
            } else {
                Text("Лайк и плейлисты работают для Spotify и Музыки. У этого сервиса управления снаружи нет.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            }
            if let message = actions.message {
                Text(message).font(.system(size: 11.5)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            }
            if actions.needsLogin {
                if actions.message == nil {
                    Text("Чтобы лайкать песни и добавлять их в плейлисты, войдите в Spotify и подтвердите все права.")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                }
                Button(SpotifyConnect.shared.busy ? "Жду входа…" : "Войти в Spotify") { Task { await actions.login(for: track) } }
                    .font(.system(size: 12)).disabled(SpotifyConnect.shared.busy)
            }
        }
        .task(id: track.trackKey) { await actions.refresh(for: track) }
    }
}

/// Меню «добавить в плейлист». Список грузится сам при смене песни и работает и на главном экране, и в виде обложки.
struct PlaylistMenu: View {
    let track: NowPlaying
    var size: CGFloat = 38
    var actions: TrackActions = .shared

    var body: some View {
        Group {
            if actions.supports(track) {
                Menu {
                    if actions.playlists.isEmpty {
                        Text(actions.needsLogin ? "Нужен вход в Spotify" : "Своих плейлистов нет")
                    } else {
                        ForEach(actions.playlists) { list in
                            if actions.contains(track, in: list) {
                                // Песня уже в плейлисте: нажатие убирает её оттуда.
                                Button { Task { await actions.remove(track, from: list) } } label: {
                                    Label("В «\(list.name)». Убрать", systemImage: "checkmark.circle.fill")
                                }
                            } else {
                                Button(list.name) {
                                    Task {
                                        await actions.add(track, to: list)
                                        if actions.needsLogin { PlayerController.shared.showCover = true }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: actions.isInAnyPlaylist(track) ? "text.badge.checkmark" : "text.badge.plus").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: size, height: size).background(Circle().fill(Palette.hover)).contentShape(Circle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(actions.isInAnyPlaylist(track) ? "Песня уже в плейлистах: отмечены галочкой, нажатие убирает" : "Добавить в плейлист")
            }
        }
        .task(id: track.trackKey) { await actions.loadPlaylists(for: track) }
    }
}
