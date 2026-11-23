import AppKit
import Foundation
import Observation
import SwiftUI

/// Откуда играет музыка: свой цвет, значок и способ управления.
struct MediaSource: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let bundleID: String?
    /// Сайт для значка, когда приложения нет.
    let domain: String?
    /// Фирменный цвет, 0xRRGGBB.
    let tint: UInt32
    /// Тёмный значок на кнопке: у светлых цветов (жёлтый, зелёный) читается лучше, чем белый.
    let darkGlyph: Bool
    /// Имя для AppleScript: только у приложений, которые умеют перемотку и точные команды.
    let scriptName: String?
    /// Играет во встроенном окне Visor (WebPlayer): управление и перемотка идут туда.
    var embedded = false

    var color: Color {
        Color(red: Double(tint >> 16 & 255) / 255, green: Double(tint >> 8 & 255) / 255, blue: Double(tint & 255) / 255)
    }

    var glyph: Color { darkGlyph ? .black : .white }
    var canSeek: Bool { scriptName != nil || embedded }

    static let spotify = MediaSource(id: "spotify", name: "Spotify", bundleID: "com.spotify.client", domain: "spotify.com",
                                     tint: 0x1DB954, darkGlyph: true, scriptName: "Spotify")
    static let appleMusic = MediaSource(id: "music", name: "Apple Music", bundleID: "com.apple.Music", domain: "music.apple.com",
                                        tint: 0xFA243C, darkGlyph: false, scriptName: "Music")
    static let yandexApp = MediaSource(id: "yandex-app", name: "Яндекс Музыка", bundleID: nil, domain: "music.yandex.ru",
                                       tint: 0xFFDD00, darkGlyph: true, scriptName: nil)
}

/// Музыкальные сайты, которые ищутся во вкладках браузера.
struct WebService: Sendable {
    let match: String
    let source: MediaSource

    static let all: [WebService] = [
        WebService(match: "music.yandex", source: MediaSource(id: "web-yandex", name: "Яндекс Музыка", bundleID: nil, domain: "music.yandex.ru", tint: 0xFFDD00, darkGlyph: true, scriptName: nil)),
        WebService(match: "music.youtube.com", source: MediaSource(id: "web-ytmusic", name: "YouTube Music", bundleID: nil, domain: "music.youtube.com", tint: 0xFF0033, darkGlyph: false, scriptName: nil)),
        WebService(match: "soundcloud.com", source: MediaSource(id: "web-soundcloud", name: "SoundCloud", bundleID: nil, domain: "soundcloud.com", tint: 0xFF5500, darkGlyph: false, scriptName: nil)),
        WebService(match: "vk.com/audio", source: MediaSource(id: "web-vk", name: "VK Музыка", bundleID: nil, domain: "vk.com", tint: 0x0077FF, darkGlyph: false, scriptName: nil)),
        WebService(match: "vk.com/music", source: MediaSource(id: "web-vk", name: "VK Музыка", bundleID: nil, domain: "vk.com", tint: 0x0077FF, darkGlyph: false, scriptName: nil)),
        WebService(match: "deezer.com", source: MediaSource(id: "web-deezer", name: "Deezer", bundleID: nil, domain: "deezer.com", tint: 0xA238FF, darkGlyph: false, scriptName: nil)),
        WebService(match: "tidal.com", source: MediaSource(id: "web-tidal", name: "Tidal", bundleID: nil, domain: "tidal.com", tint: 0xFFFFFF, darkGlyph: true, scriptName: nil)),
        WebService(match: "open.spotify.com", source: MediaSource(id: "web-spotify", name: "Spotify", bundleID: nil, domain: "spotify.com", tint: 0x1DB954, darkGlyph: true, scriptName: nil)),
        WebService(match: "music.apple.com", source: MediaSource(id: "web-apple", name: "Apple Music", bundleID: nil, domain: "music.apple.com", tint: 0xFA243C, darkGlyph: false, scriptName: nil)),
    ]
}

struct NowPlaying: Equatable, Sendable {
    let source: MediaSource
    let title: String
    let artist: String
    let album: String
    /// Секунды. У сайтов и приложений без скриптов длины и позиции нет.
    let duration: Double?
    let position: Double?
    let artworkURL: URL?
    /// nil: состояние неизвестно (вкладка с музыкой, приложение без скриптов).
    let isPlaying: Bool?
    let fetchedAt: Date
    /// Устройство, на котором песня играет сейчас, если это не этот Mac (телефон в Spotify).
    var device: String? = nil
    /// Номер песни в Spotify (для лайка, плейлистов и ссылки).
    var trackID: String? = nil

    var trackKey: String { "\(title)|\(artist)" }
    var canSeek: Bool { source.canSeek && duration != nil }

    /// Позиция в момент `date`: между опросами она идёт сама, пока трек играет.
    func position(at date: Date) -> Double {
        guard let position else { return 0 }
        let moved = isPlaying == true ? date.timeIntervalSince(fetchedAt) : 0
        return min(duration ?? .infinity, max(0, position + moved))
    }
}

enum MediaCommand: String, Sendable {
    case playPause = "playpause"
    case next = "next track"
    case previous = "previous track"
}

/// Публичный каталог Deezer без ключа: обложки и фото артистов для любого плеера.
enum Deezer {
    static func artistURL(_ name: String) -> URL? {
        var parts = URLComponents(string: "https://api.deezer.com/search/artist")
        parts?.queryItems = [URLQueryItem(name: "q", value: name), URLQueryItem(name: "limit", value: "5")]
        return parts?.url
    }

    static func trackURL(title: String, artist: String) -> URL? {
        var parts = URLComponents(string: "https://api.deezer.com/search")
        parts?.queryItems = [URLQueryItem(name: "q", value: "artist:\"\(artist)\" track:\"\(title)\""), URLQueryItem(name: "limit", value: "1")]
        return parts?.url
    }

    /// Первый артист из строки «A, B & C feat. D»: фото ищется по нему.
    static func primaryArtist(_ text: String) -> String {
        var name = text
        for separator in [", ", " & ", " feat. ", " feat ", " ft. ", " x ", " × ", "; "] {
            if let range = name.range(of: separator, options: .caseInsensitive) { name = String(name[..<range.lowerBound]) }
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Фото артиста, только если имя совпало: иначе Deezer подсунул бы чужого.
    static func parseArtistPicture(_ data: Data, name: String) -> URL? {
        guard let items = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] else { return nil }
        func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let match = items.first { fold($0["name"] as? String ?? "") == fold(name) }
        return (match?["picture_medium"] as? String).flatMap(URL.init(string:))
    }

    static func parseTrackCover(_ data: Data) -> URL? {
        let first = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]])?.first
        return ((first?["album"] as? [String: Any])?["cover_big"] as? String).flatMap(URL.init(string:))
    }
}

/// Что играет, обложка, фото артиста и кнопки управления.
/// Умеют точный статус и перемотку Spotify и Apple Music. Музыка на сайтах (Яндекс, YouTube Music и другие)
/// находится по вкладкам браузера, а управляется клавишами мультимедиа.
@MainActor @Observable
final class PlayerController {
    static let shared = PlayerController()

    var nowPlaying: NowPlaying?
    var cover: NSImage?
    var avatar: NSImage?
    var sourceIcon: NSImage?
    var failure: String?
    /// Страница плеера открыта и опрашивает сама, с сайтами. Фоновый опрос в это время молчит.
    var panelVisible = false
    /// В плеере вместо обычного вида открыта крупная обложка с названием и артистом.
    var showCover = false
    /// В плеере вместо названия показан текст песни.
    var showLyrics = false
    /// Сервис, выбранный кнопкой: если он играет, плеер показывает его, даже когда одновременно играет другой.
    var preferredApp: String?
    /// Вместо трека открыт выбор сервиса.
    var showSources = false
    /// Вместо трека открыт список устройств Spotify (перенос на телефон).
    var showDevices = false

    @ObservationIgnored private var seekHold: (key: String, target: Double, started: Date)?
    @ObservationIgnored private var lastRecordedKey = ""
    /// Источники, игравшие при прошлом опросе.
    @ObservationIgnored private var playingBefore: Set<String> = []
    @ObservationIgnored private var artKey = ""
    @ObservationIgnored private var iconKey = ""
    @ObservationIgnored private var artTask: Task<Void, Never>?
    @ObservationIgnored private let images = NSCache<NSURL, NSImage>()

    static let browsers: [(name: String, bundleID: String, safari: Bool)] = [
        ("Google Chrome", "com.google.Chrome", false), ("Safari", "com.apple.Safari", true),
        ("Yandex", "ru.yandex.desktop.yandex-browser", false), ("Brave Browser", "com.brave.Browser", false),
        ("Microsoft Edge", "com.microsoft.edgemac", false), ("Arc", "company.thebrowser.Browser", false),
    ]

    // MARK: Опрос

    func refresh(includeWeb: Bool = true) async {
        if !includeWeb, panelVisible { return }
        var found: [NowPlaying] = []
        var denied: String?
        for source in [MediaSource.spotify, .appleMusic] where Self.isRunning(source.bundleID) {
            guard let output = await Shell.run("/usr/bin/osascript", ["-e", Self.script(for: source)]) else { continue }
            if output.contains("-1743") || output.lowercased().contains("not authorized") {
                denied = "Разрешите Visor управлять «\(source.name)»: «Конфиденциальность и безопасность» → «Автоматизация»."
            } else if let parsed = Self.parseNative(output, source: source) {
                found.append(parsed)
            }
        }
        if let own = WebPlayer.shared.track { found.append(own) }
        // Песня, которая играет в аккаунте Spotify на телефоне, показывается, пока на этом Mac Spotify молчит.
        if let remote = await SpotifyConnect.shared.remoteTrack(), remote.device != nil {
            let local = found.first { $0.source.id == MediaSource.spotify.id }
            if local?.isPlaying != true, remote.isPlaying == true || local == nil {
                found.removeAll { $0.source.id == MediaSource.spotify.id }
                found.append(remote)
            }
        }
        if includeWeb, let web = await webTrack() { found.append(web) }
        if includeWeb, found.isEmpty, Self.yandexAppRunning {
            found.append(NowPlaying(source: .yandexApp, title: "Яндекс Музыка", artist: "Приложение не сообщает название трека",
                                    album: "", duration: nil, position: nil, artworkURL: nil, isPlaying: nil, fetchedAt: Date()))
        }
        let paused = await pauseSupplanted(found)
        found.removeAll { paused.contains($0.source.id) }
        if let preferredApp, MusicApp.all.first(where: { $0.id == preferredApp })?.sourceIDs.contains(where: paused.contains) == true {
            self.preferredApp = nil
        }
        var chosen: NowPlaying?
        if let preferredApp, let ids = MusicApp.all.first(where: { $0.id == preferredApp })?.sourceIDs {
            let mine = found.filter { ids.contains($0.source.id) }
            chosen = mine.first { $0.isPlaying == true } ?? mine.first
        }
        nowPlaying = applySeekHold(to: chosen ?? found.first { $0.isPlaying == true } ?? found.first)
        if let track = nowPlaying, track.isPlaying != false, track.trackKey != lastRecordedKey {
            lastRecordedKey = track.trackKey
            ListeningHistory.shared.record(track)
        }
        failure = nowPlaying == nil ? denied : nil
        artTask?.cancel()
        artTask = Task { await loadArt(for: nowPlaying) }
    }

    /// Если заиграл второй источник (Spotify, Музыка или окно Visor), прежний ставится на паузу: два трека не мешают друг другу.
    /// Сайты в браузере сюда не входят: у них нет безопасной команды паузы. Возвращает номера источников, которые остановлены.
    private func pauseSupplanted(_ found: [NowPlaying]) async -> Set<String> {
        // Песня на телефоне сюда не входит: Mac ей не управляет через AppleScript.
        let playing = Set(found.filter { $0.isPlaying == true && $0.device == nil && ($0.source.scriptName != nil || $0.source.embedded) }.map(\.source.id))
        let newcomers = playing.subtracting(playingBefore)
        let older = playing.subtracting(newcomers)
        guard playing.count > 1, !newcomers.isEmpty, !older.isEmpty else { playingBefore = playing; return [] }
        for track in found where older.contains(track.source.id) {
            if track.source.embedded {
                WebPlayer.shared.pause()
            } else if let name = track.source.scriptName {
                _ = await Shell.run("/usr/bin/osascript", ["-e", "tell application \"\(name)\" to pause"])
            }
        }
        playingBefore = newcomers
        return older
    }

    /// Название трека для таблетки у выреза, пока вкладка «Плеер» закрыта. Только Музыка и Spotify, раз в 5 секунд,
    /// и только пока хотя бы один из них запущен.
    func startBackgroundPolling() {
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if [MediaSource.spotify, MediaSource.appleMusic].contains(where: { Self.isRunning($0.bundleID) }) || WebPlayer.shared.started
                    || SpotifyConnect.shared.signedIn {
                    await self.refresh(includeWeb: false)
                } else if self.nowPlaying != nil, !self.panelVisible {
                    self.nowPlaying = nil
                }
            }
        }
    }

    /// Команда плееру. Только Spotify и Музыка, и только если приложение уже запущено (`tell` иначе запустило бы его).
    /// Системные клавиши мультимедиа Visor не нажимает: они достаются всем играющим программам сразу
    /// (браузерам, роликам, рекламе), и звук включился бы везде.
    func send(_ command: MediaCommand) async {
        // Песня играет на телефоне: команды идут через Spotify, а не в приложение на Mac.
        if let remote = nowPlaying, remote.device != nil {
            await SpotifyConnect.shared.control(command, isPlaying: remote.isPlaying)
            try? await Task.sleep(for: .milliseconds(600))
            await refresh(includeWeb: false)
            return
        }
        if nowPlaying?.source.embedded == true {
            WebPlayer.shared.send(command)
            try? await Task.sleep(for: .milliseconds(300))
            await WebPlayer.shared.poll()
            await refresh(includeWeb: false)
            return
        }
        guard let source = nowPlaying?.source, let name = source.scriptName, Self.isRunning(source.bundleID) else { return }
        _ = await Shell.run("/usr/bin/osascript", ["-e", "tell application \"\(name)\" to \(command.rawValue)"])
        try? await Task.sleep(for: .milliseconds(300))
        await refresh()
    }

    /// Перемотка. Новая позиция применяется сразу, до ответа плеера, и удерживается, пока плеер её не подтвердит:
    /// иначе очередной опрос вернул бы старое время, и ползунок откатился бы назад перед прыжком.
    func seek(to seconds: Double) {
        guard let (name, target) = beginSeek(to: seconds) else { return }
        if nowPlaying?.device != nil { Task { await SpotifyConnect.shared.seek(to: target) }; return }
        if name.isEmpty { WebPlayer.shared.seek(to: target); return }
        Task { _ = await Shell.run("/usr/bin/osascript", ["-e", "tell application \"\(name)\" to set player position to \(Int(target))"]) }
    }

    /// Применяет новую позицию у себя и возвращает приложение и позицию для команды плееру.
    func beginSeek(to seconds: Double) -> (app: String, target: Double)? {
        guard let track = nowPlaying, let name = track.source.scriptName ?? (track.source.embedded ? "" : nil) else { return nil }
        let target = max(0, min(track.duration ?? seconds, seconds))
        seekHold = (track.trackKey, target, Date())
        nowPlaying = NowPlaying(source: track.source, title: track.title, artist: track.artist, album: track.album,
                                duration: track.duration, position: target, artworkURL: track.artworkURL,
                                isPlaying: track.isPlaying, fetchedAt: Date())
        return (name, target)
    }

    /// Пока плеер не применил перемотку (до 2,5 секунды), его устаревшая позиция заменяется ожидаемой.
    func applySeekHold(to picked: NowPlaying?) -> NowPlaying? {
        guard let hold = seekHold, let picked, picked.trackKey == hold.key else {
            seekHold = nil
            return picked
        }
        let elapsed = Date().timeIntervalSince(hold.started)
        let expected = hold.target + (picked.isPlaying == true ? elapsed : 0)
        guard elapsed < 2.5, let reported = picked.position, abs(reported - expected) > 2 else {
            seekHold = nil
            return picked
        }
        return NowPlaying(source: picked.source, title: picked.title, artist: picked.artist, album: picked.album,
                          duration: picked.duration, position: expected, artworkURL: picked.artworkURL,
                          isPlaying: picked.isPlaying, fetchedAt: Date())
    }

    // MARK: Источники

    static func isRunning(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static var yandexAppRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            let name = ($0.localizedName ?? "").lowercased()
            return name.contains("яндекс музыка") || name.contains("yandex music") || $0.bundleIdentifier?.contains("yandex.desktop.music") == true
        }
    }

    private static func script(for source: MediaSource) -> String {
        let name = source.scriptName ?? ""
        let duration = source == .spotify ? "((duration of current track) / 1000)" : "(duration of current track)"
        let artwork = source == .spotify ? "(artwork url of current track)" : "\"\""
        let trackID = source == .spotify ? "(id of current track)" : "\"\""
        return """
        tell application "\(name)"
            if player state is stopped then return "stopped"
            return (name of current track) & linefeed & (artist of current track) & linefeed & (album of current track) & linefeed & \(duration) & linefeed & player position & linefeed & \(artwork) & linefeed & (player state as text) & linefeed & \(trackID)
        end tell
        """
    }

    nonisolated static func parseNative(_ output: String, source: MediaSource, now: Date = Date()) -> NowPlaying? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 7, !lines[0].isEmpty else { return nil }
        // В русской локали AppleScript может напечатать запятую вместо точки.
        func number(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }
        return NowPlaying(source: source, title: lines[0], artist: lines[1], album: lines[2],
                          duration: number(lines[3]).flatMap { $0 > 0 ? $0 : nil }, position: number(lines[4]),
                          artworkURL: URL(string: lines[5]).flatMap { lines[5].isEmpty ? nil : $0 },
                          isPlaying: lines[6].lowercased().contains("playing"), fetchedAt: now,
                          trackID: lines.count > 7 ? SpotifyID.from(lines[7]) : nil)
    }

    private func webTrack() async -> NowPlaying? {
        let matches = WebService.all.map { "u contains \"\($0.match)\"" }.joined(separator: " or ")
        for browser in Self.browsers where Self.isRunning(browser.bundleID) {
            let titleWord = browser.safari ? "name" : "title"
            let script = """
            tell application "\(browser.name)"
                set out to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        set u to URL of t
                        if \(matches) then set out to out & u & tab & (\(titleWord) of t) & linefeed
                    end repeat
                end repeat
                return out
            end tell
            """
            guard let output = await Shell.run("/usr/bin/osascript", ["-e", script]) else { continue }
            if let track = Self.parseWeb(output) { return track }
        }
        return nil
    }

    nonisolated static func parseWeb(_ output: String, now: Date = Date()) -> NowPlaying? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let service = WebService.all.first(where: { parts[0].contains($0.match) }),
                  let split = splitTitle(parts[1]) else { continue }
            return NowPlaying(source: service.source, title: split.title, artist: split.artist, album: "", duration: nil,
                              position: nil, artworkURL: nil, isPlaying: nil, fetchedAt: now)
        }
        return nil
    }

    /// Заголовок вкладки вида «Название — Артист — Сайт»: служебные части (имя сайта, «слушать онлайн») отбрасываются.
    nonisolated static func splitTitle(_ raw: String) -> (title: String, artist: String)? {
        let service = ["яндекс", "yandex", "youtube", "soundcloud", "вконтакте", "vk ", "deezer", "tidal", "spotify", "apple music", "слушать", "listen"]
        var parts = [raw]
        for separator in [" — ", " – ", " - ", " | ", " • "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        let useful = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { part in
            !part.isEmpty && !service.contains { part.lowercased().contains($0) }
        }
        guard let title = useful.first else { return nil }
        return (title, useful.count > 1 ? useful[1] : "")
    }

    // MARK: Обложка, фото артиста, значок

    private func loadArt(for track: NowPlaying?) async {
        guard let track else {
            cover = nil; avatar = nil; sourceIcon = nil; artKey = ""; iconKey = ""
            return
        }
        if iconKey != track.source.id {
            iconKey = track.source.id
            sourceIcon = await icon(for: track.source)
        }
        guard track.trackKey != artKey else { return }
        artKey = track.trackKey
        cover = nil
        avatar = nil
        let key = artKey
        let artist = Deezer.primaryArtist(track.artist)

        var coverURL = track.artworkURL
        if coverURL == nil, !artist.isEmpty, let search = Deezer.trackURL(title: track.title, artist: artist),
           let data = await download(search) {
            coverURL = Deezer.parseTrackCover(data)
        }
        if let coverURL {
            let loaded = await image(coverURL)
            guard key == artKey, !Task.isCancelled else { return }
            cover = loaded
        }
        if !artist.isEmpty, let search = Deezer.artistURL(artist), let data = await download(search),
           let url = Deezer.parseArtistPicture(data, name: artist) {
            let loaded = await image(url)
            guard key == artKey, !Task.isCancelled else { return }
            avatar = loaded
        }
    }

    private func icon(for source: MediaSource) async -> NSImage? {
        if let bundleID = source.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        guard let domain = source.domain, let url = URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=64") else { return nil }
        return await image(url)
    }

    private func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private func image(_ url: URL) async -> NSImage? {
        if let cached = images.object(forKey: url as NSURL) { return cached }
        guard let data = await download(url), let loaded = NSImage(data: data) else { return nil }
        images.setObject(loaded, forKey: url as NSURL)
        return loaded
    }
}
