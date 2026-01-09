import Observation

@Observable
final class AppState {
    enum Capability: String, CaseIterable, Identifiable {
        case radar
        case satellite
        case lightning
        case precipTypes
        case aerosols

        var id: String { rawValue }

        var labelKey: String {
            switch self {
            case .radar:
                return "capability_radar"
            case .satellite:
                return "capability_satellite"
            case .lightning:
                return "capability_lightning"
            case .precipTypes:
                return "capability_precip_types"
            case .aerosols:
                return "capability_aerosols"
            }
        }
    }

    var activeCapability: Capability = .radar
}
