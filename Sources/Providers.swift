import Foundation

/// Выбор «что показывать во вкладке»: не больше трёх пунктов, остальные лежат в настройках.
enum PinRules {
    static let limit = 3

    /// Сохранённый список: только известные, без повторов, не больше трёх. Пусто: значения по умолчанию.
    static func normalize<Item: RawRepresentable & Hashable>(saved: [String], all: [Item], defaults: [Item]) -> [Item] where Item.RawValue == String {
        var seen = Set<Item>()
        let items = saved.compactMap { raw in all.first { $0.rawValue == raw } }.filter { seen.insert($0).inserted }
        let capped = Array(items.prefix(limit))
        return capped.isEmpty ? Array(defaults.prefix(limit)) : capped
    }

    /// Включение добавляет пункт, пока их меньше трёх. Выключить последний нельзя: вкладка не должна остаться пустой.
    static func toggled<Item: Equatable>(_ current: [Item], _ item: Item, on: Bool) -> [Item] {
        if on {
            guard !current.contains(item), current.count < limit else { return current }
            return current + [item]
        }
        guard current.contains(item), current.count > 1 else { return current }
        return current.filter { $0 != item }
    }
}
