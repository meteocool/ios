//
//  StormLogViewController.swift
//  meteocool
//
//  The storm log, from the map: the storms that passed over, or close to,
//  the phone's registered location and its places, as ng's `/v4/storm-log`
//  answers them. The backend decides every entry; this lists them in the
//  order the user picked, opens one (`StormLogDetailViewController`) and
//  wipes the log on request.
//
//  It is off until the user turns it on (`open(from:)`, `Pages.stormLog`).
//  ng logs every registration's storms whether or not, so turning it on
//  wipes what the server had before the list first shows, and turning it off
//  wipes it again. The app keeps no copy of the log.
//

import SwiftUI
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
    private var passages: [StormPassage] = []
    private var loading: Task<Void, Never>?
    private var sort: StormLogRules.Sort {
        get { Self.defaults?.string(forKey: StormLogRules.sortKey).flatMap(StormLogRules.Sort.init) ?? .recent }
        set { Self.defaults?.set(newValue.rawValue, forKey: StormLogRules.sortKey) }
    }
    private lazy var moreItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: nil)

    static let defaults = UserDefaults(suiteName: "group.org.frcy.app.meteocool")
    static var isEnabled: Bool { defaults?.bool(forKey: StormLogRules.enabledKey) ?? false }

    /// Opens the log, or, while it is off, the page that asks to turn it on
    /// and then the log if the user did.
    static func open(from presenter: UIViewController) {
        let show: () -> Void = { [weak presenter] in
            presenter?.present(UINavigationController(rootViewController: StormLogViewController()), animated: true)
        }
        guard !isEnabled else { return show() }
        let page = Pages.stormLog { done in
            defaults?.set(true, forKey: StormLogRules.enabledKey)
            defaults?.set(true, forKey: StormLogRules.wipePendingKey)
            done(true, nil)
        }
        presenter.present(OnboardingViewController(pages: [page]) {
            if isEnabled { show() }
        }, animated: true)
    }

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
        let done = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        moreItem.accessibilityLabel = Self.text("storm_log_more", "More")
        moreItem.accessibilityIdentifier = "stormLog.more"
        navigationItem.rightBarButtonItems = [done, moreItem]
        updateMenu()
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
        return SharedNotificationManager.getToken() ?? Self.defaults?.string(forKey: "pushToken")
    }

    private func load() {
        loading?.cancel()
        guard let token else {
            // Nothing registered, so nothing logged yet to wipe.
            Self.defaults?.set(false, forKey: StormLogRules.wipePendingKey)
            tableView.refreshControl?.endRefreshing()
            state = .unregistered
            return
        }
        if passages.isEmpty { state = .loading }
        loading = Task { [weak self] in
            // Just turned on: what ng logged before goes first.
            var log: StormLog?
            if Self.defaults?.bool(forKey: StormLogRules.wipePendingKey) == true {
                if await Self.wipe(token: token) {
                    Self.defaults?.set(false, forKey: StormLogRules.wipePendingKey)
                    log = StormLog(entries: [])
                }
            } else {
                log = await Self.fetch(token: token)
            }
            guard let self, !Task.isCancelled else { return }
            self.tableView.refreshControl?.endRefreshing()
            self.state = log.map { .loaded($0.entries) } ?? .failed
        }
    }

    /// The log, or nil when it could not be read. Never cached on the phone.
    private static func fetch(token: String) async -> StormLog? {
        var request = StormLogRules.request(api: NetworkHelper.apiURL, token: token, method: "GET")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            let ok = (response as? HTTPURLResponse).map { (200 ..< 300).contains($0.statusCode) } ?? false
            return ok ? StormLogRules.decode(data) : nil
        } catch {
            return nil
        }
    }

    /// Deletes every entry on the server; whether it did.
    private static func wipe(token: String) async -> Bool {
        let request = StormLogRules.request(api: NetworkHelper.apiURL, token: token, method: "DELETE")
        do {
            let (data, response) = try await session.data(for: request)
            return NetworkHelper.checkResponse(data: data, response: response, error: nil) != nil
        } catch {
            return false
        }
    }

    /// `URLSession.meteocool` without a cache, so no answer of the log is kept on disk.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": UserAgent.value]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

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
        switch state {
        case .loaded(let entries): passages = StormLogRules.sorted(entries, by: sort)
        case .loading: break // a refresh keeps the list until the answer
        case .unregistered, .failed: passages = []
        }
        contentUnavailableConfiguration = empty
        tableView.isHidden = empty != nil
        tableView.reloadData()
        updateMenu()
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

    // MARK: Menu

    /// The order, to pick from while there is a list, and turning the log off.
    private func updateMenu() {
        let current = sort
        let orders = StormLogRules.Sort.allCases.map { order in
            UIAction(title: Self.title(order), image: UIImage(systemName: Self.symbol(order)),
                     attributes: passages.isEmpty ? .disabled : [], state: order == current ? .on : .off) { [weak self] _ in
                self?.resort(order)
            }
        }
        let sortMenu = UIMenu(title: Self.text("storm_log_sort", "Sort By"), image: UIImage(systemName: "arrow.up.arrow.down"),
                              options: .singleSelection, children: orders)
        sortMenu.subtitle = Self.title(current)
        let turnOff = UIAction(title: Self.text("storm_log_turn_off", "Turn Off Storm Log"), image: UIImage(systemName: "power"),
                               attributes: .destructive) { [weak self] _ in
            self?.confirmTurnOff()
        }
        moreItem.menu = UIMenu(children: [sortMenu, UIMenu(options: .displayInline, children: [turnOff])])
    }

    private func resort(_ order: StormLogRules.Sort) {
        guard order != sort else { return }
        sort = order
        if case .loaded(let entries) = state {
            passages = StormLogRules.sorted(entries, by: order)
            tableView.reloadSections(IndexSet(integer: 0), with: UIAccessibility.isReduceMotionEnabled ? .none : .fade)
            if !passages.isEmpty { tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false) }
        }
        updateMenu()
        UIAccessibility.post(notification: .announcement, argument: Self.title(order))
    }

    static func title(_ order: StormLogRules.Sort) -> String {
        switch order {
        case .recent: text("storm_log_sort_recent", "Most Recent")
        case .severity: text("storm_log_sort_severity", "Severity")
        case .closest: text("storm_log_sort_closest", "Closest")
        case .duration: text("storm_log_sort_duration", "Longest")
        case .lightning: text("storm_log_sort_lightning", "Most Lightning")
        }
    }

    private static func symbol(_ order: StormLogRules.Sort) -> String {
        switch order {
        case .recent: "clock"
        case .severity: "exclamationmark.triangle"
        case .closest: "location"
        case .duration: "timer"
        case .lightning: "bolt"
        }
    }

    // MARK: Table

    func numberOfSections(in tableView: UITableView) -> Int {
        passages.isEmpty ? 0 : 2
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? passages.count : 1
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? Self.text("storm_log_footer", "Storms that came within 10 km of your location or your places, kept for about 13 months.") : nil
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
        cell.contentConfiguration = UIHostingConfiguration { StormLogRow(passage: passage) }
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "stormLog.entry"
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
        Task { [weak self] in
            let deleted = await Self.wipe(token: token)
            guard let self else { return }
            if deleted {
                self.state = .loaded([])
            } else {
                self.fail(Self.text("storm_log_delete_failed", "The storm log could not be deleted."))
            }
        }
    }

    // MARK: Turning off

    private func confirmTurnOff() {
        let sheet = UIAlertController(title: Self.text("storm_log_turn_off_title", "Turn off the storm log?"),
                                      message: Self.text("storm_log_turn_off_message", "Every entry is deleted from the server, your places' too. You can turn it on again later."),
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: Self.text("storm_log_turn_off_confirm", "Turn Off"), style: .destructive) { [weak self] _ in
            self?.turnOff()
        })
        sheet.addAction(UIAlertAction(title: Self.text("storm_log_cancel", "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = moreItem
        present(sheet, animated: true)
    }

    /// Wipes the log, then turns it off and closes it; stays on when the wipe failed.
    private func turnOff() {
        let off = { [weak self] in
            Self.defaults?.set(false, forKey: StormLogRules.enabledKey)
            Self.defaults?.set(false, forKey: StormLogRules.wipePendingKey)
            self?.dismiss(animated: true)
        }
        guard let token else { return off() }
        loading?.cancel()
        Task { [weak self] in
            if await Self.wipe(token: token) {
                off()
            } else {
                self?.fail(Self.text("storm_log_turn_off_failed", "The storm log could not be deleted, so it is still on. Try again later."))
            }
        }
    }

    private func fail(_ message: String) {
        let alert = UIAlertController(title: message, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Dismiss", value: "Dismiss", comment: ""), style: .cancel))
        present(alert, animated: true)
    }

    // MARK: Words

    /// The place it passed: a saved place by name, else the phone's location.
    static func `where`(_ passage: StormPassage) -> String {
        passage.placeName ?? NSLocalizedString("my_location", value: "My Location", comment: "")
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
