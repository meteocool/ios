import UIKit
import CoreLocation

/// Replace fixed storyboard rows with self-sizing, wrapping native labels.
@MainActor func layoutSettingsCell(_ cell: UITableViewCell, labels: [UILabel], accessory: UIView? = nil, bottom: Bool = true) {
    // Drops only constraints that reference these views, so UIKit's layout-margin constraints on the cell stay.
    LiquidGlass.dropConstraints(on: cell.contentView, referencing: labels + (accessory.map { [$0] } ?? []))
    for label in labels {
        NSLayoutConstraint.deactivate(label.constraints)
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .natural
    }
    let column = UIStackView(arrangedSubviews: labels)
    column.axis = .vertical
    column.spacing = 4
    accessory?.setContentHuggingPriority(.required, for: .horizontal)
    accessory?.setContentCompressionResistancePriority(.required, for: .horizontal)
    let row = UIStackView(arrangedSubviews: [column] + (accessory.map { [$0] } ?? []))
    row.spacing = 12
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    cell.contentView.addSubview(row)
    NSLayoutConstraint.activate([
        row.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
        row.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
        row.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
    ])
    if bottom { row.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12).isActive = true }
}

class LinkTableViewCell: UITableViewCell{
    @IBOutlet weak var linkInfoLable: UILabel!
    @IBOutlet weak var linkValueLable: UILabel!
    @IBOutlet weak var linkArrow: UIImageView!
    override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated { layoutSettingsCell(self, labels: [linkInfoLable, linkValueLable], accessory: linkArrow) }
    }
}

class StepperTableViewCell: UITableViewCell{
    @IBOutlet weak var stepperSliderInfoLabel: UILabel!
    @IBOutlet weak var stepperSliderValueLabel: UILabel!
    override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated { layoutSettingsCell(self, labels: [stepperSliderInfoLabel, stepperSliderValueLabel], bottom: false) }
    }
}

class SwitcherTableViewCell: UITableViewCell{
    @IBOutlet weak var switcherInfoLabel: UILabel!
    @IBOutlet weak var switcher:UISwitch!
    override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated { layoutSettingsCell(self, labels: [switcherInfoLabel], accessory: switcher) }
    }
}

class TextTableViewCell: UITableViewCell{
    @IBOutlet weak var textInfoLabel: UILabel!
    @IBOutlet weak var textValueLabel: UILabel!
    override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated { layoutSettingsCell(self, labels: [textInfoLabel, textValueLabel]) }
    }
}

class SettingsViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, UIGestureRecognizerDelegate{
    @IBOutlet weak var settingsBar:UINavigationBar!
    @IBOutlet weak var settingsTable:UITableView!
    
    //userDefaults
    let userDefaults = UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")
    
    //Kind of cells
    var stepperSliderCellThreshold: StepperTableViewCell!
    var stepperSliderCellTime: StepperTableViewCell!
    var switcherCell: SwitcherTableViewCell!
    var textCell: TextTableViewCell!
    var linkCell: LinkTableViewCell!
    
    var thresholdSliderLoad = false
    var timeSliderLoad = false

    // Step haptics before iOS 26, which has no native slider stops.
    private let stepFeedback = UISelectionFeedbackGenerator()
    private var dragStep = 0
    
    //Content
    private var header = [
        NSLocalizedString("notifications", comment: "header"),
        NSLocalizedString("notification_style_header", comment: "header"),
        NSLocalizedString("Map View", comment: "header"),
        NSLocalizedString("About", comment: "header"),
        NSLocalizedString("data_sources_header", comment: "header"),
        ""
    ]
    private var footer = [
        NSLocalizedString("notifications_explanation", comment: "footer"),
        NSLocalizedString("notification_style_footer", comment: "footer"),
        NSLocalizedString("footer_map_appearance_explanation", comment: "footer"),
        // Read from the bundle, not from the translations.
        // A version number typed into the translations went out of date.
        SettingsViewController.version,
        NSLocalizedString("data_sources_footer", comment: "footer"),
        ""
    ]

    /// Each source of data or artwork the app shows, with its licence and the licence URL.
    /// The app hides the web map's attribution, so this list is the app's credit.
    /// Keep it in sync with core's `layers/attributions.ts` and the imprint's `#data`.
    private struct DataSource {
        let name: String
        let detailKey: String
        let url: String
    }
    private let dataSources = [
        DataSource(name: "© Deutscher Wetterdienst (DWD)", detailKey: "source_dwd",
                   url: "https://www.dwd.de/EN/service/copyright/copyright_node.html"),
        DataSource(name: "© MeteoSwiss", detailKey: "source_meteoswiss",
                   url: "https://opendatadocs.meteoswiss.ch/general/terms-of-use"),
        DataSource(name: "© Météo-France", detailKey: "source_meteofrance",
                   url: "https://www.etalab.gouv.fr/licence-ouverte-open-licence/"),
        DataSource(name: "© Český hydrometeorologický ústav (ČHMÚ)", detailKey: "source_chmi",
                   url: "https://www.chmi.cz/o-chmu/caste-dotazy-faq/open-data"),
        DataSource(name: "© IMGW-PIB", detailKey: "source_imgw",
                   url: "https://danepubliczne.imgw.pl/regulations"),
        DataSource(name: "EUMETNET Open Radar Data", detailKey: "source_eumetnet",
                   url: "https://eumetnet.github.io/openradardata-documentation/"),
        DataSource(name: "NOAA / National Weather Service", detailKey: "source_noaa",
                   url: "https://www.weather.gov/disclaimer"),
        DataSource(name: "© Blitzortung.org and its contributors", detailKey: "source_blitzortung",
                   url: "https://www.blitzortung.org/"),
        DataSource(name: "© Open-Meteo.com", detailKey: "source_openmeteo",
                   url: "https://open-meteo.com/en/licence"),
        DataSource(name: "© OpenStreetMap contributors", detailKey: "source_osm",
                   url: "https://www.openstreetmap.org/copyright"),
        DataSource(name: "© Protomaps", detailKey: "source_protomaps",
                   url: "https://protomaps.com"),
        DataSource(name: "© Mapterhorn", detailKey: "source_mapterhorn",
                   url: "https://mapterhorn.com/attribution"),
        DataSource(name: "Freepik · Flaticon", detailKey: "source_freepik",
                   url: "https://www.flaticon.com"),
        DataSource(name: "Vitaly Gorbachev · Flaticon", detailKey: "source_gorbachev",
                   url: "https://www.flaticon.com/authors/vitaly-gorbachev"),
    ]

    /// Footer text such as `Version: 2.2`, built from the bundle's marketing version.
    private static var version: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return NSLocalizedString("version_label", comment: "footer") + " " + marketing
    }
    private var dataPushNotification = [
        NSLocalizedString("Enable Notifications", comment: "dataPushNotification"),
        NSLocalizedString("Intensity Threshold", comment: "dataPushNotification"),
        NSLocalizedString("Notification Timeframe", comment: "dataPushNotification")
    ]
    /// Rows after the Live Activity preview image.
    private var dataNotificationStyle = [
        NSLocalizedString("live_activity", comment: "dataPushNotification"),
        NSLocalizedString("Show Meteorological Details", comment: "dataPushNotification")
    ]

    /// The Live Activity as the App Store shows it, and how it behaves, above its switch.
    private lazy var liveActivityPreviewCell: UITableViewCell = {
        let cell = UITableViewCell()
        cell.selectionStyle = .none
        let image = UIImageView(image: UIImage(named: "LiveActivityPreview"))
        image.contentMode = .scaleAspectFit
        image.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(image)
        let caption = UILabel()
        caption.text = NSLocalizedString("live_activity_preview_caption", comment: "settings")
        caption.font = .preferredFont(forTextStyle: .footnote)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = .secondaryLabel
        caption.numberOfLines = 0
        caption.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(caption)
        let margins = cell.contentView.layoutMarginsGuide
        let fill = image.widthAnchor.constraint(equalTo: margins.widthAnchor)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            fill,
            image.widthAnchor.constraint(lessThanOrEqualTo: margins.widthAnchor),
            image.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            image.heightAnchor.constraint(equalTo: image.widthAnchor, multiplier: 355.0 / 1089.0),
            image.centerXAnchor.constraint(equalTo: margins.centerXAnchor),
            image.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 16),
            caption.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 12),
            caption.leadingAnchor.constraint(equalTo: image.leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: image.trailingAnchor),
            caption.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -16),
        ])
        return cell
    }()
    private var dataMapView = [
        NSLocalizedString("Two-Finger Map Rotation", comment: "dataMapView"),
        NSLocalizedString("Auto-Zoom After Start", comment: "dataMapView"),
        NSLocalizedString("Base Map Layer", comment: "dataMapView"),
        NSLocalizedString("Radar Color Map", comment: "dataMapView")
    ]
    private var dataAboutLabel = [
        NSLocalizedString("Contribute on GitHub", comment: "dataAboutLabel"),
        NSLocalizedString("Feedback and Support", comment: "dataAboutLabel"),
        NSLocalizedString("imprint_privacy", comment: "dataAboutLabel"),
        NSLocalizedString("Mode", comment: "dataAboutLabel")
    ]
    private var intensity = [
        NSLocalizedString("Drizzle", comment: "intensity"),
        NSLocalizedString("Light rain", comment: "intensity"),
        NSLocalizedString("Rain", comment: "intensity"),
        NSLocalizedString("Intense Rain", comment: "intensity"),
        NSLocalizedString("Heavy Rain", comment: "intensity")
    ]
    
    //General View Things
    override func loadView() {
        super.loadView()
        self.view.addSubview(settingsBar)
        self.view.addSubview(settingsTable)
        
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        settingsTable.estimatedRowHeight = 100
        settingsTable.rowHeight = UITableView.automaticDimension
        if #available(iOS 26.0, *) {
            LiquidGlass.float(settingsBar, over: settingsTable, in: view)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: NSNotification.Name("SettingsChanged"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: MeteocoolEnvironment.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(SettingsViewController.willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    //Return Back with Done
    @IBAction func doneSettings(_ sender: Any){
        self.dismiss(animated: true,completion:nil)
    }
    
    //Nuber of Selections
    func numberOfSections(in tableView: UITableView) -> Int {
        return header.count
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if #available(iOS 26.0, *) {
            LiquidGlass.inset(settingsTable, below: settingsBar)
        }
    }

    //Number of Rows
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section{
        case 0: //Notification
            let pushNotification = userDefaults?.bool(forKey: "pushNotification")
            if pushNotification!{
                return dataPushNotification.count
            }
            else {
                return 1
            }
        case 1: //Notification style, only with notifications on
            return notificationStyleShown ? 1 + dataNotificationStyle.count : 0
        case 2: //Map View
            return dataMapView.count
        case 3: //About
            return dataAboutLabel.count
        case 4: //Data sources
            return dataSources.count
        case 5: //Open-source licences
            return 1
        default:
            return 0
        }
    }
    
    //Sections Header
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 1 && !notificationStyleShown { return nil }
        return header[section]
    }

    private var notificationStyleShown: Bool {
        userDefaults?.bool(forKey: "pushNotification") ?? false
    }

    // A hidden section must not leave its spacing behind.
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        section == 1 && !notificationStyleShown ? .leastNonzeroMagnitude : UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        section == 1 && !notificationStyleShown ? .leastNonzeroMagnitude : UITableView.automaticDimension
    }
    
    //Selection Footer
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            if SharedNotificationManager.syncFailed {
                return NSLocalizedString("notification_sync_failed", comment: "")
            }
            if SharedNotificationManager.enabled {
                if !SharedNotificationManager.authorized || SharedLocationUpdater.authorizationStatus != .authorizedAlways {
                    return NSLocalizedString("notification_permissions_help", comment: "")
                }
                return NSLocalizedString("meteorological_details_help", comment: "")
            }
        }
        if section == 1 && !notificationStyleShown { return nil }
        return footer[section]
    }
    
    //Table Content
    func tableView(_ tableView: UITableView,cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // kind of cells
        switcherCell = tableView.dequeueReusableCell(withIdentifier: "switcherCell") as? SwitcherTableViewCell
        textCell = tableView.dequeueReusableCell(withIdentifier: "textCell") as? TextTableViewCell
        linkCell = tableView.dequeueReusableCell(withIdentifier: "linkCell") as? LinkTableViewCell
        // Only the licences row has a disclosure arrow; a reused cell must not keep it.
        linkCell?.accessoryType = .none
        
        //returnCell = (textCell)!
        switch indexPath.section{
        case 0: //Push Notification
            switch indexPath.row {
            case 0: //Notificatino On/Off
                switcherCell.switcherInfoLabel.text = dataPushNotification[indexPath.row]
                switcherCell.switcher.accessibilityLabel = dataPushNotification[indexPath.row]
                switcherCell.switcher.setOn((userDefaults?.bool(forKey: "pushNotification"))!, animated: false)
                switcherCell.switcher.tag = Int(String(indexPath.section)+String(indexPath.row))!
                switcherCell.switcher.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
                return switcherCell
            case 1: //Intensity, Threshold
                if !thresholdSliderLoad{
                    stepperSliderCellThreshold = tableView.dequeueReusableCell(withIdentifier: "stepperSliderCell") as? StepperTableViewCell
                    let stepperSliderViewThreshold = UISlider()
                    pin(stepperSliderViewThreshold, steps: intensity.count, in: stepperSliderCellThreshold)
                    stepperSliderViewThreshold.tag = 5
                    stepperSliderViewThreshold.accessibilityLabel = dataPushNotification[indexPath.row]
                    stepperSliderViewThreshold.value = Float(userDefaults?.integer(forKey: "intensityValue") ?? 1)
                    
                    stepperSliderCellThreshold.stepperSliderInfoLabel.text = dataPushNotification[indexPath.row]
                    stepperSliderCellThreshold.stepperSliderValueLabel.text = intensity[(userDefaults?.integer(forKey: "intensityValue"))!]
                    
                    stepperSliderViewThreshold.accessibilityValue = stepperSliderCellThreshold.stepperSliderValueLabel.text
                    
                    thresholdSliderLoad = true
                }
                return stepperSliderCellThreshold
            case 2: //Time before
                if !timeSliderLoad{
                    stepperSliderCellTime = tableView.dequeueReusableCell(withIdentifier: "stepperSliderCell") as? StepperTableViewCell
                    let stepperSliderViewTime = UISlider()
                    pin(stepperSliderViewTime, steps: 9, in: stepperSliderCellTime)
                    stepperSliderViewTime.tag = 9
                    stepperSliderViewTime.accessibilityLabel = dataPushNotification[indexPath.row]
                    stepperSliderViewTime.value = Float(userDefaults?.integer(forKey: "timeBeforeValue") ?? 2)
                    
                    stepperSliderCellTime.stepperSliderInfoLabel.text = dataPushNotification[indexPath.row]
                    stepperSliderCellTime.stepperSliderValueLabel.text = String(((userDefaults?.integer(forKey: "timeBeforeValue"))!+1)*5) + " min"
                    
                    stepperSliderViewTime.accessibilityValue = stepperSliderCellTime.stepperSliderValueLabel.text
                
                    timeSliderLoad = true
                }
                return stepperSliderCellTime
            default:
                print("This should not happen...")
                return textCell
            }
        case 2: //Map View
            switch indexPath.row {
            case 0: //Map Rotation
                switcherCell.switcherInfoLabel.text = dataMapView[indexPath.row]
                switcherCell.switcher.accessibilityLabel = dataMapView[indexPath.row]
                switcherCell.switcher.setOn((userDefaults?.bool(forKey: "mapRotation"))!, animated: false)
                switcherCell.switcher.tag = Int(String(indexPath.section)+String(indexPath.row))!
                switcherCell.switcher.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
                return switcherCell
            case 1: //Auto Zoom
                switcherCell.switcherInfoLabel.text = dataMapView[indexPath.row]
                switcherCell.switcher.accessibilityLabel = dataMapView[indexPath.row]
                switcherCell.switcher.setOn((userDefaults?.bool(forKey: "autoZoom"))!, animated: false)
                switcherCell.switcher.tag = Int(String(indexPath.section)+String(indexPath.row))!
                switcherCell.switcher.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
                return switcherCell
            case 2: //Base Layer
                linkCell.linkInfoLable.text = dataMapView[indexPath.row]
                linkCell.linkValueLable.text = NSLocalizedString((userDefaults?.string(forKey: "baseLayer"))!, comment: "baseLayer")
                return linkCell
            case 3: //Radar Color Map
                linkCell.linkInfoLable.text = dataMapView[indexPath.row]
                linkCell.linkValueLable.text = NSLocalizedString((userDefaults?.string(forKey: "radarColorMapping"))!, comment: "radarColorMapping")
                return linkCell
            default:
                print("This should not happen...")
                return textCell
            }
        case 1: //Notification style
            guard indexPath.row > 0 else { return liveActivityPreviewCell }
            let title = dataNotificationStyle[indexPath.row - 1]
            switcherCell.switcherInfoLabel.text = title
            switcherCell.switcher.accessibilityLabel = title
            switcherCell.switcher.setOn(indexPath.row == 1 ? SharedLiveActivities.preferred : userDefaults?.bool(forKey: "withDBZ") ?? false, animated: false)
            switcherCell.switcher.tag = Int(String(indexPath.section)+String(indexPath.row))!
            switcherCell.switcher.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
            return switcherCell
        case 3: //About
            switch indexPath.row {
            case 3: // Mode: the deployment (`MeteocoolEnvironment`)
                linkCell.linkInfoLable.text = dataAboutLabel[indexPath.row]
                linkCell.linkValueLable.text = EnvironmentPickerViewController.title(of: MeteocoolEnvironment.current)
                return linkCell
            default: //Feedack and Links to Websides
                linkCell.linkInfoLable.text = dataAboutLabel[indexPath.row]
                linkCell.linkValueLable.text = ""
                return linkCell
            }
        case 4: //Data sources
            let source = dataSources[indexPath.row]
            linkCell.linkInfoLable.text = source.name
            linkCell.linkValueLable.text = NSLocalizedString(source.detailKey, comment: "data source")
            return linkCell
        case 5: //Open-source licences, on their own page
            linkCell.linkInfoLable.text = NSLocalizedString("open_source_header", comment: "licence")
            linkCell.linkValueLable.text = ""
            linkCell.accessoryType = .disclosureIndicator
            return linkCell
        default:
            print("This should not happen...")
            return textCell
        }
        
        
    }
    
    /// Pins a step slider inside its cell with Auto Layout and gives it adaptive colors.
    ///
    /// - A frame derived from the table width overflows an inset-grouped cell.
    /// - Fixed light-mode colors are invisible in dark mode.
    /// - A plain continuous slider only buzzes at its two ends; each step
    ///   should tick, as the old StepSlider did.
    private func pin(_ slider: UISlider, steps: Int, in cell: StepperTableViewCell) {
        slider.maximumValue = Float(steps - 1)
        if #available(iOS 26.0, *) {
            // Native stops snap and tick on every step.
            slider.trackConfiguration = .init(numberOfTicks: steps)
        }
        slider.isContinuous = true
        slider.addTarget(self, action: #selector(sliderTouchedDown(_:)), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderChanged(_:event:)), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderCommitted(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let tap = UITapGestureRecognizer(target: self, action: #selector(sliderTrackTapped(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        slider.addGestureRecognizer(tap)
        slider.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(slider)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            slider.topAnchor.constraint(equalTo: cell.stepperSliderValueLabel.bottomAnchor, constant: 8),
            slider.heightAnchor.constraint(equalToConstant: 50),
            slider.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
        ])

        slider.maximumTrackTintColor = .tertiarySystemFill
        slider.minimumTrackTintColor = .tintColor
        slider.thumbTintColor = .tintColor
    }

    //Cell Height
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        
        if (indexPath.section == 2 && indexPath.row == 2){ // Base Layer
            performSegue(withIdentifier: "baseLayerMappingView", sender: self)
        }
        if (indexPath.section == 2 && indexPath.row == 3){ // Color Mapping
            performSegue(withIdentifier: "radarColorMappingView", sender: self)
        }
        if (indexPath.section == 3 && indexPath.row == 0){
            if let url = URL(string: "https://github.com/meteocool/ios") {
                UIApplication.shared.open(url)
            }
        }
        if (indexPath.section == 3 && indexPath.row == 1){ //Feedback
            let mailAdress = "support@meteocool.com"
            let mailBody = NSLocalizedString("feedback_body", comment: "mail")
            // XXX store version number somewhere central
            let mailSubject = "iOS App Feedback (\(Self.version))"

            if let url = URL(string: "mailto:\(mailAdress)?subject=\(mailSubject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)&body=\(mailBody.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)") {
                UIApplication.shared.open(url)
            }
        }
        if (indexPath.section == 3 && indexPath.row == 2){
            if let url = URL(string: "https://meteocool.com/privacy.html") {
                UIApplication.shared.open(url)
            }
        }
        if (indexPath.section == 3 && indexPath.row == 3){ // Mode
            present(UINavigationController(rootViewController: EnvironmentPickerViewController()), animated: true)
        }
        if indexPath.section == 4, let url = URL(string: dataSources[indexPath.row].url) {
            UIApplication.shared.open(url)
        }
        if indexPath.section == 5 {
            present(UINavigationController(rootViewController: LicencesViewController()), animated: true)
        }
    }
    
    @objc func willEnterForeground() {
        SharedNotificationManager.refreshAuthorization()
        settingsTable.reloadData()
    }

    private func permissionHelp() {
        let alert = UIAlertController(title: NSLocalizedString("notification_permissions_title", comment: ""),
                                      message: NSLocalizedString("notification_permissions_help", comment: ""), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Change In Settings", comment: ""), style: .default) { _ in
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Dismiss", comment: ""), style: .cancel))
        present(alert, animated: true)
    }

    @objc func switchChanged(_ sender: UISwitch) {
        switch sender.tag {
        case 20:
            userDefaults?.set(sender.isOn, forKey: "mapRotation")
            NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
        case 21:
            userDefaults?.set(sender.isOn, forKey: "autoZoom")
            if sender.isOn {
                SharedLocationUpdater.requestAuthorization({ [weak self] granted, _ in
                    self?.userDefaults?.set(granted, forKey: "autoZoom")
                    self?.settingsTable.reloadData()
                    if !granted { self?.permissionHelp() }
                })
            }
        case 0:
            if !sender.isOn {
                SharedNotificationManager.disable()
            } else {
                SharedNotificationManager.registerForPushNotifications { [weak self] granted, _ in
                    guard let self else { return }
                    guard granted else {
                        self.settingsTable.reloadData()
                        self.permissionHelp()
                        return
                    }
                    SharedLocationUpdater.requestAuthorization({ [weak self] locationGranted, _ in
                        guard let self else { return }
                        if locationGranted {
                            SharedLocationUpdater.requestBackgroundAuthorization()
                            SharedLocationUpdater.refreshNotificationRegistration()
                        } else {
                            self.permissionHelp()
                        }
                        self.settingsTable.reloadData()
                    })
                }
            }
        case 12:
            userDefaults?.set(sender.isOn, forKey: "withDBZ")
            SharedLocationUpdater.refreshNotificationRegistration()
        case 11:
            userDefaults?.set(sender.isOn, forKey: "liveActivity")
            SharedLiveActivities.settingChanged()
        default:
            assertionFailure("Unknown settings switch")
        }
        settingsTable.reloadData()
    }

    private func updateSliderLabel(_ sender: UISlider) {
        let index = Int(sender.value.rounded())
        switch sender.tag {
        case 5:
            let text = intensity[index]
            stepperSliderCellThreshold.stepperSliderValueLabel.text = text
            sender.accessibilityValue = text
        case 9:
            let text = "\((index + 1) * 5) min"
            stepperSliderCellTime.stepperSliderValueLabel.text = text
            sender.accessibilityValue = text
        default:
            assertionFailure("Unknown settings slider")
        }
    }

    @objc private func sliderTouchedDown(_ sender: UISlider) {
        dragStep = Int(sender.value.rounded())
        stepFeedback.prepare()
    }

    @objc private func sliderChanged(_ sender: UISlider, event: UIEvent?) {
        if #unavailable(iOS 26.0), event?.allTouches?.isEmpty == false {
            let step = Int(sender.value.rounded())
            if step != dragStep {
                dragStep = step
                stepFeedback.selectionChanged()
            }
        }
        updateSliderLabel(sender)
        // Touch gestures commit on release. Accessibility adjustments and
        // track taps send valueChanged without touches and commit immediately.
        if event?.allTouches?.isEmpty != false {
            sliderCommitted(sender)
        }
    }

    @objc private func sliderCommitted(_ sender: UISlider) {
        sender.value = sender.value.rounded()
        updateSliderLabel(sender)
        let key: String
        switch sender.tag {
        case 5: key = "intensityValue"
        case 9: key = "timeBeforeValue"
        default:
            assertionFailure("Unknown settings slider")
            return
        }
        let index = Int(sender.value)
        guard userDefaults?.integer(forKey: key) != index else { return }
        userDefaults?.set(index, forKey: key)
        if let location = SharedLocationUpdater.getCurrentLocation() {
            SharedLocationUpdater.postLocation(location: location, pressure: -1)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let slider = gestureRecognizer.view as? UISlider else { return true }
        let track = slider.trackRect(forBounds: slider.bounds)
        let thumb = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: slider.value)
        // Leave thumb tracking entirely to UISlider.
        return !thumb.contains(touch.location(in: slider))
    }

    @objc private func sliderTrackTapped(_ gesture: UITapGestureRecognizer) {
        guard let slider = gesture.view as? UISlider else { return }
        let track = slider.trackRect(forBounds: slider.bounds)
        let start = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: slider.minimumValue).midX
        let end = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: slider.maximumValue).midX
        guard start != end else { return }
        let fraction = min(max((gesture.location(in: slider).x - start) / (end - start), 0), 1)
        slider.setValue((slider.minimumValue + Float(fraction) * (slider.maximumValue - slider.minimumValue)).rounded(), animated: true)
        slider.sendActions(for: .valueChanged)
    }
    
    @objc func reload(){
        settingsTable.reloadData()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
}
