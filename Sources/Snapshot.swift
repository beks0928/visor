import AppKit
import AVFoundation
import SwiftUI

/// Отладочный режим `Visor --snapshot <папка>`: рисует остров в PNG, проверяет сохранение настроек
/// и разбор событий агентов и выходит. Нужен, чтобы проверять вид без права «запись экрана».
@MainActor
enum Snapshot {
    static func write(to directory: String) {
        let notch: CGFloat = 179
        let row: CGFloat = 32
        let closedSize = CGSize(width: notch + IslandLayout.leftWing + IslandLayout.rightWing, height: row)
        let openSize = CGSize(width: 860, height: 380)

        // Свои настройки для снимков: не трогаем то, что сохранил пользователь.
        let suite = "com.beksultan.visor.snapshot"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite) ?? .standard

        let empty = IslandModel(defaults: defaults)
        save(ClosedIsland(model: empty, notchWidth: notch, rowHeight: row).frame(width: closedSize.width, height: closedSize.height),
             to: directory + "/closed.png")

        AgentCenter.shared.seedForSnapshot()
        let live = IslandModel(defaults: defaults)
        save(ClosedIsland(model: live, notchWidth: notch, rowHeight: row).frame(width: closedSize.width, height: closedSize.height),
             to: directory + "/closed-agent.png")
        live.rotation = 1
        save(ClosedIsland(model: live, notchWidth: notch, rowHeight: row).frame(width: closedSize.width, height: closedSize.height),
             to: directory + "/closed-agent-capsule.png")

        let agents = IslandModel(defaults: defaults)
        save(OpenIsland(model: agents, rowHeight: row, onClose: {}).frame(width: openSize.width, height: openSize.height),
             to: directory + "/open-agents.png")

        let sound = IslandModel(defaults: defaults)
        sound.page = .settings
        sound.settingsTab = .sound
        save(OpenIsland(model: sound, rowHeight: row, onClose: {}).frame(width: openSize.width, height: openSize.height),
             to: directory + "/open-settings-sound.png")

        let power = IslandModel(defaults: defaults)
        power.page = .settings
        power.settingsTab = .awake
        save(OpenIsland(model: power, rowHeight: row, onClose: {}).frame(width: openSize.width, height: openSize.height),
             to: directory + "/open-settings-power.png")

        let chatSettings = IslandModel(defaults: defaults)
        chatSettings.page = .settings
        chatSettings.settingsTab = .chat
        save(OpenIsland(model: chatSettings, rowHeight: row, onClose: {}).frame(width: openSize.width, height: openSize.height),
             to: directory + "/open-settings-chat.png")

        let addPage = IslandModel(defaults: defaults)
        addPage.page = .add
        save(OpenIsland(model: addPage, rowHeight: row, onClose: {}).frame(width: openSize.width, height: openSize.height),
             to: directory + "/open-add.png")

        let connect = IslandModel(defaults: defaults)
        connect.page = .settings
        connect.settingsTab = .agents
        save(OpenIsland(model: connect, rowHeight: row, onClose: {}).frame(width: openSize.width, height: openSize.height),
             to: directory + "/open-settings-agents.png")

        // Что изменится в настоящих файлах, только чтение: ничего не записывается.
        for target in AgentTarget.allCases {
            guard let plan = try? AgentInstaller.plan(target, install: true) else {
                print("plan \(target.rawValue): ошибка чтения")
                continue
            }
            print("plan \(target.rawValue): +\(plan.diff.filter { $0.kind == .added }.count) −\(plan.diff.filter { $0.kind == .removed }.count), копия: \(plan.hasBackup)")
            save(PlanConfirm(plan: plan, onCancel: {}, onApply: {}).padding(14).frame(width: 860, height: 380).background(Color.black),
                 to: directory + "/plan-\(target.rawValue).png")
        }

        if let plan = try? AgentInstaller.plan(.claude, install: true, feature: .limits) {
            print("plan limits: +\(plan.diff.filter { $0.kind == .added }.count) −\(plan.diff.filter { $0.kind == .removed }.count), прежняя строка: \(plan.previousStatusLine ?? "нет")")
            save(PlanConfirm(plan: plan, onCancel: {}, onApply: {}).padding(14).frame(width: 860, height: 380).background(Color.black),
                 to: directory + "/plan-limits.png")
        }

        // Капсула лимитов для свёрнутого острова.
        let limitsModel = IslandModel(defaults: defaults)
        limitsModel.rotation = 2
        save(ClosedIsland(model: limitsModel, notchWidth: notch, rowHeight: row).frame(width: closedSize.width, height: closedSize.height),
             to: directory + "/closed-limits.png")

        AgentCenter.shared.clearForSnapshot()
        print(shelfSelfTest(renderTo: directory) ? "shelf: OK" : "shelf: FAIL")
        print(clipboardSelfTest(renderTo: directory) ? "clipboard: OK" : "clipboard: FAIL")
        print(timeSelfTest(renderTo: directory) ? "time: OK" : "time: FAIL")
        print(plansSelfTest(renderTo: directory) ? "plans: OK" : "plans: FAIL")
        print(toolsSelfTest(renderTo: directory) ? "tools: OK" : "tools: FAIL")
        print(devSelfTest(renderTo: directory) ? "dev: OK" : "dev: FAIL")
        print(mediaSelfTest(renderTo: directory) ? "media: OK" : "media: FAIL")
        print(lyricsSelfTest() ? "lyrics: OK" : "lyrics: FAIL")
        print(prefsSelfTest(renderTo: directory) ? "prefs: OK" : "prefs: FAIL")
        print(sessionFilesSelfTest() ? "sessions: OK" : "sessions: FAIL")
        print(keysSelfTest(renderTo: directory) ? "keys: OK" : "keys: FAIL")
        print(limitsSelfTest() ? "limits: OK" : "limits: FAIL")
        print(persistenceSelfTest() ? "persistence: OK" : "persistence: FAIL")
        print(agentFlowSelfTest() ? "agent flow: OK" : "agent flow: FAIL")
        print(socketSelfTest() ? "socket relay: OK" : "socket relay: FAIL")
        for event in SoundEvent.allCases {
            let player = try? AVAudioPlayer(data: SoundEngine.synthesize(event))
            print("sound \(event.rawValue): \(player.map { String(format: "%.2f с", $0.duration) } ?? "ошибка")")
        }
    }

    /// Полка во временной папке: копии, выбор, удаление, сохранение и слежение за скриншотами.
    private static func shelfSelfTest(renderTo directory: String) -> Bool {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("visor-shelf-test-\(UUID().uuidString)")
        let root = tmp.appendingPathComponent("store"), shots = tmp.appendingPathComponent("shots"), source = tmp.appendingPathComponent("source")
        try? fm.createDirectory(at: shots, withIntermediateDirectories: true)
        try? fm.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        func image(_ color: NSColor) -> NSImage {
            let image = NSImage(size: NSSize(width: 160, height: 100))
            image.lockFocus()
            color.setFill()
            NSRect(x: 0, y: 0, width: 160, height: 100).fill()
            image.unlockFocus()
            return image
        }
        func pngData(_ color: NSColor) -> Data {
            guard let tiff = image(color).tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
            return rep.representation(using: .png, properties: [:]) ?? Data()
        }
        let colors: [NSColor] = [.systemIndigo, .systemTeal, .systemOrange, .systemPink]
        var urls: [URL] = []
        for (index, color) in colors.enumerated() {
            let url = source.appendingPathComponent("Снимок экрана \(index + 1).png")
            try? pngData(color).write(to: url)
            urls.append(url)
        }
        let note = source.appendingPathComponent("Расписание.txt")
        try? Data("урок 1".utf8).write(to: note)
        urls.append(note)

        let store = ShelfStore(root: root)
        let added = store.add(urls: urls)
        let copied = store.items.allSatisfy { fm.fileExists(atPath: store.url(for: $0).path) }
        let originalsStay = urls.allSatisfy { fm.fileExists(atPath: $0.path) }
        let addOK = added == 5 && store.items.count == 5 && copied && originalsStay

        // Выбор: клик, Shift+клик, повторный клик по единственной выбранной.
        let ids = store.items.map(\.id)
        store.select(ids[0], extend: false)
        let one = store.selection == [ids[0]]
        store.select(ids[1], extend: true)
        let two = store.selection == [ids[0], ids[1]]
        store.select(ids[1], extend: true)
        let backToOne = store.selection == [ids[0]]
        store.select(ids[0], extend: false)
        let cleared = store.selection.isEmpty
        // Перетаскивание невыбранной карточки делает её единственным выбором, выбранной уносит всю выборку.
        let single = store.dragURLs(starting: ids[2]).count == 1
        store.select(ids[3], extend: true)
        let group = store.dragURLs(starting: ids[3]).count == 2
        let selectOK = one && two && backToOne && cleared && single && group

        // Снимок для просмотра: две выбранные карточки.
        for item in store.items {
            let color = colors[Int(item.name.last { $0.isNumber }.map(String.init) ?? "1")! % colors.count]
            store.primeThumbnail(image(color), for: item.id)
        }
        store.selection = [ids[0], ids[2]]
        let page = ShelfPage(model: IslandModel(defaults: UserDefaults(suiteName: "com.beksultan.visor.snapshot") ?? .standard), store: store)
        save(page.padding(14).frame(width: 860, height: 340, alignment: .top).background(Color.black), to: directory + "/shelf.png")

        // Удаление чистит файл и запись, выбор убирается.
        let doomed = store.items[0]
        let doomedFolder = store.url(for: doomed).deletingLastPathComponent()
        store.remove([doomed.id])
        let removeOK = store.items.count == 4 && !fm.fileExists(atPath: doomedFolder.path) && !store.selection.contains(doomed.id)
        let reloaded = ShelfStore(root: root)
        let persistOK = reloaded.items.map(\.id) == store.items.map(\.id)

        // Скриншоты: подходящий файл попадает на полку, обычный нет.
        let watcher = ScreenshotWatcher(directory: shots, store: store)
        watcher.start()
        let before = store.items.count
        try? pngData(.systemGreen).write(to: shots.appendingPathComponent("Screenshot 2026-10-31 at 22.30.00.png"))
        try? Data("не снимок".utf8).write(to: shots.appendingPathComponent("notes.txt"))
        try? pngData(.systemRed).write(to: shots.appendingPathComponent("photo.png")) // не по имени, без пометки системы
        let end = Date().addingTimeInterval(4)
        while store.items.count == before, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        // даём шанс лишним файлам попасть на полку, если бы фильтр был неверным
        let settle = Date().addingTimeInterval(1.2)
        while Date() < settle { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        watcher.stop()
        let watchOK = store.items.count == before + 1 && store.items.first?.isScreenshot == true
            && store.items.first?.name.hasPrefix("Screenshot") == true

        print("shelf: add=\(addOK) select=\(selectOK) remove=\(removeOK) persist=\(persistOK) watch=\(watchOK)")
        return addOK && selectOK && removeOK && persistOK && watchOK
    }

    /// Буфер на отдельном буфере обмена во временной папке: история, закрепы, секреты, цвета, сниппеты.
    private static func clipboardSelfTest(renderTo directory: String) -> Bool {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("visor-clip-test-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let formatKey = "clipboard.colorFormat"
        let savedFormat = UserDefaults.standard.string(forKey: formatKey) // тест не должен менять настройку пользователя
        let pb = NSPasteboard.withUniqueName()
        defer {
            try? fm.removeItem(at: tmp)
            pb.releaseGlobally()
            if let savedFormat { UserDefaults.standard.set(savedFormat, forKey: formatKey) } else { UserDefaults.standard.removeObject(forKey: formatKey) }
        }
        let store = ClipboardStore(pasteboard: pb, directory: tmp)

        func put(_ text: String, extra: [NSPasteboard.PasteboardType] = []) {
            pb.clearContents()
            pb.declareTypes([.string] + extra, owner: nil)
            pb.setString(text, forType: .string)
            for type in extra { pb.setString("1", forType: type) }
        }

        put("привет"); store.poll()
        let first = store.items.count == 1 && store.items.first?.text == "привет"
        put("привет"); store.poll()
        let dedupe = store.items.count == 1
        put("пароль123", extra: [NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")]); store.poll()
        let secret = store.items.count == 1 && !store.items.contains { $0.text == "пароль123" }
        put("#5B8CFF"); store.poll()
        put("https://github.com/example/project"); store.poll()
        let kinds = store.items.first { $0.text == "#5B8CFF" }?.kind == .color
            && store.items.first { $0.text.hasPrefix("https") }?.kind == .link
            && store.items.first { $0.text == "привет" }?.kind == .text

        // Запись с цветом берём заранее: лимит ниже вытеснит её из истории.
        guard let color = store.items.first(where: { $0.text == "#5B8CFF" }) else { return false }

        // Закреп переживает переполнение истории, остальное вытесняется по лимиту.
        if let target = store.items.first(where: { $0.text == "привет" }) { store.togglePin(target.id) }
        for index in 0..<50 { store.record("запись \(index)") }
        let limit = store.items.filter { !$0.pinned }.count == ClipboardStore.limit
            && store.items.contains { $0.text == "привет" && $0.pinned }

        // Своя запись в буфер не попадает в историю повторно.
        let before = store.items.count
        if let top = store.items.first { store.copy(top) }
        store.poll()
        let own = store.items.count == before && pb.string(forType: .string) == "запись 49"

        // Цвет копируется в выбранном формате.
        store.setColorFormat(.rgb); store.copy(color)
        let rgb = pb.string(forType: .string) == "rgb(91, 140, 255)"
        store.setColorFormat(.swiftUI); store.copy(color)
        let swift = pb.string(forType: .string) == "Color(red: 0.357, green: 0.549, blue: 1.000)"
        store.setColorFormat(.hex)
        store.addPicked((91, 140, 255)) // пипетка: тот же цвет, поднимается наверх
        let pick = store.items.first?.text == "#5B8CFF" && pb.string(forType: .string) == "#5B8CFF"

        // Хранение: на диске только закреплённое, сниппеты правятся руками.
        let reloaded = ClipboardStore(pasteboard: pb, directory: tmp)
        let pinnedOnly = reloaded.items.count == 1 && reloaded.items.first?.text == "привет" && reloaded.items.first?.pinned == true
        store.addSnippet(title: "Адрес", text: "Алматы, ул. Примерная 12")
        let snippetSaved = ClipboardStore(pasteboard: pb, directory: tmp).snippets.map(\.title) == ["Адрес"]
        let edited = #"[{"id":"11111111-1111-1111-1111-111111111111","title":"Почта","text":"a@b.c"},{"id":"22222222-2222-2222-2222-222222222222","title":"Телефон","text":"+7 700 000 00 00"}]"#
        try? Data(edited.utf8).write(to: tmp.appendingPathComponent("snippets.json"))
        store.reloadSnippets()
        let externalEdit = store.snippets.map(\.title) == ["Почта", "Телефон"] && store.snippets.allSatisfy { !$0.pinned }
        // Закрепленный сниппет встаёт первым и остаётся так после перезапуска.
        if let second = store.snippets.last { store.toggleSnippetPin(second.id) }
        let pinnedFirst = store.orderedSnippets.map(\.title) == ["Телефон", "Почта"]
        let pinSaved = ClipboardStore(pasteboard: pb, directory: tmp).orderedSnippets.first?.title == "Телефон"
        if let second = store.snippets.last { store.toggleSnippetPin(second.id) }
        let unpinned = store.orderedSnippets.map(\.title) == ["Почта", "Телефон"]
        let snippetPin = pinnedFirst && pinSaved && unpinned

        // Вид для просмотра.
        let show = ClipboardStore(pasteboard: pb, directory: tmp.appendingPathComponent("show"))
        for text in ["https://github.com/example/project", "#FFB454", "npm run dev -- --port 5173", "#5B8CFF",
                     "name@example.com", "+7 700 000 00 00", "Город, ул. Примерная 12"] { show.record(text) }
        for text in ["+7 700 000 00 00", "name@example.com"] {
            if let item = show.items.first(where: { $0.text == text }) { show.togglePin(item.id) }
        }
        show.addSnippet(title: "Адрес", text: "Алматы, ул. Примерная 12")
        show.addSnippet(title: "Телефон", text: "+7 700 000 00 00")
        show.addSnippet(title: "Почта", text: "name@example.com")
        let model = IslandModel(defaults: UserDefaults(suiteName: "com.beksultan.visor.snapshot") ?? .standard)
        save(ClipboardPage(model: model, store: show).padding(14).frame(width: 860, height: 380, alignment: .top).background(Color.black),
             to: directory + "/clipboard.png")

        print("clipboard: first=\(first) dedupe=\(dedupe) secret=\(secret) kinds=\(kinds) limit=\(limit) own=\(own) rgb=\(rgb) swift=\(swift) pick=\(pick) pinnedOnly=\(pinnedOnly) snippet=\(snippetSaved) edit=\(externalEdit)")
        print("clipboard: snippetPin=\(snippetPin)")
        return first && dedupe && secret && kinds && limit && own && rgb && swift && pick && pinnedOnly && snippetSaved && externalEdit && snippetPin
    }

    /// Инструменты: калькулятор, проценты, единицы, валюты, курсы и их хранение.
    private static func toolsSelfTest(renderTo directory: String) -> Bool {
        var failures: [String] = []
        func expect(_ name: String, _ ok: Bool) { if !ok { failures.append(name) } }
        func norm(_ text: String?) -> String? {
            text?.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        }
        let rates = RateTable.builtIn
        func run(_ text: String, defaultCurrency: String = "KZT") -> ToolResult? {
            ToolsEngine.evaluate(text, rates: rates, defaultCurrency: defaultCurrency)
        }
        func value(_ text: String, _ expected: String?, defaultCurrency: String = "KZT") {
            let got = norm(run(text, defaultCurrency: defaultCurrency)?.value)
            expect("«\(text)» → \(expected ?? "ничего"), а получено \(got ?? "ничего")", got == expected)
        }

        // График курса: пара и сумма берутся из строки, архив разбирается по базовой валюте.
        let chartPair = run("100 usd в kzt")?.pair
        expect("график: пара и сумма из строки", chartPair == CurrencyPair(from: "USD", to: "KZT", amount: 100) && chartPair?.key == "USD>KZT")
        expect("график: у процентов пары нет", run("15% от 84000")?.pair == nil)
        let archive = Data(#"{"date":"2026-11-04","try":{"kzt":8.95,"usd":0.0238,"bad":0}}"#.utf8)
        let archived = RateHistory.parse(archive, base: "TRY")
        expect("график: разбор архива курсов", archived?["kzt"] == 8.95 && archived?["bad"] == nil && RateHistory.parse(archive, base: "USD") == nil)

        let gridNow = Date()
        let gridToday = RateHistory.gridDays(now: gridNow).map(\.text)
        let gridTomorrow = RateHistory.gridDays(now: gridNow.addingTimeInterval(86400)).map(\.text)
        expect("история: сетка из 10 дат, назавтра почти та же", gridToday.count == 10 && Set(gridToday).intersection(gridTomorrow).count >= 9)
        let historyFile = URL(fileURLWithPath: directory).appendingPathComponent("rate-history-test.json")
        let seeded = Dictionary(uniqueKeysWithValues: gridToday.enumerated().map { ("TRY>KZT|" + $1, 8.0 + Double($0) * 0.1) })
        try? JSONEncoder().encode(seeded).write(to: historyFile)
        let cachedHistory = RateHistory(file: historyFile)
        cachedHistory.load(CurrencyPair(from: "TRY", to: "KZT", amount: 100), live: 9.2)
        expect("история: кеш с диска рисует график сразу, без сети",
               cachedHistory.points.count == 11 && !cachedHistory.isLoading && !cachedHistory.failed && cachedHistory.points.last?.rate == 9.2)
        try? FileManager.default.removeItem(at: historyFile)

        // Валюты: свободный ввод, знак или слово, валюта по умолчанию.
        value("310$ в тенге", "140 538 ₸")
        value("100 долларов", "45 335 ₸")
        value("100 usd", "45 335 ₸")
        value("$100", "45 335 ₸")
        value("100usd в kzt", "45 335 ₸")
        value("5000 тг в евро", "9,88 €")
        value("€50 to usd", "55,83 $")
        value("100 тенге", "0,2206 $")
        value("100 в usd", "0,2206 $")
        value("100 usd", "8 041 ₽", defaultCurrency: "RUB") // валюта по умолчанию рубли
        value("100PLN в EUR", "22,72 €")
        expect("2.5к фунтов в рубли", norm(run("2.5к фунтов в рубли")?.headline)?.hasPrefix("2 500 £ =") == true)
        expect("1,5 млн руб в тенге", norm(run("1,5 млн руб в тенге")?.headline)?.hasPrefix("1 500 000 ₽ =") == true)
        expect("курс в подписи", run("310$ в тенге")?.detail == "Курс: 1 USD = 453,35 KZT")
        expect("другие валюты", norm(run("310$ в тенге")?.extras.joined(separator: " | ")) == "277,64 € | 24 927 ₽")

        // Проценты и калькулятор.
        value("15% от 84 000", "12 600")
        value("84000 + 15%", "96 600")
        value("12*(3+4)", "84")
        value("0xFF + 12", "267")
        value("2^3^2", "512")
        value("1 000 000 / 8", "125 000")
        value("10 / 0", nil)
        value("310", nil)
        value("привет", nil)

        // Единицы.
        value("5 миль в км", "8,0467 км")
        value("72 f в c", "22,2222 °C")
        value("180 см в футы", "5,9055 фут")
        value("100 km/h in mph", "62,1371 миль/ч")
        value("5 фунтов в кг", "2,268 кг")
        value("20 c в k", "293,15 K")
        value("1 гб в мб", "1 000 МБ")
        expect("фунты в валюте", run("100 фунтов в рубли")?.kind == .currency)

        // Курсы: разбор ответа, неудачный запрос, настоящий запрос и кеш.
        func sample(_ count: Int) -> Data {
            var rows = ["\"USD\":1"]
            for index in 0..<count { rows.append("\"C\(index)\":\(index + 2).5") }
            return Data("{\"result\":\"success\",\"time_last_update_unix\":1793404951,\"rates\":{\(rows.joined(separator: ","))}}".utf8)
        }
        let parsed = try? RatesStore.parse(sample(30))
        expect("разбор курсов", parsed?.perUSD.count == 31 && parsed?.updated == Date(timeIntervalSince1970: 1_793_404_951))
        expect("слишком мало курсов", (try? RatesStore.parse(sample(5))) == nil)
        expect("не успех", (try? RatesStore.parse(Data(#"{"result":"error"}"#.utf8))) == nil)

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("visor-rates-test-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        final class Flag { var done = false }
        func pump(_ flag: Flag, seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while !flag.done, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }

        let offline = RatesStore(directory: tmp, endpoint: URL(string: "http://127.0.0.1:9/")!)
        let offlineFlag = Flag()
        Task { await offline.refresh(); offlineFlag.done = true }
        pump(offlineFlag, seconds: 15)
        expect("без сети остаётся встроенный курс", offline.lastError != nil && offline.table == .builtIn && offline.isStale)

        let live = RatesStore(directory: tmp)
        let liveFlag = Flag()
        Task { await live.refresh(); liveFlag.done = true }
        pump(liveFlag, seconds: 20)
        var network = "нет сети, настоящий запрос пропущен"
        if live.lastError == nil {
            let kzt = live.table.perUSD["KZT"] ?? 0
            expect("настоящие курсы", live.table.perUSD.count > 100 && (200...900).contains(kzt) && !live.isStale)
            let cached = RatesStore(directory: tmp, endpoint: URL(string: "http://127.0.0.1:9/")!)
            expect("кеш курсов", cached.table.perUSD.count == live.table.perUSD.count && !cached.isStale)
            network = "курсы получены: \(live.table.perUSD.count) валют, 1 USD = \(Int(kzt)) KZT"
        }

        // Вид.
        let model = IslandModel(defaults: UserDefaults(suiteName: "com.beksultan.visor.snapshot") ?? .standard)
        save(ToolsPage(model: model).padding(14).frame(width: 860, height: 520, alignment: .top).background(Color.black),
             to: directory + "/tools.png")
        save(ToolsPage(model: model, translate: true).padding(14).frame(width: 860, height: 380, alignment: .top).background(Color.black),
             to: directory + "/tools-translate.png")
        let preset = TranslateModel()
        preset.text = "привет"
        preset.output = "hello"
        preset.status = .failed("Нет связи с Google. Проверьте интернет и нажмите «Повторить».")
        save(TranslateTool(model: model, state: preset).padding(14).frame(width: 860, height: 380, alignment: .top).background(Color.black),
             to: directory + "/tools-translate-download.png")

        // Направление перевода: язык по буквам, «Авто» и выбранный язык.
        let direction = TranslateModel()
        direction.text = "привет"
        let ruToEn = direction.sourceLanguage.minimalIdentifier == "ru" && direction.targetLanguage.minimalIdentifier == "en"
        direction.text = "hello"
        let enToRu = direction.sourceLanguage.minimalIdentifier == "en" && direction.targetLanguage.minimalIdentifier == "ru"
        direction.target = .german
        expect("направление перевода", ruToEn && enToRu && direction.targetLanguage.minimalIdentifier == "de"
               && TranslateModel.name(Locale.Language(identifier: "ru")) == "русский")

        // Разбор ответа Google и запрос.
        let sample = Data(#"[[["Привет, ","Hello, ",null,null,1],["мир","world",null,null,1]],null,"en"]"#.utf8)
        let googleParsed = GoogleTranslate.parse(sample)
        expect("разбор ответа Google", googleParsed == GoogleTranslate.Result(text: "Привет, мир", detected: "en")
               && GoogleTranslate.parse(Data("[]".utf8)) == nil)
        let body = String(data: GoogleTranslate.request(text: "a&b привет", target: "ru").httpBody ?? Data(), encoding: .utf8) ?? ""
        expect("запрос Google", body.contains("tl=ru") && body.contains("sl=auto") && body.contains("q=a%26b%20%D0%BF"))
        direction.target = .chinese
        expect("китайский для Google", direction.googleCode == "zh-CN")
        let googleFlag = Flag()
        var googleText: String?
        Task { googleText = (try? await GoogleTranslate.translate("привет", to: "en"))?.text; googleFlag.done = true }
        pump(googleFlag, seconds: 15)
        if let googleText {
            expect("настоящий перевод Google", googleText.lowercased().contains("hello") || googleText.lowercased().contains("hi"))
            network += "; Google: привет → \(googleText)"
        } else {
            network += "; Google недоступен"
        }

        print("tools: \(failures.isEmpty ? "все проверки" : "провалены:\n  " + failures.joined(separator: "\n  ")); \(network)")
        return failures.isEmpty
    }

    private static func mediaSelfTest(renderTo directory: String) -> Bool {
        var failures: [String] = []
        func expect(_ name: String, _ ok: Bool) { if !ok { failures.append(name) } }
        final class Flag { var done = false }
        func pump(_ flag: Flag, seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while !flag.done, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("visor-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let suite = "com.beksultan.visor.snapshot.media"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let keychain = "com.beksultan.visor.selftest.chat"
        for provider in ChatProvider.allCases { SecretStore.delete(provider.keyAccount, service: keychain) }
        defer { for provider in ChatProvider.allCases { SecretStore.delete(provider.keyAccount, service: keychain) } }

        // Запросы и ответы моделей.
        let history = [ChatMessage(role: .user, text: "Привет"), ChatMessage(role: .assistant, text: "Здравствуйте"), ChatMessage(role: .user, text: "Как дела?")]
        let claude = ChatAPI.request(provider: .claude, key: "k1", messages: history)
        let claudeBody = (claude?.httpBody).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        expect("запрос Claude", claude?.value(forHTTPHeaderField: "x-api-key") == "k1"
               && claude?.value(forHTTPHeaderField: "anthropic-version") != nil
               && claudeBody?["model"] as? String == "claude-sonnet-5-5"
               && (claudeBody?["messages"] as? [[String: Any]])?.count == 3)
        let gemini = ChatAPI.request(provider: .gemini, key: "k2", messages: history)
        let geminiBody = (gemini?.httpBody).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let geminiRoles = (geminiBody?["contents"] as? [[String: Any]])?.compactMap { $0["role"] as? String }
        expect("запрос Gemini", gemini?.value(forHTTPHeaderField: "x-goog-api-key") == "k2" && geminiRoles == ["user", "model", "user"]
               && gemini?.url?.absoluteString.contains("key=") == false)
        expect("ответы моделей",
               ChatAPI.parse(provider: .claude, data: Data(#"{"content":[{"type":"text","text":"Привет, "},{"type":"text","text":"мир"}]}"#.utf8)) == "Привет, мир"
               && ChatAPI.parse(provider: .gemini, data: Data(#"{"candidates":[{"content":{"parts":[{"text":"Да"}]}}]}"#.utf8)) == "Да"
               && ChatAPI.parse(provider: .claude, data: Data("{}".utf8)) == nil
               && ChatAPI.errorMessage(Data(#"{"error":{"message":"плохой ключ"}}"#.utf8)) == "плохой ключ")

        // Чат: ключ, хранение переписки, настоящий отказ по неверному ключу.
        let chat = ChatStore(directory: tmp, defaults: defaults, keychainService: keychain)
        expect("чат без ключа", !chat.hasKey)
        chat.saveKey("  bad-key  ")
        expect("ключ сохранён", chat.hasKey && SecretStore.get(ChatProvider.claude.keyAccount, service: keychain) == "bad-key")
        chat.preset(history, for: .gemini)
        chat.clear() // сохраняет переписку на диск (очищается только текущая модель)
        let reloaded = ChatStore(directory: tmp, defaults: defaults, keychainService: keychain)
        expect("переписка хранится", reloaded.conversations[.gemini]?.count == 3 && reloaded.hasKey)
        let flag = Flag()
        Task { await chat.send("Привет"); flag.done = true }
        pump(flag, seconds: 20)
        let offline = chat.error?.contains("Нет связи") == true
        expect("отказ по неверному ключу", flag.done && (offline || chat.error?.contains("не принял ключ") == true || chat.error?.contains("Claude:") == true))

        // Плеер.
        let nativeOutput = "Song\nArtist\nAlbum\n194.3\n12,5\nhttps://i.scdn.co/image/x\nplaying\n"
        let native = PlayerController.parseNative(nativeOutput, source: .spotify)
        expect("разбор плеера", native?.title == "Song" && native?.artist == "Artist" && native?.duration == 194.3
               && native?.position == 12.5 && native?.artworkURL?.host == "i.scdn.co" && native?.isPlaying == true
               && PlayerController.parseNative("S\nA\nB\n10\n1\n\npaused", source: .appleMusic)?.isPlaying == false
               && PlayerController.parseNative("S\nA\nB\n10\n1\n\npaused", source: .appleMusic)?.artworkURL == nil
               && PlayerController.parseNative("stopped", source: .spotify) == nil)
        let web = PlayerController.parseWeb("https://music.yandex.ru/album/1\tКак дела — Мот — слушать онлайн на Яндекс Музыке\n")
        expect("Яндекс Музыка во вкладке", web?.source.id == "web-yandex" && web?.title == "Как дела" && web?.artist == "Мот" && web?.isPlaying == nil
               && PlayerController.parseWeb("https://example.com\tHello\n") == nil)
        let t0 = Date()
        let running = NowPlaying(source: .spotify, title: "t", artist: "a", album: "", duration: 100, position: 10, artworkURL: nil, isPlaying: true, fetchedAt: t0)
        expect("позиция идёт сама", running.position(at: t0.addingTimeInterval(5)) == 15 && running.position(at: t0.addingTimeInterval(500)) == 100)
        expect("пауза стоит", NowPlaying(source: .spotify, title: "t", artist: "a", album: "", duration: 100, position: 10, artworkURL: nil, isPlaying: false, fetchedAt: t0)
            .position(at: t0.addingTimeInterval(5)) == 10)
        expect("таймлайн", SeekBar.seconds(at: 50, width: 200, duration: 100) == 25 && SeekBar.seconds(at: -5, width: 200, duration: 100) == 0
               && SeekBar.seconds(at: 900, width: 200, duration: 100) == 100 && SeekBar.format(125) == "2:05")
        // Перемотка: ползунок не откатывается, пока плеер ещё сообщает старую позицию.
        let seeker = PlayerController()
        seeker.nowPlaying = NowPlaying(source: .spotify, title: "t", artist: "a", album: "", duration: 200, position: 30,
                                       artworkURL: nil, isPlaying: false, fetchedAt: Date())
        let began = seeker.beginSeek(to: 120)
        let stale = NowPlaying(source: .spotify, title: "t", artist: "a", album: "", duration: 200, position: 30,
                               artworkURL: nil, isPlaying: false, fetchedAt: Date())
        let held = seeker.applySeekHold(to: stale)
        expect("перемотка применяется сразу", began?.app == "Spotify" && began?.target == 120 && seeker.nowPlaying?.position == 120)
        expect("старая позиция плеера отбрасывается", held?.position == 120)
        let confirmed = NowPlaying(source: .spotify, title: "t", artist: "a", album: "", duration: 200, position: 121,
                                   artworkURL: nil, isPlaying: false, fetchedAt: Date())
        expect("подтверждённая позиция принимается", seeker.applySeekHold(to: confirmed)?.position == 121
               && seeker.applySeekHold(to: stale)?.position == 30)
        seeker.nowPlaying = NowPlaying(source: .yandexApp, title: "t", artist: "a", album: "", duration: nil, position: nil,
                                       artworkURL: nil, isPlaying: nil, fetchedAt: Date())
        expect("перемотка недоступна без скриптов", seeker.beginSeek(to: 10) == nil)
        let deezerArtists = Data(#"{"data":[{"name":"Other","picture_medium":"https://a/1.jpg"},{"name":"Drake","picture_medium":"https://b/2.jpg"}]}"#.utf8)
        expect("Deezer", Deezer.parseArtistPicture(deezerArtists, name: "drake")?.host == "b"
               && Deezer.parseArtistPicture(deezerArtists, name: "Nobody") == nil
               && Deezer.parseTrackCover(Data(#"{"data":[{"album":{"cover_big":"https://c/3.jpg"}}]}"#.utf8))?.host == "c"
               && Deezer.primaryArtist("Drake, Future & Metro") == "Drake" && Deezer.primaryArtist("Мот") == "Мот")
        let livePlayer = PlayerController()
        let playerFlag = Flag()
        Task {
            await livePlayer.refresh()
            // Обложка и фото грузятся отдельной задачей: ждём, пока появятся.
            for _ in 0..<100 where livePlayer.nowPlaying != nil && (livePlayer.cover == nil || livePlayer.avatar == nil) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            playerFlag.done = true
        }
        pump(playerFlag, seconds: 40)
        let liveTrack = livePlayer.nowPlaying.map { "\($0.source.name): \($0.title) — \($0.artist), обложка \(livePlayer.cover != nil), фото \(livePlayer.avatar != nil), значок \(livePlayer.sourceIcon != nil)" } ?? "ничего не играет"

        // Заметки.
        let notes = NotesStore(directory: tmp)
        let first = notes.add("Первая\nвторая строка")
        let second = notes.add("Вторая")
        notes.update(first.id, body: "Первая, исправлена")
        notes.togglePin(second.id)
        expect("заметки", notes.ordered.first?.id == second.id && notes.note(first.id)?.title == "Первая, исправлена" && Note(id: UUID(), body: " \n ", pinned: false, updated: Date()).title == "Пустая заметка")
        let notesAgain = NotesStore(directory: tmp)
        expect("заметки хранятся", notesAgain.notes.count == 2 && notesAgain.notes.contains { $0.pinned })
        notesAgain.delete(first.id)
        expect("удаление заметки", notesAgain.notes.count == 1)

        // Телесуфлёр.
        let prompter = TeleprompterStore(defaults: defaults)
        prompter.text = "строка"
        prompter.speed = 50
        prompter.contentHeight = 80
        prompter.start()
        prompter.advance(by: 1)
        let afterSecond = prompter.offset
        prompter.advance(by: 5)
        expect("телесуфлёр", afterSecond == 50 && prompter.offset == 80 && !prompter.isRunning
               && TeleprompterStore(defaults: defaults).text == "строка" && TeleprompterStore(defaults: defaults).speed == 50)
        prompter.rewind()
        expect("перемотка", prompter.offset == 0)
        expect("диктовка выключена", Dictation.shared.state == .idle)

        // Вид.
        let model = IslandModel(defaults: defaults)
        func frame<V: View>(_ view: V) -> some View {
            view.padding(14).frame(width: 860, height: 380, alignment: .top).background(Color.black)
        }
        let shown = ChatStore(directory: tmp.appendingPathComponent("view"), defaults: defaults, keychainService: keychain)
        shown.preset([
            ChatMessage(role: .user, text: "Объясни, чем отличается процесс от потока"),
            ChatMessage(role: .assistant, text: "Процесс это программа в памяти со своим адресным пространством. Поток это цепочка команд внутри процесса, потоки делят память процесса."),
            ChatMessage(role: .user, text: "А где это нужно на практике?"),
        ], for: .claude)
        save(frame(ChatPage(model: model, store: shown)), to: directory + "/chat.png")
        shown.provider = .gemini
        save(frame(ChatPage(model: model, store: shown)), to: directory + "/chat-key.png")

        let player = PlayerController()
        player.nowPlaying = NowPlaying(source: .spotify, title: "What Did I Miss?", artist: "Drake", album: "ICEMAN", duration: 194.3,
                                       position: 151, artworkURL: nil, isPlaying: true, fetchedAt: Date())
        player.cover = livePlayer.cover
        player.avatar = livePlayer.avatar
        player.sourceIcon = livePlayer.sourceIcon
        let sample = TeleprompterStore(defaults: UserDefaults(suiteName: suite + ".view") ?? .standard)
        sample.text = "Добрый день. Сегодня я расскажу, как устроен остров в вырезе экрана и почему он нужен.\n\nПервое: он показывает состояние агентов. Второе: он всегда под рукой."
        let shownNotes = NotesStore(directory: tmp.appendingPathComponent("notes-view"))
        shownNotes.add("План на неделю\n— докрутить Dev\n— сделать подпись")
        shownNotes.add("Идеи для сайта")
        save(frame(MediaPage(model: model, player: player, teleprompter: sample, notes: shownNotes)), to: directory + "/media-player.png")
        let apple = PlayerController()
        apple.nowPlaying = NowPlaying(source: .appleMusic, title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming", duration: 243,
                                      position: 40, artworkURL: nil, isPlaying: false, fetchedAt: Date())
        save(frame(MediaPage(model: model, player: apple, teleprompter: sample, notes: shownNotes)), to: directory + "/media-player-apple.png")
        apple.showCover = true
        save(frame(MediaPage(model: model, player: apple, teleprompter: sample, notes: shownNotes)), to: directory + "/media-cover-apple.png")
        apple.showCover = false
        let yandex = PlayerController()
        yandex.nowPlaying = PlayerController.parseWeb("https://music.yandex.ru/album/1\tКак дела — Мот — слушать онлайн на Яндекс Музыке\n")
        save(frame(MediaPage(model: model, player: yandex, teleprompter: sample, notes: shownNotes)), to: directory + "/media-player-yandex.png")
        save(frame(MediaPage(model: model, player: PlayerController(), teleprompter: sample, notes: shownNotes)), to: directory + "/media-player-idle.png")
        save(frame(MediaPage(model: model, player: player, teleprompter: sample, notes: shownNotes, start: .teleprompter)), to: directory + "/media-teleprompter.png")
        save(frame(MediaPage(model: model, player: player, teleprompter: sample, notes: shownNotes, start: .notes)), to: directory + "/media-notes.png")
        // Поиск в плеере: разбор ответов Spotify и iTunes, история, поиск по тексту, адреса сайтов.
        let spotifyJSON = #"{"tracks":{"items":[{"name":"Moonlight","uri":"spotify:track:abc","artists":[{"name":"Kali Uchis"},{"name":"X"}],"album":{"name":"Isolation","images":[{"url":"https://i/640"},{"url":"https://i/300"}]}}]}}"#
        let spotifyHits = SpotifySearch.parse(Data(spotifyJSON.utf8))
        expect("поиск Spotify: разбор", spotifyHits.count == 1 && spotifyHits[0].artist == "Kali Uchis, X" && spotifyHits[0].uri == "spotify:track:abc" && spotifyHits[0].coverURL?.absoluteString == "https://i/300")
        let tokenParsed = SpotifySearch.parseToken(Data(#"{"access_token":"t","expires_in":3600}"#.utf8))
        expect("поиск Spotify: токен", tokenParsed?.token == "t" && tokenParsed?.lifetime == 3600)
        let tokenBody = SpotifySearch.tokenRequest(id: "id", secret: "sec")
        expect("поиск Spotify: запрос ключа", tokenBody.value(forHTTPHeaderField: "Authorization") == "Basic aWQ6c2Vj" && tokenBody.httpMethod == "POST")
        let appleHits = ITunesSearch.parse(Data(#"{"results":[{"trackId":1,"trackName":"Moonlight","artistName":"Ariana","collectionName":"Album","artworkUrl60":"https://i/60","trackViewUrl":"https://music.apple.com/x"}]}"#.utf8))
        expect("поиск Apple Music: разбор", appleHits.count == 1 && appleHits[0].origin == .apple && appleHits[0].pageURL != nil)
        let historyFile = tmp.appendingPathComponent("history.json")
        let devicesParsed = SpotifyDevice.parse(Data(#"{"devices":[{"id":"d1","name":"iPhone","type":"Smartphone","is_active":false},{"id":"d2","name":"Mac","type":"Computer","is_active":true}]}"#.utf8))
        expect("Spotify Connect: устройства", devicesParsed.count == 2 && devicesParsed[0].isPhone && devicesParsed[1].isActive)
        let verifierValue = SpotifyConnect.verifier()
        expect("Spotify Connect: PKCE", verifierValue.count >= 43 && !SpotifyConnect.challenge(verifierValue).contains("=")
               && SpotifyConnect.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let callback = SpotifyConnect.parseCallback("GET /callback?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        expect("Spotify Connect: ответ входа", callback.code == "abc" && callback.state == "xyz")
        let heard = ListeningHistory(file: historyFile)
        heard.record(NowPlaying(source: .spotify, title: "Honeypie", artist: "JAWNY", album: "For Abby", duration: 135, position: 5,
                                  artworkURL: nil, isPlaying: true, fetchedAt: Date()), fetchLyrics: false)
        heard.setLyrics([LyricLine(time: nil, text: "Sweet as honeypie"), LyricLine(time: nil, text: "Moonlight on my face")], for: "Honeypie|JAWNY")
        expect("история: по названию", heard.search("honey").first?.origin == .history)
        expect("история: по строчке из текста", heard.search("MOONLIGHT").first?.origin == .lyrics && heard.search("moonlight").first?.snippet == "Moonlight on my face")
        expect("история: сохранена в файл", ListeningHistory(file: historyFile).entries.first?.lyrics?.contains("honeypie") == true)
        expect("поиск: адрес Яндекс Музыки", MusicSearchModel.webSearchURL(sourceID: "web-yandex", query: "лунный свет")?.absoluteString == "https://music.yandex.ru/search?text=%D0%BB%D1%83%D0%BD%D0%BD%D1%8B%D0%B9%20%D1%81%D0%B2%D0%B5%D1%82")
        expect("поиск: кавычки в AppleScript", MusicSearchModel.quoted("a\"b\\c") == "\"a\\\"b\\\\c\"")
        let searchModel = MusicSearchModel(history: heard)
        let siteTabs = SiteWatcher.parse("true\thttps://www.youtube.com/watch?v=abc\t(3) Как собрать клавиатуру - YouTube\nfalse\thttps://music.youtube.com/watch?v=zzz\tSong\ntrue\thttps://www.tiktok.com/foryou\tTikTok - Make Your Day\n")
        expect("сайты: разбор вкладок, YouTube Music не берётся",
               siteTabs.count == 2 && siteTabs[0].title == "Как собрать клавиатуру" && siteTabs[0].key == "YouTube:abc" && siteTabs[1].title == "TikTok")
        let watcher = SiteWatcher()
        var announced = 0
        watcher.onNew = { announced += 1 }
        watcher.apply(siteTabs)
        let quietAtStart = announced == 0 && watcher.current?.service == "YouTube"
        watcher.apply(siteTabs + SiteWatcher.parse("true\thttps://www.instagram.com/reel/x\tInstagram\n"))
        let announcedNew = announced == 1 && watcher.current?.service == "Instagram"
        watcher.apply(siteTabs + SiteWatcher.parse("true\thttps://www.instagram.com/reel/y\tInstagram\n"))
        expect("сайты: при запуске молчит, новая вкладка выходит первой, прокрутка ленты не новая",
               quietAtStart && announcedNew && announced == 1)
        searchModel.query = "moonlight"
        searchModel.hits = spotifyHits + appleHits + heard.search("moonlight")
        searchModel.spotifyConnected = true
        expect("поиск: список открыт", searchModel.isOpen)
        let count = searchModel.hits.count
        searchModel.moveSelection(1)
        let movedDown = searchModel.selected == 0
        searchModel.moveSelection(-1)
        let wrapped = searchModel.selected == count - 1
        searchModel.update("moon")
        expect("поиск: стрелки идут по кругу и сбрасываются при вводе", movedDown && wrapped && searchModel.selected == nil)
        searchModel.query = "moonlight"
        searchModel.hits = spotifyHits + appleHits + heard.search("moonlight")
        save(frame(MediaPage(model: model, player: player, teleprompter: sample, notes: shownNotes, search: searchModel, start: .player)), to: directory + "/media-search.png")
        searchModel.clear()
        player.showCover = true
        save(frame(MediaPage(model: model, player: player, teleprompter: sample, notes: shownNotes, search: searchModel, start: .player)), to: directory + "/media-cover.png")
        player.showCover = false
        defaults.removePersistentDomain(forName: suite)
        defaults.removePersistentDomain(forName: suite + ".view")

        print("media:\(failures.isEmpty ? "все проверки" : "провалены:\n  " + failures.joined(separator: "\n  ")); ответ чата: \(chat.error ?? "нет ошибки"); плеер: \(liveTrack)")
        return failures.isEmpty
    }

    /// Сессии по файлам процессов: находятся без событий хуков, уходят вместе с процессом, хуки главнее.
    private static func sessionFilesSelfTest() -> Bool {
        var failures: [String] = []
        func expect(_ name: String, _ ok: Bool) { if !ok { failures.append(name) } }

        let sample = Data(#"{"pid":4242,"sessionId":"abc-1","cwd":"/tmp/proj","name":"visor project","status":"busy","updatedAt":1793641742554}"#.utf8)
        let entry = ClaudeSessionFiles.parse(sample)
        expect("разбор файла сессии", entry?.pid == 4242 && entry?.sessionID == "abc-1" && entry?.name == "visor project"
               && entry?.status == "busy" && abs((entry?.updated.timeIntervalSince1970 ?? 0) - 1793641742.554) < 0.01
               && ClaudeSessionFiles.parse(Data("{}".utf8)) == nil)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("visor-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try? sample.write(to: tmp.appendingPathComponent("4242.json"))
        try? Data(#"{"pid":999,"sessionId":"dead-1","cwd":"/x","status":"idle"}"#.utf8).write(to: tmp.appendingPathComponent("999.json"))
        try? Data("секрет".utf8).write(to: tmp.appendingPathComponent("4242.abc.key"))
        let scanned = ClaudeSessionFiles.scan(in: tmp, isAlive: { $0 == 4242 })
        expect("сканирование файлов", scanned.map(\.sessionID) == ["abc-1"])

        let center = AgentCenter.shared
        center.clearForSnapshot()
        let busy = ClaudeSessionEntry(pid: 1, sessionID: "s1", cwd: "/tmp/a", name: "первая", status: "busy", updated: Date())
        let idle = ClaudeSessionEntry(pid: 2, sessionID: "s2", cwd: "/tmp/b", name: "вторая", status: "idle", updated: Date().addingTimeInterval(-3600))
        center.rescanSessions([busy, idle])
        expect("сессии найдены без хуков", center.sessions.count == 2 && center.sessions["claude:s1"]?.state == .working
               && center.sessions["claude:s2"]?.state == .done && center.sessions["claude:s1"]?.project == "первая")
        expect("ни звука, ни карточки", center.permissions.isEmpty)
        center.rescanSessions([ClaudeSessionEntry(pid: 1, sessionID: "s1", cwd: "/tmp/a", name: "первая", status: "idle", updated: Date())])
        expect("статус обновился, ушедшая убрана", center.sessions.count == 1 && center.sessions["claude:s1"]?.state == .done)

        // Событие хука делает сессию «своей»: файл больше не перебивает её состояние.
        let json = #"{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/tmp/a"}"#
        center.handle(HookRequest(agent: "claude", body: Data(json.utf8), reply: HookReply(fd: -1)))
        center.rescanSessions([ClaudeSessionEntry(pid: 1, sessionID: "s1", cwd: "/tmp/a", name: "первая", status: "idle", updated: Date())])
        expect("хуки главнее файла", center.sessions["claude:s1"]?.state == .working && center.sessions["claude:s1"]?.discovered == false)
        center.rescanSessions([])
        expect("сессия хуков не пропадает при скане", center.sessions["claude:s1"] != nil)
        center.clearForSnapshot()

        let live = ClaudeSessionFiles.scan()
        print("sessions: \(failures.isEmpty ? "все проверки" : "провалены:\n  " + failures.joined(separator: "\n  ")); живых сессий Claude Code на этом Mac: \(live.count) (\(live.map(\.name).joined(separator: ", ")))")
        return failures.isEmpty
    }

    /// Клавиши острова: вкладки по стрелкам и цифрам, разделы, пробел в плеере, Esc.
    private static func keysSelfTest(renderTo directory: String) -> Bool {
        var failures: [String] = []
        func expect(_ name: String, _ ok: Bool) { if !ok { failures.append(name) } }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        let suite = "com.beksultan.visor.snapshot.keys"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let model = IslandModel(defaults: defaults)
        var closed = 0
        func press(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> Bool {
            IslandKeys.handle(key(code, flags), model: model) { closed += 1 }
        }
        let tabs = model.visibleTabs
        expect("стрелка вправо", press(124) && model.tab == tabs[1])
        expect("стрелка влево", press(123) && model.tab == tabs[0])
        expect("влево с первой уходит на последнюю", press(123) && model.tab == tabs[tabs.count - 1])
        expect("цифра 3", press(20) && model.tab == tabs[2])
        expect("цифра больше числа вкладок", !press(25) || tabs.count >= 9)

        model.select(.time)
        let before = TimeStore.shared.sub
        expect("стрелка вниз листает раздел", press(125) && TimeStore.shared.sub != before)
        TimeStore.shared.sub = .pomodoro
        model.select(.media)
        model.mediaSub = .player
        expect("вниз в медиа", press(125) && model.mediaSub == .web)
        model.mediaSub = .player
        expect("пробел в плеере обрабатывается", press(49))

        model.select(.agents)
        expect("пробел на агентах не трогается", !press(49))
        expect("запятая открывает настройки", press(43) && model.page == .settings)
        expect("стрелка в настройках листает раздел", press(124) && model.settingsTab != .general)
        expect("Esc закрывает страницу, а не остров", press(53) && model.page == nil && closed == 0)
        expect("Esc сворачивает остров", press(53) && closed == 1)
        expect("вопрос открывает памятку", press(44, .shift) && model.page == .settings && model.settingsTab == .keys)
        defaults.removePersistentDomain(forName: suite)

        // Перетаскивание вкладок: взятая едет за курсором, соседи расступаются, порядок пишется при отпускании.
        let drag = ReorderDrag()
        let four: [IslandTab] = [.agents, .chat, .time, .plans]
        drag.frames = Dictionary(uniqueKeysWithValues: four.enumerated().map { ($1, CGRect(x: CGFloat($0) * 40, y: 0, width: 40, height: 30)) })
        drag.begin(.chat, order: four, axis: .horizontal, spacing: 0)
        drag.move(translation: 85)
        expect("вкладка едет за курсором", drag.dragging == .chat && drag.shift(for: .chat) == 85)
        expect("соседи расступаются", drag.shift(for: .time) == -40 && drag.shift(for: .plans) == -40 && drag.shift(for: .agents) == 0)
        drag.move(translation: -50)
        expect("назад к началу", drag.shift(for: .agents) == 40 && drag.shift(for: .time) == 0)
        let moved = drag.finish()
        expect("порядок записывается при отпускании", moved?.tab == .chat && moved?.onto == .agents && drag.dragging == nil)
        drag.begin(.time, order: four, axis: .horizontal, spacing: 0)
        drag.move(translation: 6)
        expect("лёгкое движение ничего не меняет", drag.finish() == nil)

        // Таблетки у выреза: музыка играет и на паузе, длинное название обрезается.
        let pills = IslandModel(defaults: UserDefaults(suiteName: suite + ".pills") ?? .standard)
        let width = IslandLayout.leftWing + 179 + IslandLayout.rightWing
        for (name, title, playing) in [("music", "What Did I Miss?", true), ("music-long", "Очень длинное название трека, которое не поместится", false)] {
            PlayerController.shared.nowPlaying = NowPlaying(source: .spotify, title: title, artist: "Drake", album: "", duration: 200,
                                                           position: 10, artworkURL: nil, isPlaying: playing, fetchedAt: Date())
            pills.rotation = pills.capsuleItems.firstIndex(of: .music) ?? 0
            save(ClosedIsland(model: pills, notchWidth: 179, rowHeight: 32).frame(width: width, height: 32), to: directory + "/closed-\(name).png")
        }
        expect("таблетка музыки в ротации", pills.capsuleItems.contains(.music))
        PlayerController.shared.nowPlaying = nil
        expect("без музыки таблетки нет", !pills.capsuleItems.contains(.music))
        UserDefaults(suiteName: suite + ".pills")?.removePersistentDomain(forName: suite + ".pills")

        print("keys: \(failures.isEmpty ? "все проверки" : "провалены:\n  " + failures.joined(separator: "\n  "))")
        return failures.isEmpty
    }

    /// Тексты песен (разбор LRC, выбор строки). Сеть не нужна.
    private static func lyricsSelfTest() -> Bool {
        var failures: [String] = []
        func expect(_ name: String, _ ok: Bool) { if !ok { failures.append(name) } }

        let lrc = "[ar:Тест]\n[00:12.50] Первая\n[00:20.00][01:05.25] Припев\n[00:30.00]\nмусор"
        let lines = LRC.parse(lrc)
        expect("LRC разбор", lines.count == 4 && lines[0].text == "Первая" && lines[0].time == 12.5 && lines[3].time == 65.25)
        expect("LRC строка", LRC.activeIndex(lines, at: 5) == nil && LRC.activeIndex(lines, at: 13) == 0
               && LRC.activeIndex(lines, at: 25) == 1 && LRC.activeIndex(lines, at: 31) == 2 && LRC.activeIndex(lines, at: 400) == 3)
        expect("LRC без времени", LRC.activeIndex(LRC.plain("а\nб"), at: 10) == nil && LRC.plain("а\nб").count == 2)
        // Точное совпадение без таймингов не мешает взять близкий вариант с таймингами (так было у «Кинолента — Basta»).
        let plainExact: [String: Any] = ["plainLyrics": "строка", "duration": 263.0]
        let syncedLive: [String: Any] = ["trackName": "Кинолента - Live", "artistName": "Basta", "syncedLyrics": "[00:05.00] строка", "duration": 261.0]
        let syncedFar: [String: Any] = ["trackName": "Кинолента", "artistName": "Basta", "syncedLyrics": "[00:05.00] далеко", "duration": 400.0]
        let otherSong: [String: Any] = ["trackName": "Другая песня", "artistName": "Другой артист", "syncedLyrics": "[00:05.00] чужая", "duration": 263.0]
        func choose(_ exact: [String: Any]?, _ list: [[String: Any]]) -> [LyricLine]? {
            LyricsStore.choose(exact: exact, candidates: list, duration: 263.3, title: "Кинолента", artist: "Basta")
        }
        expect("текст: тайминги важнее точного совпадения без них",
               choose(plainExact, [syncedLive])?.first?.time == 5 && choose(plainExact, [syncedFar])?.first?.time == nil
               && choose(nil, []) == nil)
        expect("текст: чужая песня той же длины не берётся", choose(nil, [otherSong]) == nil && choose(plainExact, [otherSong])?.first?.time == nil)
        expect("текст: сравнение названий без скобок и feat",
               LyricsStore.fold("Blinding Lights (feat. X) - Remastered 2020") == "blindinglights"
               && LyricsStore.sameSong(["trackName": "Blinding Lights", "artistName": "The Weeknd"], title: "Blinding Lights - Remastered", artist: "The Weeknd, Daft Punk"))
        let nativeLines = "Headlines\nDrake\nTake Care\n236.0\n12.5\nhttps://example.com/c.jpg\nplaying\nspotify:track:ABC123"
        expect("лайк: номер песни из Spotify и из восьмой строки скрипта",
               SpotifyID.from("spotify:track:ABC123") == "ABC123" && SpotifyID.from("spotify:episode:ABC123") == nil
               && SpotifyID.from("spotify:local:a:b:c") == nil && SpotifyID.from("") == nil
               && PlayerController.parseNative(nativeLines, source: .spotify)?.trackID == "ABC123"
               && PlayerController.parseNative(String(nativeLines.dropLast(21)), source: .appleMusic)?.trackID == nil)
        let loginURL = SpotifyConnect.authorizeURL(clientID: "abc", challenge: "xyz", state: "st")?.absoluteString ?? ""
        expect("вход: окно согласия всегда и права на лайки и плейлисты",
               loginURL.contains("show_dialog=true") && loginURL.contains("user-library-modify") && loginURL.contains("playlist-modify-private")
               && SpotifyConnect.errorMessage(Data(#"{"error":{"status":403,"message":"Insufficient client scope"}}"#.utf8)) == "Insufficient client scope"
               && SpotifyConnect.errorMessage(Data("{}".utf8)) == nil)
        // Песня с телефона: ответ GET /me/player.
        let playback = Data(#"{"device":{"name":"iPhone Beka"},"is_playing":true,"progress_ms":42000,"currently_playing_type":"track","item":{"id":"6rqhFgbbKwnb9MLmUQDhG6","name":"Pray For Me","duration_ms":211000,"artists":[{"name":"The Weeknd"},{"name":"Kendrick Lamar"}],"album":{"name":"Black Panther","images":[{"url":"https://example.com/a.jpg"}]}}}"#.utf8)
        let phoneTrack = SpotifyConnect.parsePlayback(playback)
        expect("телефон: разбор текущей песни аккаунта",
               phoneTrack?.title == "Pray For Me" && phoneTrack?.artist == "The Weeknd, Kendrick Lamar" && phoneTrack?.device == "iPhone Beka"
               && phoneTrack?.position == 42 && phoneTrack?.duration == 211 && phoneTrack?.isPlaying == true
               && phoneTrack?.trackID == "6rqhFgbbKwnb9MLmUQDhG6"
               && SpotifyConnect.parsePlayback(Data(#"{"currently_playing_type":"ad","item":{"name":"x"}}"#.utf8)) == nil)
        expect("телефон: почему плеер аккаунта не виден",
               SpotifyConnect.syncStatus(code: 200, data: Data()) == nil && SpotifyConnect.syncStatus(code: 204, data: Data()) == nil
               && SpotifyConnect.syncStatus(code: 401, data: Data())?.contains("устарел") == true
               && SpotifyConnect.syncStatus(code: 403, data: Data(#"{"error":{"status":403,"message":"User not registered"}}"#.utf8))?.contains("User not registered") == true
               && SpotifyConnect.syncStatus(code: 500, data: Data())?.contains("500") == true)
        let itemsPage = Data(#"{"items":[{"item":{"id":"A1"}},{"track":{"id":"B2"}},{"item":null},{"item":{"name":"без id"}}],"next":"https://x"}"#.utf8)
        let parsedItems = TrackActions.parsePlaylistItems(itemsPage)
        expect("плейлист: песни в плейлисте из ответа Spotify",
               parsedItems?.ids == ["A1", "B2"] && parsedItems?.hasNext == true
               && TrackActions.parsePlaylistItems(Data(#"{"items":[],"next":null}"#.utf8))?.hasNext == false
               && TrackActions.parsePlaylistItems(Data("мусор".utf8)) == nil)
        expect("сообщения: удачные гаснут за секунду, ошибки позже",
               TrackActions.lifetime(of: "Добавлено в «Любимые треки».") == 1 && TrackActions.lifetime(of: "Убрано из любимых.") == 1
               && TrackActions.lifetime(of: "Spotify отказал (403)") == 6 && TrackActions.lifetime(of: nil) == 6)
        expect("лайк: адрес песни в новых запросах Spotify", SpotifyID.uri("ABC123") == "spotify%3Atrack%3AABC123")
        expect("выбор текста", LyricsStore.pick(["syncedLyrics": "[00:01.00] да", "plainLyrics": "да"])?.first?.time == 1
               && LyricsStore.pick(["plainLyrics": "да"])?.first?.time == nil && LyricsStore.pick(["instrumental": true]) == nil)

        print("lyrics: \(failures.isEmpty ? "все проверки" : "провалены:\n  " + failures.joined(separator: "\n  "))")
        return failures.isEmpty
    }

    private static func prefsSelfTest(renderTo directory: String) -> Bool {
        var failures: [String] = []
        func expect(_ name: String, _ ok: Bool) { if !ok { failures.append(name) } }

        // Вырез: настоящий и виртуальный для Mac без выреза.
        let real = NotchMetrics.resolve(screenWidth: 1728, left: 774.5, right: 774.5, safeTop: 32, menuBar: 32)
        expect("настоящий вырез", real == NotchMetrics.Result(width: 179, height: 32, minX: 774.5))
        let virtual = NotchMetrics.resolve(screenWidth: 1440, left: nil, right: nil, safeTop: 0, menuBar: 24)
        expect("вырез без выреза", virtual == NotchMetrics.Result(width: 180, height: 24, minX: 630))
        expect("высота строки меню", NotchMetrics.resolve(screenWidth: 1440, left: nil, right: nil, safeTop: 0, menuBar: 0).height == 22
               && NotchMetrics.resolve(screenWidth: 1440, left: nil, right: nil, safeTop: 0, menuBar: 80).height == 40)

        // Настройки: значения по умолчанию, хранение, мусор в хранилище.
        let suite = "com.beksultan.visor.snapshot.prefs"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let fresh = IslandPrefs(defaults: defaults)
        expect("настройки по умолчанию", fresh.autoCloseSeconds == 8 && fresh.rotationSeconds == 3 && fresh.screen == .auto && fresh.hotKey == .option)
        fresh.autoCloseSeconds = 0
        fresh.rotationSeconds = 10
        fresh.screen = .cursor
        let again = IslandPrefs(defaults: defaults)
        expect("настройки хранятся", again.autoCloseSeconds == 0 && again.rotationSeconds == 10 && again.screen == .cursor)
        defaults.set(7, forKey: "prefs.autoClose")
        defaults.set("мусор", forKey: "prefs.screen")
        let broken = IslandPrefs(defaults: defaults)
        expect("мусор в настройках", broken.autoCloseSeconds == 8 && broken.screen == .auto)
        expect("горячие клавиши", HotKeyChoice.option.carbonModifiers != HotKeyChoice.commandShift.carbonModifiers
               && Set(HotKeyChoice.allCases.map(\.title)).count == 3)
        // Правый клик по острову: спрятать глазок и таблетку, выбрать виды таблеток. По умолчанию всё показано.
        expect("видимость: по умолчанию всё показано", fresh.showEye && fresh.showCapsule && fresh.hiddenCapsules.isEmpty
               && fresh.eyeVisible && fresh.capsuleVisible && !fresh.temporarilyHidden)
        fresh.showEye = false
        fresh.hiddenCapsules = ["music", "site"]
        let wingsAgain = IslandPrefs(defaults: defaults)
        expect("видимость: хранится", !wingsAgain.showEye && wingsAgain.showCapsule && wingsAgain.hiddenCapsules == ["music", "site"])
        wingsAgain.hiddenUntil = Date().addingTimeInterval(60)
        let hiddenNow = !wingsAgain.capsuleVisible && wingsAgain.temporarilyHidden
        wingsAgain.hiddenUntil = Date().addingTimeInterval(-1)
        expect("видимость: временное скрытие прячет и само заканчивается",
               hiddenNow && wingsAgain.capsuleVisible && !wingsAgain.temporarilyHidden)
        let kinds = Set(CapsuleItem.menuKinds.map(\.kind))
        let sample: [CapsuleItem] = [.clock, .timer, .stopwatch, .meeting, .agent, .music, .site, .tasks, .battery, .limits(.claude)]
        expect("видимость: у каждого вида таблетки есть пункт меню", sample.allSatisfy { kinds.contains($0.kind) } && kinds.count == sample.count)
        // Режим «не засыпать при закрытой крышке»: разбор pmset, правило sudoers, страховка.
        expect("крышка: разбор pmset -g", LidPmset.readSleepDisabled(" SleepDisabled\t\t1\n") == true
               && LidPmset.readSleepDisabled("sleep 1\n SleepDisabled 0") == false
               && LidPmset.readSleepDisabled("sleep 1") == nil && LidPmset.readSleepDisabled("SleepDisabled x") == nil)
        expect("крышка: имя пользователя в sudoers только безопасное",
               LidPmset.isSafeUser("username") && LidPmset.isSafeUser("_svc.user-1")
               && !LidPmset.isSafeUser("bad user") && !LidPmset.isSafeUser("a;b") && !LidPmset.isSafeUser("x,y")
               && !LidPmset.isSafeUser("") && !LidPmset.isSafeUser("1abc") && !LidPmset.isSafeUser("a\"b")
               && LidPmset.sudoersLine(user: "bad user") == nil && LidPmset.installScript(user: "a;b") == nil)
        let ruleLine = LidPmset.sudoersLine(user: NSUserName()) ?? ""
        let ruleFile = URL(fileURLWithPath: directory).appendingPathComponent("lid-rule-test.txt")
        try? (ruleLine + "\n").write(to: ruleFile, atomically: true, encoding: .utf8)
        func status(_ path: String, _ arguments: [String]) -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return -1 }
            process.waitUntilExit()
            return process.terminationStatus
        }
        let visudoStatus = status("/usr/sbin/visudo", ["-cf", ruleFile.path])
        try? FileManager.default.removeItem(at: ruleFile)
        let script = LidPmset.installScript(user: "username") ?? ""
        expect("крышка: правило проходит настоящий visudo, а установка проверяет его перед записью",
               visudoStatus == 0 && ruleLine.contains("NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -b lowpowermode 1, /usr/bin/pmset -b lowpowermode 0")
               && script.contains("visudo -cf") && script.contains(LidPmset.rulePath) && !script.contains("\n"))
        expect("крышка: команды без пароля и проверка правила",
               LidPmset.arguments(disabled: true) == ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"]
               && LidPmset.checkArguments(disabled: false) == ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"])
        // Скрипт страховки и агент не запускаются (они меняют питание), только проверяется их синтаксис.
        let guardFile = URL(fileURLWithPath: directory).appendingPathComponent("lid-guard-test.sh")
        let plistFile = URL(fileURLWithPath: directory).appendingPathComponent("lid-agent-test.plist")
        try? LidPmset.guardScript.write(to: guardFile, atomically: true, encoding: .utf8)
        try? LidPmset.agentPlist(scriptPath: "/tmp/x.sh").write(to: plistFile, atomically: true, encoding: .utf8)
        expect("крышка: скрипт страховки и агент launchd корректны",
               status("/bin/sh", ["-n", guardFile.path]) == 0 && status("/usr/bin/plutil", ["-lint", plistFile.path]) == 0
               && LidPmset.guardScript.contains("disablesleep 0") && LidPmset.guardScript.contains("lid-session"))
        try? FileManager.default.removeItem(at: guardFile)
        try? FileManager.default.removeItem(at: plistFile)
        expect("крышка: остаток времени", LidPmset.remaining(6120) == "1:42" && LidPmset.remaining(61) == "0:01" && LidPmset.remaining(-5) == "0:00")
        let lidSuite = suite + ".lid"
        let lidDefaults = UserDefaults(suiteName: lidSuite) ?? .standard
        lidDefaults.removePersistentDomain(forName: lidSuite)
        let lidDirectory = URL(fileURLWithPath: directory)
        let lidFresh = LidAwake(defaults: lidDefaults, directory: lidDirectory)
        expect("крышка: по умолчанию 2 часа и порог 10 %", lidFresh.durationSeconds == 7200 && lidFresh.batteryFloor == 10 && !lidFresh.owned && lidFresh.endsAt == nil)
        lidFresh.durationSeconds = 0
        lidFresh.batteryFloor = 20
        lidDefaults.set(true, forKey: "visor.lid.owned")
        lidDefaults.set(Date().addingTimeInterval(600).timeIntervalSince1970, forKey: "visor.lid.endsAt")
        let lidAgain = LidAwake(defaults: lidDefaults, directory: lidDirectory)
        expect("крышка: настройки и сессия переживают перезапуск",
               lidAgain.durationSeconds == 0 && lidAgain.batteryFloor == 20 && lidAgain.owned && (lidAgain.remaining ?? 0) > 500)
        lidDefaults.set(5, forKey: "visor.lid.floor")
        lidDefaults.set(123, forKey: "visor.lid.duration")
        let lidBroken = LidAwake(defaults: lidDefaults, directory: lidDirectory)
        expect("крышка: мусор в настройках", lidBroken.batteryFloor == 10 && lidBroken.durationSeconds == 7200)
        lidDefaults.removePersistentDomain(forName: lidSuite)
        // Энергосбережение по заряду: решение, гистерезис, только своё.
        typealias Policy = PowerSaverPolicy
        expect("энергосбережение: включается на батарее ниже порога",
               Policy.decide(level: 30, percent: 28, onPower: false, lowPowerOn: false, owned: false) == .enable
               && Policy.decide(level: 30, percent: 40, onPower: false, lowPowerOn: false, owned: false) == .none
               && Policy.decide(level: 30, percent: 20, onPower: true, lowPowerOn: false, owned: false) == .none
               && Policy.decide(level: 0, percent: 5, onPower: false, lowPowerOn: false, owned: false) == .none
               && Policy.decide(level: 30, percent: 20, onPower: false, lowPowerOn: true, owned: false) == .none)
        expect("энергосбережение: выключается на зарядке или выше порога, чужое не трогает",
               Policy.decide(level: 30, percent: 20, onPower: true, lowPowerOn: true, owned: true) == .disable
               && Policy.decide(level: 30, percent: 36, onPower: false, lowPowerOn: true, owned: true) == .disable
               && Policy.decide(level: 30, percent: 33, onPower: false, lowPowerOn: true, owned: true) == .none
               && Policy.decide(level: 0, percent: 90, onPower: false, lowPowerOn: true, owned: true) == .disable
               && Policy.decide(level: 30, percent: 90, onPower: true, lowPowerOn: true, owned: false) == .none)
        expect("энергосбережение: только при закрытой крышке",
               Policy.decide(level: 30, percent: 20, onPower: false, lowPowerOn: false, owned: false, lidClosed: false) == .none
               && Policy.decide(level: 30, percent: 20, onPower: false, lowPowerOn: true, owned: true, lidClosed: false) == .disable
               && Policy.decide(level: 30, percent: 20, onPower: false, lowPowerOn: false, owned: false, lidClosed: true) == .enable)
        // Мигающие таблетки: зарядка, мало процентов, ответ агенту.
        typealias Reading = BatteryReading
        let plugged = AlertPolicy.batteryAlerts(previous: Reading(percent: 14, onPower: false), current: Reading(percent: 14, onPower: true))
        expect("таблетка: зарядку при низком заряде показывает 3 секунды",
               plugged.transient.first?.0.kind == .charging && plugged.transient.first?.1 == 3 && plugged.persistent == nil
               && plugged.transient.first?.0.text == "14% · заряжается")
        let crossing = AlertPolicy.batteryAlerts(previous: Reading(percent: 21, onPower: false), current: Reading(percent: 20, onPower: false))
        let staying = AlertPolicy.batteryAlerts(previous: Reading(percent: 20, onPower: false), current: Reading(percent: 19, onPower: false))
        let critical = AlertPolicy.batteryAlerts(previous: Reading(percent: 11, onPower: false), current: Reading(percent: 10, onPower: false))
        let fine = AlertPolicy.batteryAlerts(previous: Reading(percent: 80, onPower: false), current: Reading(percent: 79, onPower: false))
        expect("таблетка: мало процентов мигает при переходе, критический заряд пока не подключили",
               crossing.transient.first?.0.kind == .batteryLow && crossing.transient.first?.0.blink == true
               && staying.transient.isEmpty && staying.persistent == nil
               && critical.persistent?.kind == .batteryCritical && critical.transient.isEmpty
               && fine.transient.isEmpty && fine.persistent == nil)
        let blinkers = [CapsuleAlert(kind: .done, text: "", symbol: "", state: .done, blink: true), CapsuleAlert(kind: .needsAnswer, text: "", symbol: "", state: .waiting, blink: true),
                        CapsuleAlert(kind: .batteryLow, text: "", symbol: "", state: .waiting, blink: true)]
        let ended = CapsuleAlert(kind: .lidOff, text: "", symbol: "", state: .waiting, blink: true)
        expect("таблетка: конец режима «не спит» мигает, но ответ агенту важнее", ended.priority == 55 && AlertPolicy.pick([ended, blinkers[1]])?.kind == .needsAnswer
               && AlertPolicy.pick([ended, blinkers[0]])?.kind == .lidOff)
        expect("таблетка: ответ агенту важнее всего", AlertPolicy.pick(blinkers)?.kind == .needsAnswer && AlertPolicy.pick([]) == nil)
        expect("энергосбережение: команды",
               Policy.arguments(on: true) == ["-n", "/usr/bin/pmset", "-b", "lowpowermode", "1"]
               && Policy.checkArguments(on: false) == ["-n", "-l", "/usr/bin/pmset", "-b", "lowpowermode", "0"])
        expect("крышка: состояние из ioreg",
               ClosedLidActions.parseClamshell("    \"AppleClamshellState\" = Yes\n") == true
               && ClosedLidActions.parseClamshell("  \"AppleClamshellCausesSleep\" = No\n  \"AppleClamshellState\" = No") == false
               && ClosedLidActions.parseClamshell("ничего") == nil)
        let table = ClosedLidActions.parseProcessTable("  1 0\n 10 1\n 11 10\n 12 11\n 20 1\nмусор\n")
        expect("заморозка: процесс и все потомки",
               table.count == 5 && ClosedLidActions.tree(of: 10, in: table) == [10, 11, 12] && ClosedLidActions.tree(of: 20, in: table) == [20]
               && ClosedLidActions.tree(of: 99, in: table) == [99])
        let steps = HotspotPolicy.checklist(ssid: " iPhone ", hasPassword: true, locationAllowed: false)
        // Другие агенты и модели чата: общие названия событий, три пункта во вкладке, запросы в формате OpenAI.
        expect("агенты: названия событий Gemini CLI приводятся к общим",
               AgentKind.canonicalEvent("BeforeTool") == "PreToolUse" && AgentKind.canonicalEvent("AfterTool") == "PostToolUse"
               && AgentKind.canonicalEvent("BeforeAgent") == "UserPromptSubmit" && AgentKind.canonicalEvent("AfterAgent") == "Stop"
               && AgentKind.canonicalEvent("Notification") == "Notification" && AgentKind(rawValue: "custom") == .custom)
        let geminiEvents = AgentTarget.gemini.events
        expect("агенты: Gemini CLI считает тайм-аут в миллисекундах и ждёт шаблон у инструментов",
               AgentTarget.gemini.timeoutScale == 1000 && AgentTarget.claude.timeoutScale == 1
               && geminiEvents.first { $0.name == "BeforeTool" }?.matcher == "*" && geminiEvents.contains { $0.name == "AfterAgent" }
               && AgentTarget.qwen.url.path.hasSuffix("/.qwen/settings.json") && AgentTarget.gemini.displayPath == "~/.gemini/settings.json")
        typealias Pin = PinRules
        expect("три пункта во вкладке: не больше трёх, последний не убрать, мусор отбрасывается",
               Pin.toggled([ChatProvider.claude, .gemini, .openai], .qwen, on: true) == [.claude, .gemini, .openai]
               && Pin.toggled([ChatProvider.claude, .gemini], .qwen, on: true) == [.claude, .gemini, .qwen]
               && Pin.toggled([ChatProvider.claude], .claude, on: false) == [.claude]
               && Pin.toggled([ChatProvider.claude, .gemini], .claude, on: false) == [.gemini]
               && Pin.normalize(saved: ["xxx", "qwen", "qwen", "gemini", "claude", "openai"], all: ChatProvider.allCases, defaults: ChatProvider.defaultPinned) == [.qwen, .gemini, .claude]
               && Pin.normalize(saved: [], all: ChatProvider.allCases, defaults: ChatProvider.defaultPinned) == ChatProvider.defaultPinned)
        let compat = ChatAPI.request(provider: .deepseek, key: "k1", messages: [ChatMessage(role: .user, text: "привет")], model: "deepseek-reasoner")
        let compatBody = compat?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        expect("чат: запрос в формате OpenAI (DeepSeek)",
               compat?.url?.absoluteString == "https://api.deepseek.com/chat/completions" && compat?.value(forHTTPHeaderField: "authorization") == "Bearer k1"
               && compatBody?["model"] as? String == "deepseek-reasoner" && (compatBody?["messages"] as? [[String: String]])?.count == 2
               && ChatProvider.allCases.filter { $0.compatibleBase != nil }.count == ChatProvider.allCases.count - 2
               && ChatAPI.request(provider: .claude, key: "k", messages: [])?.url?.host == "api.anthropic.com")
        expect("чат: разбор ответа формата OpenAI",
               ChatAPI.parse(provider: .groq, data: Data(#"{"choices":[{"message":{"content":"ответ"}}]}"#.utf8)) == "ответ"
               && ChatAPI.parse(provider: .groq, data: Data(#"{"choices":[]}"#.utf8)) == nil)
        let issue = Feedback.issueURL(repository: "me/visor", kind: .bug, version: "Visor 0.1.0 (1)", macos: "macOS 15.2.0, Mac15,6")?.absoluteString ?? ""
        expect("отзыв: ссылка на форму с версией и macOS, заготовка OWNER не считается",
               issue.hasPrefix("https://github.com/me/visor/issues/new?template=bug.yml") && issue.contains("version=Visor%200.1.0%20(1)")
               && issue.contains("macos=macOS%2015.2.0,%20Mac15,6")
               && Feedback.issueURL(repository: "me/visor", kind: .feature, version: "", macos: "")?.absoluteString == "https://github.com/me/visor/issues/new?template=feature.yml"
               && Feedback.normalized("OWNER/visor") == nil && Feedback.normalized("me/visor") == "me/visor"
               && Feedback.normalized("bad repo") == nil && Feedback.normalized(nil) == nil)
        expect("автозапуск: включается один раз и только из «Программ»",
               LaunchAtLogin.shouldEnableOnFirstRun(offered: false, inApplications: true, enabled: false)
               && !LaunchAtLogin.shouldEnableOnFirstRun(offered: true, inApplications: true, enabled: false)
               && !LaunchAtLogin.shouldEnableOnFirstRun(offered: false, inApplications: false, enabled: false)
               && !LaunchAtLogin.shouldEnableOnFirstRun(offered: false, inApplications: true, enabled: true))
        expect("часы: разница с вашим временем",
               ZoneClock.offsetText(minutes: 0) == "как у вас" && ZoneClock.offsetText(minutes: 300) == "+5 ч"
               && ZoneClock.offsetText(minutes: -210) == "−3 ч 30 м" && ZoneClock.offsetText(minutes: 330) == "+5 ч 30 м")
        expect("хотспот: чек-лист и сигнал",
               steps.map(\.ok) == [true, true, false] && steps[0].title == "Название: iPhone"
               && HotspotPolicy.checklist(ssid: "", hasPassword: false, locationAllowed: true).map(\.ok) == [false, false, true]
               && HotspotPolicy.signalQuality(rssi: -50) == "сигнал хороший" && HotspotPolicy.signalQuality(rssi: -70) == "сигнал средний"
               && HotspotPolicy.signalQuality(rssi: -90) == "сигнал слабый" && HotspotPolicy.sameName("Beka\u{2019}s iPhone", "beka's iphone") && HotspotCheck.found(rssi: -50).ok && !HotspotCheck.notFound.ok)
        expect("хотспот: паузы и подсказки",
               HotspotPolicy.delay(afterAttempt: 1) == 5 && HotspotPolicy.delay(afterAttempt: 3) == 20 && HotspotPolicy.delay(afterAttempt: 9) == 30
               && HotspotPolicy.account(for: " iPhone ") == "hotspot:iPhone"
               && HotspotPolicy.suggestions(for: "beka's", among: ["Beka\u{2019}s iPhone", "Дом", "Beka\u{2019}s iPhone", " "]) == ["Beka\u{2019}s iPhone"]
               && HotspotPolicy.suggestions(for: "", among: ["A", "B"]).count == 2)
        expect("крышка: замораживать можно не всё",
               ClosedLidActions.freezable(bundle: "com.google.Chrome", policy: .regular)
               && !ClosedLidActions.freezable(bundle: "com.apple.finder", policy: .regular)
               && !ClosedLidActions.freezable(bundle: "com.apple.Terminal", policy: .regular)
               && !ClosedLidActions.freezable(bundle: "com.google.Chrome", policy: .accessory)
               && !ClosedLidActions.freezable(bundle: nil, policy: .regular))
        // Календари: предел числа и ссылка на подписку.
        expect("календарь: ссылка на подписку",
               CalendarService.subscriptionURL(from: " https://example.com/a/b.ics ")?.absoluteString == "webcal://example.com/a/b.ics"
               && CalendarService.subscriptionURL(from: "webcal://cal.example.org/x")?.scheme == "webcal"
               && CalendarService.subscriptionURL(from: "hello") == nil && CalendarService.subscriptionURL(from: "https://localhost/x") == nil)
        // Стороны глазка и таблетки.
        let sidesSuite = suite + ".sides"
        let sidesDefaults = UserDefaults(suiteName: sidesSuite) ?? .standard
        sidesDefaults.removePersistentDomain(forName: sidesSuite)
        sidesDefaults.set(true, forKey: "prefs.swapSides")
        expect("стороны: сохраняются", IslandPrefs(defaults: sidesDefaults).swapSides && !IslandPrefs(defaults: UserDefaults(suiteName: sidesSuite + "x") ?? .standard).swapSides)
        sidesDefaults.removePersistentDomain(forName: sidesSuite)
        // Порядок вкладок: перенос, хранение, мусор, скрытая вкладка.
        let orderSuite = suite + ".order"
        let orderDefaults = UserDefaults(suiteName: orderSuite) ?? .standard
        orderDefaults.removePersistentDomain(forName: orderSuite)
        let ordered = IslandModel(defaults: orderDefaults)
        expect("порядок по умолчанию", ordered.tabOrder == IslandTab.allCases)
        ordered.moveTab(.media, onto: .agents)
        expect("перенос вперёд", ordered.tabOrder.first == .media && ordered.visibleTabs.first == .media)
        ordered.moveTab(.media, by: 1)
        expect("перенос стрелкой", ordered.tabOrder.first == .agents && ordered.tabOrder[1] == .media)
        ordered.moveTab(.agents, by: -1) // дальше начала не двигается
        expect("край списка", ordered.tabOrder.first == .agents)
        expect("порядок хранится", IslandModel(defaults: orderDefaults).tabOrder == ordered.tabOrder)
        ordered.setTab(.media, enabled: false)
        expect("скрытая вкладка", !ordered.visibleTabs.contains(.media) && ordered.tabOrder.contains(.media))
        orderDefaults.set(["dev", "dev", "мусор"], forKey: "island.tabOrder")
        let broken2 = IslandModel(defaults: orderDefaults)
        expect("мусор в порядке", broken2.tabOrder.first == .dev && broken2.tabOrder.count == IslandTab.allCases.count
               && Set(broken2.tabOrder) == Set(IslandTab.allCases))
        orderDefaults.removePersistentDomain(forName: orderSuite)
        _ = LaunchAtLogin.isEnabled // чтение статуса не должно падать
        let launch = "автозапуск: \(LaunchAtLogin.isEnabled ? "включён" : "выключен"), в «Программах»: \(LaunchAtLogin.isInApplications)"

        // Вид: основные настройки и остров без выреза (высота строки меню 24).
        let model = IslandModel(defaults: defaults)
        model.page = .settings
        model.settingsTab = .general
        let general = IslandPrefs(defaults: UserDefaults(suiteName: suite + ".view") ?? .standard)
        save(GeneralSettings(prefs: general).padding(14).frame(width: 860, height: 380, alignment: .top).background(Color.black),
             to: directory + "/settings-general.png")
        let plain = IslandModel(defaults: defaults)
        let width = IslandLayout.leftWing + NotchMetrics.virtualWidth + IslandLayout.rightWing
        save(ClosedIsland(model: plain, notchWidth: NotchMetrics.virtualWidth, rowHeight: 24).frame(width: width, height: 24),
             to: directory + "/closed-no-notch.png")
        defaults.removePersistentDomain(forName: suite)
        defaults.removePersistentDomain(forName: suite + ".view")

        print("prefs: \(failures.isEmpty ? "все проверки" : "провалены:\n  " + failures.joined(separator: "\n  ")); \(launch)")
        return failures.isEmpty
    }

    private static func devSelfTest(renderTo directory: String) -> Bool {
        var failures: [String] = []
        func expect(_ name: String, _ ok: Bool) { if !ok { failures.append(name) } }
        final class Flag { var done = false }
        func pump(_ flag: Flag, seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while !flag.done, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }

        // Разбор вывода утилит на синтетических данных.
        let bluetoothJSON = Data(#"""
        {"SPBluetoothDataType":[{"device_connected":[{"Magic Mouse":{"device_batteryLevelMain":"64%"}},
        {"AirPods Pro":{"device_batteryLevelLeft":"100%","device_batteryLevelRight":"90%","device_batteryLevelCase":"82%"}}],
        "device_not_connected":[{"Old Speaker":{"device_address":"x"}},{"AirPods Pro 2":{"device_batteryLevelCase":"40%"}}]}]}
        """#.utf8)
        let devices = SystemMonitor.parseBluetooth(bluetoothJSON)
        expect("bluetooth", devices.count == 3 && devices[0].name == "Magic Mouse" && devices[0].batteries.first?.percent == 64
               && devices[1].batteries.count == 3 && !devices[2].connected && devices[2].batteries.first?.percent == 40)

        let topText = """
        Processes: 400 total
        PID    COMMAND          %CPU
        1      launchd          9.0
        Processes: 400 total
        PID    COMMAND          %CPU
        123    Google Chrome He 45.2
        456    WindowServer     12.0
        789    top              3.1
        5      idle             0.0
        """
        let hot = SystemMonitor.parseTop(topText)
        expect("top", hot.map(\.name) == ["Google Chrome He", "WindowServer"] && hot.first?.cpu == 45.2 && hot.first?.pid == 123)

        let ports = DevAPI.parsePorts("p100\ncnode\nn*:3000\nn[::1]:3000\np200\ncControl\\x20Center\nn127.0.0.1:7000\n")
        expect("порты", ports.map(\.port) == [3000, 7000] && ports[0].exposed && !ports[1].exposed && ports[1].command == "Control Center")

        let search = Data(#"""
        {"items":[{"id":1,"number":7,"title":"Fix timer","html_url":"https://github.com/o/r/pull/7","draft":true,
        "repository_url":"https://api.github.com/repos/o/r","pull_request":{"url":"https://api.github.com/repos/o/r/pulls/7"}}]}
        """#.utf8)
        let pulls = DevAPI.parsePulls(search)
        expect("PR", pulls.count == 1 && pulls[0].repository == "o/r" && pulls[0].draft && pulls[0].apiURL != nil && pulls[0].number == 7)
        expect("sha коммита", DevAPI.parseHeadSHA(Data(#"{"head":{"sha":"abc"}}"#.utf8)) == "abc")
        func checks(_ body: String) -> CIState { DevAPI.parseChecks(Data(#"{"check_runs":\#(body)}"#.utf8)) }
        expect("проверки CI", checks(#"[{"status":"completed","conclusion":"success"}]"#) == .passing
               && checks(#"[{"status":"completed","conclusion":"failure"},{"status":"in_progress"}]"#) == .failing
               && checks(#"[{"status":"completed","conclusion":"success"},{"status":"in_progress"}]"#) == .running
               && checks("[]") == .unknown)

        let vercel = Data(#"""
        {"deployments":[{"uid":"d1","name":"site","url":"site-abc.vercel.app","state":"READY","created":1767225600000,"target":"production"},
        {"uid":"d2","name":"site","url":"x.vercel.app","readyState":"BUILDING","created":1767225600000}]}
        """#.utf8)
        let deploys = DevAPI.parseDeployments(vercel)
        expect("Vercel", deploys.count == 2 && deploys[0].state == .ready && deploys[0].production && deploys[1].state == .building
               && deploys[0].url?.absoluteString == "https://site-abc.vercel.app")

        // Связка ключей: запись, замена, удаление.
        let service = "com.beksultan.visor.selftest"
        SecretStore.delete("probe", service: service)
        let wrote = SecretStore.set("one", account: "probe", service: service)
        let replaced = SecretStore.set("two", account: "probe", service: service) && SecretStore.get("probe", service: service) == "two"
        SecretStore.delete("probe", service: service)
        expect("связка ключей", wrote && replaced && SecretStore.get("probe", service: service) == nil)

        // Настоящие счётчики этого Mac.
        let live = SystemMonitor()
        live.sample()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        live.sample()
        let stats = live.snapshot
        expect("счётчики", (0...1).contains(stats.cpu) && stats.memoryUsed > 0 && stats.memoryUsed < stats.memoryTotal
               && stats.batteryPercent.map { (0...100).contains($0) } ?? true)
        let flag = Flag()
        let liveServices = DevServices(hasGitHubToken: false, hasVercelToken: false)
        Task { await live.refreshBluetooth(); await live.refreshHot(); await liveServices.refreshPorts(); flag.done = true }
        pump(flag, seconds: 30)
        expect("настоящие процессы", flag.done && !live.hot.isEmpty)
        let summary = "CPU \(Int(stats.cpu * 100))%, память \(DevFormat.gigabytes(stats.memoryUsed)), батарея \(stats.batteryPercent ?? -1)%, "
            + "bluetooth \(live.bluetooth.count), процессов \(live.hot.count), портов \(liveServices.ports.count)"

        // Вид.
        let suite = "com.beksultan.visor.snapshot.dev"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let model = IslandModel(defaults: defaults)
        for module in IslandModule.allCases { model.setModule(module, enabled: true) }

        let preset = SystemMonitor()
        preset.snapshot = SystemSnapshot(cpu: 0.37, memoryUsed: 14_500_000_000, memoryTotal: 24 * 1_073_741_824, batteryPercent: 59,
                                         onPower: false, isCharging: false, minutesRemaining: 434, batteryTemperature: 31.4, thermal: .fair)
        preset.bluetooth = devices
        preset.hot = hot + [HotProcess(pid: 9, name: "node", cpu: 8.5)]
        func frame<V: View>(_ view: V) -> some View {
            view.padding(14).frame(width: 860, height: 380, alignment: .top).background(Color.black)
        }
        let empty = DevServices(hasGitHubToken: false, hasVercelToken: false)
        save(frame(DevPage(model: model, monitor: preset, services: empty)), to: directory + "/dev-system.png")

        let withPorts = DevServices(hasGitHubToken: true, hasVercelToken: true)
        withPorts.preset(ports: ports + [ListeningPort(pid: 301, command: "vite", port: 5173, exposed: false)],
                         pulls: .loaded([
                            PullRequest(id: 1, number: 12, title: "Таймер: звук в конце", repository: "beks/visor", url: nil, draft: false, apiURL: nil, ci: .passing),
                            PullRequest(id: 2, number: 13, title: "Dev: порты и процессы", repository: "beks/visor", url: nil, draft: true, apiURL: nil, ci: .running),
                            PullRequest(id: 3, number: 41, title: "Курсы валют", repository: "beks/site", url: nil, draft: false, apiURL: nil, ci: .failing),
                         ]),
                         deployments: .loaded(deploys))
        save(frame(DevPage(model: model, monitor: preset, services: withPorts, start: .ports)), to: directory + "/dev-ports.png")
        save(frame(DevPage(model: model, monitor: preset, services: withPorts, start: .github)), to: directory + "/dev-github.png")
        save(frame(DevPage(model: model, monitor: preset, services: withPorts, start: .vercel)), to: directory + "/dev-vercel.png")
        save(frame(DevPage(model: model, monitor: preset, services: empty, start: .github)), to: directory + "/dev-github-token.png")
        defaults.removePersistentDomain(forName: suite)

        print("dev: \(failures.isEmpty ? "все проверки" : "провалены:\n  " + failures.joined(separator: "\n  ")); \(summary)")
        return failures.isEmpty
    }

    /// Заглушка календаря: события в памяти, доступ выдаётся по запросу.
    @MainActor private final class FakeCalendar: CalendarSource {
        var access: CalendarAccess
        var events: [CalendarEvent] = []

        init(access: CalendarAccess) { self.access = access }

        func requestAccess() async -> Bool {
            access = .granted
            return true
        }

        func events(in interval: DateInterval) -> [CalendarEvent] {
            events.filter { $0.start < interval.end && $0.end > interval.start }.sorted { $0.start < $1.start }
        }

        func defaultCalendarName() -> String? { "Дом" }

        var infos: [CalendarInfo] = [
            CalendarInfo(id: "home", title: "Дом", account: "iCloud", writable: true),
            CalendarInfo(id: "school", title: "Школа", account: "Gmail", writable: true),
            CalendarInfo(id: "holidays", title: "Праздники", account: "Gmail", writable: false),
        ]
        var lastCalendarID: String?

        func calendars() -> [CalendarInfo] { infos }

        func create(title: String, start: Date, end: Date, calendarID: String?) throws -> CalendarEvent {
            lastCalendarID = calendarID
            let event = CalendarEvent(id: UUID().uuidString, title: title, start: start, end: end, isAllDay: false, calendar: "Дом",
                                      joinURL: nil, calendarID: calendarID ?? "home")
            events.append(event)
            return event
        }
    }

    /// Планы: разбор строк, дела, календарь на заглушке, ссылки на звонки. Плюс вид трёх списков.
    private static func plansSelfTest(renderTo directory: String) -> Bool {
        let cal = Calendar.current
        var failures: [String] = []
        func expect(_ name: String, _ ok: Bool) { if !ok { failures.append(name) } }
        func at(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 11) -> Date {
            cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)) ?? Date()
        }
        let now = at(1, 10) // воскресенье, 10:00
        func parse(_ text: String) -> ParsedEntry? { QuickParser.parse(text, now: now, calendar: cal) }

        // Разбор строк быстрого ввода.
        let a = parse("завтра 16:00 репетитор 1ч")
        expect("завтра 16:00", a?.title == "Репетитор" && a?.start == at(2, 16) && a?.durationMinutes == 60 && a?.isEvent == true)
        let b = parse("в пятницу в 15 робототехника 90 мин")
        expect("в пятницу в 15", b?.title == "Робототехника" && b?.start == at(6, 15) && b?.durationMinutes == 90)
        let c = parse("15 ноября день рождения")
        expect("15 ноября", c?.title == "День рождения" && c?.date == at(15) && c?.start == nil && c?.horizon(now: now, calendar: cal) == .month)
        let d = parse("через 3 дня 18:30 созвон по макету")
        expect("через 3 дня", d?.title == "Созвон по макету" && d?.start == at(4, 18, 30))
        let e = parse("в 16 репетитор")
        expect("в 16", e?.title == "Репетитор" && e?.start == at(1, 16))
        let f = parse("в 9 зарядка")
        expect("в 9 прошло", f?.title == "Зарядка" && f?.start == at(2, 9))
        let g = parse("сдать домашку по химии")
        expect("просто дело", g?.title == "Сдать домашку по химии" && g?.isEvent == false && g?.date == nil)
        let h = parse("завтра сдать домашку")
        expect("завтра без времени", h?.title == "Сдать домашку" && h?.date == at(2) && h?.horizon(now: now, calendar: cal) == .week)
        let i = parse("сегодня уборка")
        expect("сегодня без времени", i?.horizon(now: now, calendar: cal) == .day)
        let j = parse("послезавтра 12:30 стоматолог 1,5 часа")
        expect("полтора часа", j?.title == "Стоматолог" && j?.start == at(3, 12, 30) && j?.durationMinutes == 90)
        let k = parse("25.11 дедлайн проекта")
        expect("25.11", k?.title == "Дедлайн проекта" && k?.date == at(25))
        expect("только дата без названия", parse("завтра") == nil)
        let l = parse("в понедельник 8:00 урок")
        expect("в понедельник", l?.title == "Урок" && l?.start == at(2, 8))
        let m = parse("в воскресенье в 18 ужин")
        expect("воскресенье сегодня", m?.start == at(1, 18))
        let n = parse("в воскресенье в 9 бег")
        expect("воскресенье прошло", n?.start == at(8, 9))
        let o = parse("5 января отпуск")
        expect("январь следующего года", o?.date == cal.date(from: DateComponents(year: 2027, month: 1, day: 5)))

        // Ссылки на звонки.
        let zoom = ConferenceLink.find(in: [nil, "Звонок: https://us02web.zoom.us/j/123456?pwd=abc", "x"])
        let meet = ConferenceLink.find(in: ["https://meet.google.com/abc-defg-hij"])
        expect("ссылки", zoom?.host == "us02web.zoom.us" && meet?.host == "meet.google.com"
               && ConferenceLink.find(in: ["https://example.com/page", "просто текст"]) == nil)

        // Дела: добавление, отметка, хранение и очистка сделанного за прошлые периоды.
        final class Clock: @unchecked Sendable { var now: Date; init(_ now: Date) { self.now = now } }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("visor-plans-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let clock = Clock(now)
        let store = PlansStore(directory: tmp, clock: { clock.now })
        store.add(title: "Дело дня", horizon: .day)
        store.add(title: "Дело недели", horizon: .week, due: at(5))
        store.add(title: "Дело месяца", horizon: .month)
        store.add(title: "Несделанное", horizon: .day)
        store.add(title: "   ", horizon: .day) // пустое не добавляется
        for task in store.tasks where ["Дело дня", "Дело недели", "Дело месяца"].contains(task.title) { store.toggle(task.id) }
        expect("дела", store.tasks.count == 4 && store.tasks(in: .day).first?.title == "Несделанное" && store.tasks(in: .day).last?.done == true)
        expect("хранение дел", PlansStore(directory: tmp, clock: { clock.now }).tasks.count == 4)
        clock.now = at(2, 10) // понедельник, новая неделя, тот же месяц
        let nextDay = PlansStore(directory: tmp, clock: { clock.now })
        expect("очистка недели", Set(nextDay.tasks.map(\.title)) == ["Несделанное", "Дело месяца"])
        clock.now = at(1, 10, month: 12)
        let nextMonth = PlansStore(directory: tmp, clock: { clock.now })
        expect("очистка месяца и перенос несделанного", nextMonth.tasks.map(\.title) == ["Несделанное"])

        // Календарь: доступ по запросу, ближайшие встречи, создание события.
        let fake = FakeCalendar(access: .notDetermined)
        let service = CalendarService(source: fake)
        expect("до доступа", service.access == .notDetermined && service.events(in: DateInterval(start: Date(), duration: 3600)).isEmpty)
        let real = Date()
        func event(_ title: String, from start: TimeInterval, length: TimeInterval, allDay: Bool = false, link: String? = nil) -> CalendarEvent {
            CalendarEvent(id: UUID().uuidString, title: title, start: real.addingTimeInterval(start), end: real.addingTimeInterval(start + length),
                          isAllDay: allDay, calendar: "Дом", joinURL: link.flatMap(URL.init(string:)))
        }
        fake.events = [event("Вчера", from: -86_400, length: 3600), event("Скоро", from: 1200, length: 3600),
                       event("Звонок", from: 3 * 3600, length: 3600, link: "https://meet.google.com/abc-defg-hij"),
                       event("Весь день", from: 86_400, length: 86_400, allDay: true)]
        final class Flag { var done = false }
        let flag = Flag()
        Task { await service.requestAccess(); flag.done = true }
        let wait = Date().addingTimeInterval(3)
        while !flag.done, Date() < wait { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        expect("доступ выдан", service.access == .granted)
        service.refresh()
        expect("ближайшие", service.nextEvent()?.title == "Скоро" && service.nextConference()?.title == "Звонок"
               && service.imminentEvent()?.title == "Скоро" && !service.upcoming.contains { $0.title == "Вчера" })
        let created = try? service.create(ParsedEntry(title: "Репетитор", date: nil, start: real.addingTimeInterval(5 * 3600), durationMinutes: 45))
        expect("создание", created?.title == "Репетитор" && created.map { $0.end.timeIntervalSince($0.start) } == 2700
               && fake.events.contains { $0.title == "Репетитор" })

        // Выбор календарей: скрытый не показывается, новое событие идёт в выбранный, настройки сохраняются.
        let pickSuite = "com.beksultan.visor.caltest"
        UserDefaults(suiteName: pickSuite)?.removePersistentDomain(forName: pickSuite)
        if let pickDefaults = UserDefaults(suiteName: pickSuite) {
            let pickFake = FakeCalendar(access: .granted)
            pickFake.events = [
                CalendarEvent(id: "1", title: "Дома", start: real.addingTimeInterval(600), end: real.addingTimeInterval(4200),
                              isAllDay: false, calendar: "Дом", joinURL: nil, calendarID: "home"),
                CalendarEvent(id: "2", title: "В школе", start: real.addingTimeInterval(900), end: real.addingTimeInterval(4500),
                              isAllDay: false, calendar: "Школа", joinURL: nil, calendarID: "school"),
            ]
            let pickService = CalendarService(source: pickFake, defaults: pickDefaults)
            pickService.refresh()
            expect("два календаря", pickService.upcoming.count == 2 && pickService.calendarsByAccount.map(\.account) == ["Gmail", "iCloud"] && pickService.hasGoogle)
            pickService.setVisible("school", false)
            expect("скрытый календарь", pickService.upcoming.map(\.title) == ["Дома"] && !pickService.isVisible("school"))
            pickService.setVisible("school", true)
            let order = pickService.calendars.map(\.id)
            pickService.setLimit(1)
            let firstOnly = pickService.upcoming.map(\.calendarID)
            expect("предел календарей: остаётся первый по порядку, лишний помечен",
                   order.count >= 2 && firstOnly.allSatisfy { $0 == pickService.shownIDs?.first } && !pickService.isOverLimit(order[0]) == (pickService.shownIDs?.contains(order[0]) == true)
                   && pickService.shownIDs?.count == 1 && pickService.limit == 1)
            pickService.setLimit(0)
            expect("предел календарей: «все»", pickService.shownIDs == nil && pickService.upcoming.count == 2)
            pickService.setLimit(4) // такого значения нет: остаются все
            expect("предел календарей: мусор", pickService.limit == 0)
            pickService.setVisible("school", false)
            pickService.setTarget("school")
            _ = try? pickService.create(ParsedEntry(title: "Урок", date: nil, start: real.addingTimeInterval(7200), durationMinutes: 60))
            expect("новое событие в выбранный", pickFake.lastCalendarID == "school" && pickService.destinationName == "Школа")
            pickService.setTarget("holidays") // в него нельзя писать: берётся календарь по умолчанию
            expect("только чтение", pickService.destinationName == "Дом")
            let again = CalendarService(source: pickFake, defaults: pickDefaults)
            expect("хранение выбора", !again.isVisible("school") && again.targetID == "holidays")
            UserDefaults(suiteName: pickSuite)?.removePersistentDomain(forName: pickSuite)
        }

        // Вид: сегодня, неделя, месяц.
        let showFake = FakeCalendar(access: .granted)
        let today = cal.startOfDay(for: real)
        func slot(_ title: String, day: Int, hour: Int, minutes: Int = 60, link: String? = nil) -> CalendarEvent {
            let start = (cal.date(byAdding: .day, value: day, to: today).flatMap { cal.date(bySettingHour: hour, minute: 0, second: 0, of: $0) }) ?? real
            return CalendarEvent(id: UUID().uuidString, title: title, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                                 isAllDay: false, calendar: "Дом", joinURL: link.flatMap(URL.init(string:)))
        }
        showFake.events = [slot("Репетитор, математика", day: 0, hour: 23, minutes: 30),
                           slot("Созвон по макету", day: 0, hour: 23, minutes: 30, link: "https://meet.google.com/abc-defg-hij"),
                           slot("Робототехника", day: 1, hour: 15, minutes: 90), slot("Урок химии", day: 3, hour: 9),
                           slot("ГО и зал", day: 5, hour: 16)]
        let showService = CalendarService(source: showFake)
        showService.refresh()
        let showDir = tmp.appendingPathComponent("show")
        let showPlans = PlansStore(directory: showDir)
        showPlans.add(title: "Сдать домашку по химии", horizon: .day)
        showPlans.add(title: "Сделать правки в макете Visor", horizon: .day)
        showPlans.add(title: "Подготовиться к контрольной", horizon: .week, due: cal.date(byAdding: .day, value: 4, to: today))
        showPlans.add(title: "Записаться на олимпиаду", horizon: .month)
        if let first = showPlans.tasks.first { showPlans.toggle(first.id) }
        let model = IslandModel(defaults: UserDefaults(suiteName: "com.beksultan.visor.snapshot") ?? .standard)
        for (horizon, name, height) in [(PlanHorizon.day, "day", 380.0), (.week, "week", 600.0), (.month, "month", 640.0)] {
            save(PlansPage(model: model, plans: showPlans, calendar: showService, horizon: horizon).padding(14)
                .frame(width: 860, height: height, alignment: .top).background(Color.black), to: directory + "/plans-\(name).png")
        }

        print("plans: \(failures.isEmpty ? "все проверки" : "провалены: " + failures.joined(separator: ", "))")
        return failures.isEmpty
    }

    /// Таймер, секундомер и часы на подменённых часах, плюс один настоящий таймер на секунду.
    private static func timeSelfTest(renderTo directory: String) -> Bool {
        final class Clock: @unchecked Sendable { var now = Date() }
        let suite = "com.beksultan.visor.timetest"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        SoundEngine.shared.isMuted = true
        defer { SoundEngine.shared.isMuted = false }

        let clock = Clock()
        let store = TimeStore(defaults: defaults)
        store.clock = { clock.now }

        // Обратный отсчёт: идёт, пауза замораживает остаток, продолжение отсчитывает от остатка.
        store.start(seconds: 600, label: "Фокус")
        let running = store.isRunning && abs(store.remaining(at: clock.now.addingTimeInterval(60)) - 540) < 0.01
        clock.now = clock.now.addingTimeInterval(100)
        store.pause()
        clock.now = clock.now.addingTimeInterval(1000)
        let paused = store.isPaused && abs(store.remaining(at: clock.now) - 500) < 0.01
        store.resume()
        let resumed = store.isRunning && abs(store.remaining(at: clock.now.addingTimeInterval(100)) - 400) < 0.01

        // После перезапуска идущий таймер продолжается, а закончившийся без нас молча убирается.
        let restored = TimeStore(defaults: defaults, clock: { clock.now })
        let keeps = restored.isRunning && restored.countdown?.label == "Фокус"
        clock.now = clock.now.addingTimeInterval(10_000)
        let expired = TimeStore(defaults: defaults, clock: { clock.now }).countdown == nil

        // Настоящий таймер на секунду заканчивается сам.
        let real = TimeStore(defaults: UserDefaults(suiteName: suite + ".real") ?? defaults)
        real.start(seconds: 1, label: "Тест")
        let end = Date().addingTimeInterval(3)
        while !real.isFinished, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let finished = real.isFinished && real.remaining(at: Date()) == 0
        real.reset()
        UserDefaults(suiteName: suite + ".real")?.removePersistentDomain(forName: suite + ".real")

        // Секундомер.
        let watch = TimeStore(defaults: defaults)
        watch.clock = { clock.now }
        watch.swToggle()
        clock.now = clock.now.addingTimeInterval(12.3)
        watch.swLap()
        watch.swToggle()
        let stopped = !watch.swRunning && abs(watch.swElapsed(at: clock.now) - 12.3) < 0.01 && watch.laps.count == 1
        clock.now = clock.now.addingTimeInterval(50)
        let frozen = abs(watch.swElapsed(at: clock.now) - 12.3) < 0.01
        watch.swToggle()
        clock.now = clock.now.addingTimeInterval(5)
        let again = abs(watch.swElapsed(at: clock.now) - 17.3) < 0.01
        watch.swReset()
        let cleared = watch.swElapsed(at: clock.now) == 0 && watch.laps.isEmpty && !watch.swRunning

        // Часы: города сохраняются, неизвестный пояс отбрасывается.
        let zones = TimeStore(defaults: defaults)
        zones.addZone("Europe/Paris")
        zones.addZone("Nowhere/Land")
        zones.removeZone("Asia/Tokyo")
        let zonesSaved = TimeStore(defaults: defaults).zones == ["Asia/Almaty", "Europe/London", "America/New_York", "Europe/Paris"]
        let names = TimeStore.name(of: "Asia/Almaty") == "Алматы" && TimeStore.name(of: "Africa/Cairo") == "Cairo"

        let formats = TimeFormat.clock(1122) == "18:42" && TimeFormat.clock(3900) == "1:05:00"
            && TimeFormat.stopwatch(83.4) == "01:23.4"

        // Вид: Pomodoro на ходу, часы, секундомер и капсула в острове.
        let showSuite = suite + ".show"
        UserDefaults(suiteName: showSuite)?.removePersistentDomain(forName: showSuite)
        let show = TimeStore(defaults: UserDefaults(suiteName: showSuite) ?? defaults)
        show.start(seconds: 1122, label: "Фокус")
        let model = IslandModel(defaults: UserDefaults(suiteName: "com.beksultan.visor.snapshot") ?? .standard)
        show.sub = .pomodoro
        save(TimePage(model: model, store: show).padding(14).frame(width: 860, height: 300, alignment: .top).background(Color.black),
             to: directory + "/time-pomodoro.png")
        show.sub = .timer
        save(TimePage(model: model, store: show).padding(14).frame(width: 860, height: 300, alignment: .top).background(Color.black),
             to: directory + "/time-timer.png")
        show.sub = .stopwatch
        save(TimePage(model: model, store: show).padding(14).frame(width: 860, height: 300, alignment: .top).background(Color.black),
             to: directory + "/time-stopwatch.png")
        show.sub = .clocks
        save(TimePage(model: model, store: show).padding(14).frame(width: 860, height: 300, alignment: .top).background(Color.black),
             to: directory + "/time-clocks.png")
        save(TimerCapsule(store: show).padding(14).background(Color.black), to: directory + "/time-capsule.png")
        show.reset()
        UserDefaults(suiteName: showSuite)?.removePersistentDomain(forName: showSuite)

        print("time: run=\(running) pause=\(paused) resume=\(resumed) restore=\(keeps) expired=\(expired) finish=\(finished) watch=\(stopped && frozen && again && cleared) zones=\(zonesSaved && names) formats=\(formats)")
        return running && paused && resumed && keeps && expired && finished && stopped && frozen && again && cleared && zonesSaved && names && formats
    }

    /// Разбор лимитов Claude и Codex на образцах.
    private static func limitsSelfTest() -> Bool {
        // Настоящий JSON, как его читает приложение: числа приходят как NSNumber, а не как литералы Swift.
        func json(_ text: String) -> [String: Any] {
            ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]) ?? [:]
        }
        let future = Int(Date().timeIntervalSince1970) + 7200
        let claude = PlanParser.claude(payload: json(#"{"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":\#(future)},"seven_day":{"used_percentage":18,"resets_at":\#(future + 259200)}}}"#))
        let claudeOK = claude?.fiveHour?.usedPct == 42.5 && claude?.sevenDay?.usedPct == 18
        // Миллисекунды вместо секунд отбрасываются.
        let milliseconds = PlanParser.claude(payload: json(#"{"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":99999999999999}}}"#)) == nil
        let codex = PlanParser.codex(result: json(#"{"rateLimits":{"primary":{"usedPercent":30,"resetsAt":\#(future),"windowDurationMins":300},"secondary":{"usedPercent":70.5,"resetsAt":\#(future),"windowDurationMins":10080}}}"#))
        let codexOK = codex?.fiveHour?.usedPct == 30 && codex?.sevenDay?.usedPct == 70.5
        let expired = PlanWindow(usedPct: 80, resetsAt: Date().addingTimeInterval(-5)).effectivePct() == 0
        return claudeOK && milliseconds && codexOK && expired
    }

    /// Настоящий скрипт-ретранслятор против настоящего сервера на сокете, без агентов.
    private static func socketSelfTest() -> Bool {
        SoundEngine.shared.isMuted = true
        defer { SoundEngine.shared.isMuted = false }
        HookRelay.install()
        let server = HookServer()
        do {
            try server.start { request in
                Task { @MainActor in AgentCenter.shared.handle(request) }
            }
        } catch {
            print("socket: сервер не запустился \(error)")
            return false
        }

        func spawn(_ agent: String, wait: Int, payload: String) -> (process: Process, out: Pipe) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [VisorPaths.relayURL.path, agent, String(wait)]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try? process.run()
            input.fileHandleForWriting.write(Data((payload + "\n").utf8))
            try? input.fileHandleForWriting.close()
            return (process, output)
        }
        func pump(until limit: TimeInterval, _ done: () -> Bool) {
            let end = Date().addingTimeInterval(limit)
            while !done(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }

        // 1. Обычное событие: ответа нет, ретранслятор выходит быстро, сессия появилась.
        let started = Date()
        let stop = spawn("claude", wait: 3, payload: #"{"hook_event_name":"Stop","session_id":"sock1","cwd":"/tmp/sock"}"#)
        pump(until: 5) { !stop.process.isRunning }
        let stopOut = (try? stop.out.fileHandleForReading.readToEnd()) ?? Data()
        let quick = Date().timeIntervalSince(started) < 2
        let stopOK = !stop.process.isRunning && stop.process.terminationStatus == 0 && stopOut.isEmpty
            && AgentCenter.shared.sessions["claude:sock1"] != nil && quick

        // 2. Запрос прав: ретранслятор ждёт, пока не нажмут «Разрешить».
        let ask = spawn("claude", wait: 20, payload: #"{"hook_event_name":"PermissionRequest","session_id":"sock1","cwd":"/tmp/sock","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        pump(until: 5) { !AgentCenter.shared.permissions.isEmpty }
        let held = AgentCenter.shared.permissions.count == 1 && ask.process.isRunning
        if let id = AgentCenter.shared.permissions.first?.id { AgentCenter.shared.decide(id, .allow) }
        pump(until: 5) { !ask.process.isRunning }
        let askOut = String(data: (try? ask.out.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
        let askOK = held && !ask.process.isRunning && askOut.contains("\"behavior\":\"allow\"") && askOut.contains("PermissionRequest")

        // 4. Строка состояния Claude Code: лимиты доходят до приложения, прежняя строка продолжает печатать.
        let usageKey = "plan.usage.claude"
        let savedUsage = UserDefaults.standard.data(forKey: usageKey) // тест не должен портить сохранённые лимиты
        defer {
            if let savedUsage { UserDefaults.standard.set(savedUsage, forKey: usageKey) } else { UserDefaults.standard.removeObject(forKey: usageKey) }
        }
        func runStatus(_ payload: String) -> (ok: Bool, out: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [VisorPaths.statusRelayURL.path]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try? process.run()
            input.fileHandleForWriting.write(Data((payload + "\n").utf8))
            try? input.fileHandleForWriting.close()
            pump(until: 5) { !process.isRunning }
            let text = String(data: (try? output.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
            return (!process.isRunning && process.terminationStatus == 0, text)
        }
        let reset = Int(Date().timeIntervalSince1970) + 3600
        let statusPayload = #"{"session_id":"s","rate_limits":{"five_hour":{"used_percentage":55,"resets_at":\#(reset)},"seven_day":{"used_percentage":9,"resets_at":\#(reset + 86400)}}}"#
        let plain = runStatus(statusPayload)
        pump(until: 2) { AgentCenter.shared.usage[.claude]?.fiveHour?.usedPct == 55 }
        var statusOK = plain.ok && plain.out.isEmpty && AgentCenter.shared.usage[.claude]?.fiveHour?.usedPct == 55
            && AgentCenter.shared.usage[.claude]?.sevenDay?.usedPct == 9
        if !FileManager.default.fileExists(atPath: VisorPaths.previousStatusLineURL.path) {
            try? "echo PREV-OK".write(to: VisorPaths.previousStatusLineURL, atomically: true, encoding: .utf8)
            let chained = runStatus(statusPayload)
            try? FileManager.default.removeItem(at: VisorPaths.previousStatusLineURL)
            statusOK = statusOK && chained.ok && chained.out.contains("PREV-OK")
        }

        // 3. Приложение не запущено: ретранслятор тихо выходит с кодом 0.
        server.stop()
        let gone = Date()
        let none = spawn("claude", wait: 3, payload: #"{"hook_event_name":"Stop","session_id":"sock2"}"#)
        pump(until: 5) { !none.process.isRunning }
        let noneOK = !none.process.isRunning && none.process.terminationStatus == 0 && Date().timeIntervalSince(gone) < 2

        print("socket: stop=\(stopOK) ask=\(askOK) status=\(statusOK) noServer=\(noneOK)")
        return stopOK && askOK && statusOK && noneOK
    }

    /// Прогоняет события агента через AgentCenter без сокета.
    private static func agentFlowSelfTest() -> Bool {
        let center = AgentCenter.shared
        func send(_ agent: String, _ json: [String: Any]) -> String? {
            let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
            let reply = HookReply(fd: -1)
            center.handle(HookRequest(agent: agent, body: body, reply: reply))
            return nil
        }
        _ = send("claude", ["hook_event_name": "SessionStart", "session_id": "t1", "cwd": "/tmp/proj"])
        let idleAfterStart = center.sessions["claude:t1"]?.state == .done
        _ = send("claude", ["hook_event_name": "UserPromptSubmit", "session_id": "t1"])
        let working = center.summary.state == .working
        _ = send("claude", ["hook_event_name": "PermissionRequest", "session_id": "t1", "tool_name": "Bash",
                            "tool_input": ["command": "npm run build"]])
        let waiting = center.summary.state == .waiting && center.permissions.count == 1
        let id = center.permissions.first?.id
        if let id { center.decide(id, .allow) }
        let resumed = center.permissions.isEmpty && center.sessions["claude:t1"]?.state == .working
        _ = send("claude", ["hook_event_name": "Stop", "session_id": "t1"])
        let done = center.summary.state == .done && center.focusSession != nil
        // «Готово» гаснет через 2 минуты, а сессия остаётся в списке.
        center.backdateForSnapshot("claude:t1", by: 130)
        let faded = center.summary.state == .idle && center.focusSession == nil && center.sessions["claude:t1"] != nil
        // «Ждёт вас» не гаснет, сколько бы ни прошло времени.
        _ = send("claude", ["hook_event_name": "Notification", "session_id": "t1", "message": "Claude needs your permission"])
        center.backdateForSnapshot("claude:t1", by: 3600)
        let waitStays = center.summary.state == .waiting && center.focusSession != nil
        _ = send("claude", ["hook_event_name": "Stop", "session_id": "t1"])
        _ = send("claude", ["hook_event_name": "SessionEnd", "session_id": "t1"])
        let gone = center.sessions.isEmpty && center.summary.state == .idle

        // Формат ответа на запрос прав.
        let probe = AgentPermission(sessionKey: "k", agent: .claude, tool: "Bash", summary: "", suggestions: nil, reply: HookReply(fd: -1))
        let allow = AgentCenter.hookOutput(for: probe, decision: .allow) ?? ""
        let deny = AgentCenter.hookOutput(for: probe, decision: .deny) ?? ""
        let format = allow.contains("\"behavior\":\"allow\"") && allow.contains("PermissionRequest")
            && deny.contains("\"behavior\":\"deny\"")
        return idleAfterStart && working && waiting && resumed && done && faded && waitStays && gone && format
    }

    /// Меняем настройки в одной модели и читаем их из новой на том же хранилище.
    private static func persistenceSelfTest() -> Bool {
        let name = "com.beksultan.visor.selftest"
        guard let suite = UserDefaults(suiteName: name) else { return false }
        suite.removePersistentDomain(forName: name)
        defer { suite.removePersistentDomain(forName: name) }

        let first = IslandModel(defaults: suite)
        let startsClean = first.tab == .agents
            && first.visibleTabs.count == IslandTab.allCases.count
            && first.enabledModules.isEmpty
            && !first.isMuted
        first.setTab(.chat, enabled: false)
        first.setTab(.agents, enabled: false) // должна остаться включённой
        first.select(.time)
        first.toggleMute()
        first.setModule(.github, enabled: true)

        let second = IslandModel(defaults: suite)
        let restored = second.tab == .time
            && !second.enabledTabs.contains(.chat)
            && second.enabledTabs.contains(.agents)
            && second.isMuted
            && second.enabledModules == [.github]

        // Если выбранную вкладку выключить, остров возвращается на «Агенты».
        second.setTab(.time, enabled: false)
        let fallsBack = second.tab == .agents
        SoundEngine.shared.isMuted = false
        return startsClean && restored && fallsBack
    }

    private static func save<V: View>(_ view: V, to path: String) {
        let framed = ZStack(alignment: .top) {
            Color(white: 0.16)
            view
        }
        .environment(\.colorScheme, .dark)
        .environment(\.snapshotMode, true)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
