import Foundation

/// Одно окно лимита: сколько процентов израсходовано и когда оно сбросится.
struct PlanWindow: Codable, Equatable, Sendable {
    var usedPct: Double
    var resetsAt: Date

    /// После времени сброса окно пустое, даже если мы ещё не получали новых данных.
    func effectivePct(at now: Date = Date()) -> Double {
        resetsAt <= now ? 0 : usedPct
    }
}

/// Лимиты плана агента: окно 5 часов и недельное.
struct PlanUsage: Codable, Equatable, Sendable {
    var fiveHour: PlanWindow?
    var sevenDay: PlanWindow?
    var updated: Date

    /// Большая из двух долей. nil, если окон нет.
    func dominantPct(at now: Date = Date()) -> Double? {
        [fiveHour, sevenDay].compactMap { $0?.effectivePct(at: now) }.max()
    }
}

enum PlanParser {
    /// Claude Code кладёт лимиты в JSON строки состояния: `rate_limits.five_hour` и `rate_limits.seven_day`.
    static func claude(payload: [String: Any]) -> PlanUsage? {
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        let five = claudeWindow(limits["five_hour"])
        let seven = claudeWindow(limits["seven_day"])
        guard five != nil || seven != nil else { return nil }
        return PlanUsage(fiveHour: five, sevenDay: seven, updated: Date())
    }

    private static func claudeWindow(_ raw: Any?) -> PlanWindow? {
        guard let dict = raw as? [String: Any],
              let pct = (dict["used_percentage"] as? Double) ?? (dict["used_percentage"] as? Int).map(Double.init),
              pct >= 0, pct <= 200,
              let epoch = (dict["resets_at"] as? Double) ?? (dict["resets_at"] as? Int).map(Double.init),
              epoch > 0,
              // дальше 400 суток вперёд это скорее миллисекунды, чем секунды
              epoch <= Date().timeIntervalSince1970 + 400 * 86400
        else { return nil }
        return PlanWindow(usedPct: min(100, pct), resetsAt: Date(timeIntervalSince1970: epoch))
    }

    /// Ответ `account/rateLimits/read` из `codex app-server`.
    static func codex(result: [String: Any]) -> PlanUsage? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        var usage = PlanUsage(fiveHour: nil, sevenDay: nil, updated: Date())
        // primary и secondary не привязаны к окну, их различает длительность
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  let pct = window["usedPercent"] as? Double,
                  let resets = window["resetsAt"] as? Double else { continue }
            let value = PlanWindow(usedPct: min(100, max(0, pct)), resetsAt: Date(timeIntervalSince1970: resets))
            if let minutes = window["windowDurationMins"] as? Int, minutes <= 24 * 60 {
                usage.fiveHour = value
            } else {
                usage.sevenDay = value
            }
        }
        return usage.fiveHour != nil || usage.sevenDay != nil ? usage : nil
    }
}

/// Лимиты Codex берутся у самого Codex: `codex app-server` отвечает на `account/rateLimits/read`.
/// Если Codex не установлен или не вошёл в аккаунт, лимитов просто нет.
enum CodexLimits {
    static func executable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          "\(home)/.npm-global/bin/codex", "\(home)/.volta/bin/codex", "\(home)/.bun/bin/codex",
                          "\(home)/Library/pnpm/codex"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(nvm)/\($0)/bin/codex" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func fetch() async -> PlanUsage? {
        guard let codex = executable() else { return nil }
        return await Task.detached { read(codex: codex) }.value
    }

    private static func read(codex: String) -> PlanUsage? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [URL(fileURLWithPath: codex).deletingLastPathComponent().path,
                       "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer { if process.isRunning { process.terminate() } }

        // Через 15 секунд сдаёмся: завершение процесса закрывает вывод и обрывает чтение.
        let giveUp = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: giveUp)
        defer { giveUp.cancel() }

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"visor","version":"1"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read"}"#,
        ]
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))

        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      object["id"] as? Int == 2 else { continue }
                return (object["result"] as? [String: Any]).flatMap(PlanParser.codex(result:))
            }
        }
    }
}
