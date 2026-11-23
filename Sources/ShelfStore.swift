import AppKit
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    /// Путь внутри хранилища: «<id>/<имя файла>».
    var relativePath: String
    var added: Date
    var isScreenshot: Bool
}

/// Полка: файлы, которые лежат на острове, пока они не понадобятся. Хранятся копиями в Application Support,
/// оригиналы не трогаются. Сами не удаляются никогда: только по крестику.
@MainActor @Observable
final class ShelfStore {
    static let shared = ShelfStore(root: VisorPaths.shelfDir)

    /// Новые сверху.
    private(set) var items: [ShelfItem] = []
    var selection: Set<UUID> = []

    @ObservationIgnored private let root: URL
    @ObservationIgnored private var thumbnails: [UUID: NSImage] = [:]

    init(root: URL) {
        self.root = root
        load()
    }

    private var indexURL: URL { root.appendingPathComponent("index.json") }

    func url(for item: ShelfItem) -> URL {
        root.appendingPathComponent(item.relativePath)
    }

    // MARK: Добавление и удаление

    /// Копирует файлы на полку. Возвращает, сколько добавилось.
    @discardableResult
    func add(urls: [URL], screenshot: Bool = false) -> Int {
        let fm = FileManager.default
        var added = 0
        for source in urls where source.isFileURL && fm.fileExists(atPath: source.path) {
            let id = UUID()
            let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
            let name = source.lastPathComponent
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let target = folder.appendingPathComponent(name)
                if screenshot {
                    // Снимок переезжает на полку и исчезает с рабочего стола. Если переместить не вышло, остаётся копия.
                    do { try fm.moveItem(at: source, to: target) } catch { try fm.copyItem(at: source, to: target) }
                } else {
                    try fm.copyItem(at: source, to: target) // на APFS это клон, места не занимает
                }
            } catch {
                try? fm.removeItem(at: folder)
                continue
            }
            items.insert(ShelfItem(id: id, name: name, relativePath: "\(id.uuidString)/\(name)", added: Date(),
                                   isScreenshot: screenshot), at: 0)
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    func selectAll() { selection = Set(items.map(\.id)) }

    /// Открывает файл с полки в программе по умолчанию.
    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(url(for: item))
    }

    func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for item in items where ids.contains(item.id) {
            try? FileManager.default.removeItem(at: url(for: item).deletingLastPathComponent())
            thumbnails.removeValue(forKey: item.id)
        }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        save()
    }

    func removeSelected() {
        remove(selection)
    }

    // MARK: Выбор

    /// Клик выбирает одну карточку, Shift+клик добавляет к выбору или убирает из него.
    func select(_ id: UUID, extend: Bool) {
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if selection == [id] {
            selection = []
        } else {
            selection = [id]
        }
    }

    /// Файлы для перетаскивания. Если тащат невыбранную карточку, она становится единственным выбором, как в Finder.
    func dragURLs(starting id: UUID) -> [(url: URL, item: ShelfItem)] {
        if !selection.contains(id) { selection = [id] }
        return items.filter { selection.contains($0.id) }.map { (url($0 as ShelfItem), $0) }
    }

    private func url(_ item: ShelfItem) -> URL { url(for: item) }

    // MARK: Миниатюры

    func cachedThumbnail(for item: ShelfItem) -> NSImage? { thumbnails[item.id] }

    func primeThumbnail(_ image: NSImage, for id: UUID) { thumbnails[id] = image }

    func thumbnail(for item: ShelfItem) async -> NSImage {
        if let cached = thumbnails[item.id] { return cached }
        let fileURL = url(for: item)
        let request = QLThumbnailGenerator.Request(fileAt: fileURL, size: CGSize(width: 120, height: 80), scale: 2,
                                                   representationTypes: .thumbnail)
        let image: NSImage
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            image = representation.nsImage
        } else {
            image = NSWorkspace.shared.icon(forFile: fileURL.path)
        }
        thumbnails[item.id] = image
        return image
    }

    // MARK: Хранение

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Записи без файла (его могли удалить руками) пропускаются.
        items = ((try? decoder.decode([ShelfItem].self, from: data)) ?? [])
            .filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(items) { try? data.write(to: indexURL, options: .atomic) }
    }

    // MARK: Перетаскивание на остров

    /// Идёт ли сейчас перетаскивание файлов. Нужно, чтобы остров раскрылся сам.
    static func dragHasFiles() -> Bool {
        NSPasteboard(name: .drag).canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Принимает файлы, брошенные на остров.
    static func accept(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in ShelfStore.shared.add(urls: [url]) }
            }
        }
    }
}

/// Следит за папкой со скриншотами и кладёт новые снимки на полку.
/// Папка берётся из настроек системы (по умолчанию «Рабочий стол»).
@MainActor
final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher(directory: ScreenshotWatcher.systemLocation(), store: ShelfStore.shared)

    private let directory: URL
    private let store: ShelfStore
    private var source: DispatchSourceFileSystemObject?
    private var seen: Set<String> = []
    private var startedAt = Date()
    private var scheduled = false

    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "mov"]
    private static let namePrefixes = ["Screenshot", "Screen Shot", "Screen Recording", "Снимок экрана", "Запись экрана"]

    init(directory: URL, store: ShelfStore) {
        self.directory = directory
        self.store = store
    }

    /// Папка, куда система сохраняет снимки: `defaults read com.apple.screencapture location`.
    static func systemLocation() -> URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    func start() {
        startedAt = Date().addingTimeInterval(-1)
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// Снимок сначала пишется во временный файл и переименовывается: ждём, пока всё уляжется.
    private func scheduleScan() {
        guard !scheduled else { return }
        scheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.scheduled = false
            self?.scan()
        }
    }

    private func scan() {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return }
        for url in urls where !seen.contains(url.path) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, Self.extensions.contains(url.pathExtension.lowercased()),
                  let created = values?.creationDate, created >= startedAt, Self.isScreenshot(url) else { continue }
            seen.insert(url.path)
            store.add(urls: [url], screenshot: true)
        }
    }

    /// Имя, как у системного снимка, или пометка, которую система ставит на файл.
    static func isScreenshot(_ url: URL) -> Bool {
        if namePrefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) { return true }
        return getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }
}
