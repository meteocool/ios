//
//  SecoondSettingPageViewController.swift
//  meteocool
//
//  Created by Nina Loser on 27.10.20.
//

import UIKit

class BaseLayerMappingViewController: UIViewController, UITableViewDelegate, UITableViewDataSource{
    
    @IBOutlet weak var baseLayerMappingSettingsBar:UINavigationBar!
    @IBOutlet weak var baseLayerMappingList:UITableView!
    
    private let optionKeys = ["light", "dark", "osm", "cyclosm"]

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
        self.view.addSubview(baseLayerMappingList)
        baseLayer = userDefaults?.string(forKey: "baseLayer")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        baseLayerMappingList.register(UITableViewCell.self, forCellReuseIdentifier: "baseLayer")
        baseLayerMappingList.accessibilityIdentifier = "settings.options"
        if #available(iOS 26.0, *) {
            LiquidGlass.float(baseLayerMappingSettingsBar, over: baseLayerMappingList, in: view)
        }
        baseLayerMappingList.delegate = self
        baseLayerMappingList.dataSource = self
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if #available(iOS 26.0, *) {
            LiquidGlass.inset(baseLayerMappingList, below: baseLayerMappingSettingsBar)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return optionKeys.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "baseLayer", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = baseLayerMapping[indexPath.row]
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        let selected = optionKeys[indexPath.row] == baseLayer
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
        baseLayer = optionKeys[indexPath.row]
        tableView.reconfigureRows(at: optionKeys.indices.map { IndexPath(row: $0, section: 0) })
        tableView.deselectRow(at: indexPath, animated: true)
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
