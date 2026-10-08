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
    
    /// Same keys and order as the web's settings (core's `SettingsDialog.svelte`).
    /// "system" draws Light or Dark to match the appearance. The web map resolves it.
    private let optionKeys = ["system", "light", "dark", "osm", "cyclosm"]

    //userDefaults
    let userDefaults = UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")

    /// The basemaps the web map draws.
    ///
    /// All four use meteocool's own Protomaps tiles (core's `src/layers/base.ts`)
    /// and differ only in which map features they draw.
    /// There is no Satellite option: the frontend removed it together with the OroraTech tiles it used.
    private var baseLayerMapping = [
        NSLocalizedString("system", comment: "baseLayer"),
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
        baseLayerMappingSettingsBar.topItem?.rightBarButtonItem?.accessibilityIdentifier = "picker.save"
        if #available(iOS 26.0, *) {
            LiquidGlass.float(baseLayerMappingSettingsBar, over: baseLayerMappingList, in: view)
        }
        baseLayerMappingList.delegate = self
        baseLayerMappingList.dataSource = self
        // The "system" row names the basemap it currently resolves to.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            self.baseLayerMappingList.reconfigureRows(at: [IndexPath(row: 0, section: 0)])
        }
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
        if optionKeys[indexPath.row] == "system" {
            let resolved = traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
            content.secondaryText = String(format: NSLocalizedString("system_detail", comment: "baseLayer"),
                                           NSLocalizedString(resolved, comment: "baseLayer"))
            content.secondaryTextProperties.color = .secondaryLabel
        }
        cell.contentConfiguration = content
        let selected = optionKeys[indexPath.row] == baseLayer
        let checkmark = UIImage(systemName: "checkmark")!
        let accessory = UIImageView(frame: CGRect(origin: .zero, size: checkmark.size))
        // The accessory keeps the checkmark's width on every row.
        // An unchecked row gets no image, not alpha 0, because UIKit sets accessory alpha during layout.
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

    //Return Back with the checkmark (saves)
    @IBAction func saveSettings(_ sender: Any){
        self.dismiss(animated: true,completion:nil)
        userDefaults?.setValue(baseLayer, forKey: "baseLayer")
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }
    
    //Return Back without saving
    @IBAction func cancelSettings(_ sender: Any){
        self.dismiss(animated: true,completion:nil)
    }
}
