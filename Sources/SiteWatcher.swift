import AppKit
import SwiftUI

/// Сайты с видео и лентами, которые показываются в таблетке у выреза. Музыка сюда не входит: она в плеере.
struct SiteService: Sendable {
    let name: String
    let matches: [String]
    let excludes: [String]
    let symbol: String
    let tint: UInt32

    var color: Color {
        Color(red: Double(tint >> 16 & 255) / 255, green: Double(tint >> 8 & 255) / 255, blue: Double(tint & 255) / 255)
    }

    static let all: [SiteService] = [
        SiteService(name: "YouTube", matches: ["youtube.com/watch", "youtube.com/shorts", "youtu.be/"], excludes: ["music.youtube.com"],
                    symbol: "play.rectangle.fill", tint: 0xFF0033),
        SiteService(name: "TikTok", matches: ["tiktok.com"], excludes: [], symbol: "music.note", tint: 0x25F4EE),
        SiteService(name: "Instagram", matches: ["instagram.com"], excludes: [], symbol: "camera.fill", tint: 0xE1306C),
        SiteService(name: "Twitch", matches: ["twitch.tv/"], excludes: [], symbol: "dot.radiowaves.left.and.right", tint: 0x9146FF),
        SiteService(name: "Netflix", matches: ["netflix.com/watch"], excludes: [], symbol: "tv.fill", tint: 0xE50914),
        SiteService(name: "Rutube", matches: ["rutube.ru/video"], excludes: [], symbol: "play.rectangle.fill", tint: 0x00A5FF),
    ]

    static func service(for url: String) -> SiteService? {
        all.first { service in
            service.matches.contains { url.contains($0) } && !service.excludes.contains { url.contains($0) }
        }
    }
}

/// Открытая вкладка такого сайта.
struct SiteTab: Equatable, Sendable {
    let service: String
    let symbol: String
    let tint: UInt32
    let title: String
    /// Для YouTube это ролик, для остальных сам сайт: прокрутка ленты не считается новым.
    let key: String
    /// Вкладка выбрана в своём окне, то есть её видно.
    let active: Bool

    var color: Color { SiteService.all.first { $0.name == service }?.color ?? .white }
}

/// Следит за вкладками браузеров. Видимая вкладка YouTube, TikTok, Instagram и других становится таблеткой в ротации,
/// а новая вкладка выходит в таблетку сразу.
@MainActor @Observable
final class SiteWatcher {
    static let shared = SiteWatcher()

    /// Видимые вкладки; самая новая первая.
    private(set) var tabs: [SiteTab] = []
    var current: SiteTab? { tabs.first }
    /// Вызывается, когда открылась новая видимая вкладка: таблетка встаёт на неё.
    @ObservationIgnored var onNew: (() -> Void)?

    @ObservationIgnored private var known: Set<String>?
    @ObservationIgnored private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        Task { await poll() }
    }

    func poll() async {
        var all: [SiteTab] = []
        for browser in PlayerController.browsers where PlayerController.isRunning(browser.bundleID) {
            guard let output = await Shell.run("/usr/bin/osascript", ["-e", Self.script(browser: browser.name, safari: browser.safari)]) else { continue }
            all += Self.parse(output)
        }
        apply(all)
    }

    /// Применяет новый снимок вкладок. Первый снимок после запуска ничего не объявляет: сайты, открытые заранее, не новые.
    func apply(_ all: [SiteTab]) {
        let keys = Set(all.map(\.key))
        let fresh = all.filter { $0.active && !(known ?? keys).contains($0.key) }
        let visible = all.filter(\.active)
        // Новая вкладка встаёт первой, остальные сохраняют порядок.
        tabs = fresh + visible.filter { tab in !fresh.contains(tab) }
        known = keys
        if !fresh.isEmpty { onNew?() }
    }

    nonisolated static func script(browser: String, safari: Bool) -> String {
        let matches = SiteService.all.flatMap(\.matches).map { "u contains \"\($0)\"" }.joined(separator: " or ")
        let activeIndex = safari ? "index of current tab of w" : "active tab index of w"
        let titleWord = safari ? "name" : "title"
        return """
        tell application "\(browser)"
            set out to ""
            repeat with w in windows
                try
                    set ai to \(activeIndex)
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        set u to URL of t
                        if \(matches) then set out to out & (i = ai) & tab & u & tab & (\(titleWord) of t) & linefeed
                    end repeat
                end try
            end repeat
            return out
        end tell
        """
    }

    /// Строки вида «true⇥адрес⇥заголовок».
    nonisolated static func parse(_ output: String) -> [SiteTab] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let service = SiteService.service(for: parts[1]) else { return nil }
            return SiteTab(service: service.name, symbol: service.symbol, tint: service.tint,
                           title: cleanTitle(parts[2], service: service), key: key(url: parts[1], service: service),
                           active: parts[0] == "true")
        }
    }

    nonisolated static func key(url: String, service: SiteService) -> String {
        guard service.name == "YouTube" else { return service.name }
        if let id = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "v" })?.value { return "YouTube:" + id }
        return "YouTube:" + (url.split(separator: "/").last.map(String.init) ?? url)
    }

    /// «(3) Как собрать клавиатуру - YouTube» → «Как собрать клавиатуру».
    nonisolated static func cleanTitle(_ raw: String, service: SiteService) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasPrefix("("), let close = title.firstIndex(of: ")"), title[title.index(after: title.startIndex)..<close].allSatisfy(\.isNumber) {
            title = String(title[title.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        for separator in [" - ", " | ", " • ", " · ", " — "] {
            // «TikTok - Make Your Day»: после названия сайта идёт слоган, он в таблетке не нужен.
            if title.lowercased().hasPrefix(service.name.lowercased() + separator) { return service.name }
            if let range = title.range(of: separator, options: .backwards), title[range.upperBound...].lowercased().contains(service.name.lowercased()) {
                title = String(title[..<range.lowerBound])
            }
        }
        title = title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? service.name : title
    }
}

/// Таблетка у выреза: что открыто в браузере. Не плеер, управлять тут нечем.
struct SiteCapsule: View {
    var body: some View {
        if let tab = SiteWatcher.shared.current {
            PillLabel(text: tab.title, maxWidth: 96) {
                Image(systemName: tab.symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(tab.color)
            }
        }
    }
}
