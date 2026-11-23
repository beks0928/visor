import Darwin
import Foundation

/// Живая сессия Claude Code по файлу процесса.
struct ClaudeSessionEntry: Equatable, Sendable {
    let pid: Int
    let sessionID: String
    let cwd: String
    let name: String
    /// «busy» пока Claude работает, «idle» когда ждёт вас.
    let status: String
    let updated: Date
}

/// Claude Code пишет по файлу на каждый свой процесс: `~/.claude/sessions/<pid>.json`.
/// Формат внутренний и может измениться, поэтому это запасной источник: по нему сессии находятся даже без событий хуков
/// (например, после перезапуска Visor). События хуков точнее и главнее.
enum ClaudeSessionFiles {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }

    static func parse(_ data: Data) -> ClaudeSessionEntry? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = object["pid"] as? Int, let sessionID = object["sessionId"] as? String, !sessionID.isEmpty else { return nil }
        let updated = (object["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        return ClaudeSessionEntry(pid: pid, sessionID: sessionID, cwd: object["cwd"] as? String ?? "",
                                  name: object["name"] as? String ?? "", status: object["status"] as? String ?? "",
                                  updated: updated)
    }

    /// Процесс жив и это действительно claude: номер процесса мог достаться чужой программе.
    static func isClaudeProcess(_ pid: Int) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer).lowercased().contains("claude")
    }

    static func scan(in directory: URL = directory, isAlive: (Int) -> Bool = isClaudeProcess) -> [ClaudeSessionEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" && Int($0.deletingPathExtension().lastPathComponent) != nil }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap(parse) }
            .filter { isAlive($0.pid) }
    }
}
