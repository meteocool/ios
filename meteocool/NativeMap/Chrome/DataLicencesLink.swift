//
//  DataLicencesLink.swift
//  meteocool
//
//  The small "Data Licenses" link in the map's bottom-right corner.
//

import SwiftUI

/// Small print across from Apple's logo and Legal link, as Apple's Maps puts
/// its own: opens Data Licences (`DataLicencesViewController`).
struct DataLicencesLink: View {
    @ObservedObject var model: NativeMapModel
    let open: () -> Void

    var body: some View {
        let theme = ChromeTheme(dark: model.isDark)
        Button(action: open) {
            Text(NSLocalizedString("data_licences", comment: "licence"))
                .scaledFont(10, weight: .medium, relativeTo: .caption2)
                .foregroundStyle(theme.text2)
                // A halo, so it reads over the radar as well as the map.
                .shadow(color: theme.dark ? .black.opacity(0.6) : .white.opacity(0.9), radius: 1)
                .hitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isLink)
        .accessibilityIdentifier("map.dataLicences")
    }
}
