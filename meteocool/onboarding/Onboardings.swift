import UIKit

typealias OnboardingAction = @MainActor (@escaping @MainActor (Bool, Error?) -> Void) -> Void

@MainActor struct OnboardingPage {
    let title: String
    let imageName: String
    let description: String
    var advanceButtonTitle: String = NSLocalizedString("Next", comment: "")
    var actionButtonTitle: String? = nil
    var action: OnboardingAction? = nil
}

/// A scrolling page keeps permission explanations readable at every text size.
@MainActor final class OnboardingViewController: UIViewController {
    private let pages: [OnboardingPage]
    private let completion: () -> Void
    private var index = 0
    private let scroll = UIScrollView()
    private let titleLabel = UILabel()
    private let illustration = UIImageView()
    private let bodyLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let progressLabel = UILabel()

    init(pages: [OnboardingPage], completion: @escaping () -> Void) {
        self.pages = pages
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) { fatalError("Use init(pages:completion:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let stack = UIStackView(arrangedSubviews: [titleLabel, illustration, bodyLabel, actionButton, nextButton, progressLabel])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
            illustration.heightAnchor.constraint(equalToConstant: 140),
            actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            nextButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        for (label, style) in [(titleLabel, UIFont.TextStyle.title1), (bodyLabel, .body), (progressLabel, .caption1)] {
            label.font = .preferredFont(forTextStyle: style)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.textAlignment = .center
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        titleLabel.accessibilityTraits.insert(.header)
        illustration.contentMode = .scaleAspectFit
        illustration.isAccessibilityElement = false
        actionButton.configuration = .borderedProminent()
        nextButton.configuration = .bordered()
        for button in [actionButton, nextButton] {
            button.configuration?.titleLineBreakMode = .byWordWrapping
            button.titleLabel?.adjustsFontForContentSizeCategory = true
        }
        actionButton.addTarget(self, action: #selector(performAction), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(advance), for: .touchUpInside)
        showPage()
    }

    private func showPage() {
        let page = pages[index]
        titleLabel.text = page.title
        illustration.image = UIImage(named: page.imageName)
        bodyLabel.text = page.description
        actionButton.setTitle(page.actionButtonTitle, for: .normal)
        actionButton.isHidden = page.action == nil
        actionButton.isEnabled = true
        nextButton.isEnabled = true
        nextButton.setTitle(page.advanceButtonTitle, for: .normal)
        progressLabel.text = "\(index + 1) / \(pages.count)"
        view.layoutIfNeeded()
        scroll.setContentOffset(.zero, animated: false)
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    @objc private func performAction() {
        guard let action = pages[index].action else { return }
        actionButton.isEnabled = false
        nextButton.isEnabled = false
        action { [weak self] _, _ in self?.advance() }
    }

    @objc private func advance() {
        if index + 1 == pages.count {
            dismiss(animated: true, completion: completion)
        } else {
            index += 1
            showPage()
        }
    }
}
