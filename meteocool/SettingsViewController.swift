//
//  SettingsController.swift
//  meteocool
//
//  Created by Nina Loser on 30.01.20.
//  Copyright © 2020 Florian Mauracher. All rights reserved.
//
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
    
    //Content
    private var header = [
        NSLocalizedString("Map View", comment: "header"),
        NSLocalizedString("Layers", comment: "header"),
        NSLocalizedString("Push Notification", comment: "header"),
        NSLocalizedString("About", comment: "header")
    ]
    private var footer = [
        NSLocalizedString("Customize the appearance and behavior of the main map.", comment: "footer"),
        NSLocalizedString("Enable or disable informational layers on the main map.", comment: "footer"),
        NSLocalizedString("If you want, we can notify you ahead of rain or snow at your current location.", comment: "footer"),
        NSLocalizedString("Version: 2.0\n\nData Providers:\n© DWD © blitzortung.org © Contains Modified Copernicus Sentinel Data (2020)\n\nMap Providers:\n© OpenStreetMap Contributors © CARTO © MapTiler © Who's On First © Natural Earth", comment: "footer")
    ]
    private var dataPushNotification = [
        NSLocalizedString("Push Notifications", comment: "dataPushNotification"),
        NSLocalizedString("Include Meteorological Details", comment: "dataPushNotification"),
        NSLocalizedString("Intensity Threshold", comment: "dataPushNotification"),
        NSLocalizedString("Notification Timeframe", comment: "dataPushNotification")
    ]
    private var dataMapView = [
        NSLocalizedString("Map Rotation", comment: "dataMapView"),
        NSLocalizedString("Auto-Zoom After Start", comment: "dataMapView"),
        NSLocalizedString("Base Layer", comment: "dataMapView"),
        NSLocalizedString("Color Map", comment: "dataMapView")
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
        NSLocalizedString("Push Token", comment: "dataAboutLabel"),
        NSLocalizedString("Privacy Policy", comment: "dataAboutLabel")
    ]
    private var intensity = [
        NSLocalizedString("Drizzle", comment: "intensity"),
        NSLocalizedString("Light rain", comment: "intensity"),
        NSLocalizedString("Rain", comment: "intensity"),
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
            return NSLocalizedString("Show Meteorological Details:\nFor advanced users, include meteorological details in the notification text (like dBZ values). \n\nThreshold:\nOnly send a notification if incoming precipitation is expected to be at least this intense. \n\nNotification Timeframe:\nChange the amount of time before you want to be notified about precipitation.",comment: "selection Footer")
        }
        return footer[section]
    }
    
    //Table Content
    func tableView(_ tableView: UITableView,cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // kind of cells
        let switcherCell = tableView.dequeueReusableCell(withIdentifier: "switcherCell") as! SwitcherTableViewCell
        let textCell = tableView.dequeueReusableCell(withIdentifier: "textCell") as! TextTableViewCell
        let stepperSliderCell = tableView.dequeueReusableCell(withIdentifier: "stepperSliderCell") as! StepperTableViewCell
        let linkCell = tableView.dequeueReusableCell(withIdentifier: "linkCell") as! LinkTableViewCell
        
        // StepperSlider
        let stepperSliderView = StepSlider.init(frame: CGRect(x: 15.0,y: 50.0,width: tableView.frame.width-30,height: 50.0))
        stepperSliderView.sliderCircleColor = UIColor(red: 233/255, green: 233/255, blue: 235/255, alpha: 1.0)
        stepperSliderView.labelColor = UIColor(red: 0, green: 0, blue: 0, alpha: 1.0)
        
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
            }
        case 2: //Push Notification
            switch indexPath.row {
            case 0: //Notificatino On/Off
                switcherCell.switcherInfoLabel.text = dataPushNotification[indexPath.row]
                switcherCell.switcher.setOn((userDefaults?.bool(forKey: "pushNotification"))!, animated: false)
                switcherCell.switcher.tag = Int(String(indexPath.section)+String(indexPath.row))!
                switcherCell.switcher.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
                return switcherCell
            case 1: //with dbZ
                switcherCell.switcherInfoLabel.text = dataPushNotification[indexPath.row]
                switcherCell.switcher.setOn((userDefaults?.bool(forKey: "withDBZ"))!, animated: false)
                switcherCell.switcher.tag = Int(String(indexPath.section)+String(indexPath.row))!
                switcherCell.switcher.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
                return switcherCell
            case 2: //Intensity, Threshold
                stepperSliderCell.addSubview(stepperSliderView)
                stepperSliderView.maxCount = UInt(intensity.count)
                stepperSliderView.index = UInt.init(bitPattern: (userDefaults?.integer(forKey: "intensityValue"))!)
                
                stepperSliderCell.stepperSliderInfoLabel.text = dataPushNotification[indexPath.row]
                stepperSliderCell.stepperSliderValueLabel.text = intensity[(userDefaults?.integer(forKey: "intensityValue"))!]
                
                stepperSliderView.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
                
                return stepperSliderCell
            case 3: //Time before
                stepperSliderCell.addSubview(stepperSliderView)
                stepperSliderView.maxCount = 9
                stepperSliderView.index = UInt.init(bitPattern: (userDefaults?.integer(forKey: "timeBeforeValue"))!)
                
                stepperSliderCell.stepperSliderInfoLabel.text = dataPushNotification[indexPath.row]
                stepperSliderCell.stepperSliderValueLabel.text = String(((userDefaults?.integer(forKey: "timeBeforeValue"))!+1)*5) + " min"
                
                stepperSliderView.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
                
                return stepperSliderCell
            default:
                print("This should not happen...")
            }
        case 3: //About
            switch indexPath.row {
            case 3: //Push Token
                textCell.textInfoLabel.text = dataAboutLabel[indexPath.row]
                textCell.textValueLabel.text = SharedNotificationManager.getToken() ?? "Not Enabled"
                // XXX localize
                return textCell
                
            default: //Feedack and Links to Websides
                linkCell.linkInfoLable.text = dataAboutLabel[indexPath.row]
                linkCell.linkValueLable.text = ""
                return linkCell
            }
        default:
            print("This should not happen...")
        }
        
        return textCell
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
            if let url = URL(string: "https://twitter.com/meteocool_de") {
                UIApplication.shared.open(url)
            }
        }
        if (indexPath.section == 3 && indexPath.row == 2){ //Feedback
            let mailAdress = "support@meteocool.com"
            let token = SharedNotificationManager.getToken() ?? "no-token"
            if let url = URL(string: "mailto:\(mailAdress)?subject=suggestions&body=token=\(token)") {
                UIApplication.shared.open(url)
            }
        }
        if (indexPath.section == 3 && indexPath.row == 4){
            if let url = URL(string: "https://meteocool.com/privacy.html") {
                UIApplication.shared.open(url)
            }
        }
    }
    
    var alertWindow: UIWindow?
    
    @objc func switchChanged(_ sender : UISwitch!){
        switch sender.tag {
        //Map View
        case 0:
            userDefaults?.setValue(sender.isOn, forKey: "mapRotation")
            print("window.inject1ngs({\"mapRotation\": \(sender.isOn)});")
            viewController?.webView.evaluateJavaScript("window.settings.injectSettings({\"mapRotation\": \(sender.isOn)});")
        case 1:
            userDefaults?.setValue(sender.isOn, forKey: "autoZoom")
            viewController?.webView.evaluateJavaScript("window.injectSettings({\"zoomOnForeground\": \(sender.isOn)});")
        //Layers
        case 10:
            userDefaults?.setValue(sender.isOn, forKey: "lightning")
            viewController?.webView.evaluateJavaScript("window.injectSettings({\"layerLightning\": \(sender.isOn)});")
        case 11:
            userDefaults?.setValue(sender.isOn, forKey: "mesocyclones")
            viewController?.webView.evaluateJavaScript("window.injectSettings({\"layerMesocyclones\": \(sender.isOn)});")
        case 12:
            userDefaults?.setValue(sender.isOn, forKey: "shelters")
        //viewController?.webView.evaluateJavaScript("window.injectSettings({\"layerShelters\": \(sender.isOn)});")
        //Push Notification
        case 20:
            if (!sender.isOn) {
                userDefaults?.setValue(false, forKey: "pushNotification")
                return
            }
            switch(CLLocationManager.authorizationStatus()) {
            case .denied, .authorizedWhenInUse, .notDetermined:
                let alertController = UIAlertController(title: "Location Permission Required", message: "In order to check your current location for upcoming rain while you're not using the app, background location access is required.\n\nIn your device's Settings, set \"Location\" to \"Always\" to enable notifications.", preferredStyle: UIAlertController.Style.alert)
                
                alertController.addAction(UIAlertAction(title: "Change in Settings", style: UIAlertAction.Style.default, handler: {_ in
                    if let url = NSURL(string: UIApplication.openSettingsURLString) as URL? {
                        UIApplication.shared.open(url, options: [:], completionHandler: {_ in
                            self.userDefaults?.setValue(true, forKey: "pushNotification")
                            self.alertWindow = nil
                        })
                    }
                }
                ))
                alertController.addAction(UIAlertAction(title: "Disable Notifications", style: UIAlertAction.Style.default, handler: {_ in
                    self.userDefaults?.setValue(false, forKey: "pushNotification")
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
                userDefaults?.setValue(sender.isOn, forKey: "pushNotification")
                settingsTable.reloadData()
                break;
            default:
                break;
            }
        case 22:
            userDefaults?.setValue(sender.isOn, forKey: "withDBZ")
        default:
            print("This not happen")
        }
    }
    
    @objc func sliderChanged(_ sender: StepSlider!){
        switch sender.maxCount {
        case 4: //Intensity
            userDefaults?.setValue(sender.index, forKey: "intensityValue")
        // 0 -> any
        // 1 -> light
        // 2 -> normal
        // 3 -> heavy
        case 9: //Time before
            userDefaults?.setValue(sender.index, forKey: "timeBeforeValue")
        //Value +1 *5 for minutes
        default:
            print ("This not happen")
        }
        settingsTable.reloadData()
    }
    
    @objc func reload(){
        settingsTable.reloadData()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
