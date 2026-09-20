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
    
    /// The basemaps the web map actually draws.
    ///
    /// All four come from meteocool's own Protomaps tiles
    /// (core's `src/layers/base.ts`); they differ in which features earn ink,
    /// not in provider. Satellite used to be a fifth option and is gone: the
    /// frontend withdrew the capability along with the OroraTech tiles it read.
    private var baseLayerMapping = [
        NSLocalizedString("light", comment: "baseLayer"),
        NSLocalizedString("dark", comment: "baseLayer"),
        NSLocalizedString("osm", comment: "baseLayer"),
        NSLocalizedString("cyclosm", comment: "baseLayer")
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
        if #available(iOS 26.0, *) {
            LiquidGlass.float(baseLayerMappingSettingsBar, over: baseLayerMappingSettingsTable, in: view)
        }
        baseLayerMappingSettingsTable.delegate = self
        baseLayerMappingSettingsTable.dataSource = self
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if #available(iOS 26.0, *) {
            LiquidGlass.inset(baseLayerMappingSettingsTable, below: baseLayerMappingSettingsBar)
        }
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
        case 0: //light
            cell.lable.text = baseLayerMapping[indexPath.row]
            cell.checkbox.isHidden = baseLayer != "light"
        case 1: //dark
            cell.lable.text = baseLayerMapping[indexPath.row]
            cell.checkbox.isHidden = baseLayer != "dark"
        case 2: //osm
            cell.lable.text = baseLayerMapping[indexPath.row]
            cell.checkbox.isHidden = baseLayer != "osm"
        case 3: //cyclosm
            cell.lable.text = baseLayerMapping[indexPath.row]
            cell.checkbox.isHidden = baseLayer != "cyclosm"
        default:
            break;
        }
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        if (indexPath.section == 0 && indexPath.row == 0){ //light
            baseLayer = "light"
        }
        if (indexPath.section == 0 && indexPath.row == 1){ //dark
            baseLayer = "dark"
        }
        if (indexPath.section == 0 && indexPath.row == 2){ //osm
            baseLayer = "osm"
        }
        if (indexPath.section == 0 && indexPath.row == 3){ //cyclosm
            baseLayer = "cyclosm"
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
