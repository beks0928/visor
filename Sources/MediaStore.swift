import AppKit
import Foundation
import Observation

// MARK: Заметки

struct Note: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var body: String
    var pinned: Bool
    var updated: Date

    var title: String {
        let first = body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let clean = first.trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "Пустая заметка" : String(clean.prefix(40))
    }
}

@MainActor @Observable
final class NotesStore {
    static let shared = NotesStore(directory: VisorPaths.supportDir)

    private(set) var notes: [Note] = []
    @ObservationIgnored private let directory: URL

    init(directory: URL) {
        self.directory = directory
        load()
    }

    private var fileURL: URL { directory.appendingPathComponent("notes.json") }

    /// Закреплённые сверху, затем по времени изменения.
    var ordered: [Note] {
        notes.sorted { ($0.pinned ? 1 : 0, $0.updated) > ($1.pinned ? 1 : 0, $1.updated) }
    }

    @discardableResult
    func add(_ body: String = "") -> Note {
        let note = Note(id: UUID(), body: body, pinned: false, updated: Date())
        notes.append(note)
        save()
        return note
    }

    func update(_ id: UUID, body: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].body != body else { return }
        notes[index].body = body
        notes[index].updated = Date()
        save()
    }

    func togglePin(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].pinned.toggle()
        save()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    func note(_ id: UUID?) -> Note? { notes.first { $0.id == id } }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        notes = (try? decoder.decode([Note].self, from: data)) ?? []
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

// MARK: Телесуфлёр

@MainActor @Observable
final class TeleprompterStore {
    static let shared = TeleprompterStore(defaults: .standard)

    var text: String { didSet { defaults.set(text, forKey: "teleprompter.text") } }
    /// Скорость прокрутки в пунктах в секунду.
    var speed: Double { didSet { defaults.set(speed, forKey: "teleprompter.speed") } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "teleprompter.font") } }
    var mirrored: Bool { didSet { defaults.set(mirrored, forKey: "teleprompter.mirrored") } }
    private(set) var offset: Double = 0
    private(set) var isRunning = false
    /// Высоту текста сообщает вид: по ней прокрутка останавливается в конце.
    var contentHeight: Double = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var timer: Timer?

    static let tick = 1.0 / 30

    init(defaults: UserDefaults) {
        self.defaults = defaults
        text = defaults.string(forKey: "teleprompter.text") ?? ""
        let savedSpeed = defaults.double(forKey: "teleprompter.speed")
        speed = savedSpeed > 0 ? savedSpeed : 40
        let savedFont = defaults.double(forKey: "teleprompter.font")
        fontSize = savedFont > 0 ? savedFont : 26
        mirrored = defaults.bool(forKey: "teleprompter.mirrored")
    }

    func start() {
        guard !isRunning, !text.isEmpty else { return }
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance(by: Self.tick) }
        }
    }

    func pause() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    func toggle() { isRunning ? pause() : start() }

    func rewind() {
        offset = 0
    }

    func advance(by seconds: TimeInterval) {
        guard isRunning else { return }
        offset += speed * seconds
        if contentHeight > 0, offset >= contentHeight {
            offset = contentHeight
            pause()
        }
    }
}
