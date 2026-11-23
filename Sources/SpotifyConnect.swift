import AppKit
import CryptoKit
import Foundation
import Network
import Observation

struct SpotifyDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Computer, Smartphone, Speaker…
    let type: String
    let isActive: Bool

    var symbol: String {
        switch type.lowercased() {
        case "smartphone": "iphone"
        case "computer": "laptopcomputer"
        case "tablet": "ipad"
        case "tv", "castvideo": "tv"
        default: "hifispeaker"
        }
    }

    var isPhone: Bool { type.lowercased() == "smartphone" }

    static func parse(_ data: Data) -> [SpotifyDevice] {
        let list = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["devices"] as? [[String: Any]]
        return (list ?? []).compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return SpotifyDevice(id: id, name: name, type: item["type"] as? String ?? "", isActive: item["is_active"] as? Bool ?? false)
        }
    }
}

/// Spotify Connect: перенос играющей песни на другое устройство (телефон) с того же места.
/// Нужен вход в аккаунт (PKCE, без Client Secret) и Spotify Premium: Spotify не пускает управление воспроизведением без них.
@MainActor @Observable
final class SpotifyConnect {
    static let shared = SpotifyConnect()
    static let refreshAccount = "spotify.refresh"
    nonisolated static let redirect = "http://127.0.0.1:8888/callback"
    /// Управление воспроизведением, лайки (библиотека) и плейлисты. Права добавились позже: кто входил раньше, входит заново.
    nonisolated static let scopes = "user-read-playback-state user-modify-playback-state user-library-read user-library-modify "
        + "playlist-read-private playlist-modify-private playlist-modify-public"

    var devices: [SpotifyDevice] = []
    var message: String?
    var busy = false
    /// Токен есть: можно запрашивать устройства без нового входа.
    var signedIn: Bool

    /// При сне и выключении Mac играющая песня сама уходит на телефон, если он есть в Spotify.
    var autoHandoff: Bool {
        didSet { UserDefaults.standard.set(autoHandoff, forKey: "visor.spotify.autoHandoff") }
    }

    @ObservationIgnored private var access: (value: String, expires: Date)?
    @ObservationIgnored private var watching = false
    @ObservationIgnored private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        signedIn = SecretStore.get(Self.refreshAccount) != nil
        autoHandoff = UserDefaults.standard.bool(forKey: "visor.spotify.autoHandoff")
    }

    // MARK: Автоперенос при сне и выключении

    /// Телефон запоминается, когда его увидели в списке: при сне запрос на перенос идёт сразу, без лишнего запроса списка.
    private var phoneID: String? {
        get { UserDefaults.standard.string(forKey: "visor.spotify.phoneID") }
        set { UserDefaults.standard.set(newValue, forKey: "visor.spotify.phoneID") }
    }

    func startWatching() {
        guard !watching else { return }
        watching = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.handoffBeforeSleep() }
            }
        }
    }

    /// Только если включено, играет именно Spotify и телефон известен. Запрос короткий: у Mac перед сном несколько секунд.
    func handoffBeforeSleep() async {
        guard autoHandoff, signedIn, PlayerController.shared.nowPlaying?.source.id == MediaSource.spotify.id,
              PlayerController.shared.nowPlaying?.isPlaying == true, let id = phoneID else { return }
        let body = try? JSONSerialization.data(withJSONObject: ["device_ids": [id], "play": true])
        _ = try? await call("PUT", "/me/player", body: body)
    }

    /// Client ID: тот, что введён для поиска, иначе сохранённый при прежнем входе.
    var clientID: String? {
        SecretStore.get(SpotifySearch.idAccount) ?? UserDefaults.standard.string(forKey: "visor.spotify.clientID")
    }

    struct Failure: Error { let text: String }

    // MARK: Вход (PKCE)

    nonisolated static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    nonisolated static func challenge(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    nonisolated static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func authorizeURL(clientID: String, challenge: String, state: String) -> URL? {
        var parts = URLComponents(string: "https://accounts.spotify.com/authorize")
        parts?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect), URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            // Окно согласия показывается всегда: без этого Spotify мог молча подтвердить вход со старыми правами.
            URLQueryItem(name: "show_dialog", value: "true"),
        ]
        return parts?.url
    }

    /// Права, которые Spotify выдал при последнем входе или обновлении токена.
    @ObservationIgnored private(set) var grantedScopes: Set<String> = []

    /// Каких из нужных прав нет. Пусто, пока Spotify не сообщил выданные права (проверять нечего).
    func missingScopes(_ needed: [String]) -> [String] {
        grantedScopes.isEmpty ? [] : needed.filter { !grantedScopes.contains($0) }
    }

    /// Текст ошибки из ответа Spotify: `{"error":{"status":403,"message":"Insufficient client scope"}}`.
    nonisolated static func errorMessage(_ data: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["error"] as? [String: Any])?["message"] as? String ?? object?["error_description"] as? String
    }

    /// «GET /callback?code=…&state=… HTTP/1.1» → (code, state).
    nonisolated static func parseCallback(_ request: String) -> (code: String?, state: String?, error: String?) {
        guard let line = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first else { return (nil, nil, nil) }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let items = URLComponents(string: "http://x" + parts[1])?.queryItems else { return (nil, nil, nil) }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        return (value("code"), value("state"), value("error"))
    }

    func signIn() async {
        guard let clientID else { message = "Сначала подключите поиск Spotify: нужен Client ID."; return }
        busy = true
        defer { busy = false }
        let verifier = Self.verifier()
        let state = Self.base64url(Data((0..<12).map { _ in UInt8.random(in: 0...255) }))
        guard let url = Self.authorizeURL(clientID: clientID, challenge: Self.challenge(verifier), state: state) else { return }
        let server = LoopbackServer(port: 8888)
        guard server.start() else {
            message = "Порт 8888 занят. Закройте программу, которая его использует, и повторите."
            return
        }
        NSWorkspace.shared.open(url)
        message = "Откройте браузер и разрешите доступ в Spotify. Жду ответа до двух минут."
        let result = await server.waitForRequest(timeout: 120)
        server.stop()
        guard let result else { message = "Вход не завершён: ответа от Spotify не было."; return }
        let parsed = Self.parseCallback(result)
        guard parsed.state == state, let code = parsed.code else {
            message = parsed.error == "access_denied" ? "Доступ отклонён в Spotify." : "Spotify вернул ошибку входа. Проверьте, что в приложении указан Redirect URI \(Self.redirect)."
            return
        }
        do {
            try await exchange(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                                "client_id": clientID, "code_verifier": verifier])
            message = nil
            await loadDevices()
        } catch let failure as Failure {
            message = failure.text
        } catch {
            message = "Нет ответа от Spotify: проверьте интернет."
        }
    }

    private func exchange(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String else {
            if code == 400 { SecretStore.delete(Self.refreshAccount); signedIn = false }
            throw Failure(text: code == 400 ? "Вход в Spotify устарел. Нажмите «Войти в Spotify»." : "Spotify ответил кодом \(code) при входе.")
        }
        access = (token, Date().addingTimeInterval(((object["expires_in"] as? Double) ?? 3600) - 60))
        if let scope = object["scope"] as? String {
            grantedScopes = Set(scope.split(separator: " ").map(String.init))
            Self.log("token scope: \(scope)")
        }
        if let refresh = object["refresh_token"] as? String {
            SecretStore.set(refresh, account: Self.refreshAccount)
            signedIn = true
        }
    }

    private func token() async throws -> String {
        if let access, access.expires > Date() { return access.value }
        guard let clientID, let refresh = SecretStore.get(Self.refreshAccount) else { throw Failure(text: "") }
        try await exchange(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        guard let access else { throw Failure(text: "") }
        return access.value
    }

    // MARK: Устройства и перенос

    /// Журнал запросов к Spotify для разбора неполадок: метод, путь, код и начало ответа. Токены и тела запросов не пишутся.
    nonisolated static func log(_ line: String) {
        let url = VisorPaths.supportDir.appendingPathComponent("spotify.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 200_000 { try? FileManager.default.removeItem(at: url) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func call(_ method: String, _ path: String, body: Data? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1\(path)")!, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 || path.contains("/me/tracks") || path.contains("/playlists") {
            Self.log("\(method) \(path.split(separator: "?").first.map(String.init) ?? path) -> \(code) \(String(decoding: data.prefix(160), as: UTF8.self))")
        }
        return (code, data)
    }

    func loadDevices() async {
        guard signedIn else { devices = []; return }
        busy = true
        defer { busy = false }
        do {
            let (code, data) = try await call("GET", "/me/player/devices")
            switch code {
            case 200:
                devices = SpotifyDevice.parse(data)
                if let phone = devices.first(where: \.isPhone) { phoneID = phone.id }
                message = devices.contains(where: \.isPhone) ? nil : "Телефона в списке нет. Откройте Spotify на телефоне (в той же сети или с тем же аккаунтом) и нажмите «Обновить»."
            case 401, 403:
                message = "Spotify не дал доступ к устройствам. Нужен Premium и вход с правом управления: нажмите «Войти в Spotify» ещё раз."
                devices = []
            default:
                message = "Spotify ответил кодом \(code)."
            }
        } catch let failure as Failure {
            message = failure.text.isEmpty ? "Войдите в Spotify." : failure.text
        } catch {
            message = "Нет ответа от Spotify: проверьте интернет."
        }
    }

    /// Песня продолжается на выбранном устройстве с того же места, а здесь замолкает.
    func transfer(to device: SpotifyDevice) async {
        busy = true
        defer { busy = false }
        let body = try? JSONSerialization.data(withJSONObject: ["device_ids": [device.id], "play": true])
        do {
            let (code, _) = try await call("PUT", "/me/player", body: body)
            switch code {
            case 200, 202, 204:
                message = "Играет на «\(device.name)»."
                try? await Task.sleep(for: .milliseconds(800))
                await loadDevices()
                message = "Играет на «\(device.name)»."
            case 403: message = "Spotify отказал: перенос играющего трека доступен только с Premium."
            case 404: message = "Устройство «\(device.name)» сейчас недоступно. Откройте на нём Spotify и повторите."
            default: message = "Spotify ответил кодом \(code)."
            }
        } catch let failure as Failure {
            message = failure.text.isEmpty ? "Войдите в Spotify." : failure.text
        } catch {
            message = "Нет ответа от Spotify: проверьте интернет."
        }
    }

    // MARK: Что играет в аккаунте

    /// Ответ `GET /me/player`: что играет на любом устройстве аккаунта. nil: ничего не играет или это реклама и подкаст.
    nonisolated static func parsePlayback(_ data: Data, now: Date = Date()) -> NowPlaying? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = object["item"] as? [String: Any], let title = item["name"] as? String, !title.isEmpty,
              (object["currently_playing_type"] as? String ?? "track") == "track" else { return nil }
        let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
        let album = item["album"] as? [String: Any]
        let cover = (album?["images"] as? [[String: Any]])?.first?["url"] as? String
        let length = (item["duration_ms"] as? Double).map { $0 / 1000 }
        let progress = (object["progress_ms"] as? Double).map { $0 / 1000 }
        return NowPlaying(source: .spotify, title: title, artist: artists, album: album?["name"] as? String ?? "",
                          duration: length.flatMap { $0 > 0 ? $0 : nil }, position: progress,
                          artworkURL: cover.flatMap(URL.init(string:)), isPlaying: object["is_playing"] as? Bool ?? false,
                          fetchedAt: now, device: (object["device"] as? [String: Any])?["name"] as? String,
                          trackID: item["id"] as? String)
    }

    @ObservationIgnored private var remoteCache: (track: NowPlaying?, at: Date)?
    /// Почему Visor не видит песню с телефона. nil: связь в порядке или ничего не играет.
    private(set) var syncStatus: String?

    /// Что значит ответ `GET /me/player`. nil: всё хорошо (200) или нигде ничего не играет (204).
    nonisolated static func syncStatus(code: Int, data: Data) -> String? {
        switch code {
        case 200, 204: nil
        case 401: "Вход в Spotify устарел: войдите заново, иначе телефон не виден."
        case 403: (errorMessage(data).map { "Spotify не пускает к плееру: \($0)." } ?? "Spotify не пускает к плееру (403).")
            + " Выйдите и войдите в Spotify заново."
        case 429: "Spotify просит подождать, телефон обновится чуть позже."
        default: "Spotify ответил кодом \(code), телефон не виден."
        }
    }

    /// Песня аккаунта, где бы она ни играла (в том числе на телефоне). Запрос не чаще раза в 4 секунды.
    func remoteTrack() async -> NowPlaying? {
        guard signedIn else { return nil }
        if let cache = remoteCache, Date().timeIntervalSince(cache.at) < 4 { return cache.track }
        var track: NowPlaying?
        do {
            let (code, data) = try await call("GET", "/me/player")
            if code == 200 { track = Self.parsePlayback(data) }
            syncStatus = Self.syncStatus(code: code, data: data)
        } catch let failure as Failure {
            syncStatus = failure.text.isEmpty ? "Вход в Spotify не завершён: телефон не виден." : failure.text
        } catch {
            syncStatus = "Нет связи со Spotify."
        }
        remoteCache = (track, Date())
        return track
    }

    /// Кнопки плеера для песни, которая играет не на этом Mac: команды идут через Spotify.
    func control(_ command: MediaCommand, isPlaying: Bool?) async {
        let request: (method: String, path: String)
        switch command {
        case .playPause: request = ("PUT", isPlaying == true ? "/me/player/pause" : "/me/player/play")
        case .next: request = ("POST", "/me/player/next")
        case .previous: request = ("POST", "/me/player/previous")
        }
        _ = try? await call(request.method, request.path)
        remoteCache = nil
    }

    func seek(to seconds: Double) async {
        _ = try? await call("PUT", "/me/player/seek?position_ms=\(Int(max(0, seconds) * 1000))")
        remoteCache = nil
    }

    /// Песня с телефона переходит на этот Mac с того же места. Если Spotify на Mac закрыт, он открывается в фоне.
    func playHere() async {
        busy = true
        defer { busy = false }
        await loadDevices()
        if !devices.contains(where: { $0.type.lowercased() == "computer" }),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            try? await Task.sleep(for: .seconds(4))
            await loadDevices()
        }
        guard let mac = devices.first(where: { $0.type.lowercased() == "computer" }) else {
            message = "Spotify на этом Mac не нашёлся в списке устройств. Откройте его и повторите."
            return
        }
        await transfer(to: mac)
        remoteCache = nil
    }

    func signOut() {
        SecretStore.delete(Self.refreshAccount)
        access = nil
        signedIn = false
        devices = []
    }
}

/// Принимает один HTTP-запрос на 127.0.0.1 (ответ Spotify после входа) и отдаёт страницу «можно закрыть вкладку».
final class LoopbackServer: @unchecked Sendable {
    private let port: UInt16
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String?, Never>?
    private let lock = NSLock()
    private var finished = false
    private var result: String?

    init(port: UInt16) { self.port = port }

    func start() -> Bool {
        let parameters = NWParameters.tcp
        guard let number = NWEndpoint.Port(rawValue: port) else { return false }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: number)
        guard let listener = try? NWListener(using: parameters) else { return false }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let page = "<html><meta charset=utf-8><body style='font-family:-apple-system;text-align:center;margin-top:80px'><h2>Готово</h2><p>Вернитесь в Visor, эту вкладку можно закрыть.</p></body></html>"
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if request.hasPrefix("GET /callback") { self?.finish(request) }
            }
        }
        listener.start(queue: .global())
        self.listener = listener
        return true
    }

    func waitForRequest(timeout: TimeInterval) async -> String? {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if finished { let early = result; lock.unlock(); continuation.resume(returning: early); return }
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func finish(_ request: String?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        result = request
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: request)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        finish(nil)
    }
}
