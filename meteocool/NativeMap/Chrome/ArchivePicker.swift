//
//  ArchivePicker.swift
//  meteocool
//
//  The archive's sheet: which past window the map is used in (ng's
//  `doc/archive.md`, "How the window is chosen").
//

import SwiftUI

/// What the archive keeps, and the day, start and length chosen in it.
@MainActor
final class ArchivePickerState: ObservableObject {
    enum Phase: Equatable {
        case loading
        /// `/v3/archive` answered 404: nothing is kept yet.
        case empty
        case failed
        case ready(ArchiveCoverage)
    }

    @Published private(set) var phase = Phase.loading
    /// The day; only its date counts.
    @Published var day = Date()
    /// The start; only its time of day counts, on the five-minute grid.
    @Published var start = Date() {
        didSet {
            let snapped = Self.snapped(start)
            if snapped != start { start = snapped }
        }
    }
    @Published var hours = 3

    private let url: URL
    private let fetch: (URL, @escaping @MainActor (Data?, Int?) -> Void) -> Void
    private let current: RadarWindow?

    init(url: URL, fetch: @escaping (URL, @escaping @MainActor (Data?, Int?) -> Void) -> Void, current: RadarWindow?) {
        self.url = url
        self.fetch = fetch
        self.current = current
        if let current { choose(current) }
    }

    func load() {
        phase = .loading
        fetch(url) { [weak self] data, status in
            guard let self else { return }
            if let coverage = data.flatMap(ArchiveCoverage.decode) {
                if self.current == nil, case .loading = self.phase, let latest = RadarWindow(ending: coverage.until, hours: 3) {
                    // The newest three hours, until the reader picks.
                    self.choose(coverage.window(start: latest.start, hours: 3) ?? latest)
                }
                self.phase = .ready(coverage)
            } else {
                self.phase = status == 404 ? .empty : .failed
            }
        }
    }

    /// The window chosen, kept inside what the archive holds.
    var window: RadarWindow? {
        guard case .ready(let coverage) = phase else { return nil }
        let calendar = Calendar.current
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        let time = calendar.dateComponents([.hour, .minute], from: start)
        parts.hour = time.hour
        parts.minute = time.minute
        guard let date = calendar.date(from: parts) else { return nil }
        return coverage.window(start: Int(date.timeIntervalSince1970), hours: hours)
    }

    private func choose(_ window: RadarWindow) {
        let date = Date(timeIntervalSince1970: TimeInterval(window.start))
        day = date
        start = date
        hours = RadarWindow.lengths.min { abs(Double($0) - window.hours) < abs(Double($1) - window.hours) } ?? 3
    }

    private static func snapped(_ date: Date) -> Date {
        let seconds = Int(date.timeIntervalSince1970)
        let on = RadarWindow.grid(seconds + RadarWindow.stepSeconds / 2)
        return seconds == on ? date : Date(timeIntervalSince1970: TimeInterval(on))
    }
}

/// A day the archive covers, a start time and a length, and Open.
struct ArchivePicker: View {
    @ObservedObject var state: ArchivePickerState
    let open: (RadarWindow) -> Void
    /// Back to live, offered while a window is open.
    let live: (() -> Void)?
    let close: () -> Void

    private func s(_ key: String, _ english: String) -> String {
        NSLocalizedString(key, value: english, comment: "")
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(s("native_map_archive", "Archive"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: close) { Image(systemName: "xmark") }
                            .accessibilityLabel(CoreStrings.t("close"))
                            .accessibilityIdentifier("nativeMap.archive.close")
                    }
                    if case .ready = state.phase {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(s("native_map_archive_open", "Open")) {
                                if let window = state.window { open(window) }
                            }
                            .disabled(state.window == nil)
                            .accessibilityIdentifier("nativeMap.archive.open")
                        }
                    }
                }
        }
        .task { state.load() }
        // A container: its own children keep their identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nativeMap.archive.sheet")
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView {
                Label(s("native_map_archive_empty_title", "Nothing Kept Yet"), systemImage: "calendar.badge.clock")
            } description: {
                Text(s("native_map_archive_empty", "The archive is empty. Once it starts, the radar, lightning, storms and stations are kept."))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("nativeMap.archive.empty")
        case .failed:
            ContentUnavailableView {
                Label(s("native_map_archive_failed_title", "Archive Unavailable"), systemImage: "wifi.exclamationmark")
            } description: {
                Text(s("native_map_archive_failed", "The archive could not be reached."))
            } actions: {
                Button(s("native_map_archive_retry", "Try Again")) { state.load() }
                    .buttonStyle(.bordered)
            }
        case .ready(let coverage):
            form(coverage)
        }
    }

    private func form(_ coverage: ArchiveCoverage) -> some View {
        let first = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(coverage.since)))
        let last = Date(timeIntervalSince1970: TimeInterval(coverage.until))
        return Form {
            Section {
                DatePicker(s("native_map_archive_day", "Day"), selection: $state.day, in: first ... last, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .accessibilityIdentifier("nativeMap.archive.day")
            }
            Section {
                DatePicker(s("native_map_archive_start", "Start"), selection: $state.start, displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("nativeMap.archive.start")
                Picker(s("native_map_archive_length", "Length"), selection: $state.hours) {
                    ForEach(RadarWindow.lengths, id: \.self) { hours in
                        Text(String(format: s("native_map_archive_hours", "%d h"), hours)).tag(hours)
                    }
                }
                .accessibilityIdentifier("nativeMap.archive.length")
            } footer: {
                if let window = state.window {
                    Text(window.summary())
                        .accessibilityIdentifier("nativeMap.archive.summary")
                }
            }
            Section {
                Text(String(format: s("native_map_archive_kept", "Kept from %1$@ to %2$@."),
                            RadarWindow.dateTime(coverage.since), RadarWindow.dateTime(coverage.until)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let live {
                    Button(s("native_map_archive_back", "Back to Live"), action: live)
                        .accessibilityIdentifier("nativeMap.archive.live")
                }
            }
        }
    }
}
