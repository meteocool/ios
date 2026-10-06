import SwiftUI
import WidgetKit

/// The widget extension that draws the rain Live Activity. It has no
/// home-screen widgets of its own.
@main
struct RainActivityBundle: WidgetBundle {
    var body: some Widget {
        RainActivityWidget()
    }
}
