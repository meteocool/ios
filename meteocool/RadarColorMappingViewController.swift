//
//  SecoondSettingPageViewController.swift
//  meteocool
//
//  Created by Nina Loser on 27.10.20.
//

import UIKit

class RadarColorMappingTableViewCell: UITableViewCell{
    @IBOutlet weak var lable: UILabel!
    @IBOutlet weak var checkbox: UIImageView!
}

class RadarColorMappingViewController: UIViewController, UITableViewDelegate, UITableViewDataSource{
    
    @IBOutlet weak var radarColorMappingSettingsBar:UINavigationBar!
    @IBOutlet weak var radarColorMappingSettingsTable:UITableView!
    
    //userDefaults
    let userDefaults = UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")
    
    //Content
    private var radarColorMapping = [
        NSLocalizedString("classic", comment: "radarColorMapping"),
        NSLocalizedString("nws", comment: "radarColorMapping"),
        NSLocalizedString("pyart_stepseq", comment: "radarColorMapping"),
        NSLocalizedString("homeyer", comment: "radarColorMapping"),
        NSLocalizedString("lang", comment: "radarColorMapping")
    ]

    // colormap explanation
    private var explainRadarColorMapping = [
        NSLocalizedString("colormap_explanation", comment: "radarColorMapping"),
    ]
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return explainRadarColorMapping[section]
    }
    
    var colorMapping:String!
    
    //General View Things
    override func loadView() {
        super.loadView()
        self.view.addSubview(radarColorMappingSettingsBar)
        self.view.addSubview(radarColorMappingSettingsTable)
        colorMapping = userDefaults?.string(forKey: "radarColorMapping")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        radarColorMappingSettingsTable.estimatedRowHeight = 100
        radarColorMappingSettingsTable.rowHeight = 44
        radarColorMappingSettingsTable.delegate = self
        radarColorMappingSettingsTable.dataSource = self
    }
    
    //Number of Rows
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section{
        case 0:
            return radarColorMapping.count
        default:
            return 0
        }
    }
    
    //Table Content
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "radarColorMapping",for: indexPath) as! RadarColorMappingTableViewCell
        
        switch indexPath.row {
        case 0: //meteocool Classic
            cell.lable.text = radarColorMapping[indexPath.row]
            cell.checkbox.isHidden = colorMapping != "classic"
        case 1: //nws
            cell.lable.text = radarColorMapping[indexPath.row]
            cell.checkbox.isHidden = colorMapping != "nws"
        case 2: //pyart stepseq
            cell.lable.text = radarColorMapping[indexPath.row]
            cell.checkbox.isHidden = colorMapping != "pyart_stepseq"
        case 3: //homeyer
            cell.lable.text = radarColorMapping[indexPath.row]
            cell.checkbox.isHidden = colorMapping != "homeyer"
        case 4: //lang
            cell.lable.text = radarColorMapping[indexPath.row]
            cell.checkbox.isHidden = colorMapping != "lang"
        default:
            print("this should not happen")
        }
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        
        if (indexPath.section == 0 && indexPath.row == 0){
            colorMapping = "classic"
        }
        if (indexPath.section == 0 && indexPath.row == 1){
            colorMapping = "nws"
        }
        if (indexPath.section == 0 && indexPath.row == 2){
            colorMapping = "pyart_stepseq"
        }
        if (indexPath.section == 0 && indexPath.row == 3){
            colorMapping = "homeyer"
        }
        if (indexPath.section == 0 && indexPath.row == 4){
            colorMapping = "lang"
        }
        radarColorMappingSettingsTable.reloadData()
    }
    
    //Return Back with Save
    @IBAction func saveSettings(_ sender: Any){
        self.dismiss(animated: true,completion:nil)
        userDefaults?.setValue(colorMapping, forKey: "radarColorMapping")
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }
    
    //Return Back without Save
    @IBAction func cancelSettings(_ sender: Any){
        self.dismiss(animated: true,completion:nil)
    }
}
