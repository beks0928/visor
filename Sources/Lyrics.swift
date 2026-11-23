import Foundation
import Observation

struct LyricLine: Equatable, Sendable {
    /// Секунды от начала трека; nil у текста без разметки по времени.
    let time: Double?
    let text: String
}

enum LyricsState: Equatable {
    case idle, loading, found, missing, failed
}

/// Разбор LRC и выбор текущей строки. Чистые функции, проверяются в --snapshot.
enum LRC {
    /// «[01:23.45] текст» (можно несколько меток на строку). Служебные строки вроде «[ar:…]» пропускаются.
    static func parse(_ text: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":", maxSplits: 1)
                if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) { times.append(minutes * 60 + seconds) }
                rest = rest[rest.index(after: close)...]
            }
            guard !times.isEmpty else { continue }
            let line = rest.trimmingCharacters(in: .whitespaces)
            for time in times { out.append(LyricLine(time: time, text: line)) }
        }
        return out.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
    }

    static func plain(_ text: String) -> [LyricLine] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { LyricLine(time: nil, text: String($0)) }
    }

    /// Индекс строки, которая звучит в момент `position`; nil, пока первая ещё не началась или текст без времени.
    static func activeIndex(_ lines: [LyricLine], at position: Double) -> Int? {
        var found: Int?
        for (index, line) in lines.enumerated() {
            guard let time = line.time else { return nil }
            if time <= position + 0.15 { found = index } else { break }
        }
        return found
    }
}

/// Тексты песен из lrclib.net (открытый каталог без ключа). С отметками времени, если они есть: строка подсвечивается по позиции трека.
/// Позицию отдают только Spotify и Музыка; у сайтов (Яндекс Музыка и др.) текст показывается целиком без подсветки.
@MainActor @Observable
final class LyricsStore {
    static let shared = LyricsStore()

    var lines: [LyricLine] = []
    var state: LyricsState = .idle
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    var isSynced: Bool { lines.first?.time != nil }

    func ensure(for track: NowPlaying) {
        guard track.trackKey != key else { return }
        key = track.trackKey
        task?.cancel()
        lines = []
        state = .loading
        task = Task { [weak self] in
            let result = await Self.fetch(title: track.title, artist: track.artist, album: track.album, duration: track.duration)
            guard let self, !Task.isCancelled, self.key == track.trackKey else { return }
            switch result {
            case .success(let found):
                self.lines = found
                self.state = found.isEmpty ? .missing : .found
            case .failure:
                self.state = .failed
                self.key = "" // следующий опрос попробует снова
            }
        }
    }

    // MARK: Сеть

    private static func url(_ path: String, _ items: [(String, String)]) -> URL? {
        var parts = URLComponents(string: "https://lrclib.net/api/\(path)")
        parts?.queryItems = items.filter { !$0.1.isEmpty }.map { URLQueryItem(name: $0.0, value: $0.1) }
        return parts?.url
    }

    private static func get(_ url: URL?) async throws -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Visor (personal macOS app)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    static func pick(_ object: [String: Any]) -> [LyricLine]? {
        if let synced = object["syncedLyrics"] as? String, !synced.isEmpty {
            let parsed = LRC.parse(synced)
            if !parsed.isEmpty { return parsed }
        }
        if let plain = object["plainLyrics"] as? String, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LRC.plain(plain)
        }
        return nil
    }

    /// Название или артист для сравнения: без скобок, «feat.», «- Remastered», знаков и регистра.
    static func fold(_ text: String) -> String {
        var value = text.lowercased()
        value = value.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        for cut in [" - ", " – ", " feat", " ft.", " ft "] {
            if let range = value.range(of: cut) { value = String(value[..<range.lowerBound]) }
        }
        return value.folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    /// Запись из каталога это та же песня: совпадает название и артист (допускается вариант вроде «Live» или «feat.»).
    static func sameSong(_ item: [String: Any], title: String, artist: String) -> Bool {
        let wantTitle = fold(title), wantArtist = fold(Deezer.primaryArtist(artist))
        let haveTitle = fold(item["trackName"] as? String ?? item["name"] as? String ?? "")
        let haveArtist = fold(item["artistName"] as? String ?? "")
        guard !wantTitle.isEmpty, !haveTitle.isEmpty else { return false }
        let titleOK = wantTitle == haveTitle || (min(wantTitle.count, haveTitle.count) >= 4
                                                  && (wantTitle.contains(haveTitle) || haveTitle.contains(wantTitle)))
        let artistOK = wantArtist.isEmpty || haveArtist.isEmpty || haveArtist.contains(wantArtist) || wantArtist.contains(haveArtist)
        return titleOK && artistOK
    }

    /// Выбор варианта текста: с таймингами лучше, чем без (только такие строки идут вместе с песней и нажимаются).
    /// Точное совпадение главнее, но если у него нет таймингов, берётся близкий по длине вариант с таймингами.
    static func choose(exact: [String: Any]?, candidates: [[String: Any]], duration: Double?,
                       title: String, artist: String) -> [LyricLine]? {
        var plainFallback: [LyricLine]?
        if let exact, let lines = pick(exact) {
            if lines.first?.time != nil { return lines }
            plainFallback = lines
        }
        // Из поиска берётся только та же песня (название и артист), близкая по длине: иначе в текст попадала чужая запись.
        let close = candidates.filter { item in
            guard sameSong(item, title: title, artist: artist) else { return false }
            guard let duration, let length = item["duration"] as? Double else { return true }
            return abs(length - duration) <= 3
        }
        for item in close.sorted(by: { ($0["syncedLyrics"] is String ? 0 : 1) < ($1["syncedLyrics"] is String ? 0 : 1) }) {
            guard let lines = pick(item) else { continue }
            if lines.first?.time != nil { return lines }
            if plainFallback == nil { plainFallback = lines }
        }
        return plainFallback
    }

    static func fetch(title: String, artist: String, album: String, duration: Double?) async -> Result<[LyricLine], Error> {
        let name = Deezer.primaryArtist(artist)
        do {
            let exactData = try await get(url("get", [("track_name", title), ("artist_name", name), ("album_name", album),
                                                      ("duration", duration.map { String(Int($0.rounded())) } ?? "")]))
            let exact = exactData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            // Точное совпадение с таймингами: поиск не нужен.
            if let exact, let lines = pick(exact), lines.first?.time != nil { return .success(lines) }
            let search = try await get(url("search", [("track_name", title), ("artist_name", name)]))
            let list = search.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            return .success(choose(exact: exact, candidates: list, duration: duration, title: title, artist: artist) ?? [])
        } catch {
            return .failure(error)
        }
    }
}
