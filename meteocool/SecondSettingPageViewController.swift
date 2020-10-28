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
    
    private var colorMaping = [
        NSLocalizedString("Classic", comment: "colorMaping"),
        NSLocalizedString("Viridis", comment: "colorMaping")
    ]
    
    //General View Things
    override func loadView() {
        super.loadView()
        self.view.addSubview(secondPageSettingsBar)
        self.view.addSubview(secondPageSettingsTable)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        secondPageSettingsTable.estimatedRowHeight = 100
        secondPageSettingsTable.rowHeight = 44
        secondPageSettingsTable.delegate = self
        secondPageSettingsTable.dataSource = self
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section{
        case 0:
            return 2
        default:
            return 0
        }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "colourMap",for: indexPath) as! ColourMapTableViewCell
        
        switch indexPath.row {
        case 0: //meteocool Classic
            cell.lable.text = colorMaping[indexPath.row]
            cell.checkbox.isHidden = (userDefaults?.bool(forKey: "colourMapClassic"))!
            //viewController?.webView.evaluateJavaScript()
        case 1: //Viridis
            cell.lable.text = colorMaping[indexPath.row]
            cell.checkbox.isHidden = (userDefaults?.bool(forKey: "colourMapViridis"))!
            //viewController?.webView.evaluateJavaScript()
        default:
            print("this not happen")
        }
        
        return cell

    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        
        if (indexPath.section == 0 && indexPath.row == 0){
            userDefaults?.setValue(false, forKey: "colourMapClassic")
            userDefaults?.setValue(true, forKey: "colourMapViridis")
        }
        if (indexPath.section == 0 && indexPath.row == 1){
            userDefaults?.setValue(false, forKey: "colourMapViridis")
            userDefaults?.setValue(true, forKey: "colourMapClassic")
        }
        secondPageSettingsTable.reloadData()
    }
    
    //Return Back with Save
    @IBAction func saveSettings(_ sender: Any){
        self.dismiss(animated: true,completion:nil)
        //ToDo Call the reloadData of the SettingsViewTable
    }
}
