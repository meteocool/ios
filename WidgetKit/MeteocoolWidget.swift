import SwiftUI
import WidgetKit
import CoreLocation

struct MeteocoolEntry: TimelineEntry {
    let date: Date
    let location: CLLocationCoordinate2D?
}

struct MeteocoolProvider: TimelineProvider {
    func placeholder(in context: Context) -> MeteocoolEntry {
        MeteocoolEntry(date: Date(), location: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (MeteocoolEntry) -> Void) {
        completion(MeteocoolEntry(date: Date(), location: readLocation()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MeteocoolEntry>) -> Void) {
        let entry = MeteocoolEntry(date: Date(), location: readLocation())
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
        completion(timeline)
    }

    private func readLocation() -> CLLocationCoordinate2D? {
        let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
        guard let lat = defaults?.value(forKey: "lat") as? Double,
              let lon = defaults?.value(forKey: "lon") as? Double else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

struct MeteocoolWidgetEntryView: View {
    var entry: MeteocoolProvider.Entry

    var body: some View {
        ZStack {
            Color(.systemBackground)
            VStack(alignment: .leading, spacing: 8) {
                Text("meteocool")
                    .font(.headline)
                if let location = entry.location {
                    Text(String(format: "%.3f, %.3f", location.latitude, location.longitude))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Open app to set location")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
        }
    }
}

@main
struct MeteocoolWidget: Widget {
    let kind: String = "meteocool"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MeteocoolProvider()) { entry in
            MeteocoolWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("meteocool")
        .description("Live radar and storm tracking.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
