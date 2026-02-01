import SwiftUI

struct TimelineControls: View {
    let timestamps: [TimeInterval]
    @Binding var selectedIndex: Int
    @Binding var isPlaying: Bool

    private var maxIndex: Int {
        max(timestamps.count - 1, 0)
    }

    private var selectedTimestamp: TimeInterval? {
        guard !timestamps.isEmpty else { return nil }
        let index = min(max(selectedIndex, 0), maxIndex)
        return timestamps[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let timeLabel {
                    Text(timeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(LocalizedStringKey("timeline_no_frames"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(isPlaying ? LocalizedStringKey("timeline_live") : LocalizedStringKey("timeline_paused"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(action: { isPlaying.toggle() }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .accessibilityIdentifier("TimelinePlay")

                if maxIndex > 0 {
                    Slider(value: Binding(
                        get: { Double(selectedIndex) },
                        set: { selectedIndex = Int($0) }
                    ), in: 0...Double(maxIndex), step: 1)
                    .controlSize(.small)
                    .frame(height: 24)
                    .frame(maxWidth: .infinity)
                } else {
                    Slider(value: .constant(0), in: 0...1, step: 1)
                        .disabled(true)
                        .controlSize(.small)
                        .frame(height: 24)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .liquidGlass(cornerRadius: 16, material: .thick)
        .padding(.horizontal, 4)
    }

    private var timeLabel: String? {
        guard let ts = selectedTimestamp else { return nil }
        let date = Date(timeIntervalSince1970: ts)
        return TimelineControls.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
