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
        NSLocalizedString("viridis", comment: "radarColorMapping")
    ]

    // colormap explanation
    private var explainRadarColorMapping = [
        NSLocalizedString("Change the colormap to change the color scheme of the precipitation-visualization on the map.", comment: "radarColorMapping"),
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
            cell.checkbox.isHidden = colorMapping == "viridis"
        case 1: //Viridis
            cell.lable.text = radarColorMapping[indexPath.row]
            cell.checkbox.isHidden = colorMapping == "classic"
        default:
            print("this not happen")
        }
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        
        if (indexPath.section == 0 && indexPath.row == 0){ //Classic
            colorMapping = "classic"
        }
        if (indexPath.section == 0 && indexPath.row == 1){ //Viridis
            colorMapping = "viridis"
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
