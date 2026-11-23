import AppKit
import Foundation
import Observation

/// Один вариант в выпадающем списке поиска.
struct SearchHit: Identifiable, Equatable, Sendable {
    enum Origin: String, Sendable { case spotify, apple, history, lyrics }

    let id: String
    let title: String
    let artist: String
    let album: String
    let coverURL: URL?
    let origin: Origin
    /// spotify:track:… у результатов Spotify.
    var uri: String?
    /// Страница трека в Apple Music.
    var pageURL: URL?
    /// У истории и поиска по тексту: приложение, где трек играл (MediaSource.id).
    var sourceID: String?
    /// Строка песни, в которой нашёлся запрос.
    var snippet: String?
}

/// Поиск Spotify без входа в аккаунт: токен приложения по Client ID и Client Secret (Client Credentials).
enum SpotifySearch {
    static let idAccount = "spotify.search.id"
    static let secretAccount = "spotify.search.secret"

    static var credentials: (id: String, secret: String)? {
        guard let id = SecretStore.get(idAccount), let secret = SecretStore.get(secretAccount) else { return nil }
        return (id, secret)
    }

    static func tokenRequest(id: String, secret: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Basic " + Data("\(id):\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)
        return request
    }

    static func parseToken(_ data: Data) -> (token: String, lifetime: TimeInterval)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String else { return nil }
        return (token, (object["expires_in"] as? Double) ?? 3600)
    }

    static func searchURL(_ query: String) -> URL? {
        var parts = URLComponents(string: "https://api.spotify.com/v1/search")
        parts?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: "track"),
                             URLQueryItem(name: "limit", value: "8")]
        return parts?.url
    }

    static func parse(_ data: Data) -> [SearchHit] {
        let tracks = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tracks"] as? [String: Any])?["items"] as? [[String: Any]]
        return (tracks ?? []).compactMap { item in
            guard let name = item["name"] as? String, let uri = item["uri"] as? String else { return nil }
            let artists = (item["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
            let album = item["album"] as? [String: Any]
            // картинки идут от большой к маленькой: для строки списка берётся средняя
            let images = album?["images"] as? [[String: Any]] ?? []
            let cover = (images.count > 1 ? images[1] : images.first)?["url"] as? String
            return SearchHit(id: uri, title: name, artist: artists, album: album?["name"] as? String ?? "",
                             coverURL: cover.flatMap(URL.init(string:)), origin: .spotify, uri: uri)
        }
    }
}

/// Открытый каталог iTunes: список для Apple Music без ключа.
enum ITunesSearch {
    static func searchURL(_ query: String) -> URL? {
        var parts = URLComponents(string: "https://itunes.apple.com/search")
        parts?.queryItems = [URLQueryItem(name: "term", value: query), URLQueryItem(name: "media", value: "music"),
                             URLQueryItem(name: "entity", value: "song"), URLQueryItem(name: "limit", value: "8")]
        return parts?.url
    }

    static func parse(_ data: Data) -> [SearchHit] {
        let results = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]]
        return (results ?? []).compactMap { item in
            guard let name = item["trackName"] as? String else { return nil }
            let id = (item["trackId"] as? Int).map(String.init) ?? name
            return SearchHit(id: "apple:\(id)", title: name, artist: item["artistName"] as? String ?? "",
                             album: item["collectionName"] as? String ?? "",
                             coverURL: (item["artworkUrl60"] as? String).flatMap(URL.init(string:)), origin: .apple,
                             pageURL: (item["trackViewUrl"] as? String).flatMap(URL.init(string:)))
        }
    }
}

/// Что слушали: название, откуда играло и текст песни для поиска по строчке.
struct HistoryEntry: Codable, Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var sourceID: String
    var lyrics: String?
    var date: Date

    var key: String { "\(title)|\(artist)" }
}

@MainActor @Observable
final class ListeningHistory {
    static let shared = ListeningHistory()
    static let limit = 300
    static let lyricsLimit = 5000

    private(set) var entries: [HistoryEntry] = []
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var lyricsTasks: [String: Task<Void, Never>] = [:]

    init(file: URL = VisorPaths.supportDir.appendingPathComponent("listening-history.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    /// Новый трек попадает в начало; повтор только поднимает его наверх. Текст песни докачивается в фоне, чтобы по нему искать.
    func record(_ track: NowPlaying, fetchLyrics: Bool = true) {
        guard !track.title.isEmpty, track.source.id != MediaSource.yandexApp.id || !track.artist.isEmpty else { return }
        let key = track.trackKey
        var entry = entries.first { $0.key == key }
            ?? HistoryEntry(title: track.title, artist: track.artist, album: track.album, sourceID: track.source.id, lyrics: nil, date: Date())
        entry.date = Date()
        entry.sourceID = track.source.id
        entries.removeAll { $0.key == key }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
        guard fetchLyrics, entry.lyrics == nil, lyricsTasks[key] == nil else { return }
        lyricsTasks[key] = Task { [weak self] in
            let result = await LyricsStore.fetch(title: track.title, artist: track.artist, album: track.album, duration: track.duration)
            guard let self else { return }
            self.lyricsTasks[key] = nil
            if case .success(let lines) = result { self.setLyrics(lines, for: key) }
        }
    }

    func setLyrics(_ lines: [LyricLine], for key: String) {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return }
        let text = lines.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        // пустая строка отличает «текста нет» от «ещё не искали»
        entries[index].lyrics = String(text.prefix(Self.lyricsLimit))
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }

    /// Совпадения по названию и артисту (история) и по строчке из текста. Без различия регистра и диакритики.
    func search(_ query: String, sourceID: String? = nil, limit: Int = 4) -> [SearchHit] {
        func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard needle.count >= 2 else { return [] }
        var byName: [SearchHit] = []
        var byText: [SearchHit] = []
        for entry in entries where sourceID == nil || entry.sourceID == sourceID {
            if fold(entry.title).contains(needle) || fold(entry.artist).contains(needle) {
                if byName.count < limit { byName.append(hit(entry, origin: .history, snippet: nil)) }
            } else if byText.count < limit, let lyrics = entry.lyrics,
                      let line = lyrics.split(separator: "\n").first(where: { fold(String($0)).contains(needle) }) {
                byText.append(hit(entry, origin: .lyrics, snippet: String(line)))
            }
        }
        return byName + byText
    }

    private func hit(_ entry: HistoryEntry, origin: SearchHit.Origin, snippet: String?) -> SearchHit {
        SearchHit(id: "\(origin.rawValue):\(entry.key)", title: entry.title, artist: entry.artist, album: entry.album,
                  coverURL: nil, origin: origin, sourceID: entry.sourceID, snippet: snippet)
    }
}

enum SearchStatus: Equatable {
    case idle, searching, done
}

/// Строка поиска плеера: Spotify и Apple Music отвечают списком, остальные приложения открываются на странице поиска.
@MainActor @Observable
final class MusicSearchModel {
    static let shared = MusicSearchModel()

    var query = ""
    var hits: [SearchHit] = []
    var status: SearchStatus = .idle
    /// Подсказки об ошибках отдельных источников: «Spotify не принял ключи».
    var notes: [String] = []
    var spotifyConnected: Bool
    /// Форма ввода Client ID и Secret раскрыта.
    var showSetup = false
    var message: String?
    /// Строка списка, выбранная стрелками.
    var selected: Int?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token: (value: String, expires: Date)?
    @ObservationIgnored private let history: ListeningHistory
    @ObservationIgnored private let session: URLSession

    init(history: ListeningHistory = .shared, session: URLSession = .shared) {
        self.history = history
        self.session = session
        spotifyConnected = SpotifySearch.credentials != nil
    }

    /// Выпадающий список открыт: остров не закрывается, пока вы выбираете.
    var isOpen: Bool { !trimmed.isEmpty || showSetup || message != nil }
    var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Ввод

    func update(_ text: String) {
        query = text
        message = nil
        selected = nil
        task?.cancel()
        guard trimmed.count >= 2 else {
            hits = []; notes = []; status = .idle
            return
        }
        status = .searching
        let text = trimmed
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            await self.run(text)
        }
    }

    func clear() {
        task?.cancel()
        query = ""; hits = []; notes = []; status = .idle; showSetup = false; message = nil; selected = nil
    }

    /// Стрелки вверх и вниз по списку; с конца и с начала список замыкается.
    func moveSelection(_ step: Int) {
        guard !hits.isEmpty else { return }
        guard let current = selected, hits.indices.contains(current) else {
            selected = step > 0 ? 0 : hits.count - 1
            return
        }
        selected = (current + step + hits.count) % hits.count
    }

    /// Enter: играет выбранную строку, а если ничего не выбрано, то первую.
    func playSelected() {
        guard !hits.isEmpty else { return }
        let index = selected.flatMap { hits.indices.contains($0) ? $0 : nil } ?? 0
        let hit = hits[index]
        Task { await play(hit) }
    }

    /// Приложение, которое сейчас в плеере: поиск идёт только в нём. Если ничего не играет, берётся то, что слушали последним.
    var activeSource: MediaSource {
        if let source = PlayerController.shared.nowPlaying?.source { return source }
        switch history.entries.first?.sourceID {
        case MediaSource.appleMusic.id: return .appleMusic
        default: return .spotify
        }
    }

    func run(_ text: String) async {
        let source = activeSource
        var found: [SearchHit] = []
        var problems: [String] = []
        let result: Result<[SearchHit], SourceError>
        switch source.id {
        case MediaSource.spotify.id: result = await searchSpotify(text)
        case MediaSource.appleMusic.id: result = await searchApple(text)
        default: result = .success([])
        }
        guard !Task.isCancelled, text == trimmed else { return }
        switch result {
        case .success(let list): found = list
        case .failure(let error): problems.append(error.text)
        }
        hits = found + history.search(text, sourceID: source.id)
        notes = problems
        status = .done
    }

    // MARK: Spotify

    struct SourceError: Error { let text: String }

    func saveSpotify(id: String, secret: String) async {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { message = "Нужны оба значения: Client ID и Client Secret."; return }
        do {
            _ = try await fetchToken(id: id, secret: secret)
        } catch let error as SourceError {
            message = error.text
            return
        } catch {
            message = "Нет ответа от Spotify: \(error.localizedDescription)"
            return
        }
        SecretStore.set(id, account: SpotifySearch.idAccount)
        SecretStore.set(secret, account: SpotifySearch.secretAccount)
        spotifyConnected = true
        showSetup = false
        message = nil
        if trimmed.count >= 2 { update(query) }
    }

    func disconnectSpotify() {
        SecretStore.delete(SpotifySearch.idAccount)
        SecretStore.delete(SpotifySearch.secretAccount)
        token = nil
        spotifyConnected = false
    }

    private func fetchToken(id: String, secret: String) async throws -> String {
        let (data, response) = try await session.data(for: SpotifySearch.tokenRequest(id: id, secret: secret))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let parsed = SpotifySearch.parseToken(data) else {
            if status == 400 || status == 401 { throw SourceError(text: "Spotify не принял Client ID или Client Secret. Проверьте, что скопировали оба целиком.") }
            throw SourceError(text: "Spotify ответил кодом \(status) на запрос ключа.")
        }
        token = (parsed.token, Date().addingTimeInterval(parsed.lifetime - 60))
        return parsed.token
    }

    private func spotifyToken() async throws -> String {
        if let token, token.expires > Date() { return token.value }
        guard let credentials = SpotifySearch.credentials else { throw SourceError(text: "") }
        return try await fetchToken(id: credentials.id, secret: credentials.secret)
    }

    private func searchSpotify(_ text: String) async -> Result<[SearchHit], SourceError> {
        guard spotifyConnected else { return .success([]) }
        do {
            let token = try await spotifyToken()
            guard let url = SpotifySearch.searchURL(text) else { return .success([]) }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return .success(SpotifySearch.parse(data))
            case 401: self.token = nil; return .failure(SourceError(text: "Spotify: ключ устарел, повторите поиск."))
            case 429: return .failure(SourceError(text: "Spotify: слишком много запросов, подождите минуту."))
            default: return .failure(SourceError(text: "Spotify ответил кодом \(code)."))
            }
        } catch let error as SourceError {
            return .failure(error)
        } catch {
            return .failure(SourceError(text: "Spotify не отвечает: проверьте интернет."))
        }
    }

    // MARK: Apple Music

    private func searchApple(_ text: String) async -> Result<[SearchHit], SourceError> {
        guard let url = ITunesSearch.searchURL(text) else { return .success([]) }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failure(SourceError(text: "Поиск Apple Music не ответил.")) }
            return .success(ITunesSearch.parse(data))
        } catch {
            return .failure(SourceError(text: "Поиск Apple Music не отвечает: проверьте интернет."))
        }
    }

    // MARK: Запуск

    /// Страница поиска на сайте сервиса для приложений, где нет списка (Яндекс Музыка и другие).
    nonisolated static func webSearchURL(sourceID: String, query: String) -> URL? {
        let base: String
        switch sourceID {
        case "yandex-app", "web-yandex": base = "https://music.yandex.ru/search?text="
        case "web-ytmusic": base = "https://music.youtube.com/search?q="
        case "web-soundcloud": base = "https://soundcloud.com/search?q="
        case "web-vk": base = "https://vk.com/audio?q="
        case "web-deezer": base = "https://www.deezer.com/search/"
        case "web-tidal": base = "https://tidal.com/search?q="
        case "web-spotify": base = "https://open.spotify.com/search/"
        case "web-apple": base = "https://music.apple.com/search?term="
        default: return nil
        }
        return query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap { URL(string: base + $0) }
    }

    /// Ссылка Apple Music со схемой music://: открывается сразу в приложении «Музыка», а не в браузере.
    nonisolated static func musicAppURL(_ page: URL) -> URL {
        var parts = URLComponents(url: page, resolvingAgainstBaseURL: false)
        if parts?.host == "music.apple.com" || parts?.host == "itunes.apple.com" { parts?.scheme = "music" }
        return parts?.url ?? page
    }

    /// Запускает приложение, если оно закрыто, не выводя его на передний план, и ждёт, пока оно начнёт отвечать.
    static func launchInBackground(_ bundleID: String?) async {
        guard let bundleID, NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<40 {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(2)) // приложению нужно время принять команды
    }

    /// Строка AppleScript в кавычках: обратная косая и кавычки экранируются.
    nonisolated static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func play(_ hit: SearchHit) async {
        message = nil
        var target = hit
        // История и поиск по тексту не знают адреса трека: он берётся из поиска по названию и артисту.
        if hit.origin == .history || hit.origin == .lyrics {
            let phrase = "\(hit.title) \(hit.artist)"
            switch hit.sourceID {
            case MediaSource.spotify.id:
                if case .success(let list) = await searchSpotify(phrase), let first = list.first { target = first }
            case MediaSource.appleMusic.id:
                if case .success(let list) = await searchApple(phrase), let first = list.first { target = first }
            default:
                if let id = hit.sourceID, let url = Self.webSearchURL(sourceID: id, query: phrase) {
                    NSWorkspace.shared.open(url)
                    clear()
                    return
                }
            }
            if target.origin == .history || target.origin == .lyrics {
                message = "Не нашёл «\(hit.title)» в этом сервисе."
                return
            }
        }
        switch target.origin {
        case .spotify:
            guard let uri = target.uri, uri.hasPrefix("spotify:track:") else { return }
            await Self.launchInBackground(MediaSource.spotify.bundleID)
            _ = await Shell.run("/usr/bin/osascript", ["-e", "tell application \"Spotify\" to play track \(Self.quoted(uri))"])
        case .apple:
            await Self.launchInBackground(MediaSource.appleMusic.bundleID)
            let script = """
            tell application "Music"
                set found to (every track of library playlist 1 whose name is \(Self.quoted(target.title)) and artist is \(Self.quoted(target.artist)))
                if (count of found) > 0 then
                    play (item 1 of found)
                    return "ok"
                end if
                return "none"
            end tell
            """
            let output = await Shell.run("/usr/bin/osascript", ["-e", script])
            if output?.contains("ok") != true {
                if let page = target.pageURL {
                    // страница открывается за другими окнами: Visor остаётся на переднем плане
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = false
                    _ = try? await NSWorkspace.shared.open(Self.musicAppURL(page), configuration: configuration)
                }
                message = "Трека нет в вашей медиатеке, Apple Music не умеет включать такие треки сам. Страница открыта в «Музыке» позади."
                return
            }
        case .history, .lyrics:
            return
        }
        clear()
        try? await Task.sleep(for: .milliseconds(700))
        await PlayerController.shared.refresh()
    }

    func openWebSearch(sourceID: String) {
        guard let url = Self.webSearchURL(sourceID: sourceID, query: trimmed) else { return }
        NSWorkspace.shared.open(url)
        clear()
    }
}
