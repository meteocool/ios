//
//  ShareCard.swift
//  meteocool
//
//  The card a shared link previews as, in the system's share sheet.
//

import LinkPresentation
import UIKit
import UniformTypeIdentifiers

/// The picture a link to the map unfurls as in a messenger (core's
/// `lib/sharePreview.ts`, `MapShare.previewURL`): the map at the link's view,
/// as a wide card. Core's web map shows it in a share dialog of its own; the
/// app keeps the system's share sheet and gives it the card twice: as the
/// sheet's rich preview of the link, so the sender sees what the receiver
/// will, and as a picture of its own beside the link, to save or to post
/// where a link will not do (core's "More", which shares the card's file).
///
/// The card is drawn on request, which takes a few seconds the first time a
/// view is asked for, so it is asked for as the sheet opens, off the main
/// thread. A card that fails or takes too long is left out quietly: the
/// header shows the plain link and the link is shared alone.
final class ShareCard: @unchecked Sendable {
    /// How long the card may take; the endpoint answers in two or three
    /// seconds, longer only when it is having trouble.
    static let timeout: TimeInterval = 12

    private let lock = NSLock()
    /// Nil while it loads; then the card, or nil inside for none.
    private var result: UIImage??
    private var waiting: [@Sendable (UIImage?) -> Void] = []

    init(url: URL, session: URLSession = .shared) {
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.setValue("image/png,image/*", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { [self] data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200 ..< 300).contains($0.statusCode) } ?? false
            let isImage = response?.mimeType?.hasPrefix("image/") ?? false
            finish(ok && isImage ? data.flatMap(UIImage.init(data:)) : nil)
        }.resume()
    }

    /// The card, once it has come; nil while it loads and after it failed.
    var image: UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return result ?? nil
    }

    /// Calls `handler` with the card, or nil for none, once it has come or
    /// failed; at once when it already has. On any thread.
    func whenLoaded(_ handler: @escaping @Sendable (UIImage?) -> Void) {
        lock.lock()
        if let result {
            lock.unlock()
            handler(result)
            return
        }
        waiting.append(handler)
        lock.unlock()
    }

    private func finish(_ image: UIImage?) {
        lock.lock()
        result = .some(image)
        let handlers = waiting
        waiting = []
        lock.unlock()
        handlers.forEach { $0(image) }
    }

    private struct Failed: Error {}

    /// The card for a link's rich preview, as a PNG, loaded when the sheet
    /// asks for it: the sheet draws in a process of its own, which takes
    /// the picture's data, not the picture.
    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { [self] completion in
            whenLoaded { image in
                let data = image?.pngData()
                completion(data, data == nil ? Failed() : nil)
            }
            return nil
        }
        return provider
    }
}

/// The card as a picture of its own in the share sheet, beside the link:
/// "Save Image" and the apps that take pictures get it. The sheet asks for
/// it once the reader has picked where to; a card not in by then is left
/// out, and the link goes alone.
final class ShareCardItem: NSObject, UIActivityItemSource {
    private let card: ShareCard

    init(card: ShareCard) {
        self.card = card
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        // Only its kind counts: a picture.
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        card.image
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                thumbnailImageForActivityType activityType: UIActivity.ActivityType?, suggestedSize size: CGSize) -> UIImage? {
        card.image
    }
}
