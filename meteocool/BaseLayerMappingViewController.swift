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
    
    /// Same keys as the web's settings (core's `SettingsDialog.svelte`).
    /// "system" draws Light or Dark to match the appearance; the web map
    /// resolves it. Here it is a switch above the other four: while it is on,
    /// they are greyed out and cannot be picked.
    private let optionKeys = ["light", "dark", "osm", "cyclosm"]

    //userDefaults
    let userDefaults = UserDefaults.init(suiteName: "group.org.frcy.app.meteocool")

    /// The basemaps the web map draws.
    ///
    /// All four use meteocool's own Protomaps tiles (core's `src/layers/base.ts`)
    /// and differ only in which map features they draw.
    /// There is no Satellite option: the frontend removed it together with the OroraTech tiles it used.
    private var baseLayerMapping = [
        NSLocalizedString("light", comment: "baseLayer"),
        NSLocalizedString("dark", comment: "baseLayer"),
        NSLocalizedString("osm", comment: "baseLayer"),
        NSLocalizedString("cyclosm", comment: "baseLayer")
    ]

    var baseLayer:String!
    /// The basemap picked below the switch. Kept while the switch is on, so
    /// turning it off again returns to it.
    private var manualLayer = "light"

    private let matchSystem = UISwitch()

    //General View Things
    override func loadView() {
        super.loadView()
        self.view.addSubview(baseLayerMappingSettingsBar)
        self.view.addSubview(baseLayerMappingList)
        baseLayer = userDefaults?.string(forKey: "baseLayer") ?? "system"
        manualLayer = optionKeys.contains(baseLayer) ? baseLayer : resolvedSystemLayer
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        baseLayerMappingList.register(UITableViewCell.self, forCellReuseIdentifier: "baseLayer")
        baseLayerMappingList.accessibilityIdentifier = "settings.options"
        baseLayerMappingSettingsBar.topItem?.rightBarButtonItem?.accessibilityIdentifier = "picker.save"
        if #available(iOS 26.0, *) {
            LiquidGlass.float(baseLayerMappingSettingsBar, over: baseLayerMappingList, in: view)
        }
        matchSystem.addTarget(self, action: #selector(matchSystemChanged), for: .valueChanged)
        baseLayerMappingList.delegate = self
        baseLayerMappingList.dataSource = self
        // The switch's row names the basemap it currently resolves to.
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

    private var followsSystem: Bool { baseLayer == "system" }

    private var resolvedSystemLayer: String {
        traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
    }

    @objc private func matchSystemChanged() {
        baseLayer = matchSystem.isOn ? "system" : manualLayer
        baseLayerMappingList.reconfigureRows(at: optionKeys.indices.map { IndexPath(row: $0, section: 1) })
    }

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        NSLocalizedString(section == 0 ? "basemap_system_explanation" : "basemap_explanation", comment: "baseLayer")
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : optionKeys.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "baseLayer", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 0
        if indexPath.section == 0 {
            content.text = NSLocalizedString("system", comment: "baseLayer")
            content.secondaryText = String(format: NSLocalizedString("system_detail", comment: "baseLayer"),
                                           NSLocalizedString(resolvedSystemLayer, comment: "baseLayer"))
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            matchSystem.isOn = followsSystem
            matchSystem.accessibilityLabel = content.text
            cell.accessoryView = matchSystem
            cell.selectionStyle = .none
            cell.accessibilityTraits = []
            return cell
        }
        content.text = baseLayerMapping[indexPath.row]
        // Greyed out while the switch is on: the system picks Light or Dark.
        content.textProperties.color = followsSystem ? .tertiaryLabel : .label
        cell.contentConfiguration = content
        cell.selectionStyle = followsSystem ? .none : .default
        let selected = !followsSystem && optionKeys[indexPath.row] == baseLayer
        let checkmark = UIImage(systemName: "checkmark")!
        let accessory = UIImageView(frame: CGRect(origin: .zero, size: checkmark.size))
        // The accessory keeps the checkmark's width on every row.
        // An unchecked row gets no image, not alpha 0, because UIKit sets accessory alpha during layout.
        accessory.image = selected ? checkmark : nil
        cell.accessoryView = accessory
        var traits: UIAccessibilityTraits = selected ? [.button, .selected] : [.button]
        if followsSystem { traits.insert(.notEnabled) }
        cell.accessibilityTraits = traits
        return cell
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        indexPath.section == 1 && !followsSystem ? indexPath : nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        baseLayer = optionKeys[indexPath.row]
        manualLayer = baseLayer
        tableView.reconfigureRows(at: optionKeys.indices.map { IndexPath(row: $0, section: 1) })
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
