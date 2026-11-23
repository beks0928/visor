import Foundation

/// Результат строки ввода: что показать и что скопировать.
struct ToolResult: Equatable {
    enum Kind { case math, percent, units, currency }

    var kind: Kind
    /// «310 $ = 140 538 ₸».
    var headline: String
    /// То, что копируется по клику: «140 538 ₸».
    var value: String
    var detail: String?
    var extras: [String] = []
    /// Для валют: из чего во что и сколько. По нему рисуется график курса.
    var pair: CurrencyPair?
}

/// Курсы валют: сколько единиц валюты в одном долларе США.
struct RateTable: Codable, Equatable, Sendable {
    var perUSD: [String: Double]
    var updated: Date

    /// Снимок на 31.10.2026: на нём приложение работает, пока нет сети и нет свежего кеша.
    static let builtIn = RateTable(
        perUSD: ["USD": 1, "EUR": 0.8956, "KZT": 453.3469, "RUB": 80.4089, "GBP": 0.7471, "CNY": 6.6696, "JPY": 157.4944,
                 "TRY": 49.9539, "KRW": 1334.5069, "AED": 3.6725, "UAH": 45.4013, "CHF": 0.8245, "INR": 95.0736,
                 "PLN": 3.9411, "UZS": 11994.6415, "CAD": 1.3966, "AUD": 1.4223, "GEL": 2.5963, "KGS": 87.46],
        updated: Date(timeIntervalSince1970: 1_793_404_951) // 2026-10-31 00:02 UTC
    )
}

/// Калькулятор, проценты, единицы и валюты в одной строке: «310$ в тенге», «15% от 84 000», «5 миль в км», «72 f в c».
@MainActor
enum ToolsEngine {
    static func evaluate(_ text: String, rates: RateTable, defaultCurrency: String) -> ToolResult? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        // Единицы идут первыми: «фунты в кг» это вес, а «100 фунтов в рубли» уже валюта.
        if let units = units(input) { return units }
        if let money = currency(input, rates: rates, defaultCurrency: defaultCurrency) { return money }
        return math(input)
    }

    // MARK: Форматирование

    private static var formatters: [Int: NumberFormatter] = [:]

    /// Число по-русски с пробелом между тысячами и запятой в дробной части.
    static func number(_ value: Double, maxFraction: Int) -> String {
        let formatter = formatters[maxFraction] ?? {
            let f = NumberFormatter()
            f.locale = Locale(identifier: "ru_RU")
            f.numberStyle = .decimal
            f.usesGroupingSeparator = true
            f.maximumFractionDigits = maxFraction
            formatters[maxFraction] = f
            return f
        }()
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func moneyDigits(_ value: Double) -> Int {
        abs(value) >= 1000 ? 0 : abs(value) >= 1 ? 2 : 4
    }

    // MARK: Калькулятор

    static func math(_ input: String) -> ToolResult? {
        let lower = input.lowercased()
        // «15% от 84 000», «20% of 50».
        if let found = firstMatch(#"^\s*([\d][\d\s.,]*)\s*%\s*(?:от|of)\s*([\d][\d\s.,]*)\s*$"#, in: lower),
           let percent = plainNumber(found[1]), let base = plainNumber(found[2]) {
            let result = percent * base / 100
            let text = number(result, maxFraction: 6)
            return ToolResult(kind: .percent, headline: "\(number(percent, maxFraction: 6))% от \(number(base, maxFraction: 6)) = \(text)", value: text)
        }
        guard lower.contains(where: \.isNumber) else { return nil }
        var parser = MathParser(text: lower)
        guard let result = parser.parse(), result.isFinite, parser.usedOperator else { return nil }
        let text = number(result, maxFraction: 8)
        return ToolResult(kind: .math, headline: "= \(text)", value: text)
    }

    private static func plainNumber(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: "."))
    }

    private struct MathParser {
        struct Val { var value: Double; var percent: Bool }

        private var chars: [Character]
        private var pos = 0
        private(set) var usedOperator = false

        init(text: String) {
            var normalized = text
                .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
                .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: ".")
            // «84 000» это одно число.
            if let regex = try? NSRegularExpression(pattern: #"(?<=\d)\s+(?=\d)"#) {
                normalized = regex.stringByReplacingMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "")
            }
            chars = Array(normalized)
        }

        mutating func parse() -> Double? {
            guard let value = expr() else { return nil }
            skip()
            return pos == chars.count ? value.value : nil
        }

        private mutating func skip() { while pos < chars.count, chars[pos] == " " { pos += 1 } }

        private mutating func accept(_ options: [Character]) -> Character? {
            skip()
            guard pos < chars.count, options.contains(chars[pos]) else { return nil }
            pos += 1
            usedOperator = true
            return chars[pos - 1]
        }

        private mutating func expr() -> Val? {
            guard var left = term() else { return nil }
            while let op = accept(["+", "-"]) {
                guard let right = term() else { return nil }
                // «84000 + 15%» это прибавить 15% от 84000.
                let amount = right.percent ? left.value * right.value : right.value
                left = Val(value: op == "+" ? left.value + amount : left.value - amount, percent: false)
            }
            return left
        }

        private mutating func term() -> Val? {
            guard var left = power() else { return nil }
            while let op = accept(["*", "/"]) {
                guard let right = power() else { return nil }
                if op == "/" {
                    guard right.value != 0 else { return nil }
                    left = Val(value: left.value / right.value, percent: false)
                } else {
                    left = Val(value: left.value * right.value, percent: false)
                }
            }
            return left
        }

        private mutating func power() -> Val? {
            guard let base = unary() else { return nil }
            if accept(["^"]) != nil {
                guard let exponent = power() else { return nil }
                return Val(value: pow(base.value, exponent.value), percent: false)
            }
            return base
        }

        private mutating func unary() -> Val? {
            if accept(["-"]) != nil {
                guard let value = unary() else { return nil }
                return Val(value: -value.value, percent: value.percent)
            }
            if accept(["+"]) != nil { return unary() }
            return postfix()
        }

        private mutating func postfix() -> Val? {
            guard let value = primary() else { return nil }
            if accept(["%"]) != nil { return Val(value: value.value / 100, percent: true) }
            return value
        }

        private mutating func primary() -> Val? {
            skip()
            guard pos < chars.count else { return nil }
            if chars[pos] == "(" {
                pos += 1
                guard let inner = expr() else { return nil }
                skip()
                guard pos < chars.count, chars[pos] == ")" else { return nil }
                pos += 1
                return Val(value: inner.value, percent: false)
            }
            // 0xFF
            if chars[pos] == "0", pos + 1 < chars.count, chars[pos + 1] == "x" {
                var end = pos + 2
                while end < chars.count, chars[end].isHexDigit { end += 1 }
                guard end > pos + 2, let value = Int(String(chars[(pos + 2)..<end]), radix: 16) else { return nil }
                pos = end
                return Val(value: Double(value), percent: false)
            }
            var end = pos
            while end < chars.count, chars[end].isNumber || chars[end] == "." { end += 1 }
            guard end > pos, let value = Double(String(chars[pos..<end])) else { return nil }
            pos = end
            return Val(value: value, percent: false)
        }
    }

    // MARK: Единицы

    private enum Dimension { case length, mass, volume, speed, data, temperature }

    private struct UnitDef {
        let dimension: Dimension
        /// Во сколько базовых единиц (м, кг, л, м/с, Б) входит эта. Для температуры хранит номер шкалы.
        let factor: Double
        let symbol: String
    }

    private static let unitAliases: [(aliases: [String], unit: UnitDef)] = [
        (["мм", "mm"], UnitDef(dimension: .length, factor: 0.001, symbol: "мм")),
        (["см", "cm"], UnitDef(dimension: .length, factor: 0.01, symbol: "см")),
        (["м", "m"], UnitDef(dimension: .length, factor: 1, symbol: "м")),
        (["км", "km"], UnitDef(dimension: .length, factor: 1000, symbol: "км")),
        (["inch", "inches", "дюйм", "дюйма", "дюймов", "″"], UnitDef(dimension: .length, factor: 0.0254, symbol: "дюйм")),
        (["ft", "foot", "feet", "фут", "фута", "футов", "футы"], UnitDef(dimension: .length, factor: 0.3048, symbol: "фут")),
        (["yd", "yard", "yards", "ярд", "ярда", "ярдов"], UnitDef(dimension: .length, factor: 0.9144, symbol: "ярд")),
        (["mi", "mile", "miles", "миля", "мили", "миль"], UnitDef(dimension: .length, factor: 1609.344, symbol: "миль")),
        (["мг", "mg"], UnitDef(dimension: .mass, factor: 0.000001, symbol: "мг")),
        (["г", "g", "гр"], UnitDef(dimension: .mass, factor: 0.001, symbol: "г")),
        (["кг", "kg"], UnitDef(dimension: .mass, factor: 1, symbol: "кг")),
        (["т", "t", "тонна", "тонны", "тонн"], UnitDef(dimension: .mass, factor: 1000, symbol: "т")),
        (["oz", "унция", "унции", "унций"], UnitDef(dimension: .mass, factor: 0.0283495, symbol: "унц")),
        (["lb", "lbs", "pound", "pounds", "фунт", "фунта", "фунтов", "фунты"], UnitDef(dimension: .mass, factor: 0.45359237, symbol: "фунт")),
        (["мл", "ml"], UnitDef(dimension: .volume, factor: 0.001, symbol: "мл")),
        (["л", "l", "литр", "литра", "литров", "liter", "litre"], UnitDef(dimension: .volume, factor: 1, symbol: "л")),
        (["gal", "gallon", "gallons", "галлон", "галлона", "галлонов"], UnitDef(dimension: .volume, factor: 3.785411784, symbol: "галл")),
        (["м/с", "m/s"], UnitDef(dimension: .speed, factor: 1, symbol: "м/с")),
        (["км/ч", "km/h", "kmh", "kph"], UnitDef(dimension: .speed, factor: 1000.0 / 3600, symbol: "км/ч")),
        (["mph", "миль/ч"], UnitDef(dimension: .speed, factor: 0.44704, symbol: "миль/ч")),
        (["kn", "knot", "узел", "узла", "узлов"], UnitDef(dimension: .speed, factor: 0.514444, symbol: "уз")),
        (["b", "byte", "bytes", "байт", "б"], UnitDef(dimension: .data, factor: 1, symbol: "Б")),
        (["kb", "кб", "kbyte", "килобайт"], UnitDef(dimension: .data, factor: 1e3, symbol: "КБ")),
        (["mb", "мб", "mbyte", "мегабайт"], UnitDef(dimension: .data, factor: 1e6, symbol: "МБ")),
        (["gb", "гб", "gbyte", "гигабайт"], UnitDef(dimension: .data, factor: 1e9, symbol: "ГБ")),
        (["tb", "тб", "tbyte", "терабайт"], UnitDef(dimension: .data, factor: 1e12, symbol: "ТБ")),
        (["c", "с", "°c", "°с", "цельсий", "цельсия", "цельсию"], UnitDef(dimension: .temperature, factor: 0, symbol: "°C")),
        (["f", "°f", "фаренгейт", "фаренгейта", "фаренгейту"], UnitDef(dimension: .temperature, factor: 1, symbol: "°F")),
        (["k", "°k", "кельвин", "кельвина"], UnitDef(dimension: .temperature, factor: 2, symbol: "K")),
    ]

    private static func unit(_ raw: String) -> UnitDef? {
        let word = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if let entry = unitAliases.first(where: { $0.aliases.contains(word) }) { return entry.unit }
        // Падежи и множественное число: «километров», «килограммах», «километры».
        let stems: [(String, String)] = [
            ("миллиметр", "мм"), ("сантиметр", "см"), ("километр", "км"), ("метр", "м"), ("миллилитр", "мл"), ("литр", "л"),
            ("килограмм", "кг"), ("грамм", "г"), ("тонн", "т"), ("дюйм", "дюйм"), ("фут", "фут"), ("ярд", "ярд"),
            ("мил", "миль"), ("унц", "унция"), ("фунт", "фунт"), ("галлон", "галлон"), ("байт", "байт"),
        ]
        if word.count >= 4, let stem = stems.first(where: { word.hasPrefix($0.0) }) {
            return unitAliases.first { $0.aliases.contains(stem.1) }?.unit
        }
        return nil
    }

    static func units(_ input: String) -> ToolResult? {
        let pattern = #"^\s*(-?\d[\d\s.,]*?)\s*([\p{L}°″/]+)\s+(?:в|во|to|in|into|->|→|=)\s+([\p{L}°″/]+)\s*$"#
        guard let found = firstMatch(pattern, in: input), let amount = plainNumber(found[1]),
              let from = unit(found[2]), let to = unit(found[3]), from.dimension == to.dimension else { return nil }
        let result: Double
        if from.dimension == .temperature {
            result = fromCelsius(toCelsius(amount, from.factor), to.factor)
        } else {
            result = amount * from.factor / to.factor
        }
        let digits = abs(result) >= 100 ? 2 : 4
        let text = "\(number(result, maxFraction: digits)) \(to.symbol)"
        let amountText = "\(number(amount, maxFraction: 4)) \(from.symbol)"
        var detail: String?
        if from.dimension != .temperature {
            detail = "1 \(from.symbol) = \(number(from.factor / to.factor, maxFraction: 6)) \(to.symbol)"
        }
        return ToolResult(kind: .units, headline: "\(amountText) = \(text)", value: text, detail: detail)
    }

    /// 0 это °C, 1 это °F, 2 это K.
    private static func toCelsius(_ value: Double, _ scale: Double) -> Double {
        switch Int(scale) {
        case 1: (value - 32) * 5 / 9
        case 2: value - 273.15
        default: value
        }
    }

    private static func fromCelsius(_ value: Double, _ scale: Double) -> Double {
        switch Int(scale) {
        case 1: value * 9 / 5 + 32
        case 2: value + 273.15
        default: value
        }
    }

    // MARK: Валюты

    private static let symbols: [String: String] = ["USD": "$", "EUR": "€", "KZT": "₸", "RUB": "₽", "GBP": "£", "TRY": "₺", "UAH": "₴", "INR": "₹", "KRW": "₩"]

    /// Слово с «!» на конце ищется только целиком, остальные по началу слова (доллар, долларов, долларах).
    private static let currencyAliases: [(code: String, words: [String])] = [
        ("USD", ["$", "usd", "доллар", "долл", "бакс", "dollar"]), ("EUR", ["€", "eur", "евро", "euro"]),
        ("KZT", ["₸", "kzt", "тенге", "тнг!", "тг!", "tenge"]), ("RUB", ["₽", "rub", "руб", "ruble"]),
        ("GBP", ["£", "gbp", "фунт", "pound"]), ("CNY", ["cny", "юан", "yuan", "rmb"]), ("JPY", ["¥", "jpy", "иен", "йен", "yen"]),
        ("TRY", ["₺", "try", "лир"]), ("KRW", ["₩", "krw", "вон!"]), ("AED", ["aed", "дирхам"]), ("UAH", ["₴", "uah", "грив"]),
        ("CHF", ["chf", "франк"]), ("INR", ["₹", "inr", "рупи"]), ("PLN", ["pln", "злот"]), ("UZS", ["uzs", "сум!"]),
        ("CAD", ["cad"]), ("AUD", ["aud"]), ("GEL", ["gel", "лари!"]), ("KGS", ["kgs", "сом!"]),
    ]

    private struct CurrencyHit { let code: String; let index: Int }

    private static func findCurrencies(in original: String, known: Set<String>) -> [CurrencyHit] {
        let text = original.lowercased()
        var hits: [CurrencyHit] = []
        for (code, words) in currencyAliases {
            var best = -1
            for var word in words {
                let whole = word.hasSuffix("!")
                if whole { word.removeLast() }
                var index = -1
                if !word.contains(where: \.isLetter) {
                    if let range = text.range(of: word) { index = text.distance(from: text.startIndex, to: range.lowerBound) }
                } else {
                    let strict = whole || (word.allSatisfy { $0.isASCII } && word.count < 5)
                    let pattern = "(^|[^a-zа-яё])" + NSRegularExpression.escapedPattern(for: word) + (strict ? "(?![a-zа-яё])" : "")
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                        index = match.range.location + match.range(at: 1).length
                    }
                }
                if index >= 0, best < 0 || index < best { best = index }
            }
            if best >= 0 { hits.append(CurrencyHit(code: code, index: best)) }
        }
        // Любой код из таблицы курсов, написанный заглавными: «100 PLN в EUR».
        if let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z])[A-Z]{3}(?![A-Za-z])") {
            for match in regex.matches(in: original, range: NSRange(original.startIndex..., in: original)) {
                let code = (original as NSString).substring(with: match.range)
                if known.contains(code), !hits.contains(where: { $0.code == code }) { hits.append(CurrencyHit(code: code, index: match.range.location)) }
            }
        }
        return hits.sorted { $0.index < $1.index }
    }

    /// Число с пробелами и запятой, суффикс k/к/тыс/млн.
    private static func amount(in text: String) -> Double? {
        let pattern = #"(\d[\d\s]*(?:[.,]\d+)?)(?:\s*(k|к|тыс|млн|m|м)(?![a-zа-яё]))?"#
        guard let found = firstMatch(pattern, in: text.lowercased()) else { return nil }
        var raw = found[1].replacingOccurrences(of: " ", with: "")
        if raw.range(of: #",\d{1,2}$"#, options: .regularExpression) != nil, !raw.contains(".") {
            raw = raw.replacingOccurrences(of: ",", with: ".")
        } else if raw.range(of: #"^\d{1,3}(,\d{3})+(\.\d+)?$"#, options: .regularExpression) != nil {
            raw = raw.replacingOccurrences(of: ",", with: "")
        } else {
            raw = raw.replacingOccurrences(of: ",", with: ".")
        }
        guard var value = Double(raw) else { return nil }
        switch found[2] {
        case "k", "к", "тыс": value *= 1e3
        case "": break
        default: value *= 1e6
        }
        return value
    }

    static func currency(_ input: String, rates: RateTable, defaultCurrency: String) -> ToolResult? {
        guard input.contains(where: \.isNumber) else { return nil }
        let known = Set(rates.perUSD.keys)
        let hits = findCurrencies(in: input, known: known).filter { known.contains($0.code) }
        guard !hits.isEmpty, let value = amount(in: input) else { return nil }

        func other(_ code: String) -> String { code == defaultCurrency ? (code == "USD" ? "KZT" : "USD") : defaultCurrency }
        let lower = input.lowercased()
        /// Стоит ли перед местом валюты слово «в», «to» или стрелка: тогда это валюта назначения.
        func isTarget(at index: Int) -> Bool {
            let before = String(lower.prefix(index)).trimmingCharacters(in: .whitespaces)
            return before.range(of: #"(?:^|\s)(?:в|во|на|to|in|into)$"#, options: .regularExpression) != nil
                || before.hasSuffix("->") || before.hasSuffix("→") || before.hasSuffix("=")
        }

        var source: String, target: String
        if hits.count >= 2 {
            source = hits[0].code
            target = hits[1].code
        } else if isTarget(at: hits[0].index) {
            target = hits[0].code
            source = defaultCurrency
        } else {
            source = hits[0].code
            target = other(source)
        }
        if source == target { target = other(source) }
        guard let sourceRate = rates.perUSD[source], let targetRate = rates.perUSD[target], sourceRate > 0 else { return nil }

        let rate = targetRate / sourceRate
        func shown(_ code: String) -> String { symbols[code] ?? code }
        func money(_ v: Double, _ code: String) -> String { "\(number(v, maxFraction: moneyDigits(v))) \(shown(code))" }
        let result = value * rate
        let rateText = rate < 1 ? number(rate, maxFraction: 6) : number(rate, maxFraction: moneyDigits(rate))
        let extras = ["USD", "EUR", "KZT", "RUB"].filter { $0 != source && $0 != target }.prefix(3).compactMap { code -> String? in
            rates.perUSD[code].map { money(value * $0 / sourceRate, code) }
        }
        return ToolResult(kind: .currency, headline: "\(money(value, source)) = \(money(result, target))", value: money(result, target),
                          detail: "Курс: 1 \(source) = \(rateText) \(target)", extras: Array(extras),
                          pair: CurrencyPair(from: source, to: target, amount: value))
    }

    // MARK: Общее

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let ns = text as NSString
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }
}
