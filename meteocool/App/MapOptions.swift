import Foundation

enum MapBaseLayer: String, CaseIterable, Identifiable {
    case system
    case cyclosm

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .system:
            return "base_layer_standard"
        case .cyclosm:
            return "base_layer_cyclosm"
        }
    }

    var localizedLabel: String {
        NSLocalizedString(labelKey, comment: "")
    }
}

enum RadarColorMapping: String, CaseIterable, Identifiable {
    case classic
    case nws
    case pyartStepseq = "pyart_stepseq"
    case homeyer
    case lang

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .classic:
            return "classic"
        case .nws:
            return "nws"
        case .pyartStepseq:
            return "pyart_stepseq"
        case .homeyer:
            return "homeyer"
        case .lang:
            return "lang"
        }
    }

    var localizedLabel: String {
        NSLocalizedString(labelKey, comment: "")
    }
}

enum PrimaryLayerOption: String, CaseIterable, Identifiable {
    case radar
    case satellite
    case cyclosm

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .radar:
            return "layer_radar"
        case .satellite:
            return "layer_satellite"
        case .cyclosm:
            return "layer_cyclosm"
        }
    }

    var localizedLabel: String {
        NSLocalizedString(labelKey, comment: "")
    }
}
