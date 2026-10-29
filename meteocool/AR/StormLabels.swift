//
//  StormLabels.swift
//  meteocool
//
//  The tags floating over each storm.
//

import UIKit

/// A storm's tag: where it is, how strong, how old the picture is.
///
/// This is what answers "which storm is that" even when the heading is a
/// few degrees off: the tag says "32 km WSW, 52 dBZ", and the map says the
/// same about exactly one storm.
final class StormLabelView: UIControl {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let title = UILabel()
    private let detail = UILabel()
    private let age = UILabel()
    private let flags = UIStackView()
    private let stack = UIStackView()
    let openButton = UIButton(type: .system)
    private(set) var model: StormLabelModel?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: StormLabelView, _: UITraitCollection) in
            view.fittedSize = nil
            view.invalidateIntrinsicContentSize()
        }
        blur.isUserInteractionEnabled = false
        blur.layer.cornerRadius = 12
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        addSubview(blur)

        title.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        detail.font = .preferredFont(forTextStyle: .caption1)
        age.font = .preferredFont(forTextStyle: .caption2)
        for label in [title, detail, age] {
            label.textColor = .white
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 1
        }
        // The readings can run long (place, strength, top, motion, lightning):
        // two lines rather than an ellipsis over the part that differs.
        title.numberOfLines = 2
        detail.numberOfLines = 3
        for label in [title, detail, age] { label.preferredMaxLayoutWidth = Self.maxTextWidth }
        age.alpha = 0.8
        flags.axis = .horizontal
        flags.spacing = 4

        var configuration = UIButton.Configuration.filled()
        configuration.title = NSLocalizedString("ar_open_on_map", comment: "")
        configuration.image = UIImage(systemName: "map")
        configuration.imagePadding = 6
        configuration.buttonSize = .small
        configuration.cornerStyle = .capsule
        openButton.configuration = configuration
        openButton.accessibilityIdentifier = "ar.openOnMap"

        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.isUserInteractionEnabled = true
        let header = UIStackView(arrangedSubviews: [title, flags])
        header.spacing = 6
        header.isUserInteractionEnabled = false
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(detail)
        stack.addArrangedSubview(age)
        stack.addArrangedSubview(openButton)
        stack.setCustomSpacing(6, after: age)
        addSubview(stack)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ model: StormLabelModel) {
        guard model != self.model else { return }
        self.model = model
        title.text = model.title
        detail.text = model.detail
        detail.isHidden = model.detail.isEmpty
        age.text = model.age
        age.isHidden = model.age.isEmpty
        flags.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for name in model.flags {
            let image = UIImageView(image: UIImage(systemName: name))
            image.tintColor = name == "bolt.fill" ? .systemYellow : .white
            image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
            flags.addArrangedSubview(image)
        }
        openButton.isHidden = !model.selected
        alpha = model.openable ? 1 : 0.8
        blur.layer.borderWidth = model.selected ? 2 : 0
        blur.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        accessibilityIdentifier = "ar.storm.\(model.code)"
        fittedSize = nil
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    /// Measured once per model: the labels are placed every frame, and
    /// fitting the stack each time was a frame's worth of Auto Layout.
    private var fittedSize: CGSize?

    static let maxTextWidth: CGFloat = 250

    override var intrinsicContentSize: CGSize {
        if let fittedSize { return fittedSize }
        let fitted = stack.systemLayoutSizeFitting(CGSize(width: Self.maxTextWidth, height: UIView.layoutFittingCompressedSize.height),
                                                    withHorizontalFittingPriority: .fittingSizeLevel,
                                                    verticalFittingPriority: .fittingSizeLevel)
        let size = CGSize(width: min(fitted.width, Self.maxTextWidth) + 20, height: fitted.height + 14)
        fittedSize = size
        return size
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        stack.frame = bounds.insetBy(dx: 10, dy: 7)
    }

    /// The tag is one target, except for its button: the stack inside it
    /// would otherwise take the touch, and a control only acts on touches
    /// that land on itself.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, bounds.contains(point) else { return nil }
        if !openButton.isHidden, openButton.bounds.contains(convert(point, to: openButton)) { return openButton }
        return self
    }

    // VoiceOver reads a storm as one element, and the button stays separate.
    override var accessibilityElements: [Any]? {
        get {
            let summary = UIAccessibilityElement(accessibilityContainer: self)
            summary.accessibilityLabel = [model?.title, model?.detail, model?.age].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            summary.accessibilityTraits = .button
            summary.accessibilityIdentifier = accessibilityIdentifier
            summary.accessibilityFrameInContainerSpace = bounds
            return openButton.isHidden ? [summary] : [summary, openButton]
        }
        set {}
    }
}

/// Holds the tags and the height scale's numbers, and positions them each frame.
final class StormLabelLayer: UIView {
    private var views: [String: StormLabelView] = [:]
    private var ticks: [UILabel] = []
    var onSelect: ((String) -> Void)?
    /// Height of the HUD's top bar and compass, which tags stay below.
    static let topClearance: CGFloat = 112
    /// Kept clear on the right, where the host has a column of buttons
    /// (the native 3D map's: its own discs and their margin).
    var rightClearance: CGFloat = 0
    var onOpen: ((String) -> Void)?
    var onOpenMarker: (() -> Void)?
    var onRemoveMarker: (() -> Void)?
    private var markerView: ARMarkerLabelView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    /// Place every tag at its anchor, nearest first; a farther tag that would
    /// overlap a nearer one moves up, and is hidden if it still does.
    func layout(_ items: [(model: StormLabelModel, point: CGPoint?)]) {
        var seen: Set<String> = []
        var placed: [CGRect] = []
        for (model, point) in items.sorted(by: { $0.model.distance < $1.model.distance }) {
            seen.insert(model.key)
            let view = views[model.key] ?? makeView(for: model.key)
            view.update(model)
            guard let point, bounds.insetBy(dx: -40, dy: -40).contains(point) else {
                view.isHidden = true
                continue
            }
            let size = view.intrinsicContentSize
            var rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height - 6, width: size.width, height: size.height)
            var attempts = 0
            while let blocking = placed.first(where: { $0.intersects(rect) }), attempts < 3 {
                rect.origin.y = blocking.minY - size.height - 4
                attempts += 1
            }
            // Never up under the close button, status and compass.
            rect.origin.y = max(rect.origin.y, safeAreaInsets.top + Self.topClearance)
            if rightClearance > 0 {
                rect.origin.x = min(rect.origin.x, bounds.width - safeAreaInsets.right - rightClearance - rect.width)
            }
            if placed.contains(where: { $0.intersects(rect) }) && !model.selected {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            let frame = rect.integral
            if view.frame != frame { view.frame = frame }
            placed.append(rect)
            if model.selected { bringSubviewToFront(view) }
        }
        for (key, view) in views where !seen.contains(key) {
            view.removeFromSuperview()
            views[key] = nil
        }
    }

    /// The height scale's numbers, beside its ticks.
    func layoutTicks(_ items: [(km: Int, point: CGPoint?)]) {
        while ticks.count < items.count {
            let label = UILabel()
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            label.textColor = .white
            label.shadowColor = UIColor.black.withAlphaComponent(0.7)
            label.shadowOffset = CGSize(width: 0, height: 1)
            label.isAccessibilityElement = false
            addSubview(label)
            sendSubviewToBack(label)
            ticks.append(label)
        }
        // From far away the heights run together: a tick only where it
        // clears the last one shown by a line of text.
        var lastShown: CGFloat?
        for (index, label) in ticks.enumerated() {
            guard index < items.count, let point = items[index].point,
                  lastShown.map({ abs($0 - point.y) >= 14 }) ?? true else {
                label.isHidden = true
                continue
            }
            lastShown = point.y
            label.isHidden = false
            let text = "\(items[index].km) km"
            if label.text != text {
                label.text = text
                label.sizeToFit()
            }
            label.center = CGPoint(x: point.x + label.bounds.width / 2, y: point.y)
        }
    }

    /// The marker's arrow and tag, the arrow's tip on `tip` (the top of
    /// its pole); hidden off screen or without a marker.
    func layoutMarker(_ model: ARMarkerLabelModel?, tip: CGPoint?) {
        guard let model else {
            markerView?.removeFromSuperview()
            markerView = nil
            return
        }
        let view = markerView ?? makeMarkerView()
        view.update(model)
        guard let tip, bounds.insetBy(dx: -20, dy: -20).contains(tip) else {
            view.isHidden = true
            return
        }
        view.isHidden = false
        let size = view.intrinsicContentSize
        var rect = CGRect(x: tip.x - size.width / 2, y: tip.y - size.height, width: size.width, height: size.height)
        rect.origin.x = min(max(rect.origin.x, safeAreaInsets.left + 8), bounds.width - safeAreaInsets.right - 8 - rect.width)
        rect.origin.y = max(rect.origin.y, safeAreaInsets.top + Self.topClearance)
        let frame = rect.integral
        if view.frame != frame { view.frame = frame }
        // The arrow stays on the point even where the tag is pushed aside,
        // over the tag if it has to be.
        view.pointArrow(at: CGPoint(x: tip.x - frame.minX, y: tip.y - frame.minY))
        bringSubviewToFront(view)
    }

    private func makeMarkerView() -> ARMarkerLabelView {
        let view = ARMarkerLabelView()
        view.openButton.addAction(UIAction { [weak self] _ in self?.onOpenMarker?() }, for: .touchUpInside)
        view.removeButton.addAction(UIAction { [weak self] _ in self?.onRemoveMarker?() }, for: .touchUpInside)
        addSubview(view)
        markerView = view
        return view
    }

    /// A tag for one storm, by its key (`StormGroup.key`).
    private func makeView(for key: String) -> StormLabelView {
        let view = StormLabelView()
        view.addAction(UIAction { [weak self] _ in self?.onSelect?(key) }, for: .touchUpInside)
        view.openButton.addAction(UIAction { [weak self] _ in self?.onOpen?(key) }, for: .touchUpInside)
        addSubview(view)
        views[key] = view
        return view
    }
}

/// The marked place: a big red arrow pointing down at it, under a tag
/// that says where it is, with the way to the map and a way to remove it.
final class ARMarkerLabelView: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let title = UILabel()
    private let detail = UILabel()
    private let arrow = UIImageView()
    private let stack = UIStackView()
    let openButton = UIButton(type: .system)
    let removeButton = UIButton(type: .system)
    private var model: ARMarkerLabelModel?
    private var fittedSize: CGSize?
    private var arrowTip: CGPoint?

    static let arrowSize = CGSize(width: 44, height: 40)

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ARMarkerLabelView, _: UITraitCollection) in
            view.fittedSize = nil
            view.invalidateIntrinsicContentSize()
        }
        blur.isUserInteractionEnabled = false
        blur.layer.cornerRadius = 12
        blur.layer.cornerCurve = .continuous
        blur.layer.borderWidth = 2
        blur.layer.borderColor = UIColor.systemRed.cgColor
        blur.clipsToBounds = true
        addSubview(blur)

        // Red, as the dropped pin on the map is.
        arrow.image = UIImage(systemName: "arrowtriangle.down.fill",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .bold))
        arrow.tintColor = .systemRed
        arrow.contentMode = .scaleAspectFit
        arrow.layer.shadowColor = UIColor.black.cgColor
        arrow.layer.shadowOpacity = 0.6
        arrow.layer.shadowRadius = 3
        arrow.layer.shadowOffset = CGSize(width: 0, height: 1)
        arrow.isAccessibilityElement = false
        addSubview(arrow)

        title.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        detail.font = .preferredFont(forTextStyle: .caption1)
        for label in [title, detail] {
            label.textColor = .white
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 2
            label.preferredMaxLayoutWidth = StormLabelView.maxTextWidth
        }

        var open = UIButton.Configuration.filled()
        open.title = NSLocalizedString("ar_open_on_map", comment: "")
        open.image = UIImage(systemName: "map")
        open.imagePadding = 6
        open.buttonSize = .small
        open.cornerStyle = .capsule
        openButton.configuration = open
        openButton.accessibilityIdentifier = "ar.marker.openOnMap"

        var remove = UIButton.Configuration.gray()
        remove.image = UIImage(systemName: "xmark")
        remove.buttonSize = .small
        remove.cornerStyle = .capsule
        removeButton.configuration = remove
        removeButton.tintColor = .white
        removeButton.accessibilityLabel = NSLocalizedString("ar_marker_remove", comment: "")
        removeButton.accessibilityIdentifier = "ar.marker.remove"

        let buttons = UIStackView(arrangedSubviews: [openButton, removeButton])
        buttons.spacing = 6
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(detail)
        stack.addArrangedSubview(buttons)
        stack.setCustomSpacing(6, after: detail)
        addSubview(stack)
        accessibilityIdentifier = "ar.marker"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ model: ARMarkerLabelModel) {
        guard model != self.model else { return }
        self.model = model
        title.text = model.title
        detail.text = model.detail
        fittedSize = nil
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    /// The tag over the arrow; the arrow's tip at the bottom edge.
    override var intrinsicContentSize: CGSize {
        if let fittedSize { return fittedSize }
        let fitted = stack.systemLayoutSizeFitting(CGSize(width: StormLabelView.maxTextWidth, height: UIView.layoutFittingCompressedSize.height),
                                                    withHorizontalFittingPriority: .fittingSizeLevel,
                                                    verticalFittingPriority: .fittingSizeLevel)
        let size = CGSize(width: max(min(fitted.width, StormLabelView.maxTextWidth) + 20, Self.arrowSize.width),
                          height: fitted.height + 14 + 4 + Self.arrowSize.height)
        fittedSize = size
        return size
    }

    /// Where the arrow's tip goes, in this view: the bottom middle unless told.
    func pointArrow(at tip: CGPoint) {
        guard arrowTip != tip else { return }
        arrowTip = tip
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let tag = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.arrowSize.height - 4)
        blur.frame = tag
        stack.frame = tag.insetBy(dx: 10, dy: 7)
        let tip = arrowTip ?? CGPoint(x: bounds.midX, y: bounds.height)
        arrow.frame = CGRect(x: tip.x - Self.arrowSize.width / 2, y: tip.y - Self.arrowSize.height,
                             width: Self.arrowSize.width, height: Self.arrowSize.height)
    }

    /// Only the tag and its buttons take touches; the arrow lets the sky have them.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, blur.frame.contains(point) else { return nil }
        for button in [openButton, removeButton] where button.bounds.contains(convert(point, to: button)) { return button }
        return self
    }

    override var accessibilityElements: [Any]? {
        get {
            let summary = UIAccessibilityElement(accessibilityContainer: self)
            summary.accessibilityLabel = [NSLocalizedString("ar_marker", comment: ""), model?.title, model?.detail]
                .compactMap { $0 }.joined(separator: ", ")
            summary.accessibilityFrameInContainerSpace = blur.frame
            return [summary, openButton, removeButton]
        }
        set {}
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
