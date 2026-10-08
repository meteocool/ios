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
        radarColorMappingSettingsBar.topItem?.rightBarButtonItem?.accessibilityIdentifier = "picker.save"
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
        content.image = Self.colorBar(optionKeys[indexPath.row], traits: tableView.traitCollection)
        content.imageProperties.reservedLayoutSize = Self.barSize
        cell.contentConfiguration = content
        let selected = optionKeys[indexPath.row] == colorMapping
        let checkmark = UIImage(systemName: "checkmark")!
        let accessory = UIImageView(frame: CGRect(origin: .zero, size: checkmark.size))
        // The accessory keeps the checkmark's width on every row.
        // An unchecked row gets no image, not alpha 0, because UIKit sets accessory alpha during layout.
        accessory.image = selected ? checkmark : nil
        cell.accessoryView = accessory
        cell.accessibilityTraits = selected ? [.button, .selected] : [.button]
        return cell
    }

    /// Size of the colour bar in front of each option's name.
    private static let barSize = CGSize(width: 88, height: 14)
    /// The bar runs from drizzle on the left to hail on the right, in dBZ.
    private static let barRange = 5.0...65.0

    /// The palette's colours across `barRange`, as the map draws them.
    /// Steps below the palette's first entry stay transparent, as on the map.
    private static func colorBar(_ palette: String, traits: UITraitCollection) -> UIImage {
        let size = barSize
        let format = UIGraphicsImageRendererFormat(for: traits)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: size)
            let shape = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4)
            shape.addClip()
            let steps = Int(size.width * format.scale)
            let stepWidth = size.width / CGFloat(steps)
            for step in 0..<steps {
                let fraction = (Double(step) + 0.5) / Double(steps)
                let dbz = barRange.lowerBound + fraction * (barRange.upperBound - barRange.lowerBound)
                guard let rgb = RadarPalette.colour(dbz: dbz, palette: palette) else { continue }
                UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1).setFill()
                context.fill(CGRect(x: CGFloat(step) * stepWidth, y: 0, width: stepWidth + 0.5, height: size.height))
            }
            // An outline keeps the pale low end visible on a light background.
            UIColor.separator.resolvedColor(with: traits).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        colorMapping = optionKeys[indexPath.row]
        tableView.reconfigureRows(at: optionKeys.indices.map { IndexPath(row: $0, section: 0) })
        tableView.deselectRow(at: indexPath, animated: true)
    }

    //Return Back with the checkmark (saves)
    @IBAction func saveSettings(_ sender: Any){
        self.dismiss(animated: true,completion:nil)
        userDefaults?.setValue(colorMapping, forKey: "radarColorMapping")
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }
    
    //Return Back without saving
    @IBAction func cancelSettings(_ sender: Any){
        self.dismiss(animated: true,completion:nil)
    }
}
