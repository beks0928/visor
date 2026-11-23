import AppKit

/// Отзывы через GitHub Issues: форма открывается в браузере с уже заполненными версией Visor, macOS и моделью Mac.
/// Адрес репозитория задаётся один раз в project.yml (ключ VisorRepository) скриптом scripts/set-repo.sh.
enum Feedback {
    enum Kind: String { case bug, feature }

    /// «имя/репозиторий» из Info.plist. nil, пока стоит заготовка OWNER: кнопки отзыва тогда не показываются.
    static var repository: String? { normalized(Bundle.main.object(forInfoDictionaryKey: "VisorRepository") as? String) }

    static func normalized(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.hasPrefix("OWNER/"),
              raw.range(of: #"^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return nil }
        return raw
    }

    /// Ссылка на новую форму. Поля формы заполняются через параметры с их id (version, macos).
    static func issueURL(repository: String, kind: Kind, version: String, macos: String) -> URL? {
        var parts = URLComponents(string: "https://github.com/\(repository)/issues/new")
        var items = [URLQueryItem(name: "template", value: "\(kind.rawValue).yml")]
        if kind == .bug {
            items += [URLQueryItem(name: "version", value: version), URLQueryItem(name: "macos", value: macos)]
        }
        parts?.queryItems = items
        return parts?.url
    }

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        return "Visor \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    static var macText: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let name = String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(name)"
    }

    static func open(_ kind: Kind) {
        guard let repository, let url = issueURL(repository: repository, kind: kind, version: versionText, macos: macText) else { return }
        NSWorkspace.shared.open(url)
    }
}
