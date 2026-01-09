import SwiftUI

struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            content
        }
    }
}
