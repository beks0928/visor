import Foundation

/// Результат разбора строки быстрого ввода.
struct ParsedEntry: Equatable {
    var title: String
    /// Начало суток, если названа дата.
    var date: Date?
    /// Начало события, если названо время.
    var start: Date?
    var durationMinutes: Int

    /// Со временем это событие в календаре, без времени это дело.
    var isEvent: Bool { start != nil }

    /// В какой список попадает дело без времени: по тому, как далеко названная дата.
    func horizon(now: Date = Date(), calendar: Calendar = .current) -> PlanHorizon? {
        guard let date else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: date).day ?? 0
        if days <= 0 { return .day }
        return days <= 7 ? .week : .month
    }
}

/// Разбор русской строки: «завтра 16:00 репетитор 1ч», «в пятницу в 15 робототехника 90 мин»,
/// «15 ноября день рождения», «через 3 дня 18:30 созвон». Без даты и времени это просто дело.
enum QuickParser {
    private struct Scan {
        var text: String

        func find(_ pattern: String) -> (groups: [String], range: NSRange)? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let whole = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: whole) else { return nil }
            let ns = text as NSString
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            return (groups, match.range)
        }

        mutating func remove(_ range: NSRange) {
            text = (text as NSString).replacingCharacters(in: range, with: " ")
        }

        /// Находит и сразу убирает совпадение.
        mutating func take(_ pattern: String) -> [String]? {
            guard let found = find(pattern) else { return nil }
            remove(found.range)
            return found.groups
        }
    }

    private static let weekdayByPrefix: [(String, Int)] = [
        ("пон", 2), ("вто", 3), ("сре", 4), ("чет", 5), ("пят", 6), ("суб", 7), ("вос", 1),
    ]
    private static let weekdayShort: [String: Int] = ["пн": 2, "вт": 3, "ср": 4, "чт": 5, "пт": 6, "сб": 7, "вс": 1]

    private static func month(of word: String) -> Int? {
        let w = word.lowercased()
        if w == "мая" || w == "май" { return 5 }
        let prefixes: [(String, Int)] = [("янв", 1), ("фев", 2), ("мар", 3), ("апр", 4), ("июн", 6), ("июл", 7),
                                         ("авг", 8), ("сен", 9), ("окт", 10), ("ноя", 11), ("дек", 12)]
        return prefixes.first { w.hasPrefix($0.0) }?.1
    }

    private static func weekday(of word: String) -> Int? {
        let w = word.lowercased()
        if let short = weekdayShort[w] { return short }
        return weekdayByPrefix.first { w.hasPrefix($0.0) }?.1
    }

    static func parse(_ input: String, now: Date = Date(), calendar cal: Calendar = .current) -> ParsedEntry? {
        var scan = Scan(text: input)
        var minutes = 60
        let today = cal.startOfDay(for: now)

        // Длительность: «1ч», «1.5 часа», «90 мин». «в 16 часов» это время, а не длительность.
        if let g = scan.take(#"(?<!в\s)(?<![\d.:])(\d+(?:[.,]\d+)?)\s*(?:часов|часа|час|ч|h)(?![\p{L}\d])"#) {
            let hours = Double(g[1].replacingOccurrences(of: ",", with: ".")) ?? 1
            minutes = max(5, Int((hours * 60).rounded()))
        } else if let g = scan.take(#"(?<![\d.:])(\d+)\s*(?:минуты|минут|мин|min)(?![\p{L}\d])"#) {
            minutes = max(5, Int(g[1]) ?? 60)
        }

        var hour: Int?
        var minute = 0
        if let g = scan.take(#"(?<![\d.:])([01]?\d|2[0-3]):([0-5]\d)(?![\d:])"#) {
            hour = Int(g[1])
            minute = Int(g[2]) ?? 0
        }

        var date: Date?
        var namedWeekday = false
        if let g = scan.take(#"через\s+(\d+)\s*(?:дня|дней|день|дн)(?![\p{L}])"#), let n = Int(g[1]) {
            date = cal.date(byAdding: .day, value: n, to: today)
        } else if scan.take(#"через\s+неделю(?![\p{L}])"#) != nil {
            date = cal.date(byAdding: .day, value: 7, to: today)
        } else if let g = scan.take(#"(?<![\p{L}])(послезавтра|завтра|сегодня)(?![\p{L}])"#) {
            let offset = ["сегодня": 0, "завтра": 1, "послезавтра": 2][g[1].lowercased()] ?? 0
            date = cal.date(byAdding: .day, value: offset, to: today)
        }

        if date == nil,
           let g = scan.take(#"(?<!\d)(\d{1,2})\s+(янв\p{L}*|фев\p{L}*|мар\p{L}*|апр\p{L}*|ма[яй]|июн\p{L}*|июл\p{L}*|авг\p{L}*|сен\p{L}*|окт\p{L}*|ноя\p{L}*|дек\p{L}*)"#),
           let day = Int(g[1]), let m = month(of: g[2]) {
            date = nextDate(day: day, month: m, year: nil, today: today, cal: cal)
        }

        if date == nil, let found = scan.find(#"(?<![\d:.])(\d{1,2})\.(\d{1,2})(?:\.(\d{2,4}))?(?![\d:.])"#),
           let day = Int(found.groups[1]), let m = Int(found.groups[2]), (1...31).contains(day), (1...12).contains(m) {
            scan.remove(found.range)
            var year = Int(found.groups[3])
            if let y = year, y < 100 { year = 2000 + y }
            date = nextDate(day: day, month: m, year: year, today: today, cal: cal)
        }

        if date == nil,
           let g = scan.take(#"(?<![\p{L}])(?:(?:в|во|на)\s+)?(понедельник\p{L}*|вторник\p{L}*|сред\p{L}*|четверг\p{L}*|пятниц\p{L}*|суббот\p{L}*|воскресен\p{L}*|пн|вт|ср|чт|пт|сб|вс)(?![\p{L}])"#),
           let target = weekday(of: g[1]) {
            let current = cal.component(.weekday, from: today)
            var delta = (target - current + 7) % 7
            // Если названный день сегодня, а названное время уже прошло, имеется в виду следующая неделя.
            if delta == 0, let h = hour, let moment = cal.date(bySettingHour: h, minute: minute, second: 0, of: now), moment <= now { delta = 7 }
            date = cal.date(byAdding: .day, value: delta, to: today)
            namedWeekday = true
        }

        // «в 16», «в 16 часов»: время без минут.
        if hour == nil,
           let g = scan.take(#"(?<![\p{L}\d])в\s+([01]?\d|2[0-3])(?![\d:.,])(?:\s*(?:часов|часа|час|ч)(?![\p{L}]))?"#) {
            hour = Int(g[1])
        }

        let title = cleanTitle(scan.text)
        guard !title.isEmpty else { return nil }

        var start: Date?
        if let h = hour {
            var day = date ?? today
            start = cal.date(bySettingHour: h, minute: minute, second: 0, of: day)
            // Время без даты, которое сегодня уже прошло, означает завтра.
            if date == nil, let moment = start, moment <= now {
                day = cal.date(byAdding: .day, value: 1, to: today) ?? today
                start = cal.date(bySettingHour: h, minute: minute, second: 0, of: day)
                date = day
            } else if date == nil {
                date = today
            }
            // Названный день недели оказался сегодняшним, но время «в 9» уже прошло: следующая неделя.
            if namedWeekday, let moment = start, moment <= now, let current = date, current == today {
                date = cal.date(byAdding: .day, value: 7, to: today)
                start = cal.date(byAdding: .day, value: 7, to: moment)
            }
        }
        return ParsedEntry(title: title, date: date, start: start, durationMinutes: minutes)
    }

    private static func nextDate(day: Int, month: Int, year: Int?, today: Date, cal: Calendar) -> Date? {
        var parts = DateComponents()
        parts.day = day
        parts.month = month
        parts.year = year ?? cal.component(.year, from: today)
        guard var date = cal.date(from: parts), cal.component(.day, from: date) == day else { return nil }
        // Дата без года, которая в этом году уже прошла, означает следующий год.
        if year == nil, date < today {
            parts.year = (parts.year ?? 0) + 1
            date = cal.date(from: parts) ?? date
        }
        return date
    }

    private static func cleanTitle(_ raw: String) -> String {
        var words = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let stray: Set<String> = ["в", "во", "на", "к", "с", "до", "по", "и", ","]
        while let first = words.first, stray.contains(first.lowercased()) { words.removeFirst() }
        while let last = words.last, stray.contains(last.lowercased()) { words.removeLast() }
        var title = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.-—–"))
        if let first = title.first { title = first.uppercased() + title.dropFirst() }
        return title
    }
}
