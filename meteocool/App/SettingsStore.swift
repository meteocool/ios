import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    struct Keys {
        static let suite = "group.org.frcy.app.meteocool"

        static let mapBaseLayer = "mapBaseLayer"
        static let displayStyle = "displayStyle"
        static let radarColorMapping = "radarColorMapping"
        static let layerLightning = "layerLightning"
        static let layerMesocyclones = "layerMesocyclones"
        static let layerSnow = "layerSnow"
        static let notificationsEnabled = "notificationsEnabled"
        static let motionSharingEnabled = "motionSharingEnabled"
        static let notificationShowDbz = "notificationShowDbz"
        static let notificationIntensity = "notificationIntensity"
        static let notificationTimeBefore = "notificationTimeBefore"
        static let mapRotation = "mapRotation"
        static let autoZoom = "autoZoom"
        static let experimentalFeatures = "experimentalFeatures"
        static let onboardingCompleted = "onboardingCompleted"

        // Legacy keys
        static let legacyBaseLayer = "baseLayer"
        static let legacyRadarColorMapping = "radarColorMapping"
        static let legacyLightning = "lightning"
        static let legacyMesocyclones = "mesocyclones"
        static let legacySnow = "snow"
        static let legacyPushNotification = "pushNotification"
        static let legacyPushEnabled = "pushEnabled"
        static let legacyWithDbz = "withDBZ"
        static let legacyIntensityValue = "intensityValue"
        static let legacyTimeBeforeValue = "timeBeforeValue"
        static let legacyMapRotation = "mapRotation"
        static let legacyAutoZoom = "autoZoom"
        static let legacyExperimentalFeatures = "experimentalFeatures"
        static let didMigrateBaseLayerToSystem = "didMigrateBaseLayerToSystem"
        static let legacyOnboardingDone = "onboardingDone"
    }

    let userDefaults: UserDefaults
    var mapBaseLayer: MapBaseLayer = .system {
        didSet { userDefaults.set(mapBaseLayer.rawValue, forKey: Keys.mapBaseLayer) }
    }
    var displayStyle: DisplayStyle = .system {
        didSet { userDefaults.set(displayStyle.rawValue, forKey: Keys.displayStyle) }
    }
    var radarColorMapping: RadarColorMapping = .classic {
        didSet { userDefaults.set(radarColorMapping.rawValue, forKey: Keys.radarColorMapping) }
    }
    var layerLightning: Bool = true {
        didSet { userDefaults.set(layerLightning, forKey: Keys.layerLightning) }
    }
    var layerMesocyclones: Bool = true {
        didSet { userDefaults.set(layerMesocyclones, forKey: Keys.layerMesocyclones) }
    }
    var layerSnow: Bool = true {
        didSet { userDefaults.set(layerSnow, forKey: Keys.layerSnow) }
    }
    var notificationsEnabled: Bool = false {
        didSet { userDefaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }
    var motionSharingEnabled: Bool = false {
        didSet { userDefaults.set(motionSharingEnabled, forKey: Keys.motionSharingEnabled) }
    }
    var notificationShowDbz: Bool = false {
        didSet { userDefaults.set(notificationShowDbz, forKey: Keys.notificationShowDbz) }
    }
    var notificationIntensity: Int = 1 {
        didSet { userDefaults.set(notificationIntensity, forKey: Keys.notificationIntensity) }
    }
    var notificationTimeBefore: Int = 2 {
        didSet { userDefaults.set(notificationTimeBefore, forKey: Keys.notificationTimeBefore) }
    }
    var mapRotation: Bool = false {
        didSet { userDefaults.set(mapRotation, forKey: Keys.mapRotation) }
    }
    var autoZoom: Bool = false {
        didSet { userDefaults.set(autoZoom, forKey: Keys.autoZoom) }
    }
    var experimentalFeatures: Bool = false {
        didSet { userDefaults.set(experimentalFeatures, forKey: Keys.experimentalFeatures) }
    }
    var onboardingCompleted: Bool = false {
        didSet { userDefaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted) }
    }

    init(userDefaults: UserDefaults = UserDefaults(suiteName: Keys.suite) ?? .standard) {
        self.userDefaults = userDefaults
        registerDefaultsIfNeeded()
        migrateLegacyKeysIfNeeded()
        mapBaseLayer = MapBaseLayer(rawValue: userDefaults.string(forKey: Keys.mapBaseLayer) ?? "") ?? .system
        displayStyle = DisplayStyle(rawValue: userDefaults.string(forKey: Keys.displayStyle) ?? "") ?? .system
        radarColorMapping = RadarColorMapping(rawValue: userDefaults.string(forKey: Keys.radarColorMapping) ?? "") ?? .classic
        layerLightning = userDefaults.bool(forKey: Keys.layerLightning)
        layerMesocyclones = userDefaults.bool(forKey: Keys.layerMesocyclones)
        layerSnow = userDefaults.bool(forKey: Keys.layerSnow)
        notificationsEnabled = userDefaults.bool(forKey: Keys.notificationsEnabled)
        motionSharingEnabled = userDefaults.bool(forKey: Keys.motionSharingEnabled)
        notificationShowDbz = userDefaults.bool(forKey: Keys.notificationShowDbz)
        notificationIntensity = userDefaults.integer(forKey: Keys.notificationIntensity)
        notificationTimeBefore = userDefaults.integer(forKey: Keys.notificationTimeBefore)
        mapRotation = userDefaults.bool(forKey: Keys.mapRotation)
        autoZoom = userDefaults.bool(forKey: Keys.autoZoom)
        experimentalFeatures = userDefaults.bool(forKey: Keys.experimentalFeatures)
        onboardingCompleted = userDefaults.bool(forKey: Keys.onboardingCompleted)
    }

    private func registerDefaultsIfNeeded() {
        if userDefaults.object(forKey: Keys.mapBaseLayer) == nil,
           userDefaults.object(forKey: Keys.legacyBaseLayer) == nil { userDefaults.set(MapBaseLayer.system.rawValue, forKey: Keys.mapBaseLayer) }
        if userDefaults.object(forKey: Keys.radarColorMapping) == nil,
           userDefaults.object(forKey: Keys.legacyRadarColorMapping) == nil { userDefaults.set(RadarColorMapping.classic.rawValue, forKey: Keys.radarColorMapping) }
        if userDefaults.object(forKey: Keys.layerLightning) == nil,
           userDefaults.object(forKey: Keys.legacyLightning) == nil { userDefaults.set(true, forKey: Keys.layerLightning) }
        if userDefaults.object(forKey: Keys.layerMesocyclones) == nil,
           userDefaults.object(forKey: Keys.legacyMesocyclones) == nil { userDefaults.set(true, forKey: Keys.layerMesocyclones) }
        if userDefaults.object(forKey: Keys.layerSnow) == nil,
           userDefaults.object(forKey: Keys.legacySnow) == nil { userDefaults.set(true, forKey: Keys.layerSnow) }
        if userDefaults.object(forKey: Keys.notificationsEnabled) == nil,
           userDefaults.object(forKey: Keys.legacyPushNotification) == nil,
           userDefaults.object(forKey: Keys.legacyPushEnabled) == nil { userDefaults.set(false, forKey: Keys.notificationsEnabled) }
        if userDefaults.object(forKey: Keys.motionSharingEnabled) == nil { userDefaults.set(false, forKey: Keys.motionSharingEnabled) }
        if userDefaults.object(forKey: Keys.notificationShowDbz) == nil,
           userDefaults.object(forKey: Keys.legacyWithDbz) == nil { userDefaults.set(false, forKey: Keys.notificationShowDbz) }
        if userDefaults.object(forKey: Keys.notificationIntensity) == nil,
           userDefaults.object(forKey: Keys.legacyIntensityValue) == nil { userDefaults.set(1, forKey: Keys.notificationIntensity) }
        if userDefaults.object(forKey: Keys.notificationTimeBefore) == nil,
           userDefaults.object(forKey: Keys.legacyTimeBeforeValue) == nil { userDefaults.set(2, forKey: Keys.notificationTimeBefore) }
        if userDefaults.object(forKey: Keys.mapRotation) == nil,
           userDefaults.object(forKey: Keys.legacyMapRotation) == nil { userDefaults.set(false, forKey: Keys.mapRotation) }
        if userDefaults.object(forKey: Keys.autoZoom) == nil,
           userDefaults.object(forKey: Keys.legacyAutoZoom) == nil { userDefaults.set(false, forKey: Keys.autoZoom) }
        if userDefaults.object(forKey: Keys.experimentalFeatures) == nil,
           userDefaults.object(forKey: Keys.legacyExperimentalFeatures) == nil { userDefaults.set(false, forKey: Keys.experimentalFeatures) }
        if userDefaults.object(forKey: Keys.onboardingCompleted) == nil,
           userDefaults.object(forKey: Keys.legacyOnboardingDone) == nil { userDefaults.set(false, forKey: Keys.onboardingCompleted) }
    }

    func migrateLegacyKeysIfNeeded() {
        if userDefaults.object(forKey: Keys.displayStyle) == nil {
            let legacy = userDefaults.string(forKey: Keys.mapBaseLayer)
            if legacy == DisplayStyle.light.rawValue || legacy == DisplayStyle.dark.rawValue || legacy == DisplayStyle.system.rawValue {
                userDefaults.set(legacy, forKey: Keys.displayStyle)
                userDefaults.set(MapBaseLayer.system.rawValue, forKey: Keys.mapBaseLayer)
            }
        }
        if userDefaults.object(forKey: Keys.mapBaseLayer) == nil {
            if let value = userDefaults.string(forKey: Keys.legacyBaseLayer) {
                if MapBaseLayer(rawValue: value) != nil {
                    userDefaults.set(value, forKey: Keys.mapBaseLayer)
                }
            } else {
                userDefaults.set(MapBaseLayer.system.rawValue, forKey: Keys.mapBaseLayer)
            }
        }
        if !userDefaults.bool(forKey: Keys.didMigrateBaseLayerToSystem),
           userDefaults.string(forKey: Keys.mapBaseLayer) == DisplayStyle.light.rawValue {
            userDefaults.set(MapBaseLayer.system.rawValue, forKey: Keys.mapBaseLayer)
            userDefaults.set(true, forKey: Keys.didMigrateBaseLayerToSystem)
        }
        if userDefaults.object(forKey: Keys.radarColorMapping) == nil,
           let value = userDefaults.string(forKey: Keys.legacyRadarColorMapping) {
            if RadarColorMapping(rawValue: value) != nil {
                userDefaults.set(value, forKey: Keys.radarColorMapping)
            }
        }
        if userDefaults.object(forKey: Keys.layerLightning) == nil,
           userDefaults.object(forKey: Keys.legacyLightning) != nil {
            userDefaults.set(userDefaults.bool(forKey: Keys.legacyLightning), forKey: Keys.layerLightning)
        }
        if userDefaults.object(forKey: Keys.layerMesocyclones) == nil,
           userDefaults.object(forKey: Keys.legacyMesocyclones) != nil {
            userDefaults.set(userDefaults.bool(forKey: Keys.legacyMesocyclones), forKey: Keys.layerMesocyclones)
        }
        if userDefaults.object(forKey: Keys.layerSnow) == nil,
           userDefaults.object(forKey: Keys.legacySnow) != nil {
            userDefaults.set(userDefaults.bool(forKey: Keys.legacySnow), forKey: Keys.layerSnow)
        }
        if userDefaults.object(forKey: Keys.notificationsEnabled) == nil {
            if userDefaults.object(forKey: Keys.legacyPushNotification) != nil {
                userDefaults.set(userDefaults.bool(forKey: Keys.legacyPushNotification), forKey: Keys.notificationsEnabled)
            } else if userDefaults.object(forKey: Keys.legacyPushEnabled) != nil {
                userDefaults.set(userDefaults.bool(forKey: Keys.legacyPushEnabled), forKey: Keys.notificationsEnabled)
            }
        }
        if userDefaults.object(forKey: Keys.notificationShowDbz) == nil,
           userDefaults.object(forKey: Keys.legacyWithDbz) != nil {
            userDefaults.set(userDefaults.bool(forKey: Keys.legacyWithDbz), forKey: Keys.notificationShowDbz)
        }
        if userDefaults.object(forKey: Keys.notificationIntensity) == nil,
           userDefaults.object(forKey: Keys.legacyIntensityValue) != nil {
            userDefaults.set(userDefaults.integer(forKey: Keys.legacyIntensityValue), forKey: Keys.notificationIntensity)
        }
        if userDefaults.object(forKey: Keys.notificationTimeBefore) == nil,
           userDefaults.object(forKey: Keys.legacyTimeBeforeValue) != nil {
            userDefaults.set(userDefaults.integer(forKey: Keys.legacyTimeBeforeValue), forKey: Keys.notificationTimeBefore)
        }
        if userDefaults.object(forKey: Keys.mapRotation) == nil,
           userDefaults.object(forKey: Keys.legacyMapRotation) != nil {
            userDefaults.set(userDefaults.bool(forKey: Keys.legacyMapRotation), forKey: Keys.mapRotation)
        }
        if userDefaults.object(forKey: Keys.autoZoom) == nil,
           userDefaults.object(forKey: Keys.legacyAutoZoom) != nil {
            userDefaults.set(userDefaults.bool(forKey: Keys.legacyAutoZoom), forKey: Keys.autoZoom)
        }
        if userDefaults.object(forKey: Keys.experimentalFeatures) == nil,
           userDefaults.object(forKey: Keys.legacyExperimentalFeatures) != nil {
            userDefaults.set(userDefaults.bool(forKey: Keys.legacyExperimentalFeatures), forKey: Keys.experimentalFeatures)
        }
        if userDefaults.object(forKey: Keys.onboardingCompleted) == nil,
           userDefaults.object(forKey: Keys.legacyOnboardingDone) != nil {
            userDefaults.set(userDefaults.bool(forKey: Keys.legacyOnboardingDone), forKey: Keys.onboardingCompleted)
        }
        if userDefaults.object(forKey: Keys.displayStyle) == nil {
            userDefaults.set(DisplayStyle.system.rawValue, forKey: Keys.displayStyle)
        }
    }

    // Stored properties above now drive Observation. UserDefaults is kept in sync via didSet.
}
