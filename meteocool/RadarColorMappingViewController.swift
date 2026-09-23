//
//  SecoondSettingPageViewController.swift
//  meteocool
//
//  Created by Nina Loser on 27.10.20.
//

import UIKit

class RadarColorMappingViewController: UIViewController, UITableViewDelegate, UITableViewDataSource{
    
    @IBOutlet weak var radarColorMappingSettingsBar:UINavigationBar!
    @IBOutlet weak var radarColorMappingList:UITableView!
    
    private let optionKeys = ["classic", "nws", "pyart_stepseq", "homeyer", "lang"]

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

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        NSLocalizedString("colormap_explanation", comment: "radarColorMapping")
    }

    var colorMapping:String!
    
    //General View Things
    override func loadView() {
        super.loadView()
        self.view.addSubview(radarColorMappingSettingsBar)
        self.view.addSubview(radarColorMappingList)
        colorMapping = userDefaults?.string(forKey: "radarColorMapping")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        radarColorMappingList.register(UITableViewCell.self, forCellReuseIdentifier: "radarColorMapping")
        radarColorMappingList.accessibilityIdentifier = "settings.options"
        radarColorMappingList.delegate = self
        radarColorMappingList.dataSource = self
        if #available(iOS 26.0, *) {
            LiquidGlass.float(radarColorMappingSettingsBar, over: radarColorMappingList, in: view)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if #available(iOS 26.0, *) {
            LiquidGlass.inset(radarColorMappingList, below: radarColorMappingSettingsBar)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return optionKeys.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "radarColorMapping", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = radarColorMapping[indexPath.row]
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        let selected = optionKeys[indexPath.row] == colorMapping
        let checkmark = UIImage(systemName: "checkmark")!
        let accessory = UIImageView(frame: CGRect(origin: .zero, size: checkmark.size))
        // Reserve the symbol's width. UIKit manages accessory alpha during layout,
        // so represent an unchecked row with no image instead of transparency.
        accessory.image = selected ? checkmark : nil
        cell.accessoryView = accessory
        cell.accessibilityTraits = selected ? [.button, .selected] : [.button]
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        colorMapping = optionKeys[indexPath.row]
        tableView.reconfigureRows(at: optionKeys.indices.map { IndexPath(row: $0, section: 0) })
        tableView.deselectRow(at: indexPath, animated: true)
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
