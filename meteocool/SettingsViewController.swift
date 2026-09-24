import UIKit
import CoreLocation

/// Replace fixed storyboard rows with self-sizing, wrapping native labels.
@MainActor func layoutSettingsCell(_ cell: UITableViewCell, labels: [UILabel], accessory: UIView? = nil, bottom: Bool = true) {
    // Preserve UIKit's constraints that tie the layout margins to the cell.
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

class SettingsViewController: UIViewController, UITableViewDelegate, UITableViewDataSource{
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
    
    //Content
    private var header = [
        NSLocalizedString("notifications", comment: "header"),
        NSLocalizedString("Map View", comment: "header"),
        NSLocalizedString("About", comment: "header"),
        NSLocalizedString("data_sources_header", comment: "header")
    ]
    private var footer = [
        NSLocalizedString("notifications_explanation", comment: "footer"),
        NSLocalizedString("footer_map_appearance_explanation", comment: "footer"),
        // The build's own version rather than a number typed into the
        // translations, which had drifted from the app it shipped in.
        SettingsViewController.version,
        NSLocalizedString("data_sources_footer", comment: "footer")
    ]

    /// Everyone whose data or artwork the app shows, the licence it comes
    /// under and where that licence lives. The web map's own attribution is
    /// hidden in the app, so this list is the app's credit: keep it in step
    /// with core's `layers/attributions.ts` and the imprint's `#data`.
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
        DataSource(name: "NOAA / National Weather Service", detailKey: "source_noaa",
                   url: "https://www.weather.gov/disclaimer"),
        DataSource(name: "© Blitzortung.org", detailKey: "source_blitzortung",
                   url: "https://www.blitzortung.org/"),
        DataSource(name: "© Open-Meteo.com", detailKey: "source_openmeteo",
                   url: "https://open-meteo.com/en/licence"),
        DataSource(name: "Copernicus Sentinel · © OroraTech", detailKey: "source_copernicus",
                   url: "https://sentinels.copernicus.eu/documents/247904/690755/Sentinel_Data_Legal_Notice"),
        DataSource(name: "© OpenStreetMap contributors", detailKey: "source_osm",
                   url: "https://www.openstreetmap.org/copyright"),
        DataSource(name: "© Protomaps", detailKey: "source_protomaps",
                   url: "https://protomaps.com"),
        DataSource(name: "Freepik · Flaticon", detailKey: "source_freepik",
                   url: "https://www.flaticon.com"),
    ]

    /// `Version: 2.2`, from the bundle.
    private static var version: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return NSLocalizedString("version_label", comment: "footer") + " " + marketing
    }
    private var dataPushNotification = [
        NSLocalizedString("Enable Notifications", comment: "dataPushNotification"),
        NSLocalizedString("Show Meteorological Details", comment: "dataPushNotification"),
        NSLocalizedString("Intensity Threshold", comment: "dataPushNotification"),
        NSLocalizedString("Notification Timeframe", comment: "dataPushNotification")
    ]
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
        NSLocalizedString("Experimental Features", comment: "dataAboutLabel")
    ]
    private var intensity = [
        NSLocalizedString("Drizzle", comment: "intensity"),
        NSLocalizedString("Light rain", comment: "intensity"),
        NSLocalizedString("Rain", comment: "intensity"),
        NSLocalizedString("Intense Rain", comment: "intensity"),
        NSLocalizedString("Hail", comment: "intensity")
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
        case 1: //Map View
            return dataMapView.count
        case 2: //About
            return dataAboutLabel.count
        case 3: //Data sources
            return dataSources.count
        default:
            return 0
        }
    }
    
    //Sections Header
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return header[section]
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
        return footer[section]
    }
    
    //Table Content
    func tableView(_ tableView: UITableView,cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // kind of cells
        switcherCell = tableView.dequeueReusableCell(withIdentifier: "switcherCell") as? SwitcherTableViewCell
        textCell = tableView.dequeueReusableCell(withIdentifier: "textCell") as? TextTableViewCell
        linkCell = tableView.dequeueReusableCell(withIdentifier: "linkCell") as? LinkTableViewCell
        
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
            case 1: //meteorological details
                switcherCell.switcherInfoLabel.text = dataPushNotification[indexPath.row]
                switcherCell.switcher.accessibilityLabel = dataPushNotification[indexPath.row]
                switcherCell.switcher.setOn((userDefaults?.bool(forKey: "withDBZ"))!, animated: false)
                switcherCell.switcher.tag = Int(String(indexPath.section)+String(indexPath.row))!
                switcherCell.switcher.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
                return switcherCell
            case 2: //Intensity, Threshold
                if !thresholdSliderLoad{
                    stepperSliderCellThreshold = tableView.dequeueReusableCell(withIdentifier: "stepperSliderCell") as? StepperTableViewCell
                    let stepperSliderViewThreshold = UISlider()
                    pin(stepperSliderViewThreshold, in: stepperSliderCellThreshold)
                    stepperSliderViewThreshold.maximumValue = Float(intensity.count - 1)
                    stepperSliderViewThreshold.tag = 5
                    stepperSliderViewThreshold.accessibilityLabel = dataPushNotification[indexPath.row]
                    stepperSliderViewThreshold.value = Float(userDefaults?.integer(forKey: "intensityValue") ?? 1)
                    
                    stepperSliderCellThreshold.stepperSliderInfoLabel.text = dataPushNotification[indexPath.row]
                    stepperSliderCellThreshold.stepperSliderValueLabel.text = intensity[(userDefaults?.integer(forKey: "intensityValue"))!]
                    
                    stepperSliderViewThreshold.accessibilityValue = stepperSliderCellThreshold.stepperSliderValueLabel.text
                    stepperSliderViewThreshold.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
                    
                    thresholdSliderLoad = true
                }
                return stepperSliderCellThreshold
            case 3: //Time before
                if !timeSliderLoad{
                    stepperSliderCellTime = tableView.dequeueReusableCell(withIdentifier: "stepperSliderCell") as? StepperTableViewCell
                    let stepperSliderViewTime = UISlider()
                    pin(stepperSliderViewTime, in: stepperSliderCellTime)
                    stepperSliderViewTime.maximumValue = 8
                    stepperSliderViewTime.tag = 9
                    stepperSliderViewTime.accessibilityLabel = dataPushNotification[indexPath.row]
                    stepperSliderViewTime.value = Float(userDefaults?.integer(forKey: "timeBeforeValue") ?? 2)
                    
                    stepperSliderCellTime.stepperSliderInfoLabel.text = dataPushNotification[indexPath.row]
                    stepperSliderCellTime.stepperSliderValueLabel.text = String(((userDefaults?.integer(forKey: "timeBeforeValue"))!+1)*5) + " min"
                    
                    stepperSliderViewTime.accessibilityValue = stepperSliderCellTime.stepperSliderValueLabel.text
                    stepperSliderViewTime.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
                
                    timeSliderLoad = true
                }
                return stepperSliderCellTime
            default:
                print("This should not happen...")
                return textCell
            }
        case 1: //Map View
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
        case 2: //About
            switch indexPath.row {
            case 3:
                switcherCell.switcherInfoLabel.text = dataAboutLabel[indexPath.row]
                switcherCell.switcher.accessibilityLabel = dataAboutLabel[indexPath.row]
                switcherCell.switcher.setOn((userDefaults?.bool(forKey: "experimentalFeatures"))!, animated: false)
                switcherCell.switcher.tag = Int(String(indexPath.section)+String(indexPath.row))!
                switcherCell.switcher.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
                return switcherCell
            default: //Feedack and Links to Websides
                linkCell.linkInfoLable.text = dataAboutLabel[indexPath.row]
                linkCell.linkValueLable.text = ""
                return linkCell
            }
        case 3: //Data sources
            let source = dataSources[indexPath.row]
            linkCell.linkInfoLable.text = source.name
            linkCell.linkValueLable.text = NSLocalizedString(source.detailKey, comment: "data source")
            return linkCell
        default:
            print("This should not happen...")
            return textCell
        }
        
        
    }
    
    /// Lays a step slider out inside its cell and gives it adaptive colors.
    ///
    /// It used to be positioned with a hardcoded frame derived from the table
    /// width, which overflows an inset-grouped cell, and painted with two fixed
    /// light-mode colors, which disappeared in dark mode.
    private func pin(_ slider: UISlider, in cell: StepperTableViewCell) {
        slider.isContinuous = false
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
        
        if (indexPath.section == 1 && indexPath.row == 2){ // Base Layer
            performSegue(withIdentifier: "baseLayerMappingView", sender: self)
        }
        if (indexPath.section == 1 && indexPath.row == 3){ // Color Mapping
            performSegue(withIdentifier: "radarColorMappingView", sender: self)
        }
        if (indexPath.section == 2 && indexPath.row == 0){
            if let url = URL(string: "https://github.com/meteocool/ios") {
                UIApplication.shared.open(url)
            }
        }
        if (indexPath.section == 2 && indexPath.row == 1){ //Feedback
            let mailAdress = "support@meteocool.com"
            let mailBody = NSLocalizedString("feedback_body", comment: "mail")
            // XXX store version number somewhere central
            let mailSubject = "iOS App Feedback (\(Self.version))"

            if let url = URL(string: "mailto:\(mailAdress)?subject=\(mailSubject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)&body=\(mailBody.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)") {
                UIApplication.shared.open(url)
            }
        }
        if (indexPath.section == 2 && indexPath.row == 2){
            if let url = URL(string: "https://meteocool.com/privacy.html") {
                UIApplication.shared.open(url)
            }
        }
        if indexPath.section == 3, let url = URL(string: dataSources[indexPath.row].url) {
            UIApplication.shared.open(url)
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
        case 10:
            userDefaults?.set(sender.isOn, forKey: "mapRotation")
            NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
        case 11:
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
        case 1:
            userDefaults?.set(sender.isOn, forKey: "withDBZ")
            SharedLocationUpdater.refreshNotificationRegistration()
        case 23:
            userDefaults?.set(sender.isOn, forKey: "experimentalFeatures")
            let alert = UIAlertController(title: NSLocalizedString("experimental_features", comment: ""),
                                          message: NSLocalizedString("experimental_features_require_restart", comment: ""), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("Dismiss", comment: ""), style: .default))
            present(alert, animated: true)
        default:
            assertionFailure("Unknown settings switch")
        }
        settingsTable.reloadData()
    }

    @objc func sliderChanged(_ sender: UISlider!){
        sender.value = sender.value.rounded()
        switch sender.tag {
        case 5: //Intensity
            userDefaults?.setValue(Int(sender.value), forKey: "intensityValue")
            // 0 -> drizzle
            // 1 -> light
            // 2 -> rain
            // 3 -> intense
            // 4 -> hail
            stepperSliderCellThreshold.stepperSliderValueLabel.text = intensity[(userDefaults?.integer(forKey: "intensityValue"))!]
            
            sender.accessibilityValue = sender.tag == 5 ? stepperSliderCellThreshold.stepperSliderValueLabel.text : stepperSliderCellTime.stepperSliderValueLabel.text
            if let location = SharedLocationUpdater.getCurrentLocation(){
                SharedLocationUpdater.postLocation(location: location, pressure: -1)
            }
        case 9: //Time before
            userDefaults?.setValue(Int(sender.value), forKey: "timeBeforeValue")
            //Value +1 *5 for minutes
            stepperSliderCellTime.stepperSliderValueLabel.text = String(((userDefaults?.integer(forKey: "timeBeforeValue"))!+1)*5) + " min"
            
            sender.accessibilityValue = sender.tag == 5 ? stepperSliderCellThreshold.stepperSliderValueLabel.text : stepperSliderCellTime.stepperSliderValueLabel.text
            if let location = SharedLocationUpdater.getCurrentLocation(){
                SharedLocationUpdater.postLocation(location: location, pressure: -1)
            }
        default:
            print ("This not happen: Slider")
        }
    }
    
    @objc func reload(){
        settingsTable.reloadData()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
}
