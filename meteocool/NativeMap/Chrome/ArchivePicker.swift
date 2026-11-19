//
//  ArchivePicker.swift
//  meteocool
//
//  The archive's sheet: which past window the map is used in (core's
//  `ArchivePicker.svelte`, ng's `doc/archive.md`).
//

import SwiftUI
import UIKit

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
    /// The day: its midnight. Another day keeps the start's time of day,
    /// inside what that day has.
    @Published var day = Date() {
        didSet { if day != oldValue { minute = clamped(minute) } }
    }
    /// The start, in minutes after the day's midnight, on the five-minute grid.
    @Published var minute = 0
    @Published var hours = RadarWindow.defaultHours

    private let url: URL
    private let fetch: (URL, @escaping @MainActor (Data?, Int?) -> Void) -> Void
    private let current: RadarWindow?
    private let calendar = Calendar.current

    init(url: URL, fetch: @escaping (URL, @escaping @MainActor (Data?, Int?) -> Void) -> Void, current: RadarWindow?) {
        self.url = url
        self.fetch = fetch
        self.current = current
    }

    func load() {
        phase = .loading
        fetch(url) { [weak self] data, status in
            guard let self else { return }
            if let coverage = data.flatMap(ArchiveCoverage.decode) {
                // Where it starts: the window open now, or the last few hours kept.
                let seed = coverage.seed(open: self.current)
                self.hours = seed.hours
                self.phase = .ready(coverage)
                self.start = Date(timeIntervalSince1970: TimeInterval(seed.start))
            } else {
                self.phase = status == 404 ? .empty : .failed
            }
        }
    }

    private var coverage: ArchiveCoverage? {
        if case .ready(let coverage) = phase { return coverage }
        return nil
    }

    /// The days that can be chosen, first to last (every one between is kept).
    var days: ClosedRange<Date>? {
        guard let days = coverage?.days(calendar: calendar), let first = days.first, let last = days.last else { return nil }
        // To the last day's end: the calendar keeps the time of day it was on.
        return Date(timeIntervalSince1970: TimeInterval(first)) ... Date(timeIntervalSince1970: TimeInterval(last + 86_399))
    }

    /// The minutes of the chosen day a window may start at.
    var minutes: ClosedRange<Int> {
        coverage?.startMinutes(day: midnight, calendar: calendar) ?? 0 ... 1435
    }

    private var midnight: Int { Int(calendar.startOfDay(for: day).timeIntervalSince1970) }

    private func clamped(_ minute: Int) -> Int { min(max(minute, minutes.lowerBound), minutes.upperBound) }

    /// The start as a date, for the system's time picker; setting it keeps
    /// the day and snaps to the grid.
    var start: Date {
        get { calendar.date(byAdding: .minute, value: minute, to: calendar.startOfDay(for: day)) ?? day }
        set {
            day = calendar.startOfDay(for: newValue)
            let parts = calendar.dateComponents([.hour, .minute], from: newValue)
            minute = clamped(((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 5 * 5)
        }
    }

    /// The earliest and latest start on the chosen day.
    var startRange: ClosedRange<Date> {
        let midnight = calendar.startOfDay(for: day)
        let first = calendar.date(byAdding: .minute, value: minutes.lowerBound, to: midnight) ?? midnight
        let last = calendar.date(byAdding: .minute, value: minutes.upperBound, to: midnight) ?? midnight
        return first ... max(first, last)
    }

    /// The window the choices make, kept inside the archive; nil where none can be.
    var window: RadarWindow? {
        coverage?.pick(start: Int(start.timeIntervalSince1970), hours: hours)
    }
}

/// A day the archive keeps on the system's calendar, a start on its time
/// picker on the five-minute grid, a length, and Open. core draws its own
/// month and drum wheels (`ArchiveCalendar.svelte`, `Wheel.svelte`) because
/// the web has neither; here they are the system's.
struct ArchivePicker: View {
    @ObservedObject var state: ArchivePickerState
    let open: (RadarWindow) -> Void
    /// Back to live, offered while a window is open.
    let live: (() -> Void)?
    let close: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(CoreStrings.t("chrome.archive.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: close) { Image(systemName: "xmark") }
                            .accessibilityLabel(CoreStrings.t("close"))
                            .accessibilityIdentifier("nativeMap.archive.close")
                    }
                    if case .ready = state.phase {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(CoreStrings.t("chrome.archive.open")) {
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
            VStack(spacing: 12) {
                ProgressView()
                Text(CoreStrings.t("chrome.archive.loading")).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView {
                Label(CoreStrings.t("chrome.archive.title"), systemImage: "calendar.badge.clock")
            } description: {
                Text(CoreStrings.t("chrome.archive.empty"))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("nativeMap.archive.empty")
        case .failed:
            ContentUnavailableView {
                Label(CoreStrings.t("chrome.archive.title"), systemImage: "wifi.exclamationmark")
            } description: {
                Text(CoreStrings.t("chrome.archive.failed"))
            } actions: {
                Button(CoreStrings.t("chrome.archive.retry")) { state.load() }
                    .buttonStyle(.bordered)
            }
        case .ready:
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                if let days = state.days {
                    DatePicker(CoreStrings.t("chrome.archive.day"), selection: $state.day, in: days, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .accessibilityIdentifier("nativeMap.archive.day")
                }
            } header: {
                Text(CoreStrings.t("chrome.archive.lede")).textCase(nil)
            }
            Section {
                LabeledContent(CoreStrings.t("chrome.archive.start")) {
                    StartPicker(date: Binding(get: { state.start }, set: { state.start = $0 }), range: state.startRange,
                                label: CoreStrings.t("chrome.archive.start"))
                }
                Picker(CoreStrings.t("chrome.archive.length"), selection: $state.hours) {
                    ForEach(RadarWindow.lengths, id: \.self) { hours in
                        Text(CoreStrings.t("chrome.archive.hours", ["hours": hours])).tag(hours)
                    }
                }
                .accessibilityIdentifier("nativeMap.archive.length")
            } footer: {
                if let window = state.window {
                    Text(summary(window))
                        .accessibilityIdentifier("nativeMap.archive.summary")
                }
            }
            if let live {
                Section {
                    Button(CoreStrings.t("chrome.archive.back_to_live"), action: live)
                        .accessibilityIdentifier("nativeMap.archive.live")
                }
            }
        }
    }

    /// "Thu 5 Nov, 14:05 to 17:05, 37 frames".
    private func summary(_ window: RadarWindow) -> String {
        CoreStrings.t("chrome.archive.summary", [
            "from": RadarWindow.dateTime(window.start, weekday: true),
            "to": StatusPill.clock(window.end),
            "steps": window.steps.count,
        ])
    }
}

/// The system's time picker on the five-minute grid, between the day's
/// first and last start: SwiftUI's own has no minute interval.
private struct StartPicker: UIViewRepresentable {
    @Binding var date: Date
    let range: ClosedRange<Date>
    let label: String

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .compact
        picker.minuteInterval = RadarWindow.stepSeconds / 60
        picker.accessibilityLabel = label
        picker.accessibilityIdentifier = "nativeMap.archive.start"
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        picker.setContentHuggingPriority(.required, for: .horizontal)
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {
        context.coordinator.date = $date
        picker.minimumDate = range.lowerBound
        picker.maximumDate = range.upperBound
        if picker.date != date { picker.date = date }
    }

    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

    @MainActor
    final class Coordinator: NSObject {
        var date: Binding<Date>
        init(date: Binding<Date>) { self.date = date }
        @objc func changed(_ picker: UIDatePicker) { date.wrappedValue = picker.date }
    }
}
