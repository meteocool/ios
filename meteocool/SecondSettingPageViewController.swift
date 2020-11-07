//
//  SecoondSettingPageViewController.swift
//  meteocool
//
//  Created by Nina Loser on 27.10.20.
//

import UIKit

class RadarColorMapingTableViewCell: UITableViewCell{
    @IBOutlet weak var lable: UILabel!
    @IBOutlet weak var checkbox: UIImageView!
}

class SecondSettingPageViewController: UIViewController, UITableViewDelegate, UITableViewDataSource{
    
    @IBOutlet weak var secondPageSettingsBar:UINavigationBar!
    @IBOutlet weak var secondPageSettingsTable:UITableView!
    
    //userDefaults
    let userDefaults = UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")
    
    //Content
    private var radarColorMaping = [
        NSLocalizedString("classic", comment: "radarColorMaping"),
        NSLocalizedString("viridis", comment: "radarColorMaping")
    ]
    
    var colorMaping:String!
    
    //General View Things
    override func loadView() {
        super.loadView()
        self.view.addSubview(secondPageSettingsBar)
        self.view.addSubview(secondPageSettingsTable)
        print("test")
        colorMaping = userDefaults?.string(forKey: "radarColorMaping") //(userDefaults?.string(forKey: "radarColorMap") == "classic")
       // colorMapViridis = !colorMapClassic
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        secondPageSettingsTable.estimatedRowHeight = 100
        secondPageSettingsTable.rowHeight = 44
        secondPageSettingsTable.delegate = self
        secondPageSettingsTable.dataSource = self
    }
    
    //Number of Rows
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section{
        case 0:
            return radarColorMaping.count
        default:
            return 0
        }
    }
    
    //Table Content
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "radarColorMaping",for: indexPath) as! RadarColorMapingTableViewCell
        
        switch indexPath.row {
        case 0: //meteocool Classic
            cell.lable.text = radarColorMaping[indexPath.row]
            cell.checkbox.isHidden = colorMaping == "viridis"
        case 1: //Viridis
            cell.lable.text = radarColorMaping[indexPath.row]
            cell.checkbox.isHidden = colorMaping == "classic"
        default:
            print("this not happen")
        }
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        
        if (indexPath.section == 0 && indexPath.row == 0){ //Classic
            colorMaping = "classic"
        }
        if (indexPath.section == 0 && indexPath.row == 1){ //Viridis
            colorMaping = "viridis"
        }
        secondPageSettingsTable.reloadData()
    }
    
    //Return Back with Save
    @IBAction func saveSettings(_ sender: Any){
        self.dismiss(animated: true,completion:nil)
        userDefaults?.setValue(colorMaping, forKey: "radarColorMaping")
        //userDefaults?.setValue(colorMapClassic ? "viridis" : "classic", forKey: "radarColorMap")
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }
    
    //Return Back without Save
    @IBAction func cancelSettings(_ sender: Any){
        self.dismiss(animated: true,completion:nil)
    }
}
