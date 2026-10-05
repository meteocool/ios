//
//  EnvironmentPickerViewController.swift
//  meteocool
//
//  Mode in Settings: Production, Experimental Features or Demo.
//

import UIKit

/// Picks the deployment the app talks to (`MeteocoolEnvironment`).
///
/// Works like the base map and color map pickers: a tap moves the checkmark,
/// Save applies, Cancel leaves everything as it was. Save switches at once,
/// without a restart: the map reloads and a push registration moves to the
/// new deployment (`MeteocoolEnvironment.select`).
final class EnvironmentPickerViewController: UITableViewController {
    private let options: [MeteocoolEnvironment] = [.app, .staging, .demo]
    private var selection = MeteocoolEnvironment.current

    /// The name Settings shows for `environment`.
    static func title(of environment: MeteocoolEnvironment) -> String {
        switch environment {
        case .app: return NSLocalizedString("mode_production", comment: "mode")
        case .staging: return NSLocalizedString("Experimental Features", comment: "mode")
        case .demo: return NSLocalizedString("mode_demo", comment: "mode")
        }
    }

    private static func detail(of environment: MeteocoolEnvironment) -> String {
        switch environment {
        case .app: return NSLocalizedString("mode_production_detail", comment: "mode")
        case .staging: return NSLocalizedString("mode_experimental_detail", comment: "mode")
        case .demo: return NSLocalizedString("mode_demo_detail", comment: "mode")
        }
    }

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Mode", comment: "mode")
        // System items, as in the storyboard pickers: the system localizes them.
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .save, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            let selection = self.selection
            self.dismiss(animated: true)
            MeteocoolEnvironment.select(selection)
        })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "mode")
        tableView.accessibilityIdentifier = "settings.options"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        options.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        NSLocalizedString("mode_footer", comment: "mode")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "mode", for: indexPath)
        let option = options[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = Self.title(of: option)
        content.textProperties.numberOfLines = 0
        content.secondaryText = Self.detail(of: option)
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        let selected = option == selection
        let checkmark = UIImage(systemName: "checkmark")!
        let accessory = UIImageView(frame: CGRect(origin: .zero, size: checkmark.size))
        // The accessory keeps the checkmark's width on every row.
        // An unchecked row gets no image, not alpha 0, because UIKit sets accessory alpha during layout.
        accessory.image = selected ? checkmark : nil
        cell.accessoryView = accessory
        cell.accessibilityTraits = selected ? [.button, .selected] : [.button]
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selection = options[indexPath.row]
        tableView.reconfigureRows(at: options.indices.map { IndexPath(row: $0, section: 0) })
        tableView.deselectRow(at: indexPath, animated: true)
    }
}
