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
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    static let maxTextWidth: CGFloat = 250

    override var intrinsicContentSize: CGSize {
        let fitted = stack.systemLayoutSizeFitting(CGSize(width: Self.maxTextWidth, height: UIView.layoutFittingCompressedSize.height),
                                                    withHorizontalFittingPriority: .fittingSizeLevel,
                                                    verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: min(fitted.width, Self.maxTextWidth) + 20, height: fitted.height + 14)
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
    var onOpen: ((String) -> Void)?

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
            if placed.contains(where: { $0.intersects(rect) }) && !model.selected {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            view.frame = rect.integral
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
        for (index, label) in ticks.enumerated() {
            guard index < items.count, let point = items[index].point else {
                label.isHidden = true
                continue
            }
            label.isHidden = false
            label.text = "\(items[index].km) km"
            label.sizeToFit()
            label.center = CGPoint(x: point.x + label.bounds.width / 2, y: point.y)
        }
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

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
