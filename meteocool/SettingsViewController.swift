import UIKit
import StepSlider
import CoreLocation

class LinkTableViewCell: UITableViewCell{
    @IBOutlet weak var linkInfoLable: UILabel!
    @IBOutlet weak var linkValueLable: UILabel!
    @IBOutlet weak var linkArrow: UIImageView!
}

class StepperTableViewCell: UITableViewCell{
    @IBOutlet weak var stepperSliderInfoLabel: UILabel!
    @IBOutlet weak var stepperSliderValueLabel: UILabel!
}

class SwitcherTableViewCell: UITableViewCell{
    @IBOutlet weak var switcherInfoLabel: UILabel!
    @IBOutlet weak var switcher:UISwitch!
}

class TextTableViewCell: UITableViewCell{
    @IBOutlet weak var textInfoLabel: UILabel!
    @IBOutlet weak var textValueLabel: UILabel!
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
        NSLocalizedString("Map View", comment: "header"),
        NSLocalizedString("Layers", comment: "header"),
        NSLocalizedString("notifications", comment: "header"),
        NSLocalizedString("About", comment: "header")
    ]
    private var footer = [
        NSLocalizedString("Customize the appearance and behavior of the main map.", comment: "footer"),
        NSLocalizedString("Enable or disable informational layers on the main map.", comment: "footer"),
        NSLocalizedString("notifications_explanation", comment: "footer"),
        NSLocalizedString("copyright_footer", comment: "footer")
    ]
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
    private var dataLayers = [
        NSLocalizedString("⚡️ Lightning", comment: "dataLayers"),
        NSLocalizedString("🌀 Mesocyclones", comment: "dataLayers"),
        //NSLocalizedString("☂️ Shelters", comment: "dataLayers")
    ]
    private var dataAboutLabel = [
        NSLocalizedString("Contribute on GitHub", comment: "dataAboutLabel"),
        NSLocalizedString("Follow on Twitter", comment: "dataAboutLabel"),
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
        settingsTable.rowHeight = 44
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
    
    //Number of Rows
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section{
        case 0: //Map View
            return dataMapView.count
        case 1: //Layer
            return dataLayers.count
        case 2: //Notification
            let pushNotification = userDefaults?.bool(forKey: "pushNotification")
            if pushNotification!{
                return dataPushNotification.count
            }
            else {
                return 1
            }
        case 3: //About
            return dataAboutLabel.count
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
        if(section == 2 && (userDefaults?.bool(forKey: "pushNotification"))!){
            return NSLocalizedString("meteorological_details_help" ,comment: "selection Footer")
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
        case 0: //Map View
            switch indexPath.row {
            case 0: //Map Rotation
                switcherCell.switcherInfoLabel.text = dataMapView[indexPath.row]
                switcherCell.switcher.setOn((userDefaults?.bool(forKey: "mapRotation"))!, animated: false)
                switcherCell.switcher.tag = Int(String(indexPath.section)+String(indexPath.row))!
                switcherCell.switcher.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
                return switcherCell
            case 1: //Auto Zoom
                switcherCell.switcherInfoLabel.text = dataMapView[indexPath.row]
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
        case 1: //Layers
            switch indexPath.row{
            case 0: //Lightning
                switcherCell.switcherInfoLabel.text = dataLayers[indexPath.row]
                switcherCell.switcher.setOn((userDefaults?.bool(forKey: "lightning"))!, animated: false)
                switcherCell.switcher.tag = Int(String(indexPath.section)+String(indexPath.row))!
                switcherCell.switcher.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
                return switcherCell
            case 1: //Mesocyclones
                switcherCell.switcherInfoLabel.text = dataLayers[indexPath.row]
                switcherCell.switcher.setOn((userDefaults?.bool(forKey: "mesocyclones"))!, animated: false)
                switcherCell.switcher.tag = Int(String(indexPath.section)+String(indexPath.row))!
                switcherCell.switcher.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
                return switcherCell
            /*case 2: //Shelters
             switcherCell.switcherInfoLabel.text = dataLayers[indexPath.row]
             switcherCell.switcher.setOn((userDefaults?.bool(forKey: "shelters"))!, animated: false)
             return switcherCell
             */
            default:
                print("This should not happen...")
                return textCell
            }
        case 2: //Push Notification
            switch indexPath.row {
            case 0: //Notificatino On/Off
                switcherCell.switcherInfoLabel.text = dataPushNotification[indexPath.row]
                switcherCell.switcher.setOn((userDefaults?.bool(forKey: "pushNotification"))!, animated: false)
                switcherCell.switcher.tag = Int(String(indexPath.section)+String(indexPath.row))!
                switcherCell.switcher.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
                return switcherCell
            case 1: //meteorological details
                switcherCell.switcherInfoLabel.text = dataPushNotification[indexPath.row]
                switcherCell.switcher.setOn((userDefaults?.bool(forKey: "withDBZ"))!, animated: false)
                switcherCell.switcher.tag = Int(String(indexPath.section)+String(indexPath.row))!
                switcherCell.switcher.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
                return switcherCell
            case 2: //Intensity, Threshold
                if !thresholdSliderLoad{
                    stepperSliderCellThreshold = tableView.dequeueReusableCell(withIdentifier: "stepperSliderCell") as? StepperTableViewCell
                    let stepperSliderViewThreshold = StepSlider.init(frame: CGRect(x: 15.0,y: 50.0,width: tableView.frame.width-30,height: 50.0))
                    stepperSliderCellThreshold.addSubview(stepperSliderViewThreshold)
                    
                    stepperSliderViewThreshold.sliderCircleColor = UIColor(red: 233/255, green: 233/255, blue: 235/255, alpha: 1.0)
                    stepperSliderViewThreshold.labelColor = UIColor(red: 0, green: 0, blue: 0, alpha: 1.0)
                    stepperSliderViewThreshold.maxCount = UInt(intensity.count)
                    stepperSliderViewThreshold.index = UInt.init(bitPattern: (userDefaults?.integer(forKey: "intensityValue"))!)
                    
                    stepperSliderCellThreshold.stepperSliderInfoLabel.text = dataPushNotification[indexPath.row]
                    stepperSliderCellThreshold.stepperSliderValueLabel.text = intensity[(userDefaults?.integer(forKey: "intensityValue"))!]
                    
                    stepperSliderViewThreshold.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
                    
                    thresholdSliderLoad = true
                }
                return stepperSliderCellThreshold
            case 3: //Time before
                if !timeSliderLoad{
                    stepperSliderCellTime = tableView.dequeueReusableCell(withIdentifier: "stepperSliderCell") as? StepperTableViewCell
                    let stepperSliderViewTime = StepSlider.init(frame: CGRect(x: 15.0,y: 50.0,width: tableView.frame.width-30,height: 50.0))
                    stepperSliderCellTime.addSubview(stepperSliderViewTime)
                    
                    stepperSliderViewTime.sliderCircleColor = UIColor(red: 233/255, green: 233/255, blue: 235/255, alpha: 1.0)
                    stepperSliderViewTime.labelColor = UIColor(red: 0, green: 0, blue: 0, alpha: 1.0)
                    
                    stepperSliderViewTime.maxCount = 9
                    stepperSliderViewTime.index = UInt.init(bitPattern: (userDefaults?.integer(forKey: "timeBeforeValue"))!)
                    
                    stepperSliderCellTime.stepperSliderInfoLabel.text = dataPushNotification[indexPath.row]
                    stepperSliderCellTime.stepperSliderValueLabel.text = String(((userDefaults?.integer(forKey: "timeBeforeValue"))!+1)*5) + " min"
                    
                    stepperSliderViewTime.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
                
                    timeSliderLoad = true
                }
                return stepperSliderCellTime
            default:
                print("This should not happen...")
                return textCell
            }
        case 3: //About
            switch indexPath.row {
            case 4:
                switcherCell.switcherInfoLabel.text = dataAboutLabel[indexPath.row]
                switcherCell.switcher.setOn((userDefaults?.bool(forKey: "experimentalFeatures"))!, animated: false)
                switcherCell.switcher.tag = Int(String(indexPath.section)+String(indexPath.row))!
                switcherCell.switcher.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
                return switcherCell
            default: //Feedack and Links to Websides
                linkCell.linkInfoLable.text = dataAboutLabel[indexPath.row]
                linkCell.linkValueLable.text = ""
                return linkCell
            }
        default:
            print("This should not happen...")
            return textCell
        }
        
        
    }
    
    //Cell Height
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if(indexPath.section == 2 && (indexPath.row == 2 || indexPath.row == 3)){
            return 100
        }
        return tableView.rowHeight
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        
        if (indexPath.section == 0 && indexPath.row == 2){ // Base Layer
            performSegue(withIdentifier: "baseLayerMappingView", sender: self)
        }
        if (indexPath.section == 0 && indexPath.row == 3){ // Color Mapping
            performSegue(withIdentifier: "radarColorMappingView", sender: self)
        }
        if (indexPath.section == 3 && indexPath.row == 0){
            if let url = URL(string: "https://github.com/meteocool/ios") {
                UIApplication.shared.open(url)
            }
        }
        if (indexPath.section == 3 && indexPath.row == 1){
            if let url = URL(string: "https://twitter.com/meteocool_app") {
                UIApplication.shared.open(url)
            }
        }
        if (indexPath.section == 3 && indexPath.row == 2){ //Feedback
            let token = SharedNotificationManager.getToken() ?? "no-token"
            let mailAdress = "support@meteocool.com"
            let mailBody = NSLocalizedString("feedback_text_1",comment: "mail") + token
            // XXX store version number somewhere central
            let mailSubject = "iOS App Feedback (2.1)"

            print(mailBody.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)
            if let url = URL(string: "mailto:\(mailAdress)?subject=\(mailSubject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)&body=\(mailBody.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)") {
                UIApplication.shared.open(url)
            }
        }
        if (indexPath.section == 3 && indexPath.row == 3){
            if let url = URL(string: "https://meteocool.com/privacy.html") {
                UIApplication.shared.open(url)
            }
        }
    }
    
    var alertWindow: UIWindow?
    
    var enableZoomOnStartIfGranted : Bool = false
    
    @objc func willEnterForeground() {
        if (enableZoomOnStartIfGranted) {
            enableZoomOnStartIfGranted = false
            let locationAuth = CLLocationManager.authorizationStatus()
            userDefaults?.setValue((locationAuth == .authorizedAlways || locationAuth == .authorizedWhenInUse), forKey: "autoZoom")
        }
        self.settingsTable.reloadData()
    }
    
    @objc func switchChanged(_ sender : UISwitch!){
        switch sender.tag {
        //Map View
        case 0:
            userDefaults?.setValue(sender.isOn, forKey: "mapRotation")
            viewController?.webView.evaluateJavaScript("window.settings.injectSettings({\"mapRotation\": \(sender.isOn)});")
        case 1:
            userDefaults?.setValue(sender.isOn, forKey: "autoZoom")
            if (sender.isOn) {
                let locationAuth = CLLocationManager.authorizationStatus()
                if (locationAuth != .authorizedAlways && locationAuth != .authorizedWhenInUse) {
                    switch(CLLocationManager.authorizationStatus()) {
                    case .denied:
                        self.userDefaults?.setValue(false, forKey: "autoZoom")

                        let alertController = UIAlertController(title: NSLocalizedString("Location Permission Required",comment: "Alerts"), message: NSLocalizedString("In order to auto-zoom to your current location when opening meteocool, you need to allow access to your location.\n\nIn your device's Settings, set \"Location\" to \"Allow While Using\" to use this feature.",comment: "Alerts"), preferredStyle: UIAlertController.Style.alert)
                        alertController.addAction(UIAlertAction(title: NSLocalizedString("Allow in Settings",comment: "Alerts"), style: UIAlertAction.Style.default, handler: {_ in
                            if let url = NSURL(string: UIApplication.openSettingsURLString) as URL? {
                                UIApplication.shared.open(url, options: [:], completionHandler: {_ in
                                    self.alertWindow = nil
                                    self.enableZoomOnStartIfGranted = true
                                })
                            }
                        }
                        ))
                        alertController.addAction(UIAlertAction(title: NSLocalizedString("Disable Auto-Zoom",comment: "Alerts"), style: UIAlertAction.Style.default, handler: {_ in
                            self.settingsTable.reloadData()
                            self.alertWindow = nil
                        }
                        ))
                        
                        alertWindow = UIWindow(frame: UIScreen.main.bounds)
                        alertWindow?.rootViewController = UIViewController()
                        alertWindow?.windowLevel = UIWindow.Level.alert + 1;
                        alertWindow?.makeKeyAndVisible()
                        alertWindow?.rootViewController?.present(alertController, animated: true)
                        break;
                    case .notDetermined:
                        // XXX callback
                        SharedLocationUpdater.requestAuthorization({_,_ in self.settingsTable.reloadData()}, notDetermined: false)
                        break;
                    default:
                        break;
                    }
                }
            }
        //Layers
        case 10:
            userDefaults?.setValue(sender.isOn, forKey: "lightning")
            viewController?.webView.evaluateJavaScript("window.settings.injectSettings({\"layerLightning\": \(sender.isOn)});")
        case 11:
            userDefaults?.setValue(sender.isOn, forKey: "mesocyclones")
            viewController?.webView.evaluateJavaScript("window.settings.injectSettings({\"layerMesocyclones\": \(sender.isOn)});")
        case 12:
            userDefaults?.setValue(sender.isOn, forKey: "shelters")
        //Push Notification
        case 20:
            if (sender.isOn) {
                switch(CLLocationManager.authorizationStatus()) {
                case .notDetermined:
                    self.userDefaults?.setValue(true, forKey: "pushNotification")
                    SharedLocationUpdater.requestAuthorization({success,error in
                        if CLLocationManager.authorizationStatus() != .authorizedAlways {
                            self.userDefaults?.setValue(false, forKey: "pushNotification")
                            self.unregisterToken()
                        }
                        self.reload()
                    } , notDetermined: true)
                case .denied, .authorizedWhenInUse:
                    let alertController = UIAlertController(title: NSLocalizedString("Location Permission Required",comment: "Alerts"), message: NSLocalizedString("enable_background_location_alert",comment: "Alerts"), preferredStyle: UIAlertController.Style.alert)
                    
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("Change in Settings",comment: "Alerts"), style: UIAlertAction.Style.default, handler: {_ in
                        if let url = NSURL(string: UIApplication.openSettingsURLString) as URL? {
                            UIApplication.shared.open(url, options: [:], completionHandler: {_ in
                                self.userDefaults?.setValue(true, forKey: "pushNotification")
                                self.alertWindow = nil
                                
                                if let location = SharedLocationUpdater.getCurrentLocation(){
                                    SharedLocationUpdater.postLocation(location: location, pressure: -1)
                                }
                                SharedNotificationManager.registerForPushNotifications({_,_ in })
                            })
                        }
                    }
                    ))
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("Disable Notifications",comment: "Alerts"), style: UIAlertAction.Style.default, handler: {_ in
                        self.userDefaults?.setValue(false, forKey: "pushNotification")
                        self.unregisterToken()
                        self.settingsTable.reloadData()
                        self.alertWindow = nil
                    }
                    ))
                    
                    alertWindow = UIWindow(frame: UIScreen.main.bounds)
                    alertWindow?.rootViewController = UIViewController()
                    alertWindow?.windowLevel = UIWindow.Level.alert + 1;
                    alertWindow?.makeKeyAndVisible()
                    alertWindow?.rootViewController?.present(alertController, animated: true)
                    break;
                case .authorizedAlways:
                    self.userDefaults?.setValue(sender.isOn, forKey: "pushNotification")
                    settingsTable.reloadData()
                    if let location = SharedLocationUpdater.getCurrentLocation(){
                        SharedLocationUpdater.postLocation(location: location, pressure: -1)
                    }
                    SharedNotificationManager.registerForPushNotifications({_,_ in })
                    break;
                default:
                    break;
                }
            }
            else {
                userDefaults?.setValue(sender.isOn, forKey: "pushNotification")
                if let token = SharedNotificationManager.getToken() {
                    guard let request = NetworkHelper.createJSONPostRequest(dst: "unregister", dictionary: ["token": token] as [String: Any]) else{
                        print("Would unregister, but no token")
                        return
                    }
                    URLSession.shared.dataTask(with: request) { data, response, error in
                        guard let data = NetworkHelper.checkResponse(data: data, response: response, error: error) else {
                            return
                        }

                        if let json = ((try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]) as [String : Any]??) {
                            if let errorMessage = json?["error"] as? String {
                                NSLog("ERROR: \(errorMessage)")
                            }
                        }
                    }
                } else {
                    print("Would unregister, but no token")
                }
            }
            settingsTable.reloadData()
        case 21:
            userDefaults?.setValue(sender.isOn, forKey: "withDBZ")
            
            if let location = SharedLocationUpdater.getCurrentLocation(){
                SharedLocationUpdater.postLocation(location: location, pressure: -1)
            }
        //About
        case 34:
            userDefaults?.setValue(sender.isOn, forKey: "experimentalFeatures")

            let alertController = UIAlertController(title: NSLocalizedString("experimental_features",comment: "Settings"), message: NSLocalizedString("experimental_features_require_restart",comment: "Settings"), preferredStyle: UIAlertController.Style.alert)
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Dismiss",comment: "Dismiss"), style: UIAlertAction.Style.default, handler: {_ in
                self.alertWindow = nil
            }
            ))
            alertWindow = UIWindow(frame: UIScreen.main.bounds)
            alertWindow?.rootViewController = UIViewController()
            alertWindow?.windowLevel = UIWindow.Level.alert + 1;
            alertWindow?.makeKeyAndVisible()
            alertWindow?.rootViewController?.present(alertController, animated: true)

        default:
            print("This not happen: " + String(sender.tag))
        }
    }
    
    @objc func sliderChanged(_ sender: StepSlider!){
        switch sender.maxCount {
        case 5: //Intensity
            userDefaults?.setValue(sender.index, forKey: "intensityValue")
            // 0 -> drizzle
            // 1 -> light
            // 2 -> rain
            // 3 -> intense
            // 4 -> hail
            stepperSliderCellThreshold.stepperSliderValueLabel.text = intensity[(userDefaults?.integer(forKey: "intensityValue"))!]
            
            if let location = SharedLocationUpdater.getCurrentLocation(){
                SharedLocationUpdater.postLocation(location: location, pressure: -1)
            }
        case 9: //Time before
            userDefaults?.setValue(sender.index, forKey: "timeBeforeValue")
            //Value +1 *5 for minutes
            stepperSliderCellTime.stepperSliderValueLabel.text = String(((userDefaults?.integer(forKey: "timeBeforeValue"))!+1)*5) + " min"
            
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
    
    @objc func unregisterToken(){
        if let token = SharedNotificationManager.getToken()  {
            guard let request = NetworkHelper.createJSONPostRequest(dst: "unregister", dictionary: ["token": token] as [String: Any]) else{
                return
            }
            URLSession.shared.dataTask(with: request) { data, response, error in
                guard let data = NetworkHelper.checkResponse(data: data, response: response, error: error) else {
                    return
                }

                if let json = ((try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]) as [String : Any]??) {
                    if let errorMessage = json?["error"] as? String {
                        NSLog("ERROR: \(errorMessage)")
                    }
                }
            }
        }
    }
}
