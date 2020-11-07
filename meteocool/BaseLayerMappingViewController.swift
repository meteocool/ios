//
//  SecoondSettingPageViewController.swift
//  meteocool
//
//  Created by Nina Loser on 27.10.20.
//

import UIKit

class BaseLayerMappingTableViewCell: UITableViewCell{
    @IBOutlet weak var lable: UILabel!
    @IBOutlet weak var checkbox: UIImageView!
}

class BaseLayerMappingViewController: UIViewController, UITableViewDelegate, UITableViewDataSource{
    
    @IBOutlet weak var baseLayerMappingSettingsBar:UINavigationBar!
    @IBOutlet weak var baseLayerMappingSettingsTable:UITableView!
    
    //userDefaults
    let userDefaults = UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")
    
    //Content
    private var baseLayerMapping = [
        NSLocalizedString("topographic", comment: "baseLayer"),
        NSLocalizedString("dark", comment: "baseLayer"),
        NSLocalizedString("light", comment: "baseLayer")
    ]
    
    var baseLayer:String!
    
    //General View Things
    override func loadView() {
        super.loadView()
        self.view.addSubview(baseLayerMappingSettingsBar)
        self.view.addSubview(baseLayerMappingSettingsTable)
        baseLayer = userDefaults?.string(forKey: "baseLayer")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        baseLayerMappingSettingsTable.estimatedRowHeight = 100
        baseLayerMappingSettingsTable.rowHeight = 44
        baseLayerMappingSettingsTable.delegate = self
        baseLayerMappingSettingsTable.dataSource = self
    }
    
    //Number of Rows
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section{
        case 0:
            return baseLayerMapping.count
        default:
            return 0
        }
    }
    
    //Table Content
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "baseLayer",for: indexPath) as! BaseLayerMappingTableViewCell
        
        
        
        switch indexPath.row {
        case 0: //topographic
            cell.lable.text = baseLayerMapping[indexPath.row]
            cell.checkbox.isHidden = (baseLayer == "dark" || baseLayer == "light")
        case 1: //dark
            cell.lable.text = baseLayerMapping[indexPath.row]
            cell.checkbox.isHidden = (baseLayer == "topographic" || baseLayer == "light")
        case 2: //light
            cell.lable.text = baseLayerMapping[indexPath.row]
            cell.checkbox.isHidden = (baseLayer == "topographic" || baseLayer == "dark")
        default:
            print("this not happen")
        }
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        
        if (indexPath.section == 0 && indexPath.row == 0){ //topographic
            baseLayer = "topographic"
        }
        if (indexPath.section == 0 && indexPath.row == 1){ //dark
            baseLayer = "dark"
        }
        if (indexPath.section == 0 && indexPath.row == 2){ //light
            baseLayer = "light"
        }
        baseLayerMappingSettingsTable.reloadData()
    }
    
    //Return Back with Save
    @IBAction func saveSettings(_ sender: Any){
        self.dismiss(animated: true,completion:nil)
        userDefaults?.setValue(baseLayer, forKey: "baseLayer")
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }
    
    //Return Back without Save
    @IBAction func cancelSettings(_ sender: Any){
        self.dismiss(animated: true,completion:nil)
    }
}
