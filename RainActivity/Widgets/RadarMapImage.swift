import CoreLocation
import MapKit
import SwiftUI
import WidgetKit

struct MapSnapshot {
    let image: UIImage
    /// The dark basemap's map, when the widget follows the system's appearance.
    var darkImage: UIImage? = nil
    /// When it was rendered, or as near as the widget knows: when it arrived.
    let rendered: Date
    let card: PreviewCard
    /// The place the widget is for, which the card's centre is only near.
    let location: CLLocationCoordinate2D
    var projection: NativeWidgetMap.Projection? = nil
    var darkRendered: Date? = nil

    func rendered(for colorScheme: ColorScheme) -> Date {
        colorScheme == .dark && darkImage != nil ? darkRendered ?? rendered : rendered
    }

    func position(in frame: CGSize) -> CGPoint {
        projection?.position(of: location, image: image.size, frame: frame)
            ?? card.position(of: location, croppedTo: image.size, displayedIn: frame)
    }
}

/// A label on the map: white on a dark capsule, readable on any radar.
struct MapChip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: Capsule())
    }
}

/// The radar map filling its frame, with the place marked where it is: the
/// preview service centres the map on a grid point near it, not on it.
struct RadarMapImage: View {
    let snapshot: MapSnapshot?
    let isCurrent: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let snapshot {
                    Image(uiImage: colorScheme == .dark ? snapshot.darkImage ?? snapshot.image : snapshot.image)
                        .resizable()
                        .widgetAccentedRenderingMode(.fullColor)
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    marker
                        .position(snapshot.position(in: geometry.size))
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "map")
                                .font(.system(size: min(geometry.size.width, geometry.size.height) * 0.2))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var marker: some View {
        if isCurrent {
            Circle()
                .fill(.blue)
                .stroke(.white, lineWidth: 2)
                .frame(width: 11, height: 11)
                .shadow(color: .black.opacity(0.3), radius: 2)
        } else {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 16))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                .shadow(color: .black.opacity(0.3), radius: 2)
        }
    }
}
