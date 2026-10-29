//
//  PastAlertsViewController.swift
//  meteocool
//
//  The rain alerts this phone received in the last two weeks, by day and
//  newest first, behind the map's bell (Shared/AlertHistory.swift), as Better
//  Rain Alarm lists them. Alerts that came since the list was last opened
//  have a dot.
//

import UIKit
import UserNotifications

final class PastAlertsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    /// When the user last opened the list, in the app group's defaults.
    static let seenKey = "alertsSeen"
    static var seen: Date? {
        get { UserDefaults(suiteName: AlertHistory.groupID)?.object(forKey: seenKey) as? Date }
        set { UserDefaults(suiteName: AlertHistory.groupID)?.set(newValue, forKey: seenKey) }
    }

    /// Reads the list again, adding the delivered alerts the notification
    /// service extension did not see, and says how many are unseen.
    static func unseen() async -> Int {
        await refresh()
        return AlertHistory.unseen(AlertHistory.load(), since: seen)
    }

    static func refresh() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        AlertHistory.add(delivered.map { ReceivedAlert(request: $0.request, received: $0.date) })
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var days: [(day: Date, alerts: [ReceivedAlert])] = []
    private let seenBefore = PastAlertsViewController.seen ?? .distantPast

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = Self.text("past_alerts_title", "Past Alerts")
        view.backgroundColor = .systemGroupedBackground
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsSelection = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "alert")
        tableView.accessibilityIdentifier = "pastAlerts"
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            let presenter = self?.presentingViewController as? ViewController
            self?.dismiss(animated: true) { presenter?.refreshAlertsBadge() }
        })
        render(AlertHistory.load())
        Task { [weak self] in
            await Self.refresh()
            self?.render(AlertHistory.load())
            Self.seen = Date()
        }
    }

    private func render(_ alerts: [ReceivedAlert]) {
        days = AlertHistory.days(alerts)
        if alerts.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "bell")
            empty.text = Self.text("past_alerts_empty", "No Alerts Yet")
            empty.secondaryText = Self.text("past_alerts_kept", "The rain alerts you get are kept here for two weeks, on this phone only.")
            contentUnavailableConfiguration = empty
            navigationItem.leftBarButtonItem = nil
        } else {
            contentUnavailableConfiguration = nil
            let clear = UIBarButtonItem(title: Self.text("past_alerts_clear", "Clear"), primaryAction: UIAction { [weak self] _ in self?.confirmClear() })
            clear.tintColor = .systemRed
            navigationItem.leftBarButtonItem = clear
        }
        tableView.isHidden = alerts.isEmpty
        tableView.reloadData()
    }

    private func confirmClear() {
        let title = Self.text("past_alerts_clear_all", "Clear Past Alerts")
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: title, style: .destructive) { [weak self] _ in
            AlertHistory.clear()
            self?.render([])
        })
        sheet.addAction(UIAlertAction(title: Self.text("past_alerts_cancel", "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.leftBarButtonItem
        present(sheet, animated: true)
    }

    static func text(_ key: String, _ english: String) -> String {
        NSLocalizedString(key, value: english, comment: "past alerts")
    }

    // MARK: Table

    func numberOfSections(in tableView: UITableView) -> Int { days.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { days[section].alerts.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let day = days[section].day
        if Calendar.current.isDateInToday(day) { return Self.text("past_alerts_today", "Today") }
        if Calendar.current.isDateInYesterday(day) { return Self.text("past_alerts_yesterday", "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let alert = days[indexPath.section].alerts[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "alert", for: indexPath)
        var content = cell.defaultContentConfiguration()
        let time = alert.received.formatted(.dateTime.hour().minute())
        let new = alert.received > seenBefore
        content.image = UIImage(systemName: alert.place == nil ? "location.fill" : "mappin")
        content.imageProperties.tintColor = .tintColor
        content.text = new ? "\(alert.title) · \(time) ●" : "\(alert.title) · \(time)"
        content.textProperties.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        content.secondaryText = alert.body.isEmpty ? nil : alert.body
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        cell.contentConfiguration = content
        cell.accessibilityLabel = new ? "\(alert.title), \(time), \(Self.text("past_alerts_new", "New"))" : "\(alert.title), \(time)"
        return cell
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let traits = (fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any] ?? [:]).merging([.weight: weight]) { $1 }
        return UIFont(descriptor: fontDescriptor.addingAttributes([.traits: traits]), size: pointSize)
    }
}
