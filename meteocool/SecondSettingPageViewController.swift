//
//  SecoondSettingPageViewController.swift
//  meteocool
//
//  Created by Nina Loser on 27.10.20.
//  Copyright © 2020 Florian Mauracher. All rights reserved.
//

import UIKit

class ColourMapTableViewCell: UITableViewCell{
    @IBOutlet weak var lable: UILabel!
    @IBOutlet weak var checkbox: UIImageView!
}

class SecondSettingPageViewController: UIViewController, UITableViewDelegate, UITableViewDataSource{
    
    @IBOutlet weak var secondPageSettingsBar:UINavigationBar!
    @IBOutlet weak var secondPageSettingsTable:UITableView!
    
    //userDefaults
    let userDefaults = UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")
    
    //Content
    private var colorMaping = [
        NSLocalizedString("Classic", comment: "colorMaping"),
        NSLocalizedString("Viridis", comment: "colorMaping")
    ]
    
    var colourMapClassic:Bool!
    var colourMapViridis:Bool!
    
    //General View Things
    override func loadView() {
        super.loadView()
        self.view.addSubview(secondPageSettingsBar)
        self.view.addSubview(secondPageSettingsTable)
        colourMapClassic = (userDefaults?.bool(forKey: "colourMapClassic"))!
        colourMapViridis = (userDefaults?.bool(forKey: "colourMapViridis"))!
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
            return 2
        default:
            return 0
        }
    }
    
    //Table Content
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "colourMap",for: indexPath) as! ColourMapTableViewCell
        
        switch indexPath.row {
        case 0: //meteocool Classic
            cell.lable.text = colorMaping[indexPath.row]
            cell.checkbox.isHidden = colourMapClassic
            //viewController?.webView.evaluateJavaScript()
        case 1: //Viridis
            cell.lable.text = colorMaping[indexPath.row]
            cell.checkbox.isHidden = colourMapViridis
            //viewController?.webView.evaluateJavaScript()
        default:
            print("this not happen")
        }
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        
        if (indexPath.section == 0 && indexPath.row == 0){
            colourMapClassic = false
            colourMapViridis = true
        }
        if (indexPath.section == 0 && indexPath.row == 1){
            colourMapViridis = false
            colourMapClassic = true
        }
        secondPageSettingsTable.reloadData()
    }
    
    //Return Back with Save
    @IBAction func saveSettings(_ sender: Any){
        self.dismiss(animated: true,completion:nil)
        userDefaults?.setValue(colourMapClassic, forKey: "colourMapClassic")
        userDefaults?.setValue(colourMapViridis, forKey: "colourMapViridis")
        //ToDo Call the reloadData of the SettingsViewTable
    }
    
    //Return Back without Save
    @IBAction func cancelSettings(_ sender: Any){
        self.dismiss(animated: true,completion:nil)
    }
}
