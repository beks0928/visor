import Foundation

/// Перевод через публичный веб-адрес Google Переводчика (без ключа, нужна сеть).
/// Адрес неофициальный: Google может изменить его, тогда Visor покажет ошибку, а не пустой результат.
enum GoogleTranslate {
    struct Result: Equatable, Sendable {
        let text: String
        /// Язык, который Google определил в исходном тексте, например «ru».
        let detected: String
    }

    enum Failure: Error { case network, format }

    static let endpoint = URL(string: "https://translate.googleapis.com/translate_a/single")!

    static func request(text: String, target: String, endpoint: URL = endpoint) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        request.httpBody = "client=gtx&sl=auto&tl=\(target)&dt=t&q=\(encoded)".data(using: .utf8)
        return request
    }

    /// Ответ: `[[["перевод","исходник",…],…], null, "en"]`. Длинный текст приходит кусками.
    static func parse(_ data: Data) -> Result? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [Any] else { return nil }
        let text = segments.compactMap { ($0 as? [Any])?.first as? String }.joined()
        guard !text.isEmpty else { return nil }
        let detected = root.count > 2 ? (root[2] as? String ?? "") : ""
        return Result(text: text, detected: detected)
    }

    static func translate(_ text: String, to target: String, session: URLSession = .shared,
                          endpoint: URL = endpoint) async throws -> Result {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request(text: text, target: target, endpoint: endpoint))
        } catch {
            throw Failure.network
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.network }
        guard let result = parse(data) else { throw Failure.format }
        return result
    }
}
