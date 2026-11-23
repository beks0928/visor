import Foundation
import Observation
import Security

/// Токены лежат в связке ключей macOS, а не в файлах и не в настройках.
enum SecretStore {
    /// Самопроверка (`--snapshot`) работает с отдельным набором ключей: настоящие секреты Visor она не читает,
    /// а значит macOS не спрашивает пароль связки ключей при каждой проверке.
    static let service = CommandLine.arguments.contains("--snapshot") ? "com.beksultan.visor.snapshot" : "com.beksultan.visor"

    static func get(_ account: String, service: String = service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, account: String, service: String = service) -> Bool {
        delete(account, service: service)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String, service: String = service) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct ListeningPort: Identifiable, Equatable, Sendable {
    var id: String { "\(pid):\(port)" }
    let pid: Int
    let command: String
    let port: Int
    /// Слушает не только этот Mac, а все сетевые адреса.
    let exposed: Bool
}

enum CIState: Equatable, Sendable {
    case unknown, running, passing, failing

    var title: String {
        switch self {
        case .unknown: "нет проверок"
        case .running: "идут"
        case .passing: "прошли"
        case .failing: "упали"
        }
    }
}

struct PullRequest: Identifiable, Equatable, Sendable {
    let id: Int
    let number: Int
    let title: String
    let repository: String
    let url: URL?
    let draft: Bool
    /// Адрес, по которому берётся последний коммит для проверок.
    let apiURL: URL?
    var ci: CIState = .unknown
}

enum DeployState: Equatable, Sendable {
    case ready, building, queued, error, canceled

    var title: String {
        switch self {
        case .ready: "готов"
        case .building: "собирается"
        case .queued: "в очереди"
        case .error: "ошибка"
        case .canceled: "отменён"
        }
    }
}

struct Deployment: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let url: URL?
    let state: DeployState
    let created: Date
    let production: Bool
}

enum DevAPI {
    // MARK: Порты

    /// `lsof -iTCP -sTCP:LISTEN -nP -F pcn`: строки вида `p123`, `cnode`, `n*:3000`.
    nonisolated static func parsePorts(_ text: String) -> [ListeningPort] {
        var result: [ListeningPort] = []
        var seen = Set<String>()
        var pid = 0
        var command = ""
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int(value) ?? 0
            case "c": command = value.replacingOccurrences(of: "\\x20", with: " ")
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let host = value[..<colon]
                let exposed = host == "*" || (host != "127.0.0.1" && host != "[::1]" && host != "localhost")
                let key = "\(pid):\(port)"
                if seen.insert(key).inserted {
                    result.append(ListeningPort(pid: pid, command: command, port: port, exposed: exposed))
                }
            default: break
            }
        }
        return result.sorted { $0.port < $1.port }
    }

    // MARK: GitHub

    nonisolated static func parsePulls(_ data: Data) -> [PullRequest] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? Int, let number = item["number"] as? Int, let title = item["title"] as? String else { return nil }
            let repository = (item["repository_url"] as? String).map { String($0.split(separator: "/").suffix(2).joined(separator: "/")) } ?? ""
            let apiURL = ((item["pull_request"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:))
            return PullRequest(id: id, number: number, title: title, repository: repository,
                               url: (item["html_url"] as? String).flatMap(URL.init(string:)),
                               draft: item["draft"] as? Bool ?? false, apiURL: apiURL)
        }
    }

    nonisolated static func parseHeadSHA(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["head"] as? [String: Any])?["sha"] as? String
    }

    nonisolated static func parseChecks(_ data: Data) -> CIState {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runs = root["check_runs"] as? [[String: Any]], !runs.isEmpty else { return .unknown }
        let bad: Set<String> = ["failure", "timed_out", "cancelled", "action_required", "startup_failure"]
        if runs.contains(where: { bad.contains($0["conclusion"] as? String ?? "") }) { return .failing }
        if runs.contains(where: { $0["status"] as? String != "completed" }) { return .running }
        return .passing
    }

    // MARK: Vercel

    nonisolated static func parseDeployments(_ data: Data) -> [Deployment] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["deployments"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["uid"] as? String, let name = item["name"] as? String else { return nil }
            let raw = (item["state"] as? String ?? item["readyState"] as? String ?? "").uppercased()
            let state: DeployState = switch raw {
            case "READY": .ready
            case "ERROR": .error
            case "CANCELED": .canceled
            case "QUEUED", "INITIALIZING": .queued
            default: .building
            }
            let created = Date(timeIntervalSince1970: (item["created"] as? Double ?? 0) / 1000)
            return Deployment(id: id, name: name, url: (item["url"] as? String).flatMap { URL(string: "https://\($0)") },
                              state: state, created: created, production: item["target"] as? String == "production")
        }
    }

    // MARK: Запросы

    enum Failure: Error { case token, network }

    static func get(_ url: URL, token: String, session: URLSession = .shared) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Visor", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw Failure.network }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw Failure.token }
        guard status == 200 else { throw Failure.network }
        return data
    }

    static func fetchPulls(token: String) async throws -> [PullRequest] {
        guard let search = URL(string: "https://api.github.com/search/issues?q=is:pr+is:open+author:@me&sort=updated&per_page=8") else { return [] }
        var pulls = parsePulls(try await get(search, token: token))
        for index in pulls.indices {
            guard let api = pulls[index].apiURL, let sha = parseHeadSHA((try? await get(api, token: token)) ?? Data()) else { continue }
            let repo = pulls[index].repository
            if let checks = URL(string: "https://api.github.com/repos/\(repo)/commits/\(sha)/check-runs"),
               let data = try? await get(checks, token: token) {
                pulls[index].ci = parseChecks(data)
            }
        }
        return pulls
    }

    static func fetchDeployments(token: String) async throws -> [Deployment] {
        guard let url = URL(string: "https://api.vercel.com/v6/deployments?limit=6") else { return [] }
        return parseDeployments(try await get(url, token: token))
    }
}

/// Модули вкладки Dev: порты, GitHub и Vercel. Опрашиваются только пока открыта их страница.
@MainActor @Observable
final class DevServices {
    static let shared = DevServices()

    enum Load<Value: Equatable>: Equatable {
        case idle, loading
        case loaded(Value)
        case failed(String)
    }

    var ports: [ListeningPort] = []
    var pulls: Load<[PullRequest]> = .idle
    var deployments: Load<[Deployment]> = .idle
    private(set) var hasGitHubToken: Bool
    private(set) var hasVercelToken: Bool

    init(hasGitHubToken: Bool? = nil, hasVercelToken: Bool? = nil) {
        self.hasGitHubToken = hasGitHubToken ?? (SecretStore.get("github") != nil)
        self.hasVercelToken = hasVercelToken ?? (SecretStore.get("vercel") != nil)
    }

    func refreshPorts() async {
        guard let text = await Shell.run("/usr/sbin/lsof", ["-iTCP", "-sTCP:LISTEN", "-nP", "-F", "pcn"]) else { return }
        ports = DevAPI.parsePorts(text)
    }

    /// Мягкая остановка: процессу уходит SIGTERM, как от Ctrl+C.
    func stop(_ port: ListeningPort) {
        kill(pid_t(port.pid), SIGTERM)
        ports.removeAll { $0.id == port.id }
    }

    func saveToken(_ token: String, for service: String) {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, SecretStore.set(clean, account: service) else { return }
        if service == "github" { hasGitHubToken = true; pulls = .idle } else { hasVercelToken = true; deployments = .idle }
    }

    func removeToken(for service: String) {
        SecretStore.delete(service)
        if service == "github" { hasGitHubToken = false; pulls = .idle } else { hasVercelToken = false; deployments = .idle }
    }

    func refreshPulls() async {
        guard let token = SecretStore.get("github") else { return }
        if case .loaded = pulls {} else { pulls = .loading }
        do { pulls = .loaded(try await DevAPI.fetchPulls(token: token)) } catch DevAPI.Failure.token {
            pulls = .failed("GitHub не принял токен. Создайте новый и вставьте заново.")
        } catch {
            pulls = .failed("Нет связи с GitHub.")
        }
    }

    func refreshDeployments() async {
        guard let token = SecretStore.get("vercel") else { return }
        if case .loaded = deployments {} else { deployments = .loading }
        do { deployments = .loaded(try await DevAPI.fetchDeployments(token: token)) } catch DevAPI.Failure.token {
            deployments = .failed("Vercel не принял токен. Создайте новый и вставьте заново.")
        } catch {
            deployments = .failed("Нет связи с Vercel.")
        }
    }

    /// Только для снимков экрана и самопроверок.
    func preset(ports: [ListeningPort] = [], pulls: Load<[PullRequest]> = .idle, deployments: Load<[Deployment]> = .idle) {
        self.ports = ports
        self.pulls = pulls
        self.deployments = deployments
    }
}
