import SwiftUI
import WidgetKit

/// The widget extension: the rain Live Activity, and the home and lock
/// screen widgets (`Widgets/`).
@main
struct RainActivityBundle: WidgetBundle {
    var body: some Widget {
        RainActivityWidget()
        RainForecastWidget()
        RadarMapWidget()
        RainClockWidget()
        RainPlacesWidget()
    }
}
