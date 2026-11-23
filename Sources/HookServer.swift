import Darwin
import Foundation

/// Пути приложения. Всё лежит в ~/Library/Application Support/Visor.
enum VisorPaths {
    static let supportDir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Visor", isDirectory: true)
    static let socketPath = supportDir.appendingPathComponent("visor.sock").path
    static let relayURL = supportDir.appendingPathComponent("bin/visor-hook")
    static let soundsDir = supportDir.appendingPathComponent("Sounds", isDirectory: true)
    static let shelfDir = supportDir.appendingPathComponent("Shelf", isDirectory: true)
    static let statusRelayURL = supportDir.appendingPathComponent("bin/visor-statusline")
    /// Прежняя строка состояния пользователя: её вывод Visor продолжает печатать.
    static let previousStatusLineURL = supportDir.appendingPathComponent("statusline-previous.txt")
}

/// Скрипт, который агент вызывает как хук. Он только перекладывает JSON агента в сокет приложения
/// и печатает ответ. Если приложение не запущено, он выходит сразу и всегда с кодом 0: агента он не задерживает.
enum HookRelay {
    static let script = """
    #!/bin/sh
    # Visor: ретранслятор хуков. Аргументы: агент (claude или codex) и сколько секунд ждать ответа.
    SOCK="$HOME/Library/Application Support/Visor/visor.sock"
    [ -S "$SOCK" ] || exit 0
    { printf '{"visor_agent":"%s"}\\n' "${1:-claude}"; cat | tr -d '\\r\\n'; printf '\\n'; } | /usr/bin/nc -U -w "${2:-3}" "$SOCK" 2>/dev/null
    exit 0
    """

    /// Строка состояния Claude Code. Отдаёт лимиты приложению и печатает вывод прежней строки, если она была.
    static let statusScript = """
    #!/bin/sh
    # Visor: строка состояния Claude Code. Всегда выходит с кодом 0.
    IN=$(cat)
    SOCK="$HOME/Library/Application Support/Visor/visor.sock"
    if [ -S "$SOCK" ]; then
      { printf '{"visor_agent":"claude-status"}\\n'; printf '%s' "$IN" | tr -d '\\r\\n'; printf '\\n'; } | /usr/bin/nc -U -w 2 "$SOCK" >/dev/null 2>&1
    fi
    PREV="$HOME/Library/Application Support/Visor/statusline-previous.txt"
    if [ -s "$PREV" ]; then printf '%s' "$IN" | /bin/sh -c "$(cat "$PREV")"; fi
    exit 0
    """

    static func install() {
        let fm = FileManager.default
        let dir = VisorPaths.relayURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: VisorPaths.supportDir.path)
        for (url, text) in [(VisorPaths.relayURL, script), (VisorPaths.statusRelayURL, statusScript)] {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
}

/// Ответ агенту. Закрывает соединение ровно один раз, из любого потока.
final class HookReply: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var finished = false

    init(fd: Int32) { self.fd = fd }

    /// Строка уходит агенту как есть. `nil` значит «ничего не отвечать»: агент спросит сам, в терминале.
    func send(_ line: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        guard fd >= 0 else { return }
        if let line {
            let bytes = Array((line + "\n").utf8)
            var sent = 0
            while sent < bytes.count {
                let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
                if n <= 0 { break }
                sent += n
            }
        }
        close(fd)
    }

    deinit {
        if !finished, fd >= 0 { close(fd) }
    }
}

struct HookRequest: Sendable {
    let agent: String
    let body: Data
    let reply: HookReply
}

/// Сервер на сокете Unix. Принимает по одному соединению на событие агента:
/// первая строка это заголовок `{"visor_agent":"…"}`, вторая это JSON события.
final class HookServer: @unchecked Sendable {
    enum Failure: Error { case path, socket, bind, listen }

    private let queue = DispatchQueue(label: "visor.hookserver")
    private var source: DispatchSourceRead?
    private let maxBody = 8 * 1024 * 1024

    func start(handler: @escaping @Sendable (HookRequest) -> Void) throws {
        let path = VisorPaths.socketPath
        try? FileManager.default.createDirectory(at: VisorPaths.supportDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw Failure.path }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, byte) in pathBytes.enumerated() { raw[i] = UInt8(bitPattern: byte) }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard bound == 0 else { close(fd); throw Failure.bind }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); throw Failure.listen }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(on: fd, handler: handler) }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        unlink(VisorPaths.socketPath)
    }

    private func acceptAll(on listener: Int32, handler: @escaping @Sendable (HookRequest) -> Void) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { break }
            // Принятое соединение не должно наследовать неблокирующий режим слушающего.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                read(client: client, handler: handler)
            }
        }
    }

    private func read(client: Int32, handler: @Sendable (HookRequest) -> Void) {
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var lines = 0
        while data.count < maxBody, lines < 2 {
            let n = recv(client, &buffer, buffer.count, 0)
            if n <= 0 { break }
            lines += buffer[0..<n].reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            data.append(buffer, count: n)
        }

        let newline = UInt8(ascii: "\n")
        guard let first = data.firstIndex(of: newline),
              let second = data[(first + 1)...].firstIndex(of: newline) else {
            close(client)
            return
        }
        let header = data[..<first]
        let body = data[(first + 1)..<second]
        let agent = ((try? JSONSerialization.jsonObject(with: header)) as? [String: Any])?["visor_agent"] as? String ?? "claude"
        handler(HookRequest(agent: agent, body: Data(body), reply: HookReply(fd: client)))
    }
}
