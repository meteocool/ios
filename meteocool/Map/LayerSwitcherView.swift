import SwiftUI

struct LayerSwitcherView: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsStore.self) private var settings

    @Environment(\.dismiss) private var dismiss

    private var activeLayer: PrimaryLayerOption {
        if settings.mapBaseLayer == .cyclosm {
            return .cyclosm
        }
        return appState.activeCapability == .satellite ? .satellite : .radar
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(PrimaryLayerOption.allCases) { option in
                        Button {
                            select(option)
                        } label: {
                            HStack {
                                Text(LocalizedStringKey(option.labelKey))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if activeLayer == option {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .accessibilityIdentifier("Layer\(option.rawValue)")
                    }
                } header: {
                    Text(LocalizedStringKey("settings_section_layers"))
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.visible)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationTitle(LocalizedStringKey("settings_section_layers"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .font(.title2)
                    }
                    .accessibilityLabel(LocalizedStringKey("Close"))
                }
            }
        }
    }

    private func select(_ option: PrimaryLayerOption) {
        switch option {
        case .radar:
            appState.activeCapability = .radar
            if settings.mapBaseLayer == .cyclosm {
                settings.mapBaseLayer = .system
            }
        case .satellite:
            appState.activeCapability = .satellite
            if settings.mapBaseLayer == .cyclosm {
                settings.mapBaseLayer = .system
            }
        case .cyclosm:
            appState.activeCapability = .radar
            settings.mapBaseLayer = .cyclosm
        }
        dismiss()
    }
}
