//
//  StormLogViewController.swift
//  meteocool
//
//  The storm log, from Settings: the storms that passed over, or close to,
//  the phone's registered location and its places, as ng's `/v4/storm-log`
//  answers them. The backend decides every entry; this lists them, opens one
//  (`StormLogDetailViewController`) and wipes the log on request.
//

import UIKit

/// A plain view controller holding a table, not a `UITableViewController`:
/// the empty state is then drawn beside the table rather than inside it, where
/// the table's accessibility hid it from VoiceOver.
final class StormLogViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private enum State {
        case loading
        /// No push token: the phone never registered its location here.
        case unregistered
        case failed
        case loaded([StormPassage])
    }

    private var state = State.loading {
        didSet { render() }
    }
    private var passages: [StormPassage] {
        if case .loaded(let passages) = state { return passages }
        return []
    }
    private var loading: Task<Void, Never>?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = Self.text("storm_log_title", "Storm Log")
        view.backgroundColor = .systemGroupedBackground
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "passage")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "delete")
        tableView.accessibilityIdentifier = "stormLog"
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)
        tableView.refreshControl = refresh
        load()
    }

    /// The token the phone registered with, this launch's or the last one stored.
    private var token: String? {
        #if DEBUG && targetEnvironment(simulator)
        // The loopback recorder's synthetic token, as `NotificationManager` registers with.
        if NetworkHelper.simulatorTestAPI != nil { return String(repeating: "a", count: 64) }
        #endif
        return SharedNotificationManager.getToken()
            ?? UserDefaults(suiteName: "group.org.frcy.app.meteocool")?.string(forKey: "pushToken")
    }

    private func load() {
        loading?.cancel()
        guard let token else {
            tableView.refreshControl?.endRefreshing()
            state = .unregistered
            return
        }
        if passages.isEmpty { state = .loading }
        let request = StormLogRules.request(api: NetworkHelper.apiURL, token: token, method: "GET")
        loading = Task { [weak self] in
            let log: StormLog?
            do {
                let (data, response) = try await URLSession.meteocool.data(for: request)
                let ok = (response as? HTTPURLResponse).map { (200 ..< 300).contains($0.statusCode) } ?? false
                log = ok ? StormLogRules.decode(data) : nil
            } catch {
                log = nil
            }
            guard let self, !Task.isCancelled else { return }
            self.tableView.refreshControl?.endRefreshing()
            self.state = log.map { .loaded($0.entries) } ?? .failed
        }
    }

    private func render() {
        var empty: UIContentUnavailableConfiguration?
        switch state {
        case .loading:
            empty = .loading()
        case .unregistered:
            empty = Self.empty(symbol: "location.slash", "storm_log_unregistered",
                               "Storms are logged when one passes over the location you get rain alerts for. Turn on notifications and allow the location to be used always.")
        case .failed:
            var failed = Self.empty(symbol: "wifi.exclamationmark", "storm_log_failed", "The storm log could not be loaded.")
            var retry = UIButton.Configuration.borderedTinted()
            retry.title = Self.text("storm_log_retry", "Try Again")
            failed.button = retry
            failed.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load() }
            empty = failed
        case .loaded(let passages) where passages.isEmpty:
            empty = Self.empty(symbol: "cloud.bolt", "storm_log_empty",
                               "No storms yet. A storm is logged when one passes over, or within 10 km of, the location you get rain alerts for, or one of your places. It needs notifications on and the location allowed always.")
        case .loaded:
            empty = nil
        }
        contentUnavailableConfiguration = empty
        tableView.isHidden = empty != nil
        tableView.reloadData()
    }

    private static func empty(symbol: String, _ key: String, _ english: String) -> UIContentUnavailableConfiguration {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: symbol)
        configuration.text = text("storm_log_title", "Storm Log")
        configuration.secondaryText = text(key, english)
        return configuration
    }

    /// A string from `Localizable.strings`; English where a language has none yet.
    static func text(_ key: String, _ english: String) -> String {
        NSLocalizedString(key, value: english, comment: "storm log")
    }

    // MARK: Table

    func numberOfSections(in tableView: UITableView) -> Int {
        passages.isEmpty ? 0 : 2
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? passages.count : 1
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? Self.text("storm_log_footer", "Storms that came within 10 km of your location or your places, kept for about a year.") : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 1 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "delete", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = Self.text("storm_log_delete", "Delete Log")
            content.textProperties.color = .systemRed
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.accessibilityTraits = .button
            return cell
        }
        let passage = passages[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "passage", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        content.text = Self.where(passage) + " · " + StormLogRules.when(passage)
        content.secondaryText = Self.readings(passage).joined(separator: " · ")
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        content.image = UIImage(systemName: passage.hail ? "cloud.hail.fill" : "cloud.bolt.fill")
        content.imageProperties.tintColor = Self.color(passage.severity)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityLabel = [Self.severityName(passage.severity), content.text, content.secondaryText]
            .compactMap { $0 }.joined(separator: ", ")
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 {
            confirmDelete(from: tableView.cellForRow(at: indexPath))
            return
        }
        navigationController?.pushViewController(StormLogDetailViewController(passage: passages[indexPath.row]), animated: true)
    }

    // MARK: Deleting

    private func confirmDelete(from source: UIView?) {
        let sheet = UIAlertController(title: Self.text("storm_log_delete_title", "Delete the storm log?"),
                                      message: Self.text("storm_log_delete_message", "Every entry is deleted, your places' too. Storms that pass later are logged again."),
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: Self.text("storm_log_delete", "Delete Log"), style: .destructive) { [weak self] _ in
            self?.delete()
        })
        sheet.addAction(UIAlertAction(title: Self.text("storm_log_cancel", "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = source ?? view
        sheet.popoverPresentationController?.sourceRect = source?.bounds ?? view.bounds
        present(sheet, animated: true)
    }

    private func delete() {
        guard let token else { return }
        let request = StormLogRules.request(api: NetworkHelper.apiURL, token: token, method: "DELETE")
        Task { [weak self] in
            let deleted: Bool
            do {
                let (data, response) = try await URLSession.meteocool.data(for: request)
                deleted = NetworkHelper.checkResponse(data: data, response: response, error: nil) != nil
            } catch {
                deleted = false
            }
            guard let self else { return }
            if deleted {
                self.state = .loaded([])
            } else {
                let alert = UIAlertController(title: Self.text("storm_log_delete_failed", "The storm log could not be deleted."),
                                              message: nil, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: NSLocalizedString("Dismiss", value: "Dismiss", comment: ""), style: .cancel))
                self.present(alert, animated: true)
            }
        }
    }

    // MARK: Words

    /// The place it passed: a saved place by name, else the phone's location.
    static func `where`(_ passage: StormPassage) -> String {
        passage.placeName ?? NSLocalizedString("my_location", value: "My Location", comment: "")
    }

    /// How close and how strong, each only when known.
    static func readings(_ passage: StormPassage) -> [String] {
        var parts = [passage.over
            ? text("storm_log_over", "Overhead")
            : String(format: text("storm_log_closest", "%@ away"), StormLogRules.kilometres(passage.closestKm))]
        if let peak = passage.peakDbz { parts.append(StormLogRules.dbz(peak)) }
        if let top = passage.topKm { parts.append(String(format: text("storm_log_top", "Top %@"), StormLogRules.top(top))) }
        if passage.strikes > 0 {
            parts.append(String(format: text("storm_log_strikes", "Lightning: %ld"), passage.strikes))
        }
        if passage.endedAt == nil { parts.append(text("storm_log_ongoing", "Still near")) }
        return parts
    }

    /// The map's name for its severity: "Strong storm" (core's `storm.storm_label`).
    static func severityName(_ severity: Int) -> String {
        CoreStrings.t("storm.storm_label.\(StormLogRules.band(severity))")
    }

    static func color(_ severity: Int) -> UIColor {
        let rgb = StormLogRules.color(severity)
        return UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
