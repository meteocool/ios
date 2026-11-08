import WidgetKit

enum RadarMapLayout {
    static var families: [WidgetFamily] {
        var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        if #available(iOS 27, *) { families.append(.systemExtraLargePortrait) }
        return families
    }

    static func locations<Place: Identifiable>(_ places: [Place], family: WidgetFamily) -> [Place] {
        let extraLarge: Bool
        if #available(iOS 27, *), family == .systemExtraLargePortrait {
            extraLarge = true
        } else {
            extraLarge = family == .systemExtraLarge
        }
        guard extraLarge else { return [] }
        var seen: Set<Place.ID> = []
        return Array(places.filter { seen.insert($0.id).inserted }.prefix(4))
    }
}
