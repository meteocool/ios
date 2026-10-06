import UIKit

/// The radar image the Live Activity shows, kept in the app group.
///
/// A Live Activity cannot load anything over the network: its views are
/// drawn from the content state and from files. The app saves the image here
/// whenever it runs (in the foreground, on a background location fix or a
/// background push, when iOS starts an activity from a push), and the
/// activity shows whatever was saved last, with its time.
enum RadarImageStore {
    /// The side of the saved image in pixels: the activity draws it at most
    /// 84 points wide, at 3x. Larger images can make iOS refuse to draw the
    /// activity at all.
    static let side: CGFloat = 252

    private static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.org.frcy.app.meteocool")?
            .appendingPathComponent("LiveActivity", isDirectory: true)
            .appendingPathComponent("radar.jpg")
    }

    /// The last saved image and when it was saved.
    static func load() -> (image: UIImage, saved: Date)? {
        guard let file, let image = UIImage(contentsOfFile: file.path),
              let saved = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        return (image, saved)
    }

    /// Scales `data`, a PNG or JPEG, to `side` and saves it. Returns when it
    /// was saved, or nil if `data` is not an image.
    @discardableResult
    static func save(_ data: Data) -> Date? {
        guard let file, let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: side, height: side)
        // Fill the square from the image's centre, as the view crops it.
        let scale = max(side / image.size.width, side / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
        guard let jpeg = scaled.jpegData(compressionQuality: 0.8) else { return nil }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jpeg.write(to: file, options: .atomic)
        } catch {
            return nil
        }
        return Date()
    }

    static func remove() {
        if let file { try? FileManager.default.removeItem(at: file) }
    }
}
