import AppKit
import Observation
import SwiftUI
import WebKit

/// Музыкальные сервисы, которые играют прямо в Visor: сайт сервиса открыт во встроенном окне, вход в аккаунт делается там же.
/// Со своей подпиской (Spotify Premium, Яндекс Плюс) реклама не включается: её решает аккаунт, а не плеер.
/// Без подписки сервис играет с рекламой, как в любом браузере.
enum WebService2: String, CaseIterable, Identifiable {
    case spotify, yandex, ytmusic, soundcloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spotify: "Spotify"
        case .yandex: "Яндекс Музыка"
        case .ytmusic: "YouTube Music"
        case .soundcloud: "SoundCloud"
        }
    }

    var url: URL {
        switch self {
        case .spotify: URL(string: "https://open.spotify.com")!
        case .yandex: URL(string: "https://music.yandex.ru")!
        case .ytmusic: URL(string: "https://music.youtube.com")!
        case .soundcloud: URL(string: "https://soundcloud.com")!
        }
    }

    var source: MediaSource {
        switch self {
        case .spotify: MediaSource(id: "own-spotify", name: "Spotify", bundleID: nil, domain: "spotify.com", tint: 0x1DB954, darkGlyph: true, scriptName: nil, embedded: true)
        case .yandex: MediaSource(id: "own-yandex", name: "Яндекс Музыка", bundleID: nil, domain: "music.yandex.ru", tint: 0xFFDD00, darkGlyph: true, scriptName: nil, embedded: true)
        case .ytmusic: MediaSource(id: "own-ytmusic", name: "YouTube Music", bundleID: nil, domain: "music.youtube.com", tint: 0xFF0033, darkGlyph: false, scriptName: nil, embedded: true)
        case .soundcloud: MediaSource(id: "own-soundcloud", name: "SoundCloud", bundleID: nil, domain: "soundcloud.com", tint: 0xFF5500, darkGlyph: false, scriptName: nil, embedded: true)
        }
    }

    /// Сайты, чьи данные стираются при выходе из аккаунта.
    var hosts: [String] {
        switch self {
        case .spotify: ["spotify.com", "scdn.co"]
        case .yandex: ["yandex.ru", "yandex.com", "ya.ru", "yandex.net"]
        case .ytmusic: ["youtube.com", "google.com"]
        case .soundcloud: ["soundcloud.com", "sndcdn.com"]
        }
    }
}

/// Встроенный плеер: одно окно веб-страницы на все сервисы, данные входа хранятся между запусками.
@MainActor @Observable
final class WebPlayer: NSObject {
    static let shared = WebPlayer()

    private(set) var service: WebService2
    /// Что играет в окне прямо сейчас; nil, пока страница ничего не воспроизводит.
    private(set) var track: NowPlaying?
    /// Окно открывали хотя бы раз: до тех пор ничего не грузится и не опрашивается.
    private(set) var started = false

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loadedService: WebService2?
    @ObservationIgnored private let defaults = UserDefaults.standard

    private static let safariAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    override init() {
        service = WebService2(rawValue: UserDefaults.standard.string(forKey: "web.service") ?? "") ?? .spotify
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.safariAgent
        webView.allowsBackForwardNavigationGestures = false
        // Окно острова низкое: страница в натуральный размер показывала бы только шапку, без плеера сервиса внизу.
        webView.pageZoom = 0.6
        super.init()
        webView.uiDelegate = self
    }

    // MARK: Открытие

    func open(_ new: WebService2? = nil) {
        if let new, new != service {
            service = new
            defaults.set(new.rawValue, forKey: "web.service")
        }
        start()
        if loadedService != service {
            loadedService = service
            webView.load(URLRequest(url: service.url))
        }
    }

    private func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    /// Выход из аккаунта сервиса: стираются его cookie и данные сайта. Окно открывается заново, уже без входа.
    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let mine = records.filter { record in service.hosts.contains { record.displayName.hasSuffix($0) } }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: mine)
        track = nil
        loadedService = nil
        open()
    }

    // MARK: Опрос и команды

    private static let pollScript = """
    (() => {
      const m = navigator.mediaSession && navigator.mediaSession.metadata;
      const els = [...document.querySelectorAll('audio,video')];
      const el = els.find(e => !e.paused && isFinite(e.duration) && e.duration > 0) || els.find(e => isFinite(e.duration) && e.duration > 0) || null;
      const art = m && m.artwork && m.artwork.length ? m.artwork[m.artwork.length - 1].src : '';
      return JSON.stringify({ title: m ? m.title : '', artist: m ? m.artist : '', album: m ? m.album : '', art,
        paused: el ? el.paused : true, pos: el ? el.currentTime : 0, dur: el ? el.duration : 0 });
    })()
    """

    func poll() async {
        guard let raw = try? await webView.evaluateJavaScript(Self.pollScript) as? String,
              let parsed = Self.parse(raw, service: service) else {
            if track != nil { track = nil }
            return
        }
        track = parsed
    }

    /// Разбор ответа страницы; nil, если названия нет (ничего не выбрано).
    nonisolated static func parse(_ raw: String, service: WebService2, now: Date = Date()) -> NowPlaying? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
        let duration = object["dur"] as? Double ?? 0
        return NowPlaying(source: service.source, title: title, artist: object["artist"] as? String ?? "", album: object["album"] as? String ?? "",
                          duration: duration > 0 ? duration : nil, position: object["pos"] as? Double,
                          artworkURL: (object["art"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                          isPlaying: !(object["paused"] as? Bool ?? true), fetchedAt: now)
    }

    func send(_ command: MediaCommand) {
        let js: String
        switch command {
        case .playPause:
            js = "(() => { const e=[...document.querySelectorAll('audio,video')].find(e=>isFinite(e.duration)&&e.duration>0); if(e){ e.paused ? e.play() : e.pause(); } })()"
        case .next:
            js = Self.clickScript(pattern: "next|следующ|вперёд|вперед")
        case .previous:
            js = Self.clickScript(pattern: "previous|предыдущ|назад")
        }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Только пауза, без переключения: если сайт уже остановил трек, ничего не запустится.
    func pause() {
        webView.evaluateJavaScript("[...document.querySelectorAll('audio,video')].forEach(e => e.pause())", completionHandler: nil)
    }

    func seek(to seconds: Double) {
        webView.evaluateJavaScript("(() => { const e=[...document.querySelectorAll('audio,video')].find(e=>isFinite(e.duration)&&e.duration>0); if(e){ e.currentTime=\(seconds); } })()", completionHandler: nil)
    }

    /// Кнопка страницы по подписи («Следующий трек», “Next”): так не зависим от названий классов.
    private static func clickScript(pattern: String) -> String {
        "(() => { const b=[...document.querySelectorAll('button,[role=button]')].find(b => /\(pattern)/i.test((b.getAttribute('aria-label')||'')+' '+(b.title||'')+' '+(b.getAttribute('data-testid')||''))); if(b) b.click(); })()"
    }
}

extension WebPlayer: WKUIDelegate {
    /// Окна входа (Google, Apple, VK) открываются в том же окне, а не пропадают.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            Task { @MainActor in webView.load(URLRequest(url: url)) }
        }
        return nil
    }
}

struct WebPlayerHost: NSViewRepresentable {
    let player: WebPlayer

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if player.webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        let web = player.webView
        web.removeFromSuperview()
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)
    }
}

/// Вкладка «В Visor»: выбор сервиса и само окно сервиса со входом в аккаунт.
struct WebPlayerPanel: View {
    var player: WebPlayer = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ChoiceChips(options: WebService2.allCases.map { ($0, $0.title) }, selection: player.service) { player.open($0) }
                Spacer()
                Text(player.track.map { "Visor видит: \($0.title)" } ?? "Трек не определён: включите песню в окне")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                Button("Выйти из аккаунта") { Task { await player.signOut() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
            }
            if player.started {
                WebPlayerHost(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08)))
            } else {
                VStack(spacing: 8) {
                    Text("Слушайте прямо в Visor, без приложений")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Выберите сервис и войдите в свой аккаунт в окне ниже. С подпиской реклама не включится. Название трека, текст песни и кнопки будут во вкладке «Плеер».")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("Открыть \(player.service.title)") { player.open() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if player.started { player.open() }
            IslandController.shared.focusForTyping()
        }
    }
}
